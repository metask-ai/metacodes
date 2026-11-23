"""One durable Bench launch. Invoked by RunManager, never from browser input."""
from __future__ import annotations

import concurrent.futures
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from scripts.eval.harbor.bench.runner import atomic_json, now, runtime_env
from scripts.eval.harbor.bench.account import Account
from scripts.eval.harbor.profiling import (JUDGE_TOKEN_ENV, TimingRelay, auth_for, judge_argv, placeholder,
                                           route_problem, upstream_for)
from scripts.eval.harbor.bench import credentials
from scripts.eval.harbor.store.ingest import WorkerSync
from scripts.eval.harbor.bench.executors import RemoteRun, signal_group, tunnel_unbound


def command(spec):
    # Specs written before suites carried only the Terminal-Bench 2.1 ref.
    dataset_args = spec.get("dataset_args") or ["-d", spec["dataset"]]
    argv = [spec["harbor"], "run", *dataset_args,
            "-a", "scripts.eval.harbor.metacodes_agent:MetacodesAgent", "-m", spec["model"],
            "--ak", "bundle=" + spec["bundle"], "--ae", spec["key_env"] + "=${" + spec["key_env"] + "}",
            "-k", str(spec["attempts"]), "-n", str(spec["concurrency"]),
            "--max-retries", "0", "-o", spec["jobs_dir"], "--job-name", spec["name"], "-y"]
    if spec.get("provider_config"):
        argv += ["--ak", "config=" + spec["provider_config"]]
    if spec.get("auth_mode") == "metask" and spec.get("account_gateway"):
        argv += ["--ak", "account_gateway=" + spec["account_gateway"]]
    if spec.get("reasoning_effort"):
        argv += ["--ak", "reasoning_effort=" + spec["reasoning_effort"]]
    if spec.get("features"):
        argv += ["--ak", "features=" + ",".join(spec["features"])]
    if spec.get("metrics_proxy"):
        argv += ["--ak", "metrics_proxy=" + spec["metrics_proxy"]]
    if spec.get("metrics_ca"):
        argv += ["--ak", "metrics_ca=" + spec["metrics_ca"]]
    if spec.get("judge") and spec.get("metrics_proxy"):
        # The verifier's LLM judge: relay route, placeholder *name*, model.
        argv += judge_argv(spec["judge"], spec["metrics_proxy"])
    filters = spec.get("task_filters") or ["terminal-bench/" + task for task in spec["tasks"]]
    for pattern in filters:
        argv += ["-i", pattern]
    return argv


def child_process(spec, env):
    """(argv, cwd, env) of the evaluation child for this spec's runner."""
    if spec.get("runner") == "workbuddy":
        from scripts.eval.harbor.suites import workbuddy
        return workbuddy.launch(spec, env)
    return command(spec), None, env


class LaunchRefused(ValueError):
    """A launch refused for a reason the run record states."""


def prepare(spec, env):
    """Resolve the run's credential and start its relay.

    Returns (spec, relay or RemoteRun or None, credential source or None).
    Harbor and its task containers see only a random run-scoped placeholder
    in `key_env`; the relay beside the Docker daemon accepts exactly that
    placeholder and forwards upstream with the real, current credential."""
    if spec.get("runner") == "workbuddy":
        if (spec.get("executor") or {}).get("kind") == "ssh":
            # The node runs its own checkout behind a relay that holds the
            # access token; a session login is refreshed here and pushed.
            try:
                source, gateway = credentials.for_run(spec, env)
            except ValueError as exc:  # account messages are user-facing, secret-free
                raise LaunchRefused(str(exc)) from None
            spec = {**spec, "account_gateway": gateway}
            remote = RemoteRun(spec)
            return {**spec, "remote_spec_path": remote.upload_run(remote.remote_spec())}, remote, source
        # WorkBuddy's own host proxy holds the key; its task containers get
        # only that proxy's route token.
        if spec.get("auth_mode") == "metask":
            account = Account(spec.get("account_state_dir"), spec.get("account_gateway"))
            env["METASK_API_KEY"] = account.credential(spec["model"], key_id=spec.get("account_key_id"))
            spec = {**spec, "account_gateway": account.gateway}
        return spec, None, None
    problem = route_problem(spec)
    if problem:
        raise LaunchRefused(problem)
    try:
        source, gateway = credentials.for_run(spec, env)
    except ValueError as exc:  # account messages are user-facing, secret-free
        raise LaunchRefused(str(exc)) from None
    if gateway:
        spec = {**spec, "account_gateway": gateway}
    upstream, auth = upstream_for(spec), auth_for(spec)
    token = placeholder(spec["name"])
    env[spec["key_env"]] = token  # the only credential Harbor ever sees
    judge_token, judge_secret = None, None
    if spec.get("judge"):
        judge_secret = judge_credential(spec, source)
        judge_token = placeholder(spec["name"] + "judge")
        # Harbor resolves `${JUDGE_TOKEN_ENV}` for the verifier; a real
        # judge key in the service environment never reaches Harbor.
        for role in ("api_key", "base_url", "model"):
            env.pop(spec["judge"]["env"][role], None)
        env[JUDGE_TOKEN_ENV] = judge_token
    record = bool(spec.get("metrics_enabled", True))
    if (spec.get("executor") or {}).get("kind") == "ssh":
        # The relay must sit beside the Docker daemon that runs the trials,
        # so the remote driver starts it; here only files are staged.
        remote = RemoteRun(spec)
        remote.judge_credential = judge_secret  # a fixed key over stdin, or None
        try:
            remote.stage()
        except ValueError as exc:  # staging messages are user-facing, secret-free
            raise LaunchRefused(str(exc)) from None
        record = record and spec["executor"].get("metrics_enabled", True)
        remote_spec = remote.remote_spec(upstream, auth, record=record)
        return {**spec, "remote_spec_path": remote.upload_run(remote_spec)}, remote, source
    relay = TimingRelay(upstream, source, Path(spec["jobs_dir"]) / spec["name"] / ".bench-metrics",
                        bind=spec.get("metrics_bind") or "172.17.0.1",
                        public_host=spec.get("metrics_host"),
                        auth_header=auth[0], auth_prefix=auth[1], tls=True,
                        token=token, record=record, judge_token=judge_token,
                        judge_credential=judge_secret).__enter__()
    spec = {**spec, "metrics_proxy": relay.url, "metrics_ca": str(relay.ca_path)}
    return spec, relay, source


def judge_credential(spec, source):
    """The fixed key the judge's requests carry upstream, or None to use the
    run's own credential (a session login serves every model).

    Refuses the launch when the account's model directory lacks the judge."""
    try:
        return credentials.for_judge(spec, source)
    except ValueError as exc:  # account messages are user-facing, secret-free
        raise LaunchRefused(str(exc)) from None


def credential_failed(source):
    return bool(source is not None and getattr(source, "failed", False))


def stamp_credential(record, source):
    """The run record's non-secret view of its credential."""
    if source is not None:
        record["credential"] = {"container": "placeholder", **source.status()}


def supervise_remote(remote, spec, env, spec_path, record_path, record, source=None):
    """Run Harbor on an SSH executor: heartbeat, cancel, background sync.

    The receipt is rewritten every two seconds whatever the copy-back is
    doing (RunManager shows a receipt older than 30 seconds as interrupted),
    and the run is `finished` only when the final copy was verified
    complete; otherwise the receipt says where the results still are."""
    secret_env = {}
    if spec.get("runner") != "workbuddy":
        # The run's key plus the suite's execution-host variables (a judge
        # key), all over the SSH channel's stdin. A WorkBuddy node needs only
        # the credential for its relay.
        secret_env = {name: env[name] for name in spec.get("forward_env") or () if env.get(name)}
        secret_env[spec["key_env"]] = env[spec["key_env"]]  # the placeholder
        if spec.get("judge"):
            secret_env[JUDGE_TOKEN_ENV] = env[JUDGE_TOKEN_ENV]  # the judge's placeholder
    # The real access token goes beside it for the remote relay only; a
    # refreshed one follows on the same channel. The refresh token stays here.
    if getattr(source, "refreshing", False):
        source.subscribe(remote.push_credential)  # first: no refresh is missed
    remote.start(secret_env, spec["remote_spec_path"], credential=source.current())
    record.update(status="running", executor=spec["executor"]["name"])
    remote.start_sync()
    cancel_path = spec_path.with_suffix(".cancel")
    cancelled_at = None
    expired = False
    last_write = 0.0
    while (remote.process.poll() is None
           or cancelled_at is None and remote.retry_tunnel(secret_env, source.current)):
        now_s = time.monotonic()
        if credential_failed(source) and cancelled_at is None:
            # Fail fast instead of burning the remaining tasks on 401s.
            expired = True
            record["error"] = source.error
            cancelled_at = now_s
            remote.cancel()
        if cancel_path.exists() and cancelled_at is None:
            cancelled_at = now_s
            record["status"] = "cancelling"
            remote.cancel()
        if cancelled_at and now_s - cancelled_at > 40:
            remote.hang_up()
        if cancelled_at and now_s - cancelled_at > 60:
            remote.process.kill()
        if now_s - remote.last_event > remote.HEARTBEAT_TIMEOUT and cancelled_at is None:
            # A silent channel: closing it makes the driver stop Harbor.
            record["error"] = "远程执行机器心跳超时"
            cancelled_at = now_s
            remote.hang_up()
        if now_s - last_write > 2:
            stamp_credential(record, source)
            atomic_json(record_path, record)
            last_write = time.monotonic()
        time.sleep(0.25)
    remote.hang_up()
    remote.close()  # the session (and its ssh -R) is over: stop the egress proxy
    stamp_credential(record, source)
    # Copy what is left beside the heartbeat; a cancel now stops the copy
    # (the results stay on the executor and the receipt says so). A lost
    # channel (no exit event) tries briefly: the host is likely unreachable.
    stop = threading.Event()
    timeout = None if remote.exit_code() is not None else min(remote.final_timeout, 120)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        copying = pool.submit(remote.final_sync, stop, timeout)
        while not copying.done():
            if cancel_path.exists() and cancelled_at is None:
                stop.set()
            if time.monotonic() - last_write > 2:
                atomic_json(record_path, record)
                last_write = time.monotonic()
            concurrent.futures.wait([copying], timeout=0.25)
    try:
        complete = copying.result()
    except Exception as exc:  # never lose the run's outcome to the copy
        remote.log(f"同步远程作业目录失败：{type(exc).__name__}: {exc}")
        complete = False
    code = remote.exit_code()
    if code is None:
        lost = remote.error_message() or "SSH 连接中断"
        if remote.forward_was_refused():
            lost = tunnel_unbound(remote.executor, remote.tunnel_ports)
        elif remote.tunnel_port is not None and not remote.events and remote.process.returncode == 255:
            lost += (f"（会话带有 ssh -R 127.0.0.1:{remote.tunnel_port} 反向转发；"
                     "若该端口在执行机器上已被占用，重新启动评测会换一个端口）")
        record.update(status="cancelled" if cancelled_at and not record.get("error") else "failed",
                      exit_code=remote.process.returncode, finished_at=now(),
                      error=record.get("error") or (lost if not cancelled_at else None))
    else:
        record.update(status="cancelled" if cancelled_at else ("finished" if code == 0 else "failed"),
                      exit_code=code, finished_at=now())
    if expired:
        record["status"] = "failed"
    if not complete:
        note = remote.results_note()
        message = (f"结果未能完整同步回本机，仍在执行机器 {note['executor']} 的 {note['path']}；"
                   f"同步后再查看：{note['retry']}")
        if record["status"] == "finished":
            record["status"] = "failed"
        record.update(remote_results={**note, "message": message},
                      error="；".join(e for e in (record.get("error"), message) if e))


def main(argv=None):
    spec_path = Path((argv or sys.argv[1:])[0])
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    record_path = spec_path.with_suffix(".json")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record.update(status="starting", started_at=now())
    atomic_json(record_path, record)
    process = None
    relay = None
    source = None
    remote = None
    # Ingests the job into the evaluation store while it runs and at the end.
    sync = WorkerSync(spec)
    sync.start()
    try:
        env = runtime_env()
        # Account lookups can outlast RunManager's 30 second liveness window.
        # Prepare beside the heartbeat, so a live worker is never shown as
        # interrupted (which would admit a second launch). A cancel meanwhile
        # waits for the lookup in flight, which may be rotating the stored
        # OAuth token, and then ends the run before Harbor starts.
        last_write = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            preparing = pool.submit(prepare, spec, env)
            while not preparing.done():
                if spec_path.with_suffix(".cancel").exists() and record["status"] != "cancelling":
                    record["status"] = "cancelling"
                    last_write = 0.0
                if time.monotonic() - last_write > 2:
                    atomic_json(record_path, record)
                    last_write = time.monotonic()
                concurrent.futures.wait([preparing], timeout=0.25)
        spec, relay, source = preparing.result()
        if getattr(source, "refreshing", False):
            source.keep()
        stamp_credential(record, source)
        if isinstance(relay, RemoteRun):
            # Not a context manager: nothing to close before it starts.
            remote, relay = relay, None
        if spec_path.with_suffix(".cancel").exists():
            record.update(status="cancelled", finished_at=now())
            return 1
        if remote is not None:
            supervise_remote(remote, spec, env, spec_path, record_path, record, source)
            return 0 if record.get("status") == "finished" else 1
        argv, cwd, child_env = child_process(spec, env)
        process = subprocess.Popen(argv, env=child_env, cwd=cwd, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
        record["status"] = "running"
        cancelled = False
        expired = False
        last_write = 0.0
        stop_at = None
        while process.poll() is None:
            stopping = None
            if credential_failed(source) and not (cancelled or expired):
                # Fail fast instead of burning the remaining tasks on 401s.
                expired = True
                record["error"] = source.error
                stopping = "failed"
            elif spec_path.with_suffix(".cancel").exists() and not (cancelled or expired):
                cancelled = True
                record["status"] = "cancelling"
                stopping = "cancelling"
            if stopping:
                stop_at = time.monotonic()
                if os.name == "nt":
                    process.terminate()
                else:
                    signal_group(process, signal.SIGINT)
            if stop_at and time.monotonic() - stop_at > 20:
                if os.name == "nt":
                    process.kill()
                else:
                    signal_group(process, signal.SIGKILL)
            if time.monotonic() - last_write > 2:
                stamp_credential(record, source)
                atomic_json(record_path, record)
                last_write = time.monotonic()
            time.sleep(0.25)
        record.update(status="failed" if expired else "cancelled" if cancelled else
                      ("finished" if process.returncode == 0 else "failed"),
                      exit_code=process.returncode, finished_at=now())
    except LaunchRefused as exc:
        record.update(status="failed", error=str(exc), finished_at=now())
    except Exception as exc:
        record.update(status="failed", error=type(exc).__name__, finished_at=now())
    finally:
        if source is not None and hasattr(source, "stop"):
            source.stop()
        stamp_credential(record, source)
        if relay:
            relay.__exit__(None, None, None)
        if remote is not None:
            remote.close()  # the run's egress proxy, if any
        if spec.get("runner") == "workbuddy":
            from scripts.eval.harbor.suites import workbuddy
            try:
                workbuddy.finish(spec)
            except OSError:
                record["error"] = record.get("error") or "WorkBuddy 临时配置清理失败"
        # The final ingest, run row included, precedes the terminal receipt
        # (and follows the WorkBuddy job's finished_at stamp), so a finished
        # run's results are already in the store and nothing writes them once
        # the run has ended; touching the receipt keeps the worker visibly
        # alive meanwhile.
        sync.finish(lambda: os.utime(record_path), record)
        atomic_json(record_path, record)
    return 0 if record.get("status") == "finished" else 1


if __name__ == "__main__":
    sys.exit(main())
