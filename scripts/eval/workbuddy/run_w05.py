"""Run the zero-paid WorkBuddy W0.5 real control-plane vertical slice.

This runner uses the official WorkBuddy/Harbor single-task path, real Linux
metacodes/TinyKG/Lean binaries, a promoted `/workspace` project-rule bundle,
and a deterministic local scripted provider.  It never reads a real provider
credential and the resulting receipt is permanently infrastructure evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Sequence

from . import WORKBUDDY_PINNED_COMMIT
from .install_overlay import install
from .mock_provider import MOCK_CREDENTIAL
from .stage_artifacts import stage
from .trace import OBSERVATION_FILENAME, TraceError, load_control_metrics
from ..model import fsync_directory, mode_violation, open_nofollow


SCHEMA_VERSION = "metacodes-workbuddy-w05-receipt-v1"
JOB_SLUG = "metacodes-w05-real-control"
TASK_NAME = "metacodes-w05-control"
EXPECTED_PROVIDER_REQUESTS = 8
RUNTIME_CONTRACT_FILENAME = "metacodes-runtime-contract.json"
REMOTE_TINYKG_ENV = (
    "TINYKG_REMOTE_URL",
    "TINYKG_API_KEY",
    "TINYKG_REMOTE_EXPECTED_BUILD_ID",
    "TINYKG_REMOTE_CONFIG",
    "METACODES_KG_CONFIG",
    "METACODES_KG_URL",
    "METACODES_KG_API_KEY",
    "METACODES_KG_EXPECTED_BUILD_ID",
    "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
    "METASK_API_KEY",
)
PROVIDER_CREDENTIAL_ENV = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "ZAI_API_KEY",
    "GLM_API_KEY",
    "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF",
)
EXPECTED_RUNTIME_CONTRACT = {
    "schema_version": "metacodes-workbuddy-runtime-contract-v2",
    "quality_evidence": False,
    "fresh_home": True,
    "local_tinykg": True,
    "remote_tinykg_env_absent": True,
    "tinykg_store_absent_before_first_provider_request": True,
    "credential_delivery": "anonymous-fd-route-token",
    "transport_model_is_route": True,
    "actor_model_identity": "glm-5.2",
    "project_control": {
        "staged": True,
        "mode": "enforced",
        "configured": True,
        "project_state_hash": "5807156ecf67bb70",
        "artifacts_verified": True,
        "runtime_active_bundle_absent": False,
    },
}


class W05Error(RuntimeError):
    pass


def _sha256_descriptor(descriptor: int) -> str:
    digest = hashlib.sha256()
    while True:
        block = os.read(descriptor, 1024 * 1024)
        if not block:
            return digest.hexdigest()
        digest.update(block)


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise W05Error("short W0.5 write")
        offset += written


def _identity(path: Path) -> Dict[str, object]:
    if path.is_symlink():
        raise W05Error(f"evidence must not be a symlink: {path}")
    resolved = path.resolve(strict=True)
    path_before = path.lstat()
    descriptor = open_nofollow(
        path,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or (path_before.st_dev, path_before.st_ino)
            != (before.st_dev, before.st_ino)
        ):
            raise W05Error(f"evidence is not a single-link regular file: {path}")
        sha256 = _sha256_descriptor(descriptor)
        after = os.fstat(descriptor)
        path_after = path.lstat()
        stable = (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
            before.st_nlink,
        ) == (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
            after.st_nlink,
        ) and (after.st_dev, after.st_ino) == (path_after.st_dev, path_after.st_ino)
        if not stable:
            raise W05Error(f"evidence changed while hashing: {path}")
        return {
            "path": str(resolved),
            "bytes": before.st_size,
            "sha256": sha256,
        }
    finally:
        os.close(descriptor)


def _json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise W05Error(f"invalid JSON evidence {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise W05Error(f"JSON evidence is not an object: {path}")
    return value


def _json_lines(path: Path) -> list[Dict[str, Any]]:
    rows: list[Dict[str, Any]] = []
    try:
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not raw.strip():
                continue
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise W05Error(f"non-object JSON record at {path}:{number}")
            rows.append(value)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise W05Error(f"invalid JSONL evidence {path}: {exc}") from exc
    return rows


def _run(
    argv: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    pass_fds: Sequence[int] = (),
) -> None:
    completed = subprocess.run(
        list(argv),
        cwd=cwd,
        env=dict(env),
        pass_fds=tuple(pass_fds),
        check=False,
    )
    if completed.returncode != 0:
        raise W05Error(f"command failed ({completed.returncode}): {' '.join(argv)}")


def _terminate_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def _trusted_parent(path: Path) -> Path:
    if path.parent.is_symlink():
        raise W05Error(f"evidence parent must not be a symlink: {path.parent}")
    parent = path.parent.resolve(strict=True)
    info = parent.stat()
    if not stat.S_ISDIR(info.st_mode) or mode_violation(info.st_mode, 0o022):
        raise W05Error(f"evidence parent is not a trusted directory: {parent}")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise W05Error(f"evidence parent is not owned by the current user: {parent}")
    return parent


def _private_new(path: Path, payload: bytes) -> None:
    """Publish a complete 0600 artifact atomically without replacing a peer."""

    parent = _trusted_parent(path)
    if path.exists() or path.is_symlink():
        raise W05Error(f"refusing to overwrite W0.5 evidence: {path}")
    descriptor, temporary_raw = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=parent
    )
    temporary = Path(temporary_raw)
    try:
        try:
            if hasattr(os, "fchmod"):  # absent on Windows
                os.fchmod(descriptor, 0o600)
            _write_all(descriptor, payload)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            if os.link in os.supports_follow_symlinks:
                os.link(temporary, parent / path.name, follow_symlinks=False)
            else:  # Windows: no follow_symlinks; the temporary is our own regular file
                os.link(temporary, parent / path.name)
        except FileExistsError as exc:
            raise W05Error(f"refusing to overwrite W0.5 evidence: {path}") from exc
        temporary.unlink()
        fsync_directory(parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _git(repo: Path, *args: str) -> str:
    completed = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    if completed.returncode != 0:
        raise W05Error(f"git {' '.join(args)} failed: {completed.stderr.strip()}")
    return completed.stdout.strip()


def _fresh_checkout(workbuddy: Path) -> None:
    if Path(_git(workbuddy, "rev-parse", "--show-toplevel")).resolve() != workbuddy:
        raise W05Error("WorkBuddy path is not the checkout root")
    if _git(workbuddy, "rev-parse", "HEAD") != WORKBUDDY_PINNED_COMMIT:
        raise W05Error("WorkBuddy checkout is not at the pinned commit")
    origin = _git(workbuddy, "remote", "get-url", "origin")
    if not re.search(
        r"github\.com[:/]tencent/workbuddy-bench(?:\.git)?/?$", origin, re.IGNORECASE
    ):
        raise W05Error("WorkBuddy checkout origin is not Tencent/WorkBuddy-Bench")
    status = _git(workbuddy, "status", "--short", "--untracked-files=all")
    if status:
        raise W05Error("W0.5 requires a fresh WorkBuddy checkout before overlay install")
    if (workbuddy / ".env").exists() or (workbuddy / ".env").is_symlink():
        raise W05Error("W0.5 refuses an unbound WorkBuddy .env file")


def _single_new_trial(workbuddy: Path, started_ns: int) -> tuple[Path, Path]:
    root = workbuddy / "results" / JOB_SLUG
    trajectories = [
        path
        for path in root.rglob("trajectory.json")
        if path.is_file() and path.stat().st_mtime_ns >= started_ns
    ] if root.exists() else []
    if len(trajectories) != 1:
        raise W05Error(f"expected one new W0.5 trajectory, found {trajectories}")
    trajectory = trajectories[0]
    if not trajectory.parent.parent.name.startswith(f"{TASK_NAME}__"):
        raise W05Error(f"W0.5 produced another task identity: {trajectory}")
    return trajectory.parent, trajectory.parent.parent


def _control_assertions(metrics: Mapping[str, Any]) -> None:
    runtime = metrics.get("tool_runtime") or {}
    tinykg = metrics.get("tinykg") or {}
    lean = metrics.get("lean") or {}
    if (
        runtime.get("dispatch_started") != runtime.get("dispatch_finished")
        or runtime.get("dispatch_started") != 7
        or runtime.get("transcript_calls_without_result") != 0
    ):
        raise W05Error("W0.5 tool dispatch evidence is incomplete")
    if not tinykg.get("used") or not lean.get("used"):
        raise W05Error("W0.5 did not exercise both TinyKG and project Lean")
    required = {
        "remember_succeeded": 1,
        "recall_succeeded": 1,
        "context_succeeded": 1,
        "task_create_calls": 1,
        "task_update_calls": 2,
        "task_terminal_commits": 1,
    }
    if any(tinykg.get(key) != expected for key, expected in required.items()):
        raise W05Error(f"W0.5 TinyKG/task-DAG evidence is incomplete: {tinykg}")
    if lean.get("checker_calls", 0) <= 0 or lean.get("admit", 0) <= 0:
        raise W05Error("W0.5 project Lean gate produced no admitted checker decision")


def _mock_audit(rows: Iterable[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    records = list(rows)
    if len(records) != EXPECTED_PROVIDER_REQUESTS:
        raise W05Error(
            f"expected {EXPECTED_PROVIDER_REQUESTS} scripted requests, found {len(records)}"
        )
    for number, row in enumerate(records, 1):
        if (
            row.get("schema_version") != "metacodes-workbuddy-mock-provider-v2"
            or row.get("scenario") != "control-plane-v1"
            or row.get("request_number") != number
            or row.get("control_metrics_absent") is not True
        ):
            raise W05Error("mock-provider request audit drifted")
        body_sha256 = row.get("body_sha256")
        if not isinstance(body_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", body_sha256
        ):
            raise W05Error("mock-provider request body identity is missing")
    return records


def _contains_control_metrics(value: object) -> bool:
    if isinstance(value, Mapping):
        return "control_metrics" in value or any(
            _contains_control_metrics(item) for item in value.values()
        )
    if isinstance(value, list):
        return any(_contains_control_metrics(item) for item in value)
    return False


def _wire_json_sha256(value: Mapping[str, Any]) -> str:
    payload = json.dumps(
        dict(value), ensure_ascii=False, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _model_route_suffix(model: object) -> str:
    value = str(model or "")
    suffix = "--metacodes-w05-mock"
    if not value.endswith(suffix) or len(value) <= len(suffix):
        raise W05Error("WorkBuddy mock model route is not instance-scoped")
    return value


def _proxy_audit(
    rows: Iterable[Mapping[str, Any]], mock_rows: Sequence[Mapping[str, Any]]
) -> None:
    records = list(rows)
    if len(records) != EXPECTED_PROVIDER_REQUESTS or len(records) != len(mock_rows):
        raise W05Error("WorkBuddy proxy request count differs from mock audit")
    try:
        expected_route = _model_route_suffix(records[0].get("route"))
        expected_model = str(mock_rows[0].get("model") or "")
    except IndexError as exc:
        raise W05Error("WorkBuddy proxy/mock request audit is empty") from exc
    if not expected_model:
        raise W05Error("WorkBuddy mock provider model identity is missing")
    for number, (row, mock_row) in enumerate(zip(records, mock_rows), 1):
        request = row.get("request")
        upstream = request.get("upstream_body") if isinstance(request, Mapping) else None
        upstream_url = request.get("upstream_url") if isinstance(request, Mapping) else None
        if (
            row.get("seq") != number
            or row.get("route") != expected_route
            or not str(row.get("trial_id") or "").startswith(f"{TASK_NAME}__")
            or not isinstance(upstream, Mapping)
            or upstream.get("model") != expected_model
            or mock_row.get("model") != expected_model
            or upstream.get("stream") is not True
            or not isinstance(upstream_url, str)
            or not upstream_url.startswith("http://127.0.0.1:")
            or not upstream_url.endswith("/v1/messages")
            or _contains_control_metrics(upstream)
            or _wire_json_sha256(upstream) != mock_row.get("body_sha256")
        ):
            raise W05Error(f"WorkBuddy proxy/mock request audit drifted at {number}")


def _runtime_contract_assertions(value: Mapping[str, Any]) -> None:
    if value != EXPECTED_RUNTIME_CONTRACT:
        raise W05Error("runtime isolation/project-control contract drifted")


def _receipt_assertions(value: Mapping[str, Any]) -> None:
    if (
        value.get("schema_version") != SCHEMA_VERSION
        or value.get("quality_evidence") is not False
        or value.get("verifier_reward") != 1
        or (value.get("network") or {}).get("external_paid_provider_requests") != 0
        or (value.get("network") or {}).get("mock_scripted_provider_requests")
        != EXPECTED_PROVIDER_REQUESTS
    ):
        raise W05Error("W0.5 receipt classification or network claim drifted")
    _control_assertions(value.get("control_metrics") or {})


def _clean_environment(source: Mapping[str, str]) -> Dict[str, str]:
    environment = dict(source)
    for name in (*REMOTE_TINYKG_ENV, *PROVIDER_CREDENTIAL_ENV):
        environment.pop(name, None)
    return environment


def _stable_evidence(
    before: Mapping[str, Mapping[str, object]], paths: Mapping[str, Path]
) -> Dict[str, Mapping[str, object]]:
    after = {name: _identity(path) for name, path in paths.items()}
    if dict(before) != after:
        raise W05Error("W0.5 raw evidence changed during validation")
    return after


def run_w05(
    *,
    workbuddy: Path,
    metacodes: Path,
    tinykg: Path,
    formal_kernel: Path,
    ripgrep: Path,
    project_kernel: Path,
    project_rules: Path,
    metacodes_commit: str,
    tinykg_commit: str,
    metacodes_license: Path,
    tinykg_license: Path,
    lean_license: Path,
    bash: Path,
    uv: Path,
) -> Dict[str, object]:
    workbuddy = workbuddy.resolve(strict=True)
    _fresh_checkout(workbuddy)
    overlay = install(workbuddy)
    artifact_dir = workbuddy / "configs/harnesses/metacodes/docker/artifacts"
    if artifact_dir.exists():
        raise W05Error("W0.5 split-mount stage already exists after overlay install")
    manifest = stage(
        output=artifact_dir,
        metacodes=metacodes,
        tinykg=tinykg,
        formal_kernel=formal_kernel,
        ripgrep=ripgrep.resolve(),
        project_kernel=project_kernel,
        project_rules=project_rules,
        metacodes_commit=metacodes_commit,
        tinykg_commit=tinykg_commit,
        licenses=(
            ("metacodes", "NOASSERTION", metacodes_license),
            ("tinykg", "Apache-2.0", tinykg_license),
            ("lean4", "Apache-2.0", lean_license),
        ),
    )

    with tempfile.TemporaryDirectory(prefix="metacodes-workbuddy-w05-") as directory:
        private = Path(directory)
        os.chmod(private, 0o700)
        ready = private / "mock-ready.json"
        mock_requests = private / "mock-requests.jsonl"
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.eval.workbuddy.mock_provider",
                "--ready",
                str(ready),
                "--request-log",
                str(mock_requests),
                "--scenario",
                "control-plane-v1",
            ],
            cwd=Path(__file__).resolve().parents[3],
            env=_clean_environment(os.environ),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline:
                if process.poll() is not None:
                    raise W05Error(
                        f"mock provider exited early: {process.stderr.read()}"
                    )
                time.sleep(0.02)
            if not ready.is_file():
                raise W05Error("mock provider did not become ready")
            ready_value = _json(ready)
            if ready_value.get("scenario") != "control-plane-v1":
                raise W05Error("mock provider started another scenario")
            port = ready_value.get("port")
            if isinstance(port, bool) or not isinstance(port, int) or port <= 0:
                raise W05Error("mock provider did not publish a valid port")

            environment = _clean_environment(os.environ)
            environment.update(
                {
                    "METACODES_W05_MOCK_BASE_URL": f"http://127.0.0.1:{port}/v1/messages",
                    "WBBENCH_PROXY_MAX_RETRIES": "0",
                    "WBBENCH_PROXY_RETRY_DELAY_MS": "1",
                    "SHARDS": "1",
                    "SHARD_CONCURRENCY": "1",
                    "PROXY_MAX_CONCURRENT": "1",
                    "SHARED_PROXY": "0",
                    "AUTO_BUILD_HARNESS_MOUNT": "0",
                    "DOCKER_DEFAULT_PLATFORM": "linux/amd64",
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
            started_ns = time.time_ns()
            credential_read, credential_write = os.pipe()
            try:
                _write_all(credential_write, MOCK_CREDENTIAL.encode("utf-8"))
            finally:
                os.close(credential_write)
            environment["METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF"] = (
                f"fd://{credential_read}"
            )
            try:
                _run(
                    [
                        str(uv),
                        "run",
                        "--frozen",
                        str(bash),
                        "scripts/run.sh",
                        "--job",
                        JOB_SLUG,
                    ],
                    cwd=workbuddy,
                    env=environment,
                    pass_fds=(credential_read,),
                )
            finally:
                os.close(credential_read)
            if process.poll() is not None:
                raise W05Error(
                    f"mock provider exited before evidence freeze: {process.stderr.read()}"
                )
            _terminate_process(process)
            agent_dir, trial_dir = _single_new_trial(workbuddy, started_ns)
            transcript = agent_dir / "metacodes-transcript.jsonl"
            observations = agent_dir / OBSERVATION_FILENAME
            trajectory = agent_dir / "trajectory.json"
            runtime_contract_path = agent_dir / RUNTIME_CONTRACT_FILENAME
            control = load_control_metrics(transcript, observations)
            _control_assertions(control)
            trajectory_control = (
                ((_json(trajectory).get("final_metrics") or {}).get("extra") or {}).get(
                    "control_metrics"
                )
            )
            if trajectory_control != control:
                raise W05Error("trajectory control metrics differ from raw evidence")
            runtime_contract = _json(runtime_contract_path)
            _runtime_contract_assertions(runtime_contract)
            mock_rows = _mock_audit(_json_lines(mock_requests))
            retained_mock_requests = (
                workbuddy / ".workspace/metacodes-w05-mock-requests.jsonl"
            )
            retained_mock_requests.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(retained_mock_requests.parent, 0o700)
            _private_new(retained_mock_requests, mock_requests.read_bytes())
            reward = trial_dir / "verifier/reward.txt"
            if not reward.is_file() or reward.read_text(encoding="utf-8").strip() != "1":
                raise W05Error("W0.5 synthetic verifier did not award 1")

            proxy_request_path = agent_dir / "requests.jsonl"
            proxy_requests = _json_lines(proxy_request_path)
            _proxy_audit(proxy_requests, mock_rows)
            evidence_paths = {
                "trajectory": trajectory,
                "transcript": transcript,
                "observation_journal": observations,
                "runtime_contract": runtime_contract_path,
                "proxy_requests": proxy_request_path,
                "mock_requests": retained_mock_requests,
                "verifier_reward": reward,
            }
            evidence_before = {
                name: _identity(path) for name, path in evidence_paths.items()
            }
            receipt = {
                "schema_version": SCHEMA_VERSION,
                "quality_evidence": False,
                "network": {
                    "external_paid_provider_requests": 0,
                    "mock_scripted_provider_requests": EXPECTED_PROVIDER_REQUESTS,
                    "provider": "loopback-scripted-control-plane-v1",
                },
                "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
                "overlay_sha256": overlay["overlay_sha256"],
                "split_mount_manifest": _identity(
                    artifact_dir / "share/metacodes/artifact-manifest.json"
                ),
                "project_control": manifest["project_control"],
                "artifacts": evidence_before,
                "control_metrics": control,
                "verifier_reward": 1,
            }
            _receipt_assertions(receipt)
            _stable_evidence(evidence_before, evidence_paths)
            receipt_path = workbuddy / ".workspace/metacodes-w05-receipt.json"
            _private_new(
                receipt_path,
                (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode(
                    "utf-8"
                ),
            )
            return receipt
        finally:
            _terminate_process(process)
            if process.stderr is not None:
                process.stderr.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbuddy_checkout", type=Path)
    parser.add_argument("--metacodes", type=Path, required=True)
    parser.add_argument("--tinykg", type=Path, required=True)
    parser.add_argument("--formal-kernel", type=Path, required=True)
    parser.add_argument("--project-kernel", type=Path, required=True)
    parser.add_argument("--project-rules", type=Path, required=True)
    parser.add_argument("--ripgrep", type=Path, required=True)
    parser.add_argument("--metacodes-commit", required=True)
    parser.add_argument("--tinykg-commit", required=True)
    parser.add_argument("--metacodes-license", type=Path, required=True)
    parser.add_argument("--tinykg-license", type=Path, required=True)
    parser.add_argument("--lean-license", type=Path, required=True)
    parser.add_argument(
        "--bash",
        type=Path,
        default=Path("/opt/homebrew/bin/bash" if Path("/opt/homebrew/bin/bash").is_file() else (shutil.which("bash") or "bash")),
    )
    parser.add_argument("--uv", type=Path, default=Path(shutil.which("uv") or "uv"))
    args = parser.parse_args(argv)
    try:
        receipt = run_w05(
            workbuddy=args.workbuddy_checkout,
            metacodes=args.metacodes,
            tinykg=args.tinykg,
            formal_kernel=args.formal_kernel,
            ripgrep=args.ripgrep,
            project_kernel=args.project_kernel,
            project_rules=args.project_rules,
            metacodes_commit=args.metacodes_commit,
            tinykg_commit=args.tinykg_commit,
            metacodes_license=args.metacodes_license,
            tinykg_license=args.tinykg_license,
            lean_license=args.lean_license,
            bash=args.bash,
            uv=args.uv,
        )
    except (OSError, TraceError, ValueError, W05Error) as exc:
        parser.error(str(exc))
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
