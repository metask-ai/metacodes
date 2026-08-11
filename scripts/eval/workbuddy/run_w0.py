"""Run the zero-provider WorkBuddy W0 synthetic vertical slice.

This is an adapter/infrastructure test, never memory-quality evidence.  The
synthetic ELF validates the anonymous-FD, fresh HOME, local TinyKG and cleared
remote-TinyKG contract, writes one task artifact, and emits a real metacodes-
shaped transcript/result for the adapter to convert to ATIF.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterable, List

from .install_overlay import install
from .stage_artifacts import stage


class W0Error(RuntimeError):
    pass


def _run(args: List[str], *, cwd: Path, env: Dict[str, str]) -> None:
    completed = subprocess.run(args, cwd=cwd, env=env, check=False)
    if completed.returncode != 0:
        raise W0Error(f"command failed ({completed.returncode}): {' '.join(args)}")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _new_files(root: Path, name: str, started_ns: int) -> List[Path]:
    if not root.exists():
        return []
    rows = []
    for path in root.rglob(name):
        try:
            if path.is_file() and path.stat().st_mtime_ns >= started_ns:
                rows.append(path)
        except OSError:
            continue
    return sorted(rows)


def _nonempty_lines(paths: Iterable[Path]) -> int:
    count = 0
    for path in paths:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.strip():
                count += 1
    return count


def run_w0(workbuddy: Path, zig: Path, bash: Path, uv: Path) -> Dict[str, object]:
    workbuddy = workbuddy.resolve()
    install(workbuddy)
    artifact_dir = workbuddy / "configs/harnesses/metacodes/docker/artifacts"
    if artifact_dir.exists():
        raise W0Error(
            f"W0 artifact stage already exists; use a fresh checkout or archive it: {artifact_dir}"
        )

    here = Path(__file__).resolve().parent
    source = here / "fixtures/fake_metacodes.c"
    synthetic_license = here / "fixtures/SYNTHETIC_LICENSE"
    started_ns = time.time_ns()
    with tempfile.TemporaryDirectory(prefix="metacodes-workbuddy-w0-") as directory:
        fake_binary = Path(directory) / "metacodes-w0-fixture"
        _run(
            [
                str(zig),
                "cc",
                "-target",
                "x86_64-linux-musl",
                "-static",
                "-Os",
                "-o",
                str(fake_binary),
                str(source),
            ],
            cwd=here,
            env=dict(os.environ),
        )
        manifest = stage(
            output=artifact_dir,
            metacodes=fake_binary,
            tinykg=fake_binary,
            formal_kernel=fake_binary,
            metacodes_commit="0" * 40,
            tinykg_commit="0" * 40,
            licenses=(
                ("metacodes", "NOASSERTION", synthetic_license),
                ("tinykg", "NOASSERTION", synthetic_license),
                ("lean4", "NOASSERTION", synthetic_license),
            ),
            allow_synthetic_fixtures=True,
        )

    environment = dict(os.environ)
    environment.update(
        {
            "METACODES_W0_FAKE_BASE_URL": "http://127.0.0.1:9/v1/messages",
            "METACODES_W0_FAKE_API_KEY": "w0-non-secret-never-contacted",
            "WBBENCH_PROXY_MAX_RETRIES": "0",
            "WBBENCH_PROXY_RETRY_DELAY_MS": "1",
            "SHARDS": "1",
            "SHARD_CONCURRENCY": "1",
            "AUTO_BUILD_HARNESS_MOUNT": "0",
        }
    )
    _run(
        [
            str(uv),
            "run",
            "--frozen",
            str(bash),
            "scripts/harness/build-harness-mounts.sh",
            "--harness",
            "metacodes/0.1.0",
        ],
        cwd=workbuddy,
        env=environment,
    )
    _run(
        [
            str(uv),
            "run",
            "--frozen",
            str(bash),
            "scripts/run.sh",
            "--job",
            "metacodes-w0-synthetic",
        ],
        cwd=workbuddy,
        env=environment,
    )

    results_root = workbuddy / "results/metacodes-w0-synthetic"
    trajectories = _new_files(results_root, "trajectory.json", started_ns)
    if len(trajectories) != 1:
        raise W0Error(f"expected one new trajectory, found {trajectories}")
    trajectory = json.loads(trajectories[0].read_text(encoding="utf-8"))
    final = trajectory.get("final_metrics") or {}
    extra = final.get("extra") or {}
    if (
        final.get("total_prompt_tokens") != 120
        or final.get("total_completion_tokens") != 30
        or final.get("total_cached_tokens") != 80
        or extra.get("cache_creation_input_tokens") != 10
        or extra.get("metacodes_stop_reason") != "end_turn"
    ):
        raise W0Error("ATIF final metrics do not preserve metacodes usage/cache fields")

    trial_root = trajectories[0].parent.parent
    runtime_contracts = list(trial_root.rglob("fake-runtime-contract.json"))
    if len(runtime_contracts) != 1:
        raise W0Error("synthetic runtime contract artifact is missing")
    runtime_contract = json.loads(runtime_contracts[0].read_text(encoding="utf-8"))
    expected_contract = {
        "anonymous_fd": True,
        "fresh_home": True,
        "local_tinykg": True,
        "network_loopback_only": True,
        "remote_tinykg": False,
        "provider_requests": 0,
        "quality_evidence": False,
        "route_scoped_to_model": True,
    }
    if runtime_contract != expected_contract:
        raise W0Error(f"runtime contract mismatch: {runtime_contract}")

    rewards = list(trial_root.rglob("reward.txt"))
    if len(rewards) != 1 or rewards[0].read_text(encoding="utf-8").strip() != "1":
        raise W0Error(f"synthetic verifier did not award 1: {rewards}")
    artifacts = [
        path for path in trial_root.rglob("result.txt")
        if path.read_text(encoding="utf-8", errors="replace")
        == "metacodes workbuddy w0 ok\n"
    ]
    if not artifacts:
        raise W0Error("WorkBuddy did not collect the expected task artifact")

    request_logs = _new_files(workbuddy, "requests.jsonl", started_ns)
    proxy_jsonl = [
        path
        for path in _new_files(workbuddy / ".workspace", "*.jsonl", started_ns)
        if "proxy" in path.as_posix().lower()
    ]
    if _nonempty_lines([*request_logs, *proxy_jsonl]) != 0:
        raise W0Error("W0 observed a provider request despite the zero-provider contract")

    receipt = {
        "schema_version": "metacodes-workbuddy-w0-receipt-v1",
        "quality_evidence": False,
        "provider_requests": 0,
        "network_policy": "no-network",
        "network_enforcement": "docker-compose-network-mode-none-runtime-asserted",
        "workbuddy_commit": manifest["workbuddy_commit"],
        "overlay_sha256": json.loads(
            (workbuddy / "configs/harnesses/metacodes/OVERLAY.json").read_text(
                encoding="utf-8"
            )
        )["overlay_sha256"],
        "split_mount_manifest_sha256": _sha256(
            artifact_dir / "share/metacodes/artifact-manifest.json"
        ),
        "trajectory_sha256": _sha256(trajectories[0]),
        "runtime_contract_sha256": _sha256(runtime_contracts[0]),
        "verifier_reward": 1,
        "usage": {
            "input_tokens": 120,
            "output_tokens": 30,
            "cache_read_input_tokens": 80,
            "cache_creation_input_tokens": 10,
            "cost_usd": 0.0,
        },
    }
    receipt_path = workbuddy / ".workspace/metacodes-w0-receipt.json"
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(
        json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )
    return receipt


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbuddy_checkout", type=Path)
    parser.add_argument("--zig", type=Path, default=Path(shutil.which("zig") or "zig"))
    parser.add_argument(
        "--bash",
        type=Path,
        default=Path(
            "/opt/homebrew/bin/bash"
            if Path("/opt/homebrew/bin/bash").is_file()
            else (shutil.which("bash") or "bash")
        ),
    )
    parser.add_argument("--uv", type=Path, default=Path(shutil.which("uv") or "uv"))
    args = parser.parse_args(argv)
    try:
        receipt = run_w0(args.workbuddy_checkout, args.zig, args.bash, args.uv)
    except (OSError, W0Error, ValueError) as exc:
        parser.error(str(exc))
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
