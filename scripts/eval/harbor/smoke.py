"""Zero-cost end-to-end smoke of the metacodes Harbor adapter.

    python3 -m scripts.eval.harbor.smoke --bundle <linux release prefix>

Runs the real `harbor run` on the fixture task (fixtures/smoke-task) with the
adapter loaded by import path and the scripted endpoint (smoke_provider.py)
standing in for the model.  It passes only when all of these hold:

- the endpoint saw exactly its two scripted requests, the second carrying the
  result of the Bash call the first asked for;
- Harbor's verifier gave the trial reward 1 (the file the Bash call wrote is
  in the task container);
- the adapter wrote an ATIF trajectory holding that Bash call and its result,
  and filled Harbor's token counters from metacodes' `result` event.

Needs Docker and Harbor (`uv tool install harbor`) on a Linux host; no
provider credential and no network beyond the Docker image pull.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from scripts.eval.harbor import command as cmd
from scripts.eval.harbor import smoke_provider as sp
from scripts.eval.harbor.profiling import TimingRelay

REPO = Path(__file__).resolve().parents[3]
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "smoke-task"
AGENT_IMPORT_PATH = "scripts.eval.harbor.metacodes_agent:MetacodesAgent"
# docker0: what `host-gateway` resolves to inside the task container.
DEFAULT_BIND = "172.17.0.1"


def harbor_command(
    *,
    harbor: str,
    bundle: Path,
    config: Path,
    jobs_dir: Path,
    job_name: str,
    metrics_proxy: Optional[str] = None,
    metrics_ca: Optional[str] = None,
    metask_route: bool = False,
) -> List[str]:
    argv = [
        harbor,
        "run",
        "--path", str(FIXTURE),
        "--agent", AGENT_IMPORT_PATH,
        "--model", f"{'metask' if metask_route else sp.SMOKE_PROVIDER}/{sp.SMOKE_MODEL}",
        "--ak", f"bundle={bundle}",
        "--ak", f"config={config}",
        "--ae", f"{'METASK_API_KEY' if metask_route else sp.SMOKE_KEY_ENV}={sp.SMOKE_CREDENTIAL}",
        "--jobs-dir", str(jobs_dir),
        "--job-name", job_name,
        "--n-concurrent", "1",
        "--n-attempts", "1",
        "--max-retries", "0",
        "--yes",
        "--quiet",
    ]
    if metrics_proxy:
        argv += ["--ak", "metrics_proxy=" + metrics_proxy]
    if metrics_ca:
        argv += ["--ak", "metrics_ca=" + metrics_ca]
    return argv


def _trial_dirs(job_dir: Path) -> List[Path]:
    return sorted(path.parent for path in job_dir.glob("*/result.json"))


def _reward(result: Dict[str, Any]) -> Optional[float]:
    verifier = result.get("verifier_result") or {}
    rewards = verifier.get("rewards") if isinstance(verifier, dict) else None
    if isinstance(rewards, dict) and "reward" in rewards:
        return float(rewards["reward"])
    return None


def check_trial(trial_dir: Path) -> List[str]:
    """What is wrong with the trial's recorded outcome (empty when it passed)."""

    problems: List[str] = []
    result = json.loads((trial_dir / "result.json").read_text(encoding="utf-8"))
    if result.get("exception_info"):
        problems.append(f"trial raised: {json.dumps(result['exception_info'])[:600]}")
    reward = _reward(result)
    if reward != 1.0:
        problems.append(f"verifier reward is {reward!r}, expected 1.0")
    agent_dir = trial_dir / "agent"
    trajectory_path = agent_dir / "trajectory.json"
    if not trajectory_path.is_file():
        problems.append("the adapter wrote no trajectory.json")
        return problems
    trajectory = json.loads(trajectory_path.read_text(encoding="utf-8"))
    calls = [
        call
        for step in trajectory.get("steps", [])
        for call in step.get("tool_calls") or []
    ]
    if [call.get("function_name") for call in calls] != ["Bash"]:
        problems.append(f"trajectory tool calls are {calls!r}, expected one Bash call")
    observed = [
        item.get("content")
        for step in trajectory.get("steps", [])
        for item in (step.get("observation") or {}).get("results", [])
    ]
    if not any(sp.EXPECTED_TEXT in str(text) for text in observed):
        problems.append("the trajectory does not carry the Bash result")
    metrics = trajectory.get("final_metrics") or {}
    if not metrics.get("total_prompt_tokens"):
        problems.append("final_metrics has no prompt tokens")
    for name in (cmd.OUTPUT_FILENAME, cmd.TRANSCRIPT_FILENAME):
        if not (agent_dir / name).is_file():
            problems.append(f"agent log {name} is missing")
    return problems


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bundle", type=Path, required=True, help="Linux release-layout prefix")
    parser.add_argument("--harbor", default=shutil.which("harbor") or "harbor")
    parser.add_argument("--bind", default=DEFAULT_BIND, help="address the scripted endpoint listens on")
    parser.add_argument("--jobs-dir", type=Path, help="keep the job here (default: a temp dir)")
    parser.add_argument("--profile", action="store_true", help="verify request-level timing capture")
    parser.add_argument("--metask-route", action="store_true", help="test the built-in Metask route against the local mock (implies --profile)")
    args = parser.parse_args(argv)
    if args.metask_route:
        args.profile = True
        sp.SMOKE_MODEL = "glm-5.3-flash"

    cmd.check_bundle(args.bundle)
    server = sp.SmokeServer(args.bind, 0, bearer=args.metask_route)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
    thread.start()
    scratch = Path(tempfile.mkdtemp(prefix="metacodes-harbor-smoke-"))
    problems: List[str] = ["the smoke did not finish"]
    relay = None
    try:
        config = scratch / "config.json"
        sp.write_config(config, f"http://host.docker.internal:{server.server_port}")
        jobs_dir = (args.jobs_dir or scratch / "jobs").resolve()
        job_name = time.strftime("metacodes-smoke-%Y%m%d-%H%M%S")
        if args.profile:
            relay = TimingRelay(f"http://{args.bind}:{server.server_port}", sp.SMOKE_CREDENTIAL,
                                jobs_dir / job_name / ".bench-metrics", bind=args.bind,
                                auth_header="Authorization" if args.metask_route else "x-api-key",
                                auth_prefix="Bearer " if args.metask_route else "", tls=True,
                                # The smoke credential is itself a fake: the
                                # container presents it and the relay forwards it.
                                token=sp.SMOKE_CREDENTIAL)
            relay.__enter__()
        env = dict(os.environ)
        env["PYTHONPATH"] = os.pathsep.join(
            [str(REPO)] + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else [])
        )
        argv_run = harbor_command(
            harbor=args.harbor,
            bundle=args.bundle.resolve(),
            config=config,
            jobs_dir=jobs_dir,
            job_name=job_name,
            metrics_proxy=relay.url if relay else None,
            metrics_ca=str(relay.ca_path) if relay else None,
            metask_route=args.metask_route,
        )
        completed = subprocess.run(argv_run, cwd=REPO, env=env)
        problems = []
        if completed.returncode != 0:
            problems.append(f"harbor run exited {completed.returncode}")
        trials = _trial_dirs(jobs_dir / job_name)
        if len(trials) != 1:
            problems.append(f"expected one trial, found {len(trials)}")
        else:
            problems += check_trial(trials[0])
        if server.errors:
            problems.append(f"the scripted endpoint refused requests: {server.errors}")
        if len(server.requests) != 2:
            problems.append(f"the scripted endpoint saw {len(server.requests)} requests, expected 2")
        if relay:
            measurements = [json.loads(line) for path in (jobs_dir / job_name / ".bench-metrics").glob("*.jsonl") for line in path.read_text().splitlines()]
            if len(measurements) != 2 or not all(m.get("complete") and m.get("ttft_ms") is not None and m.get("output_tokens", 0) > 0 for m in measurements):
                problems.append("expected two complete measured model requests with TTFT and usage")
        receipt = {
            "schema_version": "metacodes-harbor-smoke-v1",
            "passed": not problems,
            "problems": problems,
            "requests": server.requests,
            "job_dir": str(jobs_dir / job_name),
            "trial_dir": str(trials[0]) if len(trials) == 1 else None,
        }
        if problems and args.jobs_dir is None:
            # Keep a failed job for inspection; a passing one is removed below.
            receipt["kept"] = str(scratch)
        print(json.dumps(receipt, indent=2))
        return 0 if not problems else 1
    finally:
        if relay:
            relay.__exit__(None, None, None)
        server.shutdown()
        server.server_close()
        (scratch / "config.json").unlink(missing_ok=True)
        if args.jobs_dir is None and not problems:
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
