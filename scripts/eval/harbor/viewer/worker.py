"""One durable Bench launch. Invoked by RunManager, never from browser input."""
from __future__ import annotations

import concurrent.futures
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from scripts.eval.harbor.viewer.runner import atomic_json, now, runtime_env
from scripts.eval.harbor.viewer.account import Account
from scripts.eval.harbor.profiling import TimingRelay, auth_for, upstream_for
from scripts.eval.harbor.viewer.executors import RemoteRun


def command(spec):
    argv = [spec["harbor"], "run", "-d", spec["dataset"],
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
    if spec.get("metrics_proxy"):
        argv += ["--ak", "metrics_proxy=" + spec["metrics_proxy"]]
    if spec.get("metrics_ca"):
        argv += ["--ak", "metrics_ca=" + spec["metrics_ca"]]
    for task in spec["tasks"]:
        argv += ["-i", "terminal-bench/" + task]
    return argv


def prepare(spec, env):
    """Resolve the account key and start the timing relay for one launch."""
    if spec.get("auth_mode") == "metask":
        # Resolve the key belonging to this model's group, without
        # changing the interactive CLI selection or forwarding OAuth.
        account = Account(spec.get("account_state_dir"), spec.get("account_gateway"))
        env["METASK_API_KEY"] = account.credential(spec["model"], key_id=spec.get("account_key_id"))
        spec = {**spec, "account_gateway": account.gateway}
    relay = None
    upstream = upstream_for(spec) if spec.get("metrics_enabled", True) else None
    if (spec.get("executor") or {}).get("kind") == "ssh":
        # The relay must sit beside the Docker daemon that runs the trials,
        # so the remote driver starts it; here only files are staged.
        remote = RemoteRun(spec)
        remote.stage()
        upstream = upstream if spec["executor"].get("metrics_enabled", True) else None
        remote_spec = remote.remote_spec(upstream, auth_for(spec) if upstream else None)
        return {**spec, "remote_spec_path": remote.upload_run(remote_spec)}, remote
    if upstream:
        header, prefix = auth_for(spec)
        relay = TimingRelay(upstream, env[spec["key_env"]],
                            Path(spec["jobs_dir"]) / spec["name"] / ".bench-metrics",
                            bind=spec.get("metrics_bind") or "172.17.0.1",
                            public_host=spec.get("metrics_host"),
                            auth_header=header, auth_prefix=prefix, tls=True).__enter__()
        spec = {**spec, "metrics_proxy": relay.url, "metrics_ca": str(relay.ca_path)}
    return spec, relay


def supervise_remote(remote, spec, env, spec_path, record_path, record):
    """Run Harbor on an SSH executor: heartbeat, cancel, incremental sync."""
    remote.start({spec["key_env"]: env[spec["key_env"]]}, spec["remote_spec_path"])
    record.update(status="running", executor=spec["executor"]["name"])
    cancelled_at = None
    last_write = last_sync = 0.0
    while remote.process.poll() is None:
        now_s = time.monotonic()
        if spec_path.with_suffix(".cancel").exists() and cancelled_at is None:
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
        if now_s - last_sync > remote.SYNC_INTERVAL:
            remote.sync()
            last_sync = time.monotonic()
        if now_s - last_write > 2:
            atomic_json(record_path, record)
            last_write = time.monotonic()
        time.sleep(0.25)
    remote.hang_up()
    remote.sync()
    code = remote.exit_code()
    if code is None:
        record.update(status="cancelled" if cancelled_at and not record.get("error") else "failed",
                      exit_code=remote.process.returncode, finished_at=now(),
                      error=record.get("error") or ("SSH 连接中断" if not cancelled_at else None))
        return
    record.update(status="cancelled" if cancelled_at else ("finished" if code == 0 else "failed"),
                  exit_code=code, finished_at=now())


def main(argv=None):
    spec_path = Path((argv or sys.argv[1:])[0])
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    record_path = spec_path.with_suffix(".json")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    record.update(status="starting", started_at=now())
    atomic_json(record_path, record)
    process = None
    relay = None
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
        spec, relay = preparing.result()
        if spec_path.with_suffix(".cancel").exists():
            record.update(status="cancelled", finished_at=now())
            return 1
        if isinstance(relay, RemoteRun):
            remote, relay = relay, None
            supervise_remote(remote, spec, env, spec_path, record_path, record)
            return 0 if record.get("status") == "finished" else 1
        process = subprocess.Popen(command(spec), env=env, stdin=subprocess.DEVNULL,
                                   start_new_session=True)
        record["status"] = "running"
        cancelled = False
        last_write = 0.0
        stop_at = None
        while process.poll() is None:
            if spec_path.with_suffix(".cancel").exists() and not cancelled:
                cancelled = True
                record["status"] = "cancelling"
                stop_at = time.monotonic()
                if os.name == "nt":
                    process.terminate()
                else:
                    os.killpg(process.pid, signal.SIGINT)
            if stop_at and time.monotonic() - stop_at > 20:
                if os.name == "nt":
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
            if time.monotonic() - last_write > 2:
                atomic_json(record_path, record)
                last_write = time.monotonic()
            time.sleep(0.25)
        record.update(status="cancelled" if cancelled else ("finished" if process.returncode == 0 else "failed"),
                      exit_code=process.returncode, finished_at=now())
    except Exception as exc:
        record.update(status="failed", error=type(exc).__name__, finished_at=now())
    finally:
        if relay:
            relay.__exit__(None, None, None)
        atomic_json(record_path, record)
    return 0 if record.get("status") == "finished" else 1


if __name__ == "__main__":
    sys.exit(main())
