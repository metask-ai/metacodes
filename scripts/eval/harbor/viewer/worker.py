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
from scripts.eval.harbor.viewer import builds, releases
from scripts.eval.harbor.profiling import TimingRelay, auth_for, upstream_for


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
    """Resolve the bundle and account key, then start the timing relay."""
    if spec.get("version"):
        bundle = releases.bundle(spec["version"], spec["release_cache"], spec.get("release_base"))
        spec = {**spec, "bundle": str(bundle)}
    elif spec.get("ref"):
        cancel = Path(spec["jobs_dir"]) / ".bench-runs" / (spec["name"] + ".cancel")
        bundle, info = builds.bundle(spec["ref"], spec["build_cache"], spec.get("source_repo"),
                                     cancelled=cancel.exists)
        spec = {**spec, "bundle": str(bundle),
                "metacodes_version": f"{info['version']} (git {spec['ref']} @ {info['commit'][:12]})"}
    if spec.get("auth_mode") == "metask":
        # Resolve the key belonging to this model's group, without
        # changing the interactive CLI selection or forwarding OAuth.
        account = Account(spec.get("account_state_dir"), spec.get("account_gateway"))
        env["METASK_API_KEY"] = account.credential(spec["model"], key_id=spec.get("account_key_id"))
        spec = {**spec, "account_gateway": account.gateway}
    relay = None
    upstream = upstream_for(spec) if spec.get("metrics_enabled", True) else None
    if upstream:
        header, prefix = auth_for(spec)
        relay = TimingRelay(upstream, env[spec["key_env"]],
                            Path(spec["jobs_dir"]) / spec["name"] / ".bench-metrics",
                            bind=spec.get("metrics_bind") or "172.17.0.1",
                            auth_header=header, auth_prefix=prefix, tls=True).__enter__()
        spec = {**spec, "metrics_proxy": relay.url, "metrics_ca": str(relay.ca_path)}
    return spec, relay


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
        if spec.get("metacodes_version"):
            record["metacodes_version"] = spec["metacodes_version"]
        if spec_path.with_suffix(".cancel").exists():
            record.update(status="cancelled", finished_at=now())
            return 1
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
    except (releases.ReleaseError, builds.BuildError) as exc:
        if spec_path.with_suffix(".cancel").exists():
            record.update(status="cancelled", finished_at=now())
        else:
            record.update(status="failed", error=str(exc), finished_at=now())
    except Exception as exc:
        record.update(status="failed", error=type(exc).__name__, finished_at=now())
    finally:
        if relay:
            relay.__exit__(None, None, None)
        atomic_json(record_path, record)
    return 0 if record.get("status") == "finished" else 1


if __name__ == "__main__":
    sys.exit(main())
