"""Single-machine paid launch gate for phased WorkBuddy evaluations.

The gate reuses the Lean-governed ``BudgetJournal``.  A whole WorkBuddy wave is
one conservative transaction: its maximum dollar/token exposure is durable
before the credential descriptor is consumed or a network-capable child is
started.  A crash after authorization leaves the full maximum charged and the
same run id cannot be retried.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import time
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Sequence

import yaml

from ..memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    usd_to_microusd_ceiling,
)
from ..model import ValidationError, stable_json
from . import WORKBUDDY_PINNED_COMMIT
from .environment_preflight import (
    EnvironmentPreflightError,
    validate_receipt as validate_environment_preflight,
)
from .install_overlay import OverlayError, validate_installed_overlay
from .key_fd import MAX_CREDENTIAL_BYTES
from .stage_artifacts import ELF_MACHINE_X86_64, TARGET_PLATFORM, _elf_machine


SCHEMA_VERSION = "metacodes-workbuddy-paid-launch-v1"
RECEIPT_SCHEMA_VERSION = "metacodes-workbuddy-paid-receipt-v1"
PROVIDER_KEY_ENV = "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF"
MAX_USER_AUTHORITY_MICROUSD = 1000 * 1_000_000
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$")
FaultHook = Callable[[str, Mapping[str, Any]], None]
HOST_CONTROL_PLANE_MODULES = {
    "environment_preflight": Path(__file__).with_name("environment_preflight.py"),
    "install_overlay": Path(__file__).with_name("install_overlay.py"),
    "key_fd": Path(__file__).with_name("key_fd.py"),
    "launch_gate": Path(__file__),
    "memory_budget_journal": Path(__file__).parents[1] / "memory_budget_journal.py",
    "model": Path(__file__).parents[1] / "model.py",
    "stage_artifacts": Path(__file__).with_name("stage_artifacts.py"),
}


class LaunchError(ValidationError):
    pass


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_sha256(value: object) -> str:
    return _sha256_bytes(stable_json(value).encode("utf-8"))


def _read_regular(path: Path, *, maximum: int = 16 * 1024 * 1024) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise LaunchError(f"cannot open launch input {path}: {exc}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise LaunchError(f"launch input is not a single-link regular file: {path}")
        if before.st_size <= 0 or before.st_size > maximum:
            raise LaunchError(f"launch input size is outside the safety bound: {path}")
        chunks: list[bytes] = []
        observed = 0
        while True:
            chunk = os.read(descriptor, min(65536, maximum + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > maximum:
                raise LaunchError(f"launch input exceeds the safety bound: {path}")
        after = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise LaunchError(f"launch input changed while being observed: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _json(path: Path) -> Dict[str, Any]:
    payload = _read_regular(path)

    def unique(pairs: list[tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise LaunchError(f"duplicate JSON field {key!r} in {path}")
            result[key] = value
        return result

    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=unique)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise LaunchError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LaunchError(f"expected JSON object in {path}")
    return value


def _yaml(path: Path) -> Dict[str, Any]:
    try:
        value = yaml.safe_load(_read_regular(path).decode("utf-8"))
    except (UnicodeError, yaml.YAMLError) as exc:
        raise LaunchError(f"invalid YAML in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LaunchError(f"expected YAML mapping in {path}")
    return value


def _identity(path: Path, *, maximum: int = 16 * 1024 * 1024) -> Dict[str, object]:
    payload = _read_regular(path, maximum=maximum)
    return {
        "path": str(path.resolve()),
        "bytes": len(payload),
        "sha256": _sha256_bytes(payload),
    }


def _git(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise LaunchError(f"git {' '.join(args)} failed for {repo}: {exc}") from exc


def _runner_tool(path: Path, version_args: Sequence[str], *, bash: bool = False) -> Dict[str, object]:
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise LaunchError(f"runner tool does not exist: {path}") from exc
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise LaunchError(f"runner tool is not an executable file: {resolved}")
    try:
        completed = subprocess.run(
            [str(resolved), *version_args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise LaunchError(f"cannot identify runner tool {resolved}: {exc}") from exc
    version = completed.stdout.strip()
    if not version:
        raise LaunchError(f"runner tool has no version output: {resolved}")
    if bash:
        match = re.search(r"GNU bash, version ([0-9]+)(?:\.|$)", version)
        if match is None or int(match.group(1)) < 4:
            raise LaunchError("WorkBuddy paid runner requires GNU Bash 4 or newer")
    return {
        **_identity(resolved, maximum=128 * 1024 * 1024),
        "version_sha256": _sha256_bytes(version.encode("utf-8")),
        "version_first_line": version.splitlines()[0],
    }


def _host_control_plane() -> Dict[str, object]:
    return {
        name: _identity(path.resolve(), maximum=16 * 1024 * 1024)
        for name, path in sorted(HOST_CONTROL_PLANE_MODULES.items())
    }


def _cohort(path: Path, subset: str, cohort: str, take: int) -> Dict[str, object]:
    manifest = _json(path)
    content_sha = manifest.pop("content_sha256", None)
    cohort_payload = (
        json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if content_sha != _sha256_bytes(cohort_payload):
        raise LaunchError("WorkBuddy cohort manifest content hash mismatch")
    if manifest.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT:
        raise LaunchError("WorkBuddy cohort manifest commit mismatch")
    try:
        row = manifest["subsets"][subset]
        selection = row["cohorts"][cohort]["task_selection"]
        names = list(selection["names"])
    except (KeyError, TypeError) as exc:
        raise LaunchError(f"unknown or malformed WorkBuddy cohort {subset}/{cohort}") from exc
    if selection.get("mode") != "name" or not names or len(names) != len(set(names)):
        raise LaunchError("WorkBuddy cohort task selection is malformed or duplicated")
    if take < 0 or take > len(names):
        raise LaunchError(f"take={take} is outside cohort size {len(names)}")
    selected = names[:take] if take else names
    return {
        "manifest": _identity(path),
        "content_sha256": content_sha,
        "subset": subset,
        "cohort": cohort,
        "take": take,
        "dataset": row["dataset"],
        "selected_tasks": selected,
        "selected_tasks_sha256": _canonical_sha256(selected),
    }


def _artifact_contract(path: Path) -> Dict[str, object]:
    manifest = _json(path)
    if (
        manifest.get("schema_version") != "metacodes-workbuddy-split-mount-v1"
        or manifest.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
        or manifest.get("target") != "linux-container"
        or manifest.get("target_platform") != TARGET_PLATFORM
        or manifest.get("synthetic_fixture") is not False
    ):
        raise LaunchError("paid WorkBuddy launch requires a production Linux split mount")
    stage = path.resolve().parents[2]
    expected = {
        "metacodes": stage / "bin/metacodes",
        "tinykg": stage / "bin/tinykg",
        "metacodes-formal-kernel": stage / "libexec/metacodes-formal-kernel",
    }
    executables = manifest.get("executables")
    if not isinstance(executables, dict) or set(executables) != set(expected):
        raise LaunchError("split-mount executable manifest is incomplete")
    observed: Dict[str, object] = {}
    for name, binary in expected.items():
        identity = _identity(binary, maximum=512 * 1024 * 1024)
        if identity["sha256"] != executables[name].get("sha256"):
            raise LaunchError(f"split-mount {name} hash mismatch")
        machine = _elf_machine(binary)
        if (
            machine != ELF_MACHINE_X86_64
            or executables[name].get("elf_machine") != ELF_MACHINE_X86_64
        ):
            raise LaunchError(
                f"split-mount {name} does not match {TARGET_PLATFORM} ELF machine"
            )
        identity["elf_machine"] = machine
        observed[name] = identity
    return {
        "manifest": _identity(path),
        "target_platform": TARGET_PLATFORM,
        "executables": observed,
    }


def build_launch_manifest(
    *,
    run_id: str,
    workbuddy_checkout: Path,
    cohort_manifest: Path,
    subset: str,
    cohort: str,
    take: int,
    split_mount_manifest: Path,
    environment_preflight_receipt: Path,
    job_config: Path,
    model_config: Path,
    runner_bash: Path,
    runner_uv: Path,
    provider_identity: str,
    total_cost_microusd: int,
    total_metered_tokens: int,
    max_cost_microusd: int,
    max_metered_tokens: int,
    prior_exposure_microusd: int = 0,
    quality_evidence_on_commit: bool = False,
) -> Dict[str, object]:
    if not RUN_ID_RE.fullmatch(run_id):
        raise LaunchError("run id must be a safe 3-128 character path component")
    workbuddy = workbuddy_checkout.resolve()
    if _git(workbuddy, "rev-parse", "HEAD") != WORKBUDDY_PINNED_COMMIT:
        raise LaunchError("WorkBuddy checkout commit mismatch")
    origin = _git(workbuddy, "remote", "get-url", "origin").lower()
    if "tencent/workbuddy-bench" not in origin:
        raise LaunchError("WorkBuddy checkout origin mismatch")
    overlay_path = workbuddy / "configs/harnesses/metacodes/OVERLAY.json"
    try:
        overlay = validate_installed_overlay(workbuddy)
    except OverlayError as exc:
        raise LaunchError(str(exc)) from exc

    cohort_row = _cohort(cohort_manifest.resolve(), subset, cohort, take)
    artifact_row = _artifact_contract(split_mount_manifest.resolve())
    job_path = job_config.resolve()
    model_path = model_config.resolve()
    job = _yaml(job_path)
    model = _yaml(model_path).get("model")
    if not isinstance(model, dict):
        raise LaunchError("WorkBuddy model config has no model mapping")
    selected = cohort_row["selected_tasks"]
    try:
        environment_preflight = validate_environment_preflight(
            environment_preflight_receipt.resolve(),
            workbuddy=workbuddy,
            dataset=str(cohort_row["dataset"]),
            selected_tasks=selected,
            inspect_images=True,
        )
    except EnvironmentPreflightError as exc:
        raise LaunchError(str(exc)) from exc
    bash_tool = _runner_tool(runner_bash, ("--version",), bash=True)
    uv_tool = _runner_tool(runner_uv, ("--version",))
    host_control_plane = _host_control_plane()
    expected_selection = {"mode": "name", "names": selected}
    if job.get("dataset") != cohort_row["dataset"] or job.get("task_selection") != expected_selection:
        raise LaunchError("WorkBuddy job dataset/task_selection differs from frozen cohort")
    if job.get("harness") != "metacodes/0.1.0" or job.get("model_connection") != "local_proxy":
        raise LaunchError("WorkBuddy job must use the pinned metacodes local-proxy harness")
    if job.get("record_full_io") is not True or job.get("n_attempts") != 1:
        raise LaunchError("paid WorkBuddy job requires full request audit and n_attempts=1")
    if (job.get("orchestrator_override") or {}).get("n_concurrent_trials") != 1:
        raise LaunchError("paid WorkBuddy job requires one concurrent trial")
    if model.get("backend_key_env") != PROVIDER_KEY_ENV:
        raise LaunchError("WorkBuddy model must require the anonymous credential FD env")
    model_slug = job.get("model")
    if not isinstance(model_slug, str) or not model_slug:
        raise LaunchError("WorkBuddy job has no model slug")
    if job_path != workbuddy / f"configs/jobs/{job_path.stem}.yaml":
        raise LaunchError("WorkBuddy job config is not the file consumed by the pinned runner")
    if model_path != workbuddy / f"configs/models/{model_slug}.yaml":
        raise LaunchError("WorkBuddy model config is not the file consumed by the pinned runner")
    expected_stage = workbuddy / "configs/harnesses/metacodes/docker/artifacts"
    if split_mount_manifest.resolve().parents[2] != expected_stage:
        raise LaunchError("split-mount manifest is outside the WorkBuddy metacodes stage")
    backend_url_env = model.get("backend_url_env")
    if not isinstance(backend_url_env, str) or not backend_url_env:
        raise LaunchError("WorkBuddy model has no backend URL environment name")
    backend_url = os.environ.get(backend_url_env, "")
    parsed_url = urllib.parse.urlsplit(backend_url)
    if parsed_url.scheme not in {"http", "https"} or not parsed_url.hostname:
        raise LaunchError("WorkBuddy provider base URL is missing or invalid")

    for label, value in (
        ("total_cost_microusd", total_cost_microusd),
        ("total_metered_tokens", total_metered_tokens),
        ("max_cost_microusd", max_cost_microusd),
        ("max_metered_tokens", max_metered_tokens),
        ("prior_exposure_microusd", prior_exposure_microusd),
    ):
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise LaunchError(f"{label} must be a non-negative integer")
    if min(total_cost_microusd, total_metered_tokens, max_cost_microusd, max_metered_tokens) <= 0:
        raise LaunchError("budget limits must be positive")
    if max_cost_microusd > total_cost_microusd or max_metered_tokens > total_metered_tokens:
        raise LaunchError("wave maximum exceeds its journal authority")
    if prior_exposure_microusd + total_cost_microusd > MAX_USER_AUTHORITY_MICROUSD:
        raise LaunchError("cumulative WorkBuddy authority exceeds the user $1000 limit")
    if not isinstance(quality_evidence_on_commit, bool):
        raise LaunchError("quality_evidence_on_commit must be boolean")

    job_identity = _identity(job_path)
    model_identity = _identity(model_path)
    overlay_identity = _identity(overlay_path)
    harness_fingerprint = _canonical_sha256(
        {
            "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
            "overlay": overlay_identity,
            "artifact": artifact_row,
            "environment_preflight": environment_preflight["content_sha256"],
            "job": job_identity,
            "runner_tools": {"bash": bash_tool, "uv": uv_tool},
            "host_control_plane": host_control_plane,
            "target_platform": TARGET_PLATFORM,
        }
    )
    model_fingerprint = _canonical_sha256(
        {
            "provider_identity": provider_identity,
            "model_slug": model_slug,
            "backend_model_name": model.get("name"),
            "model_config": model_identity,
        }
    )
    manifest: Dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "quality_evidence": False,
        "quality_evidence_on_commit": quality_evidence_on_commit,
        "run_id": run_id,
        "workbuddy": {
            "checkout": str(workbuddy),
            "commit": WORKBUDDY_PINNED_COMMIT,
            "overlay": overlay_identity,
            "overlay_content_sha256": overlay["overlay_sha256"],
        },
        "cohort": cohort_row,
        "artifacts": artifact_row,
        "environment_preflight": {
            "receipt": _identity(environment_preflight_receipt.resolve()),
            "content_sha256": environment_preflight["content_sha256"],
            "target_platform": environment_preflight["target_platform"],
        },
        "job": {"slug": job_path.stem, "config": job_identity},
        "model": {
            "slug": model_slug,
            "config": model_identity,
            "provider_identity": provider_identity,
            "fingerprint": model_fingerprint,
            "backend_url_env": backend_url_env,
            "backend_url_sha256": _sha256_bytes(backend_url.encode("utf-8")),
        },
        "harness_fingerprint": harness_fingerprint,
        "host_control_plane": host_control_plane,
        "budget": {
            "total_cost_microusd": total_cost_microusd,
            "total_metered_tokens": total_metered_tokens,
            "max_cost_microusd": max_cost_microusd,
            "max_metered_tokens": max_metered_tokens,
            "prior_exposure_microusd": prior_exposure_microusd,
            "user_authority_microusd": MAX_USER_AUTHORITY_MICROUSD,
        },
        "execution": {
            "n_attempts": 1,
            "n_concurrent_trials": 1,
            "shards": 1,
            "proxy_max_retries": 0,
            "shared_proxy": False,
            "credential_delivery": "anonymous-fd",
            "provider_key_env": PROVIDER_KEY_ENV,
            "remote_tinykg_env_cleared": True,
            "local_tinykg": "fresh-home-per-trial",
            "cacheable_first_request_hash_required": True,
            "target_platform": TARGET_PLATFORM,
            "docker_default_platform": TARGET_PLATFORM,
            "environment_preflight_required": True,
            "harbor_force_build": False,
            "runner_tools": {"bash": bash_tool, "uv": uv_tool},
            "runner": [
                uv_tool["path"],
                "run",
                "--frozen",
                bash_tool["path"],
                "scripts/run.sh",
                "--job",
                job_path.stem,
            ],
        },
        "dry_run": {
            "network_requests": 0,
            "credential_loaded": False,
            "journal_mutations": 0,
            "paid_rollouts_authorized": False,
        },
    }
    manifest["content_sha256"] = _canonical_sha256(manifest)
    return manifest


def validate_launch_manifest(path: Path) -> Dict[str, Any]:
    manifest = _json(path)
    content_sha = manifest.pop("content_sha256", None)
    if content_sha != _canonical_sha256(manifest):
        raise LaunchError("paid launch manifest content hash mismatch")
    manifest["content_sha256"] = content_sha
    if manifest.get("schema_version") != SCHEMA_VERSION or manifest.get("quality_evidence") is not False:
        raise LaunchError("unsupported or mislabeled paid launch manifest")
    if not isinstance(manifest.get("quality_evidence_on_commit"), bool):
        raise LaunchError("paid launch commit evidence classification is missing")
    if manifest.get("workbuddy", {}).get("commit") != WORKBUDDY_PINNED_COMMIT:
        raise LaunchError("paid launch WorkBuddy commit drifted")
    if not re.fullmatch(
        r"[0-9a-f]{64}",
        str(manifest.get("workbuddy", {}).get("overlay_content_sha256", "")),
    ):
        raise LaunchError("paid launch installed-overlay identity is incomplete")
    host_control_plane = manifest.get("host_control_plane")
    if (
        not isinstance(host_control_plane, dict)
        or set(host_control_plane) != set(HOST_CONTROL_PLANE_MODULES)
        or any(
            not isinstance(row, dict)
            or not isinstance(row.get("path"), str)
            or not Path(row["path"]).is_absolute()
            or not isinstance(row.get("bytes"), int)
            or row["bytes"] <= 0
            or not re.fullmatch(r"[0-9a-f]{64}", str(row.get("sha256", "")))
            for row in host_control_plane.values()
        )
    ):
        raise LaunchError("paid launch host control-plane identity is incomplete")
    selected = manifest.get("cohort", {}).get("selected_tasks")
    if not isinstance(selected, list) or not selected or len(selected) != len(set(selected)):
        raise LaunchError("paid launch selected task set is empty or duplicated")
    preflight = manifest.get("environment_preflight") or {}
    preflight_receipt = preflight.get("receipt") or {}
    if (
        not isinstance(preflight, dict)
        or preflight.get("target_platform") != TARGET_PLATFORM
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(preflight.get("content_sha256", ""))
        )
        or not isinstance(preflight_receipt, dict)
        or not isinstance(preflight_receipt.get("path"), str)
        or not Path(preflight_receipt["path"]).is_absolute()
        or not isinstance(preflight_receipt.get("bytes"), int)
        or preflight_receipt["bytes"] <= 0
        or not re.fullmatch(
            r"[0-9a-f]{64}", str(preflight_receipt.get("sha256", ""))
        )
    ):
        raise LaunchError("paid launch environment preflight identity is incomplete")
    execution = manifest.get("execution") or {}
    if execution != {
        **execution,
        "n_attempts": 1,
        "n_concurrent_trials": 1,
        "shards": 1,
        "proxy_max_retries": 0,
        "shared_proxy": False,
        "credential_delivery": "anonymous-fd",
        "provider_key_env": PROVIDER_KEY_ENV,
        "remote_tinykg_env_cleared": True,
        "local_tinykg": "fresh-home-per-trial",
        "cacheable_first_request_hash_required": True,
        "target_platform": TARGET_PLATFORM,
        "docker_default_platform": TARGET_PLATFORM,
        "environment_preflight_required": True,
        "harbor_force_build": False,
    }:
        raise LaunchError("paid launch execution invariants drifted")
    tools = execution.get("runner_tools") or {}
    if (
        not isinstance(tools, dict)
        or set(tools) != {"bash", "uv"}
        or any(
            not isinstance(tools[name], dict)
            or not isinstance(tools[name].get("path"), str)
            or not Path(tools[name]["path"]).is_absolute()
            or not re.fullmatch(r"[0-9a-f]{64}", str(tools[name].get("sha256", "")))
            or not re.fullmatch(
                r"[0-9a-f]{64}", str(tools[name].get("version_sha256", ""))
            )
            for name in ("bash", "uv")
        )
    ):
        raise LaunchError("paid launch runner tool identity is incomplete")
    expected_runner = [
        tools["uv"]["path"], "run", "--frozen", tools["bash"]["path"], "scripts/run.sh", "--job",
        manifest.get("job", {}).get("slug"),
    ]
    if execution.get("runner") != expected_runner:
        raise LaunchError("paid launch runner differs from the pinned WorkBuddy path")
    if manifest.get("dry_run") != {
        "network_requests": 0,
        "credential_loaded": False,
        "journal_mutations": 0,
        "paid_rollouts_authorized": False,
    }:
        raise LaunchError("paid launch dry-run contract drifted")
    budget = manifest.get("budget") or {}
    required_budget = (
        "total_cost_microusd", "total_metered_tokens", "max_cost_microusd",
        "max_metered_tokens", "prior_exposure_microusd", "user_authority_microusd",
    )
    if any(
        not isinstance(budget.get(name), int)
        or isinstance(budget.get(name), bool)
        or budget[name] < 0
        for name in required_budget
    ):
        raise LaunchError("paid launch budget fields must be non-negative integers")
    if (
        min(
            budget["total_cost_microusd"], budget["total_metered_tokens"],
            budget["max_cost_microusd"], budget["max_metered_tokens"],
        ) <= 0
        or budget["max_cost_microusd"] > budget["total_cost_microusd"]
        or budget["max_metered_tokens"] > budget["total_metered_tokens"]
        or budget["user_authority_microusd"] != MAX_USER_AUTHORITY_MICROUSD
        or budget["prior_exposure_microusd"] + budget["total_cost_microusd"]
        > MAX_USER_AUTHORITY_MICROUSD
    ):
        raise LaunchError("paid launch budget authority is inconsistent")
    return manifest


def _reobserve_identity(row: Mapping[str, Any], label: str, *, maximum: int) -> None:
    if not isinstance(row, dict) or set(("path", "bytes", "sha256")) - set(row):
        raise LaunchError(f"{label} has no complete file identity")
    current = _identity(Path(row["path"]), maximum=maximum)
    if current != {key: row[key] for key in ("path", "bytes", "sha256")}:
        raise LaunchError(f"{label} changed after launch manifest creation")


def _paid_host_guard(workbuddy: Path, preflight: Mapping[str, Any]) -> None:
    dotenv = workbuddy / ".env"
    if dotenv.exists() or dotenv.is_symlink():
        raise LaunchError(
            "paid WorkBuddy checkout must not load an unbound .env file"
        )
    bound_docker = Path(preflight["docker"]["path"]).resolve(strict=True)
    active = shutil.which("docker")
    if active is None or Path(active).resolve(strict=True) != bound_docker:
        raise LaunchError("PATH docker differs from the preflight-bound client")
    uv_shadow = workbuddy / ".venv/bin/docker"
    if uv_shadow.exists() or uv_shadow.is_symlink():
        try:
            shadow = uv_shadow.resolve(strict=True)
        except OSError as exc:
            raise LaunchError("WorkBuddy uv environment has a broken docker shadow") from exc
        if shadow != bound_docker:
            raise LaunchError("WorkBuddy uv environment shadows the preflight-bound docker")


def _reobserve_host_control_plane(manifest: Mapping[str, Any]) -> None:
    if _host_control_plane() != manifest.get("host_control_plane"):
        raise LaunchError("WorkBuddy host control plane changed after manifest creation")


def _reobserve_launch_inputs(manifest: Mapping[str, Any]) -> None:
    _reobserve_host_control_plane(manifest)
    workbuddy = Path(manifest["workbuddy"]["checkout"])
    if _git(workbuddy, "rev-parse", "HEAD") != WORKBUDDY_PINNED_COMMIT:
        raise LaunchError("WorkBuddy checkout changed after launch manifest creation")
    _reobserve_identity(manifest["workbuddy"]["overlay"], "WorkBuddy overlay", maximum=16 * 1024 * 1024)
    try:
        overlay = validate_installed_overlay(workbuddy)
    except OverlayError as exc:
        raise LaunchError(str(exc)) from exc
    if overlay["overlay_sha256"] != manifest["workbuddy"]["overlay_content_sha256"]:
        raise LaunchError("installed WorkBuddy overlay identity drifted")
    _reobserve_identity(manifest["cohort"]["manifest"], "cohort manifest", maximum=16 * 1024 * 1024)
    _reobserve_identity(manifest["artifacts"]["manifest"], "split-mount manifest", maximum=16 * 1024 * 1024)
    for name, row in manifest["artifacts"]["executables"].items():
        _reobserve_identity(row, f"split-mount {name}", maximum=512 * 1024 * 1024)
        if _elf_machine(Path(row["path"])) != ELF_MACHINE_X86_64:
            raise LaunchError(f"split-mount {name} ELF architecture drifted")
    preflight_row = manifest["environment_preflight"]
    _reobserve_identity(
        preflight_row["receipt"],
        "environment preflight receipt",
        maximum=16 * 1024 * 1024,
    )
    try:
        preflight = validate_environment_preflight(
            Path(preflight_row["receipt"]["path"]),
            workbuddy=workbuddy,
            dataset=str(manifest["cohort"]["dataset"]),
            selected_tasks=list(manifest["cohort"]["selected_tasks"]),
            inspect_images=True,
        )
    except EnvironmentPreflightError as exc:
        raise LaunchError(str(exc)) from exc
    if (
        preflight["content_sha256"] != preflight_row["content_sha256"]
        or preflight["target_platform"] != TARGET_PLATFORM
    ):
        raise LaunchError("environment preflight receipt drifted")
    _paid_host_guard(workbuddy, preflight)
    for name, args, is_bash in (
        ("bash", ("--version",), True),
        ("uv", ("--version",), False),
    ):
        observed = _runner_tool(
            Path(manifest["execution"]["runner_tools"][name]["path"]),
            args,
            bash=is_bash,
        )
        if observed != manifest["execution"]["runner_tools"][name]:
            raise LaunchError(f"WorkBuddy runner tool changed after manifest creation: {name}")
    _reobserve_identity(manifest["job"]["config"], "WorkBuddy job config", maximum=16 * 1024 * 1024)
    _reobserve_identity(manifest["model"]["config"], "WorkBuddy model config", maximum=16 * 1024 * 1024)
    backend_url = os.environ.get(manifest["model"]["backend_url_env"], "")
    if _sha256_bytes(backend_url.encode("utf-8")) != manifest["model"]["backend_url_sha256"]:
        raise LaunchError("WorkBuddy provider base URL changed after launch manifest creation")


def _write_private_new(path: Path, payload: bytes) -> None:
    if path.exists() or path.is_symlink():
        raise LaunchError(f"refusing to overwrite paid launch artifact: {path}")
    parent = path.parent.resolve(strict=True)
    info = parent.stat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o022:
        raise LaunchError("paid launch artifact parent must be a trusted private directory")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise LaunchError("paid launch artifact parent must be owned by the current user")
    path = parent / path.name
    temporary = path.with_name(path.name + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise LaunchError("short paid launch artifact write")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    parent_fd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _read_credential(descriptor: int) -> bytes:
    if descriptor < 3:
        raise LaunchError("credential FD must be greater than 2")
    chunks: list[bytes] = []
    observed = 0
    try:
        while True:
            chunk = os.read(descriptor, min(4096, MAX_CREDENTIAL_BYTES + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > MAX_CREDENTIAL_BYTES:
                raise LaunchError("credential FD exceeds 16384 bytes")
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
    payload = b"".join(chunks)
    if not payload or b"\x00" in payload or b"\r" in payload or b"\n" in payload:
        raise LaunchError("credential FD is empty or contains a forbidden byte")
    try:
        payload.decode("utf-8", errors="strict")
    except UnicodeError as exc:
        raise LaunchError("credential FD is not UTF-8") from exc
    return payload


def _task_for_path(path: Path, selected: Sequence[str]) -> str | None:
    for part in reversed(path.parts):
        for task in selected:
            if part == task or part.startswith(task + "__"):
                return task
    return None


def _official_task_identity(
    trajectory_path: Path,
    manifest: Mapping[str, Any],
    selected: Sequence[str],
    expected_model_route: str,
) -> tuple[str, Path, Dict[str, Any]]:
    """Bind a trajectory through Harbor's authoritative trial result.

    Harbor truncates long task names in trial-directory basenames and appends a
    random suffix, so directory-name heuristics are not provenance.  The
    sibling result carries the canonical task name, staged task path, source,
    model route, checksum and trial URI; require all of them to agree.
    """
    trial_dir = trajectory_path.parent.parent.resolve()
    result_path = trial_dir / "result.json"
    result = _json(result_path)
    task_id = result.get("task_id") or {}
    agent_info = result.get("agent_info") or {}
    model_info = agent_info.get("model_info") or {}
    raw_task_path = task_id.get("path") if isinstance(task_id, dict) else None
    dataset_root = Path(str(manifest["cohort"]["dataset"])).parent.name
    matches = [
        task
        for task in selected
        if result.get("task_name") == f"workbuddy/{task}"
        and raw_task_path
        == str(
            Path(".workspace/tmp/staged")
            / str(manifest["run_id"])
            / dataset_root
            / "tasks"
            / task
        )
    ]
    checksum = result.get("task_checksum")
    if (
        len(matches) != 1
        or result.get("source") != "tasks"
        or result.get("trial_uri") != trial_dir.as_uri()
        or result.get("exception_info") is not None
        or agent_info.get("name") != "metacodes"
        or model_info.get("name") != expected_model_route
        or not isinstance(checksum, str)
        or not re.fullmatch(r"[0-9a-f]{64}", checksum)
    ):
        raise LaunchError(
            f"official WorkBuddy trial identity is incomplete or drifted: {result_path}"
        )
    return matches[0], result_path, result


def _runtime_contract(manifest: Mapping[str, Any]) -> Dict[str, object]:
    workbuddy = Path(manifest["workbuddy"]["checkout"])
    run_id = manifest["run_id"]
    instance_dir = workbuddy / "scripts/logs/instances" / run_id
    resolved_path = instance_dir / "manifest.json"
    proxy_path = instance_dir / "proxy.yaml"
    resolved = _json(resolved_path)
    selected = list(manifest["cohort"]["selected_tasks"])
    if (
        resolved.get("selected_tasks") != selected
        or resolved.get("model_connection") != "local_proxy"
        or resolved.get("record_full_io") is not True
        or resolved.get("harness_resolved_slug") != "metacodes/0.1.0"
        or resolved.get("model_slug") != manifest["model"]["slug"]
    ):
        raise LaunchError("resolved WorkBuddy manifest differs from the paid launch contract")
    proxy = _yaml(proxy_path).get("proxy")
    if not isinstance(proxy, dict) or proxy.get("backend_retries") != 0:
        raise LaunchError("resolved WorkBuddy proxy does not enforce zero retries")
    for route in proxy.get("routes") or []:
        backend = route.get("backend") if isinstance(route, dict) else None
        if isinstance(backend, dict) and backend.get("max_retries", 0) != 0:
            raise LaunchError("a WorkBuddy proxy route overrides the zero-retry gate")
    unattributed = workbuddy / "scripts/logs/proxy" / f"{run_id}.jsonl"
    if unattributed.exists() and any(
        line.strip()
        for line in _read_regular(unattributed, maximum=64 * 1024 * 1024).splitlines()
    ):
        raise LaunchError("WorkBuddy left unattributed provider requests outside task receipts")
    return {
        "resolved_manifest": _identity(resolved_path),
        "proxy_config": _identity(proxy_path),
        "unattributed_provider_requests": 0,
    }


def _collect_usage(
    manifest: Mapping[str, Any], *, started_ns: int, official_runner: bool
) -> Dict[str, object]:
    workbuddy = Path(manifest["workbuddy"]["checkout"])
    job_slug = manifest["job"]["slug"]
    selected = list(manifest["cohort"]["selected_tasks"])
    result_root = workbuddy / "results" / job_slug
    trajectories = [
        path
        for path in result_root.rglob("trajectory.json")
        if path.is_file() and path.stat().st_mtime_ns >= started_ns
    ] if result_root.exists() else []
    if len(trajectories) != len(selected):
        raise LaunchError(
            f"expected {len(selected)} new WorkBuddy trajectories, observed {len(trajectories)}"
        )
    rows: Dict[str, object] = {}
    total_cost = 0.0
    total_tokens = 0
    total_cache_read = 0
    total_cache_create = 0
    total_requests = 0
    expected_model_route = ""
    if official_runner:
        resolved_path = (
            workbuddy
            / "scripts/logs/instances"
            / str(manifest["run_id"])
            / "manifest.json"
        )
        expected_model_route = str(_json(resolved_path).get("model_route") or "")
        if not expected_model_route or "__" in expected_model_route:
            raise LaunchError("official WorkBuddy model route is missing or Harbor-unsafe")
    for trajectory_path in sorted(trajectories):
        trial_result_path: Path | None = None
        trial_result: Dict[str, Any] | None = None
        if official_runner:
            task, trial_result_path, trial_result = _official_task_identity(
                trajectory_path,
                manifest,
                selected,
                expected_model_route,
            )
        else:
            task = _task_for_path(trajectory_path, selected)
        if task is None or task in rows:
            raise LaunchError(f"cannot uniquely bind trajectory to selected task: {trajectory_path}")
        trajectory = _json(trajectory_path)
        final = trajectory.get("final_metrics") or {}
        extra = final.get("extra") or {}
        cost = final.get("total_cost_usd")
        prompt = final.get("total_prompt_tokens")
        completion = final.get("total_completion_tokens")
        if not isinstance(cost, (int, float)) or isinstance(cost, bool) or not math.isfinite(cost) or cost < 0:
            raise LaunchError(f"trajectory has invalid cost: {trajectory_path}")
        if (
            not isinstance(prompt, int)
            or isinstance(prompt, bool)
            or not isinstance(completion, int)
            or isinstance(completion, bool)
            or prompt < 0
            or completion < 0
        ):
            raise LaunchError(f"trajectory has invalid token usage: {trajectory_path}")
        request_log = trajectory_path.parent / "requests.jsonl"
        request_lines = [
            line for line in _read_regular(request_log, maximum=64 * 1024 * 1024).splitlines()
            if line.strip()
        ]
        if not request_lines:
            raise LaunchError(f"trajectory has no provider request audit: {trajectory_path}")
        try:
            first_record = json.loads(request_lines[0].decode("utf-8"))
            first_body = dict(first_record["request"]["body"])
        except (UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
            raise LaunchError(f"invalid first request audit for {trajectory_path}: {exc}") from exc
        first_body.pop("model", None)
        prefix_hash = _canonical_sha256(first_body)
        cache_read = final.get("total_cached_tokens", 0)
        cache_create = extra.get("cache_creation_input_tokens", 0)
        if cache_read is None:
            cache_read = 0
        if cache_create is None:
            cache_create = 0
        if (
            not isinstance(cache_read, int)
            or isinstance(cache_read, bool)
            or cache_read < 0
            or not isinstance(cache_create, int)
            or isinstance(cache_create, bool)
            or cache_create < 0
        ):
            raise LaunchError(f"trajectory has invalid cache token usage: {trajectory_path}")
        metered_tokens = prompt + completion + cache_read + cache_create
        total_cost += float(cost)
        total_tokens += metered_tokens
        total_cache_read += cache_read
        total_cache_create += cache_create
        total_requests += len(request_lines)
        rows[task] = {
            "trajectory_sha256": _identity(trajectory_path)["sha256"],
            "requests_sha256": _identity(request_log)["sha256"],
            "provider_requests": len(request_lines),
            "cacheable_first_request_sha256": prefix_hash,
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "metered_tokens": metered_tokens,
            "cache_read_input_tokens": cache_read,
            "cache_creation_input_tokens": cache_create,
            "cost_usd": float(cost),
        }
        if trial_result_path is not None and trial_result is not None:
            rows[task].update(
                {
                    "trial_result_sha256": _identity(trial_result_path)["sha256"],
                    "task_checksum": trial_result["task_checksum"],
                }
            )
    if set(rows) != set(selected):
        raise LaunchError("WorkBuddy result set differs from frozen task selection")
    result = {
        "tasks": rows,
        "provider_requests": total_requests,
        "cost_microusd": usd_to_microusd_ceiling(total_cost),
        "metered_tokens": total_tokens,
        "cache_read_input_tokens": total_cache_read,
        "cache_creation_input_tokens": total_cache_create,
    }
    if official_runner:
        result["runtime_contract"] = _runtime_contract(manifest)
    return result


def _receipt_quality_evidence(
    manifest: Mapping[str, Any], *, official_runner: bool
) -> bool:
    return official_runner and manifest["quality_evidence_on_commit"] is True


def execute_launch(
    *,
    manifest_path: Path,
    journal_path: Path,
    receipt_path: Path,
    credential_fd: int,
    runner_argv: Sequence[str] | None = None,
    fault_hook: FaultHook | None = None,
) -> Dict[str, object]:
    manifest = validate_launch_manifest(manifest_path)
    official_runner = runner_argv is None
    if official_runner:
        _reobserve_launch_inputs(manifest)
    budget = manifest["budget"]
    model = manifest["model"]
    authority = BudgetAuthority(
        manifest_sha256=manifest["content_sha256"],
        model_fingerprint=model["fingerprint"],
        provider_identity=model["provider_identity"],
        total_cost_microusd=budget["total_cost_microusd"],
        total_metered_tokens=budget["total_metered_tokens"],
    )
    transaction = BudgetTransaction(
        run_id=manifest["run_id"],
        manifest_sha256=manifest["content_sha256"],
        model_fingerprint=model["fingerprint"],
        harness_fingerprint=manifest["harness_fingerprint"],
        provider_identity=model["provider_identity"],
        max_cost_microusd=budget["max_cost_microusd"],
        max_metered_tokens=budget["max_metered_tokens"],
    )
    workbuddy = Path(manifest["workbuddy"]["checkout"])
    argv = list(runner_argv or manifest["execution"]["runner"])
    credential_open = True
    try:
        with BudgetJournal(journal_path, authority) as journal:
            reserved = journal.reserve(transaction)
            transaction_id = reserved["transaction_id"]
            read_fd, write_fd = os.pipe()
            authorized = False
            try:
                # Re-observe every immutable input after reservation and before
                # the durable provider permit. A failure here is safely abortable.
                validate_launch_manifest(manifest_path)
                if official_runner:
                    _reobserve_launch_inputs(manifest)
                authorization = journal.authorize_request(
                    transaction_id,
                    expected_revision=reserved["journal_revision"],
                    expected_head_sha256=reserved["journal_head_sha256"],
                )
                authorized = True
                if fault_hook is not None:
                    fault_hook("after_request_authorized", authorization)

                try:
                    credential = _read_credential(credential_fd)
                finally:
                    credential_open = False
                try:
                    offset = 0
                    while offset < len(credential):
                        written = os.write(write_fd, credential[offset:])
                        if written <= 0:
                            raise LaunchError("short credential pipe write")
                        offset += written
                finally:
                    os.close(write_fd)
                    write_fd = -1

                environment = dict(os.environ)
                for name in (
                    "ANTHROPIC_API_KEY",
                    "OPENAI_API_KEY",
                    "METASK_API_KEY",
                    "TINYKG_API_KEY",
                    "TINYKG_REMOTE_URL",
                    "TINYKG_REMOTE_CONFIG",
                    "TINYKG_REMOTE_EXPECTED_BUILD_ID",
                ):
                    environment.pop(name, None)
                environment.update(
                    {
                        PROVIDER_KEY_ENV: f"fd://{read_fd}",
                        "WBBENCH_PROXY_MAX_RETRIES": "0",
                        "WBBENCH_PROXY_RETRY_DELAY_MS": "1",
                        "SHARDS": "1",
                        "SHARD_CONCURRENCY": "1",
                        "PROXY_MAX_CONCURRENT": "1",
                        "SHARED_PROXY": "0",
                        "INSTANCE_ID": str(manifest["run_id"]),
                        "DOCKER_DEFAULT_PLATFORM": TARGET_PLATFORM,
                        "NO_FORCE_BUILD": "1",
                    }
                )
                started_ns = time.time_ns()
                completed = subprocess.run(
                    argv,
                    cwd=workbuddy,
                    env=environment,
                    pass_fds=(read_fd,),
                    check=False,
                )
                os.close(read_fd)
                read_fd = -1
                if fault_hook is not None:
                    fault_hook("after_provider_return_before_commit", authorization)
                if completed.returncode != 0:
                    raise LaunchError(
                        f"WorkBuddy runner exited {completed.returncode}; "
                        "authorized maximum remains exposed"
                    )
                usage = _collect_usage(
                    manifest,
                    started_ns=started_ns,
                    official_runner=official_runner,
                )
                committed = journal.commit(
                    transaction_id,
                    actual_cost_microusd=usage["cost_microusd"],
                    actual_metered_tokens=usage["metered_tokens"],
                )
                snapshot = journal.snapshot()
                receipt = {
                    "schema_version": RECEIPT_SCHEMA_VERSION,
                    "quality_evidence": _receipt_quality_evidence(
                        manifest, official_runner=official_runner
                    ),
                    "launch_manifest_content_sha256": manifest["content_sha256"],
                    "run_id": manifest["run_id"],
                    "cohort": manifest["cohort"],
                    "usage": usage,
                    "budget_transaction": committed,
                    "journal": {
                        "journal_id": snapshot["journal_id"],
                        "revision": snapshot["revision"],
                        "head_sha256": snapshot["head_sha256"],
                        "transaction_states": snapshot["transaction_states"],
                    },
                    "elapsed_seconds": (time.time_ns() - started_ns)
                    / 1_000_000_000,
                }
                _write_private_new(
                    receipt_path,
                    (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode(
                        "utf-8"
                    ),
                )
                return receipt
            except BaseException:
                if not authorized:
                    journal.abort_pre_request(transaction_id)
                raise
            finally:
                for descriptor in (read_fd, write_fd):
                    if descriptor >= 0:
                        try:
                            os.close(descriptor)
                        except OSError:
                            pass
    finally:
        if credential_open:
            try:
                os.close(credential_fd)
            except OSError:
                pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--run-id", required=True)
    create.add_argument("--workbuddy-checkout", type=Path, required=True)
    create.add_argument("--cohort-manifest", type=Path, required=True)
    create.add_argument("--subset", choices=("code", "web", "office", "security"), required=True)
    create.add_argument("--cohort", choices=("dev", "promotion_a", "promotion_b", "sealed"), required=True)
    create.add_argument("--take", type=int, default=0)
    create.add_argument("--split-mount-manifest", type=Path, required=True)
    create.add_argument("--environment-preflight-receipt", type=Path, required=True)
    create.add_argument("--job-config", type=Path, required=True)
    create.add_argument("--model-config", type=Path, required=True)
    create.add_argument("--runner-bash", type=Path, required=True)
    create.add_argument("--runner-uv", type=Path, required=True)
    create.add_argument("--provider-identity", required=True)
    create.add_argument("--total-cost-microusd", type=int, required=True)
    create.add_argument("--total-metered-tokens", type=int, required=True)
    create.add_argument("--max-cost-microusd", type=int, required=True)
    create.add_argument("--max-metered-tokens", type=int, required=True)
    create.add_argument("--prior-exposure-microusd", type=int, default=0)
    create.add_argument("--quality-evidence-on-commit", action="store_true")
    create.add_argument("--output", type=Path, required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--budget-journal", type=Path, required=True)
    run.add_argument("--receipt", type=Path, required=True)
    run.add_argument("--credential-fd", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "create":
            manifest = build_launch_manifest(
                run_id=args.run_id,
                workbuddy_checkout=args.workbuddy_checkout,
                cohort_manifest=args.cohort_manifest,
                subset=args.subset,
                cohort=args.cohort,
                take=args.take,
                split_mount_manifest=args.split_mount_manifest,
                environment_preflight_receipt=args.environment_preflight_receipt,
                job_config=args.job_config,
                model_config=args.model_config,
                runner_bash=args.runner_bash,
                runner_uv=args.runner_uv,
                provider_identity=args.provider_identity,
                total_cost_microusd=args.total_cost_microusd,
                total_metered_tokens=args.total_metered_tokens,
                max_cost_microusd=args.max_cost_microusd,
                max_metered_tokens=args.max_metered_tokens,
                prior_exposure_microusd=args.prior_exposure_microusd,
                quality_evidence_on_commit=args.quality_evidence_on_commit,
            )
            _write_private_new(
                args.output,
                (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8"),
            )
            print(json.dumps(manifest["dry_run"], sort_keys=True))
            return 0
        receipt = execute_launch(
            manifest_path=args.manifest,
            journal_path=args.budget_journal,
            receipt_path=args.receipt,
            credential_fd=args.credential_fd,
        )
        print(json.dumps({"run_id": receipt["run_id"], "state": "committed"}, sort_keys=True))
        return 0
    except (LaunchError, OSError, ValueError) as exc:
        parser.error(str(exc))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
