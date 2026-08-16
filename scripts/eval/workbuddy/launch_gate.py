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
    MAX_USER_AUTHORITY_MICROUSD,
    MAX_USER_AUTHORITY_USD,
    validate_checkpoint_payload,
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
from .progress_analysis import analyze_progress
from .stage_artifacts import (
    ELF_MACHINE_X86_64,
    MAX_PROJECT_RULE_BYTES,
    MAX_PROJECT_RULE_FILES,
    PROJECT_KERNEL_TARGET,
    PROJECT_ROOT,
    PROJECT_RULES_TARGET,
    TARGET_PLATFORM,
    _elf_machine,
)
from .trace import (
    CONTROL_METRICS_SCHEMA,
    CONTROL_METRICS_SCHEMAS,
    LEGACY_CONTROL_METRICS_SCHEMA,
    OBSERVATION_FILENAME,
    TraceError,
    load_control_metrics,
    project_state_hash,
)


LEGACY_SCHEMA_VERSION = "metacodes-workbuddy-paid-launch-v1"
PAIRED_SCHEMA_VERSION = "metacodes-workbuddy-paid-launch-v2"
SCHEMA_VERSION = "metacodes-workbuddy-paid-launch-v3"
LEGACY_RECEIPT_SCHEMA_VERSION = "metacodes-workbuddy-paid-receipt-v1"
RECEIPT_SCHEMA_VERSION = "metacodes-workbuddy-paid-receipt-v2"
AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1 = (
    "metacodes-workbuddy-authorized-failure-v1"
)
AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION = (
    "metacodes-workbuddy-authorized-failure-v2"
)
AUTHORIZED_FAILURE_STAGES = {
    "runner_nonzero",
    "post_run_evidence_audit",
}
PROVIDER_KEY_ENV = "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF"
RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$")
MAX_FAILURE_ARTIFACTS = 256
# Request logs re-send the full accumulated conversation every provider turn,
# so a single long trial's requests.jsonl scales with (turns x context), not
# with the transcript.  Derivation from the budget cap this gate enforces:
# 40M metered tokens/arm x ~4 bytes/token x ~2x JSON-escaping overhead is a
# ~320MB worst case for one trial that burned the whole arm budget.  A 64MB
# guess already rejected a real, legitimate 88MB log after runner exit 0 and
# silently dropped it from the evidence freeze; bounds must dominate what the
# producer can actually produce.
MAX_FAILURE_ARTIFACT_BYTES = 512 * 1024 * 1024
MAX_FAILURE_ARTIFACT_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
MAX_REQUEST_LOG_BYTES = 512 * 1024 * 1024
MAX_FAILURE_REQUEST_RECORDS = 4096
MAX_FAILURE_WALK_ENTRIES = 8192
FaultHook = Callable[[str, Mapping[str, Any]], None]
HOST_CONTROL_PLANE_MODULES = {
    "environment_preflight": Path(__file__).with_name("environment_preflight.py"),
    "install_overlay": Path(__file__).with_name("install_overlay.py"),
    "key_fd": Path(__file__).with_name("key_fd.py"),
    "launch_gate": Path(__file__),
    "memory_budget_journal": Path(__file__).parents[1] / "memory_budget_journal.py",
    "model": Path(__file__).parents[1] / "model.py",
    "paired_analysis": Path(__file__).with_name("paired_analysis.py"),
    "progress_analysis": Path(__file__).with_name("progress_analysis.py"),
    "stage_artifacts": Path(__file__).with_name("stage_artifacts.py"),
    "workbuddy_trace": Path(__file__).with_name("trace.py"),
}
# Freeze every historical source set explicitly.  Computing a legacy set as
# "current minus one" silently rewrites old protocol history whenever a new
# host module is added.
LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V1 = frozenset(
    {
        "environment_preflight",
        "install_overlay",
        "key_fd",
        "launch_gate",
        "memory_budget_journal",
        "model",
        "stage_artifacts",
    }
)
LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V2 = frozenset(
    {*LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V1, "workbuddy_trace"}
)
# paid-launch-v3 manifests created before the verification-checkpoint study
# bound the paired analyzer but not its new progress-evidence dependency.
# Keep that exact source set readable; checkpoint studies reject it below and
# require the complete current set before authorization.
LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V3 = frozenset(
    set(HOST_CONTROL_PLANE_MODULES) - {"progress_analysis"}
)
AUTHORIZED_FAILURE_RECEIPT_MODES = {"in_band", "offline_recovery"}
PROJECT_CONTROL_MODES = {"absent", "disabled", "enforced"}
COMPARISON_SCHEMA_VERSION = "metacodes-workbuddy-project-control-comparison-v1"


class LaunchError(ValidationError):
    pass


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_sha256(value: object) -> str:
    return _sha256_bytes(stable_json(value).encode("utf-8"))


def _comparison_covariates(
    *,
    workbuddy_commit: str,
    overlay_sha256: str,
    cohort: Mapping[str, Any],
    artifacts: Mapping[str, Any],
    environment_preflight_sha256: str,
    job: Mapping[str, Any],
    model_fingerprint: str,
    backend_url_sha256: str,
    runner_tools: Mapping[str, Any],
    host_control_plane: Mapping[str, Any],
    budget: Mapping[str, int],
) -> Dict[str, object]:
    """Return the frozen paired-study inputs excluding only actuation.

    Baseline and treatment use separate WorkBuddy job slugs/result roots and
    separate budget transactions.  Those logistics are intentionally erased;
    every task, artifact, model, cache/context setting and cap remains bound.
    """

    normalized_job = json.loads(json.dumps(job))
    normalized_job.pop("jobs_dir", None)
    overrides = normalized_job.get("harness_params_override")
    if isinstance(overrides, dict):
        overrides.pop("METACODES_PROJECT_CONTROL_MODE", None)
        overrides.pop("METACODES_VERIFICATION_CHECKPOINT", None)
        overrides.pop("METACODES_VERIFICATION_FINAL_GATE", None)
        overrides.pop("METACODES_VERIFICATION_FINAL_OBSERVE", None)
        overrides.pop("METACODES_MEMORY_ACCUMULATION", None)
    stable_artifacts = json.loads(json.dumps(artifacts))
    # Absolute staging paths describe where identical bytes were observed, not
    # an experimental variable.  Keep every digest/size/architecture field.
    def erase_paths(value: object) -> None:
        if isinstance(value, dict):
            value.pop("path", None)
            for child in value.values():
                erase_paths(child)
        elif isinstance(value, list):
            for child in value:
                erase_paths(child)

    erase_paths(stable_artifacts)
    stable_host = {
        name: {key: value for key, value in row.items() if key != "path"}
        for name, row in host_control_plane.items()
    }
    stable_tools = {
        name: {key: value for key, value in row.items() if key != "path"}
        for name, row in runner_tools.items()
    }
    return {
        "workbuddy_commit": workbuddy_commit,
        "overlay_sha256": overlay_sha256,
        "cohort": {
            key: cohort[key]
            for key in (
                "subset",
                "cohort",
                "take",
                "dataset",
                "selected_tasks",
                "selected_tasks_sha256",
            )
        },
        "artifacts": stable_artifacts,
        "environment_preflight_sha256": environment_preflight_sha256,
        "job_without_treatment_or_result_root": normalized_job,
        "model_fingerprint": model_fingerprint,
        "backend_url_sha256": backend_url_sha256,
        "runner_tools": stable_tools,
        "host_control_plane": stable_host,
        "budget": {
            key: budget[key]
            for key in (
                "total_cost_microusd",
                "total_metered_tokens",
                "max_cost_microusd",
                "max_metered_tokens",
            )
        },
        "actor_prompt_changed": False,
        "tool_schema_changed": False,
        "provider_cache_prefix_changed_by_control_plane": False,
    }


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


def _parse_json(payload: bytes, path: Path) -> Dict[str, Any]:
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


def _observed_json(
    path: Path, *, maximum: int = 16 * 1024 * 1024
) -> tuple[Dict[str, Any], Dict[str, object], bytes]:
    """Parse and identify one immutable observation of a regular JSON file."""

    # Do not resolve this locator after the read: an attacker replacing the
    # directory entry with a symlink must not change which path the evidence
    # claims was observed.  _read_regular independently rejects links and
    # detects mutation of the opened inode.
    locator = str(path.absolute())
    payload = _read_regular(path, maximum=maximum)
    identity = {
        "path": locator,
        "bytes": len(payload),
        "sha256": _sha256_bytes(payload),
    }
    return _parse_json(payload, path), identity, payload


def _json(path: Path) -> Dict[str, Any]:
    value, _, _ = _observed_json(path)
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
            # Version banners are localized: a zh_CN host prints
            # "GNU bash，版本 5.3.15", which no English regex can parse and
            # which would reject a perfectly valid runner. Identity probes
            # must read the C-locale spelling.
            env={**os.environ, "LC_ALL": "C", "LANG": "C"},
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
    result: Dict[str, object] = {
        "manifest": _identity(path),
        "target_platform": TARGET_PLATFORM,
        "executables": observed,
    }
    project = manifest.get("project_control")
    if project is not None:
        if not isinstance(project, dict) or project.get("schema_version") != (
            "metacodes-workbuddy-project-control-v1"
        ):
            raise LaunchError("split-mount project control manifest is malformed")
        kernel = project.get("kernel")
        rules = project.get("rules")
        if not isinstance(kernel, dict) or not isinstance(rules, dict):
            raise LaunchError("split-mount project control identity is incomplete")
        kernel_relative = _stage_relative_path(
            kernel.get("relative_path"), "project kernel"
        )
        rules_relative = _stage_relative_path(
            rules.get("relative_path"), "project rules"
        )
        kernel_path = stage / kernel_relative
        kernel_identity = _identity(kernel_path, maximum=512 * 1024 * 1024)
        if (
            kernel_identity["sha256"] != kernel.get("sha256")
            or _elf_machine(kernel_path) != ELF_MACHINE_X86_64
            or kernel.get("elf_machine") != ELF_MACHINE_X86_64
        ):
            raise LaunchError("split-mount project kernel identity drifted")
        rules_identity = _project_rule_tree(stage / rules_relative)
        for key in ("files", "bytes", "tree_sha256"):
            if rules_identity[key] != rules.get(key):
                raise LaunchError("split-mount project-rules tree identity drifted")
        expected_project_sha = _sha256_bytes(
            b"metacodes-project-identity-v1\x00" + PROJECT_ROOT.encode("utf-8")
        )
        if (
            kernel_relative != PROJECT_KERNEL_TARGET
            or rules_relative != PROJECT_RULES_TARGET
            or rules.get("project_root") != PROJECT_ROOT
            or rules.get("project_sha256") != expected_project_sha
        ):
            raise LaunchError("split-mount project control target drifted")
        if rules.get("active_kernel_sha256") != kernel_identity["sha256"]:
            raise LaunchError("split-mount active project rules bind another kernel")
        result["project_control"] = {
            "schema_version": "metacodes-workbuddy-project-control-v1",
            "kernel": {
                **kernel_identity,
                "elf_machine": ELF_MACHINE_X86_64,
                "relative_path": kernel_relative.as_posix(),
            },
            "rules": {
                **rules_identity,
                "relative_path": rules_relative.as_posix(),
                "project_root": rules["project_root"],
                "project_sha256": rules["project_sha256"],
            },
        }
    return result


def _stage_relative_path(value: object, label: str) -> Path:
    if not isinstance(value, str):
        raise LaunchError(f"split-mount {label} path is missing")
    relative = Path(value)
    if (
        relative.is_absolute()
        or not relative.parts
        or "." in relative.parts
        or ".." in relative.parts
        or relative.as_posix() != value
    ):
        raise LaunchError(f"split-mount {label} path is not normalized")
    return relative


def _project_rule_tree(root: Path) -> Dict[str, object]:
    if root.is_symlink() or not root.is_dir():
        raise LaunchError("split-mount project-rules path is not a real directory")
    rows: list[tuple[str, Dict[str, object]]] = []
    total = 0
    for candidate in sorted(root.rglob("*")):
        relative = candidate.relative_to(root)
        info = candidate.lstat()
        if candidate.is_symlink():
            raise LaunchError(
                f"split-mount project-rules contains a symlink: {relative}"
            )
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise LaunchError(
                f"split-mount project-rules contains a linked/non-regular file: {relative}"
            )
        if len(rows) >= MAX_PROJECT_RULE_FILES:
            raise LaunchError("split-mount project-rules exceeds the file-count bound")
        total += info.st_size
        if total > MAX_PROJECT_RULE_BYTES:
            raise LaunchError("split-mount project-rules exceeds the byte bound")
        rows.append(
            (
                relative.as_posix(),
                _identity(candidate, maximum=MAX_PROJECT_RULE_BYTES),
            )
        )
    if not rows:
        raise LaunchError("split-mount project-rules tree is empty")
    digest = hashlib.sha256()
    for relative, identity in rows:
        name = relative.encode("utf-8")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(int(identity["bytes"]).to_bytes(8, "big"))
        digest.update(bytes.fromhex(str(identity["sha256"])))
    return {
        "path": str(root.resolve()),
        "files": len(rows),
        "bytes": total,
        "tree_sha256": digest.hexdigest(),
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
    comparison_id: str | None = None,
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
    project_control = artifact_row.get("project_control")
    project_overrides = job.get("harness_params_override") or {}
    if not isinstance(project_overrides, dict):
        raise LaunchError("WorkBuddy harness_params_override must be a mapping")
    project_control_mode = project_overrides.get("METACODES_PROJECT_CONTROL_MODE")
    verification_checkpoint = project_overrides.get(
        "METACODES_VERIFICATION_CHECKPOINT", False
    )
    if (
        "METACODES_VERIFICATION_CHECKPOINT" not in project_overrides
        or not isinstance(verification_checkpoint, bool)
    ):
        raise LaunchError(
            "WorkBuddy verification checkpoint treatment must be an explicit boolean"
        )
    verification_final_gate = project_overrides.get(
        "METACODES_VERIFICATION_FINAL_GATE", False
    )
    verification_final_observe = project_overrides.get(
        "METACODES_VERIFICATION_FINAL_OBSERVE", False
    )
    if not isinstance(verification_final_gate, bool) or not isinstance(
        verification_final_observe, bool
    ):
        raise LaunchError(
            "WorkBuddy verification final-gate treatment must be explicit booleans"
        )
    if verification_final_gate and verification_final_observe:
        raise LaunchError(
            "WorkBuddy verification final gate and observe modes are exclusive"
        )
    memory_accumulation = project_overrides.get(
        "METACODES_MEMORY_ACCUMULATION", False
    )
    if not isinstance(memory_accumulation, bool):
        raise LaunchError(
            "WorkBuddy memory accumulation treatment must be an explicit boolean"
        )
    expected_project_overrides = (
        {
            "METACODES_PROJECT_CONTROL_MODE": project_control_mode,
            "METACODES_PROJECT_RULES_RELATIVE": project_control["rules"][
                "relative_path"
            ],
            "METACODES_PROJECT_KERNEL_RELATIVE": project_control["kernel"][
                "relative_path"
            ],
        }
        if isinstance(project_control, dict)
        else {}
    )
    if isinstance(project_control, dict):
        if project_control_mode not in {"disabled", "enforced"}:
            raise LaunchError(
                "staged project control requires explicit disabled/enforced treatment"
            )
    elif project_control_mode is not None:
        raise LaunchError("project-control treatment requires staged artifacts")
    observed_project_overrides = {
        key: project_overrides.get(key)
        for key in expected_project_overrides
    }
    if observed_project_overrides != expected_project_overrides:
        raise LaunchError(
            "staged project control is not wired into the paid WorkBuddy job"
        )
    if not expected_project_overrides and any(
        key in project_overrides
        for key in (
            "METACODES_PROJECT_RULES_RELATIVE",
            "METACODES_PROJECT_KERNEL_RELATIVE",
            "METACODES_PROJECT_CONTROL_MODE",
        )
    ):
        raise LaunchError("WorkBuddy job requests project control that was not staged")
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
        raise LaunchError(
            f"cumulative WorkBuddy authority exceeds the user ${MAX_USER_AUTHORITY_USD} limit"
        )
    if not isinstance(quality_evidence_on_commit, bool):
        raise LaunchError("quality_evidence_on_commit must be boolean")
    if comparison_id is not None and not RUN_ID_RE.fullmatch(comparison_id):
        raise LaunchError("comparison id must be a safe 3-128 character component")
    if quality_evidence_on_commit and comparison_id is None:
        raise LaunchError("quality evidence requires an explicit paired comparison id")

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
    budget_contract = {
        "total_cost_microusd": total_cost_microusd,
        "total_metered_tokens": total_metered_tokens,
        "max_cost_microusd": max_cost_microusd,
        "max_metered_tokens": max_metered_tokens,
        "prior_exposure_microusd": prior_exposure_microusd,
        "user_authority_microusd": MAX_USER_AUTHORITY_MICROUSD,
    }
    comparison_covariates = _comparison_covariates(
        workbuddy_commit=WORKBUDDY_PINNED_COMMIT,
        overlay_sha256=str(overlay["overlay_sha256"]),
        cohort=cohort_row,
        artifacts=artifact_row,
        environment_preflight_sha256=str(environment_preflight["content_sha256"]),
        job=job,
        model_fingerprint=model_fingerprint,
        backend_url_sha256=_sha256_bytes(backend_url.encode("utf-8")),
        runner_tools={"bash": bash_tool, "uv": uv_tool},
        host_control_plane=host_control_plane,
        budget=budget_contract,
    )
    manifest: Dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "quality_evidence": False,
        "quality_evidence_on_commit": quality_evidence_on_commit,
        "evaluation_treatment": {
            "project_control": (
                str(project_control_mode)
                if isinstance(project_control, dict)
                else "absent"
            ),
            "actor_prompt_changed": False,
            "tool_schema_changed": False,
            "provider_cache_prefix_changed_by_control_plane": False,
            "verification_checkpoint": verification_checkpoint,
            "verification_final_gate": verification_final_gate,
            "memory_accumulation": memory_accumulation,
            "verification_final_observe": verification_final_observe,
        },
        "comparison": (
            {
                "schema_version": COMPARISON_SCHEMA_VERSION,
                "comparison_id": comparison_id,
                "covariates_sha256": _canonical_sha256(comparison_covariates),
                "covariates": comparison_covariates,
            }
            if comparison_id is not None
            else None
        ),
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
            # The proxy route is run-specific transport identity.  Persist the
            # stable actor-visible backend identity separately so every later
            # trial/runtime/cache audit compares against the value actually
            # injected into metacodes rather than an absent manifest field.
            "backend_model_name": model.get("name"),
            "backend_url_env": backend_url_env,
            "backend_url_sha256": _sha256_bytes(backend_url.encode("utf-8")),
        },
        "harness_fingerprint": harness_fingerprint,
        "host_control_plane": host_control_plane,
        "budget": budget_contract,
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


def _validate_launch_manifest(manifest: Dict[str, Any]) -> Dict[str, Any]:
    content_sha = manifest.pop("content_sha256", None)
    if content_sha != _canonical_sha256(manifest):
        raise LaunchError("paid launch manifest content hash mismatch")
    manifest["content_sha256"] = content_sha
    schema_version = manifest.get("schema_version")
    paired_schema = schema_version in {PAIRED_SCHEMA_VERSION, SCHEMA_VERSION}
    if schema_version not in {
        LEGACY_SCHEMA_VERSION,
        PAIRED_SCHEMA_VERSION,
        SCHEMA_VERSION,
    } or manifest.get("quality_evidence") is not False:
        raise LaunchError("unsupported or mislabeled paid launch manifest")
    treatment = manifest.get("evaluation_treatment")
    if paired_schema:
        checkpoint = (
            treatment.get("verification_checkpoint")
            if isinstance(treatment, dict)
            else None
        )
        if (
            not isinstance(treatment, dict)
            or treatment
            != {
                "project_control": treatment.get("project_control"),
                "actor_prompt_changed": False,
                "tool_schema_changed": False,
                "provider_cache_prefix_changed_by_control_plane": False,
                **(
                    {"verification_checkpoint": checkpoint}
                    if "verification_checkpoint" in treatment
                    else {}
                ),
                **(
                    {
                        "verification_final_gate": treatment.get(
                            "verification_final_gate"
                        ),
                        "verification_final_observe": treatment.get(
                            "verification_final_observe"
                        ),
                    }
                    if "verification_final_gate" in treatment
                    else {}
                ),
                **(
                    {"memory_accumulation": treatment.get("memory_accumulation")}
                    if "memory_accumulation" in treatment
                    else {}
                ),
            }
            or treatment.get("project_control") not in PROJECT_CONTROL_MODES
            or ("verification_checkpoint" in treatment and not isinstance(checkpoint, bool))
            or (
                "verification_final_gate" in treatment
                and not (
                    isinstance(treatment.get("verification_final_gate"), bool)
                    and isinstance(treatment.get("verification_final_observe"), bool)
                )
            )
            or (
                "memory_accumulation" in treatment
                and not isinstance(treatment.get("memory_accumulation"), bool)
            )
        ):
            raise LaunchError("paid launch treatment contract is incomplete")
    elif treatment is not None:
        raise LaunchError("legacy paid launch unexpectedly carries a v2 treatment")
    if not isinstance(manifest.get("quality_evidence_on_commit"), bool):
        raise LaunchError("paid launch commit evidence classification is missing")
    comparison = manifest.get("comparison")
    if paired_schema:
        if comparison is not None:
            if (
                not isinstance(comparison, dict)
                or set(comparison)
                != {
                    "schema_version",
                    "comparison_id",
                    "covariates_sha256",
                    "covariates",
                }
                or comparison.get("schema_version") != COMPARISON_SCHEMA_VERSION
                or not RUN_ID_RE.fullmatch(str(comparison.get("comparison_id", "")))
                or not isinstance(comparison.get("covariates"), dict)
                or comparison.get("covariates_sha256")
                != _canonical_sha256(comparison["covariates"])
            ):
                raise LaunchError("paid launch comparison contract is incomplete")
        if manifest["quality_evidence_on_commit"] is True and comparison is None:
            raise LaunchError("quality evidence is missing its paired comparison")
    elif comparison is not None:
        raise LaunchError("legacy paid launch unexpectedly carries a comparison")
    if manifest.get("workbuddy", {}).get("commit") != WORKBUDDY_PINNED_COMMIT:
        raise LaunchError("paid launch WorkBuddy commit drifted")
    model = manifest.get("model") or {}
    if schema_version == SCHEMA_VERSION and (
        not isinstance(model, dict)
        or not isinstance(model.get("backend_model_name"), str)
        or not model["backend_model_name"].strip()
    ):
        raise LaunchError("paid launch actor model identity is incomplete")
    if not re.fullmatch(
        r"[0-9a-f]{64}",
        str(manifest.get("workbuddy", {}).get("overlay_content_sha256", "")),
    ):
        raise LaunchError("paid launch installed-overlay identity is incomplete")
    host_control_plane = manifest.get("host_control_plane")
    allowed_host_modules = (
        {
            frozenset(HOST_CONTROL_PLANE_MODULES),
            LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V3,
        }
        if paired_schema
        else {
            LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V1,
            LEGACY_HOST_CONTROL_PLANE_MODULE_NAMES_V2,
        }
    )
    if (
        not isinstance(host_control_plane, dict)
        or set(host_control_plane)
        not in allowed_host_modules
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


def validate_launch_manifest(path: Path) -> Dict[str, Any]:
    manifest, _, _ = _observed_json(path)
    return _validate_launch_manifest(manifest)


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


def _reobserve_launch_inputs(
    manifest: Mapping[str, Any], *, include_host_control_plane: bool = True
) -> None:
    # Audit resumption legitimately runs under a NEWER control plane than the
    # manifest pinned — a fixed auditor is its entire premise.  The resumption
    # receipt discloses the exact module hashes instead, and paired analysis
    # only admits them through earned instrument succession.  Every
    # treatment-identity input below (checkout commit, overlay, artifacts,
    # kernel, configs) is still re-observed unconditionally.
    if include_host_control_plane:
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
    project = manifest["artifacts"].get("project_control")
    if project is not None:
        _reobserve_identity(
            project["kernel"],
            "split-mount project kernel",
            maximum=512 * 1024 * 1024,
        )
        observed_rules = _project_rule_tree(Path(project["rules"]["path"]))
        if any(
            observed_rules[key] != project["rules"].get(key)
            for key in ("path", "files", "bytes", "tree_sha256")
        ):
            raise LaunchError("split-mount project-rules changed after manifest creation")
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
    expected_project = _expected_project_control(manifest)
    current_job = _yaml(Path(manifest["job"]["config"]["path"]))
    _validate_project_control_kwargs(
        current_job.get("harness_params_override") or {},
        expected_project,
        label="reobserved WorkBuddy job",
    )
    _validate_verification_checkpoint_kwargs(
        current_job.get("harness_params_override") or {},
        manifest,
        label="reobserved WorkBuddy job",
    )
    _reobserve_identity(manifest["model"]["config"], "WorkBuddy model config", maximum=16 * 1024 * 1024)
    backend_url = os.environ.get(manifest["model"]["backend_url_env"], "")
    if _sha256_bytes(backend_url.encode("utf-8")) != manifest["model"]["backend_url_sha256"]:
        raise LaunchError("WorkBuddy provider base URL changed after launch manifest creation")


def _open_private_artifact_parent(path: Path) -> tuple[Path, int]:
    if not path.name or path.name in {".", ".."}:
        raise LaunchError("paid launch artifact has an invalid file name")
    absolute_parent = Path(os.path.abspath(os.fspath(path.parent)))
    try:
        parent_link_info = absolute_parent.lstat()
    except FileNotFoundError:
        raise LaunchError("paid launch artifact parent does not exist")
    except OSError as exc:
        raise LaunchError(
            f"paid launch artifact parent cannot be inspected: {exc}"
        ) from exc
    if stat.S_ISLNK(parent_link_info.st_mode):
        raise LaunchError("paid launch artifact parent must not be a symlink")
    try:
        parent = absolute_parent.resolve(strict=True)
    except OSError as exc:
        raise LaunchError(f"paid launch artifact parent cannot be resolved: {exc}") from exc
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_fd = os.open(parent, flags)
    except OSError as exc:
        raise LaunchError(f"paid launch artifact parent cannot be opened: {exc}") from exc
    try:
        info = os.fstat(parent_fd)
        observed = parent.stat()
        if (
            not stat.S_ISDIR(info.st_mode)
            or (info.st_dev, info.st_ino)
            != (parent_link_info.st_dev, parent_link_info.st_ino)
            or (info.st_dev, info.st_ino) != (observed.st_dev, observed.st_ino)
            or stat.S_IMODE(info.st_mode) & 0o022
        ):
            raise LaunchError(
                "paid launch artifact parent must be a stable private directory"
            )
        if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
            raise LaunchError(
                "paid launch artifact parent must be owned by the current user"
            )
        return parent, parent_fd
    except BaseException:
        os.close(parent_fd)
        raise


def _entry_exists(parent_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise LaunchError(f"cannot inspect paid launch artifact {name!r}: {exc}") from exc


def _write_private_new(
    path: Path, payload: bytes, *, preopened_parent_fd: int | None = None
) -> None:
    owns_parent_fd = preopened_parent_fd is None
    if preopened_parent_fd is not None:
        parent_fd = preopened_parent_fd
        if _entry_exists(parent_fd, path.name):
            raise LaunchError(f"refusing to overwrite paid launch artifact: {path}")
        if _entry_exists(parent_fd, path.name + ".tmp"):
            raise LaunchError(
                "incomplete paid launch artifact requires manual inspection"
            )
    else:
        _parent, parent_fd = _open_private_artifact_parent(path)
    temporary_name = path.name + ".tmp"
    try:
        if _entry_exists(parent_fd, path.name):
            raise LaunchError(f"refusing to overwrite paid launch artifact: {path}")
        if _entry_exists(parent_fd, temporary_name):
            raise LaunchError(
                "incomplete paid launch artifact requires manual inspection"
            )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        flags |= getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(temporary_name, flags, 0o600, dir_fd=parent_fd)
    except BaseException:
        if owns_parent_fd:
            os.close(parent_fd)
        raise
    try:
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
        # link(2) publishes without overwriting a concurrently-created final
        # path.  A crash before the temporary name is removed leaves an
        # explicit fail-closed artifact for manual inspection.
        os.link(
            temporary_name,
            path.name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
            follow_symlinks=False,
        )
        os.fsync(parent_fd)
        os.unlink(temporary_name, dir_fd=parent_fd)
        os.fsync(parent_fd)
        final_fd = os.open(
            path.name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        try:
            final = os.fstat(final_fd)
            if (
                not stat.S_ISREG(final.st_mode)
                or final.st_nlink != 1
                or stat.S_IMODE(final.st_mode) & 0o077
            ):
                raise LaunchError("published paid launch artifact is not private")
        finally:
            os.close(final_fd)
    finally:
        if owns_parent_fd:
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


def _validate_control_metrics(
    value: object,
    *,
    trajectory_path: Path,
    transcript_path: Path,
    observation_path: Path,
) -> Dict[str, Any]:
    """Validate post-run mechanism evidence before it enters a quality receipt."""

    if (
        not isinstance(value, dict)
        or value.get("schema_version") not in CONTROL_METRICS_SCHEMAS
    ):
        raise LaunchError("trajectory is missing the versioned control metrics")
    if set(value) != {
        "schema_version",
        "source",
        "tool_runtime",
        "tinykg",
        "lean",
        "privacy",
    }:
        raise LaunchError("control metrics top-level schema drifted")
    source = value.get("source")
    runtime = value.get("tool_runtime")
    tinykg = value.get("tinykg")
    lean = value.get("lean")
    privacy = value.get("privacy")
    if not all(isinstance(item, dict) for item in (source, runtime, tinykg, lean, privacy)):
        raise LaunchError("trajectory control metrics sections are malformed")
    source_fields = {
        "transcript_sha256",
        "observation_journal_sha256",
        "session_id_sha256",
        "run_id_sha256",
        "observation_journal_records",
    }
    if set(source) != source_fields:
        raise LaunchError("control metrics source schema drifted")
    for name in (
        "transcript_sha256",
        "observation_journal_sha256",
        "session_id_sha256",
        "run_id_sha256",
    ):
        digest = source.get(name)
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise LaunchError(f"control metrics source identity {name} is invalid")
    if source["transcript_sha256"] != _identity(transcript_path)["sha256"]:
        raise LaunchError("control metrics transcript hash does not bind the artifact")
    if source["observation_journal_sha256"] != _identity(observation_path)["sha256"]:
        raise LaunchError("control metrics observation hash does not bind the artifact")
    _non_negative_control_int(source.get("observation_journal_records"), "journal records")

    required_runtime = (
        "transcript_tool_calls",
        "transcript_tool_results",
        "transcript_calls_without_result",
        "dispatch_started",
        "dispatch_finished",
        "dispatch_outcomes",
    )
    if set(runtime) != set(required_runtime):
        raise LaunchError("control metrics tool runtime schema drifted")
    for name in required_runtime[:-1]:
        _non_negative_control_int(runtime.get(name), f"tool runtime {name}")
    if runtime["transcript_calls_without_result"] != 0:
        raise LaunchError("control metrics contain a tool call without a result")
    if runtime["dispatch_started"] != runtime["dispatch_finished"]:
        raise LaunchError("control metrics contain an unpaired tool dispatch")
    outcomes = runtime.get("dispatch_outcomes")
    if not isinstance(outcomes, dict):
        raise LaunchError("control metrics dispatch outcomes are malformed")
    outcome_total = 0
    for name in (
        "succeeded",
        "tool_error",
        "pending",
        "host_failed",
        "host_rejected",
        "host_fatal",
    ):
        count = _non_negative_control_int(outcomes.get(name), f"dispatch outcome {name}")
        outcome_total += count
    if outcome_total != runtime["dispatch_finished"]:
        raise LaunchError("control metrics dispatch outcome total is inconsistent")

    _validate_control_section(tinykg, "tinykg")
    _validate_control_section(lean, "lean")
    if privacy != {
        "tool_arguments_retained": False,
        "tool_results_retained": False,
        "memory_text_retained": False,
    }:
        raise LaunchError("control metrics privacy contract drifted")
    observed = load_control_metrics(transcript_path, observation_path)
    comparable = observed
    input_schema = value.get("schema_version")
    if input_schema != CONTROL_METRICS_SCHEMA:
        comparable = json.loads(json.dumps(observed))
        comparable["schema_version"] = input_schema
        for name in ("auto_context_succeeded", "context_observations"):
            comparable["tinykg"].pop(name)
    if input_schema == LEGACY_CONTROL_METRICS_SCHEMA:
        filter_fields = (
            "rule_filter_events",
            "active_rule_phases",
            "checker_rule_phases",
            "statically_pruned_rule_phases",
        )
        if any(observed["lean"].get(name) != 0 for name in filter_fields):
            raise LaunchError("legacy control metrics cannot represent project rule filtering")
        for name in filter_fields:
            comparable["lean"].pop(name)
    if comparable != value:
        raise LaunchError(
            f"trajectory control metrics do not match the bound artifacts: {trajectory_path}"
        )
    # Never allow a trajectory to smuggle arbitrary text or a second evidence
    # authority through the derived metrics object.
    if any(not isinstance(key, str) for key in value):
        raise LaunchError("control metrics has a non-string key")
    return observed


def _non_negative_control_int(value: object, where: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise LaunchError(f"control metrics {where} must be a non-negative integer")
    return value


def _validate_control_section(value: Mapping[str, Any], section: str) -> None:
    if not isinstance(value.get("used"), bool):
        raise LaunchError(f"control metrics {section}.used is invalid")
    for key, raw in value.items():
        if key in {"used", "kernel_sha256s", "bundle_sha256s", "actuations", "dispatch_outcomes", "operations"}:
            continue
        if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
            raise LaunchError(f"control metrics {section}.{key} is not a non-negative integer")
    for key in ("kernel_sha256s", "bundle_sha256s"):
        if key in value:
            entries = value[key]
            if not isinstance(entries, list) or any(
                not isinstance(item, str) or re.fullmatch(r"[0-9a-f]{64}", item) is None
                for item in entries
            ):
                raise LaunchError(f"control metrics {section}.{key} is invalid")
    if "actuations" in value and (
        not isinstance(value["actuations"], list)
        or any(item not in {"enforced", "shadow"} for item in value["actuations"])
    ):
        raise LaunchError(f"control metrics {section}.actuations is invalid")
    for key in ("dispatch_outcomes", "operations"):
        if key not in value:
            continue
        nested = value[key]
        if not isinstance(nested, dict) or any(
            not isinstance(name, str)
            or isinstance(raw, bool)
            or not isinstance(raw, int)
            or raw < 0
            for name, raw in nested.items()
        ):
            raise LaunchError(f"control metrics {section}.{key} is invalid")


def _aggregate_control_metrics(rows: Mapping[str, Mapping[str, Any]]) -> Dict[str, Any]:
    totals: Dict[str, Any] = {
        "tasks": len(rows),
        "tinykg_used_tasks": 0,
        "lean_used_tasks": 0,
        "tool_runtime": {
            "transcript_tool_calls": 0,
            "transcript_tool_results": 0,
            "transcript_calls_without_result": 0,
            "dispatch_started": 0,
            "dispatch_finished": 0,
            "dispatch_outcomes": {
                name: 0
                for name in (
                    "succeeded",
                    "tool_error",
                    "pending",
                    "host_failed",
                    "host_rejected",
                    "host_fatal",
                )
            },
        },
        "tinykg": {},
        "lean": {},
    }
    for metrics in rows.values():
        if metrics["tinykg"]["used"]:
            totals["tinykg_used_tasks"] += 1
        if metrics["lean"]["used"]:
            totals["lean_used_tasks"] += 1
        for section in ("tool_runtime", "tinykg", "lean"):
            target = totals[section]
            for key, raw in metrics[section].items():
                if isinstance(raw, int) and not isinstance(raw, bool):
                    if section == "lean" and key.endswith("_max"):
                        target[key] = max(target.get(key, 0), raw)
                    else:
                        target[key] = target.get(key, 0) + raw
        for key, raw in metrics["tool_runtime"]["dispatch_outcomes"].items():
            totals["tool_runtime"]["dispatch_outcomes"][key] += raw
    totals["lean"]["kernel_sha256s"] = sorted({
        digest
        for metrics in rows.values()
        for digest in metrics["lean"].get("kernel_sha256s", [])
    })
    totals["lean"]["bundle_sha256s"] = sorted({
        digest
        for metrics in rows.values()
        for digest in metrics["lean"].get("bundle_sha256s", [])
    })
    totals["lean"]["actuations"] = sorted({
        actuation
        for metrics in rows.values()
        for actuation in metrics["lean"].get("actuations", [])
    })
    return totals


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


def _cacheable_first_request_sha256(request_body: Mapping[str, Any]) -> str:
    """Hash exactly the actor-visible first-request body.

    WorkBuddy's local proxy requires a run-specific transport route in
    ``model``.  That routing envelope is deliberately excluded; everything
    visible to the actor, including the system prompt and tool schemas, remains
    byte-significant and must match across paired arms.
    """
    body = dict(request_body)
    body.pop("model", None)
    return _canonical_sha256(body)


def _expected_project_control(manifest: Mapping[str, Any]) -> Dict[str, object]:
    treatment = manifest.get("evaluation_treatment")
    project = manifest.get("artifacts", {}).get("project_control")
    mode = (
        str(treatment.get("project_control"))
        if isinstance(treatment, dict)
        else ("enforced" if project is not None else "absent")
    )
    if project is None:
        if mode != "absent":
            raise LaunchError("project-control treatment has no staged artifact")
        return {
            "staged": False,
            "mode": "absent",
            "configured": False,
            "project_root": None,
            "project_sha256": None,
            "project_state_hash": None,
            "rules_relative_path": None,
            "kernel_relative_path": None,
            "artifacts_verified": False,
            "runtime_active_bundle_absent": True,
        }
    if not isinstance(project, dict):
        raise LaunchError("paid launch project control contract is malformed")
    if mode not in {"disabled", "enforced"}:
        raise LaunchError("staged project-control treatment is invalid")
    rules = project.get("rules")
    kernel = project.get("kernel")
    if not isinstance(rules, dict) or not isinstance(kernel, dict):
        raise LaunchError("paid launch project control identity is incomplete")
    project_root = rules.get("project_root")
    project_sha256 = rules.get("project_sha256")
    rules_relative = rules.get("relative_path")
    kernel_relative = kernel.get("relative_path")
    if (
        project_root != PROJECT_ROOT
        or not isinstance(project_sha256, str)
        or re.fullmatch(r"[0-9a-f]{64}", project_sha256) is None
        or project_sha256
        != _sha256_bytes(
            b"metacodes-project-identity-v1\x00" + project_root.encode("utf-8")
        )
        or rules_relative != PROJECT_RULES_TARGET.as_posix()
        or kernel_relative != PROJECT_KERNEL_TARGET.as_posix()
    ):
        raise LaunchError("paid launch project control target identity drifted")
    return {
        "staged": True,
        "mode": mode,
        "configured": mode == "enforced",
        "project_root": project_root,
        "project_sha256": project_sha256,
        "project_state_hash": (
            project_state_hash(project_root) if mode == "enforced" else None
        ),
        "rules_relative_path": rules_relative,
        "kernel_relative_path": kernel_relative,
        "artifacts_verified": True,
        "runtime_active_bundle_absent": mode == "disabled",
    }


def _validate_project_control_kwargs(
    kwargs: object, expected: Mapping[str, object], *, label: str
) -> None:
    if not isinstance(kwargs, dict):
        raise LaunchError(f"{label} has no agent kwargs")
    observed = {
        "METACODES_PROJECT_CONTROL_MODE": kwargs.get(
            "METACODES_PROJECT_CONTROL_MODE"
        ),
        "METACODES_PROJECT_RULES_RELATIVE": kwargs.get(
            "METACODES_PROJECT_RULES_RELATIVE"
        ),
        "METACODES_PROJECT_KERNEL_RELATIVE": kwargs.get(
            "METACODES_PROJECT_KERNEL_RELATIVE"
        ),
    }
    wanted = {
        "METACODES_PROJECT_CONTROL_MODE": (
            expected["mode"] if expected["staged"] else None
        ),
        "METACODES_PROJECT_RULES_RELATIVE": expected["rules_relative_path"],
        "METACODES_PROJECT_KERNEL_RELATIVE": expected["kernel_relative_path"],
    }
    if observed != wanted:
        raise LaunchError(f"{label} project control kwargs drifted")


def _validate_actor_model_identity(
    kwargs: object, manifest: Mapping[str, Any], *, label: str
) -> None:
    if not isinstance(kwargs, dict):
        raise LaunchError(f"{label} has no agent kwargs")
    expected = str(manifest.get("model", {}).get("backend_model_name") or "")
    if not expected or kwargs.get("METACODES_MODEL_DISPLAY_NAME") != expected:
        raise LaunchError(f"{label} actor model identity drifted")


def _validate_verification_checkpoint_kwargs(
    kwargs: object, manifest: Mapping[str, Any], *, label: str
) -> None:
    if not isinstance(kwargs, dict):
        raise LaunchError(f"{label} has no agent kwargs")
    treatment = manifest.get("evaluation_treatment")
    if not isinstance(treatment, dict) or "verification_checkpoint" not in treatment:
        if "METACODES_VERIFICATION_CHECKPOINT" in kwargs:
            raise LaunchError(f"{label} unexpectedly enables verification checkpoint")
        return
    expected = _expected_verification_checkpoint(manifest)
    if kwargs.get("METACODES_VERIFICATION_CHECKPOINT") is not expected:
        raise LaunchError(f"{label} verification checkpoint treatment drifted")


def _validate_memory_accumulation_kwargs(
    kwargs: object, manifest: Mapping[str, Any], *, label: str
) -> None:
    if not isinstance(kwargs, dict):
        raise LaunchError(f"{label} has no agent kwargs")
    expected = _expected_memory_accumulation(manifest)
    if expected is None:
        if "METACODES_MEMORY_ACCUMULATION" in kwargs:
            raise LaunchError(f"{label} unexpectedly enables memory accumulation")
        return
    if kwargs.get("METACODES_MEMORY_ACCUMULATION", False) is not expected:
        raise LaunchError(f"{label} memory accumulation treatment drifted")


def _expected_memory_accumulation(manifest: Mapping[str, Any]) -> bool | None:
    treatment = manifest.get("evaluation_treatment")
    if not isinstance(treatment, dict) or "memory_accumulation" not in treatment:
        return None
    value = treatment.get("memory_accumulation")
    if not isinstance(value, bool):
        raise LaunchError("paid launch memory accumulation treatment is invalid")
    return value


def _expected_verification_checkpoint(
    manifest: Mapping[str, Any]
) -> bool | None:
    treatment = manifest.get("evaluation_treatment")
    if not isinstance(treatment, dict) or "verification_checkpoint" not in treatment:
        return None
    value = treatment.get("verification_checkpoint")
    if not isinstance(value, bool):
        raise LaunchError("paid launch verification checkpoint treatment is invalid")
    return value


def _validate_trial_project_control(
    trial_dir: Path, manifest: Mapping[str, Any]
) -> None:
    expected = _expected_project_control(manifest)
    config = _json(trial_dir / "config.json")
    agent = config.get("agent")
    if not isinstance(agent, dict):
        raise LaunchError("official WorkBuddy trial has no agent config")
    _validate_project_control_kwargs(
        agent.get("kwargs"), expected, label="official WorkBuddy trial"
    )
    _validate_actor_model_identity(
        agent.get("kwargs"), manifest, label="official WorkBuddy trial"
    )
    _validate_verification_checkpoint_kwargs(
        agent.get("kwargs"), manifest, label="official WorkBuddy trial"
    )
    _validate_memory_accumulation_kwargs(
        agent.get("kwargs"), manifest, label="official WorkBuddy trial"
    )
    runtime = _json(trial_dir / "agent/metacodes-runtime-contract.json")
    backend_model_name = str(manifest.get("model", {}).get("backend_model_name") or "")
    if (
        runtime.get("transport_model_is_route") is not True
        or not backend_model_name
        or runtime.get("actor_model_identity") != backend_model_name
        or runtime.get("verification_checkpoint")
        is not _expected_verification_checkpoint(manifest)
    ):
        raise LaunchError("official WorkBuddy runtime model identity drifted")
    expected_memory = _expected_memory_accumulation(manifest)
    if expected_memory is not None and (
        runtime.get("memory_accumulation") is not expected_memory
    ):
        raise LaunchError("official WorkBuddy runtime memory treatment drifted")
    project = runtime.get("project_control")
    if not isinstance(project, dict) or project != {
        "staged": expected["staged"],
        "mode": expected["mode"],
        "configured": expected["configured"],
        "project_state_hash": expected["project_state_hash"],
        "artifacts_verified": expected["artifacts_verified"],
        "runtime_active_bundle_absent": expected["runtime_active_bundle_absent"],
    }:
        raise LaunchError("official WorkBuddy runtime project control drifted")


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
    expected_project = _expected_project_control(manifest)
    harness_runtime = resolved.get("harness_runtime_config")
    translated_env = (
        harness_runtime.get("translated_env")
        if isinstance(harness_runtime, dict)
        else None
    )
    if (
        not isinstance(harness_runtime, dict)
        or harness_runtime.get("project_control_staged")
        is not expected_project["staged"]
        or harness_runtime.get("project_control_mode") != expected_project["mode"]
        or harness_runtime.get("project_control_configured")
        is not expected_project["configured"]
        or harness_runtime.get("transport_model_is_route") is not True
        or harness_runtime.get("actor_model_identity")
        != manifest["model"]["backend_model_name"]
        or harness_runtime.get("verification_checkpoint")
        is not _expected_verification_checkpoint(manifest)
        or not isinstance(translated_env, dict)
        or translated_env.get("METACODES_PROJECT_RULES_SOURCE")
        != (
            "/opt/metacodes/" + str(expected_project["rules_relative_path"])
            if expected_project["staged"]
            else None
        )
        or translated_env.get("METACODES_PROJECT_KERNEL_PATH")
        != (
            "/opt/metacodes/" + str(expected_project["kernel_relative_path"])
            if expected_project["staged"]
            else None
        )
    ):
        raise LaunchError("resolved WorkBuddy project control contract drifted")
    runtime_job_path = (
        workbuddy
        / ".workspace/data/generated/jobs"
        / f"{manifest['job']['slug']}.yaml"
    )
    runtime_job = _yaml(runtime_job_path)
    agents = runtime_job.get("agents")
    if not isinstance(agents, list) or len(agents) != 1 or not isinstance(agents[0], dict):
        raise LaunchError("resolved WorkBuddy runtime job has no unique agent")
    _validate_project_control_kwargs(
        agents[0].get("kwargs"),
        expected_project,
        label="resolved WorkBuddy runtime job",
    )
    _validate_actor_model_identity(
        agents[0].get("kwargs"),
        manifest,
        label="resolved WorkBuddy runtime job",
    )
    _validate_verification_checkpoint_kwargs(
        agents[0].get("kwargs"),
        manifest,
        label="resolved WorkBuddy runtime job",
    )
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
        for line in _read_regular(unattributed, maximum=MAX_REQUEST_LOG_BYTES).splitlines()
    ):
        raise LaunchError("WorkBuddy left unattributed provider requests outside task receipts")
    return {
        "resolved_manifest": _identity(resolved_path),
        "runtime_job_config": _identity(runtime_job_path),
        "proxy_config": _identity(proxy_path),
        "project_control": expected_project,
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
    control_rows: Dict[str, Mapping[str, Any]] = {}
    total_cost = 0.0
    total_tokens = 0
    total_cache_read = 0
    total_cache_create = 0
    total_requests = 0
    request_sequences: list[int] = []
    total_reward = 0.0
    full_passes = 0
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
            _validate_trial_project_control(trajectory_path.parent.parent, manifest)
        else:
            task = _task_for_path(trajectory_path, selected)
        if task is None or task in rows:
            raise LaunchError(f"cannot uniquely bind trajectory to selected task: {trajectory_path}")
        trajectory = _json(trajectory_path)
        final = trajectory.get("final_metrics") or {}
        extra = final.get("extra") or {}
        transcript_path = trajectory_path.parent / "metacodes-transcript.jsonl"
        observation_path = trajectory_path.parent / OBSERVATION_FILENAME
        try:
            control_metrics = _validate_control_metrics(
                extra.get("control_metrics"),
                trajectory_path=trajectory_path,
                transcript_path=transcript_path,
                observation_path=observation_path,
            )
        except (OSError, TraceError, ValueError) as exc:
            raise LaunchError(
                f"invalid WorkBuddy control metrics for {trajectory_path}: {exc}"
            ) from exc
        try:
            progress_metrics = analyze_progress(transcript_path, observation_path)
        except (OSError, TraceError, ValueError) as exc:
            raise LaunchError(
                f"invalid WorkBuddy progress metrics for {trajectory_path}: {exc}"
            ) from exc
        if progress_metrics.get("source") != {
            "transcript_sha256": control_metrics["source"]["transcript_sha256"],
            "observation_journal_sha256": control_metrics["source"][
                "observation_journal_sha256"
            ],
        }:
            raise LaunchError(
                f"WorkBuddy progress evidence changed during observation: {trajectory_path}"
            )
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
            line for line in _read_regular(request_log, maximum=MAX_REQUEST_LOG_BYTES).splitlines()
            if line.strip()
        ]
        if not request_lines:
            raise LaunchError(f"trajectory has no provider request audit: {trajectory_path}")
        try:
            request_records = [
                json.loads(line.decode("utf-8")) for line in request_lines
            ]
            if manifest.get("schema_version") == SCHEMA_VERSION:
                request_records.sort(key=lambda row: row["seq"])
            first_record = request_records[0]
            first_body = dict(first_record["request"]["body"])
        except (UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
            raise LaunchError(f"invalid first request audit for {trajectory_path}: {exc}") from exc
        if manifest.get("schema_version") == SCHEMA_VERSION:
            sequences = [record.get("seq") for record in request_records]
            metacodes_turns = extra.get("metacodes_turns")
            response_states = [
                (
                    (record.get("response") or {}).get("status"),
                    record.get("error"),
                )
                for record in request_records
            ]
            if (
                any(
                    not isinstance(sequence, int) or isinstance(sequence, bool)
                    for sequence in sequences
                )
                or sequences != sorted(sequences)
                or len(set(sequences)) != len(sequences)
                or not isinstance(metacodes_turns, int)
                or isinstance(metacodes_turns, bool)
                or metacodes_turns <= 0
                or len(request_records) != metacodes_turns
                or any(status != 200 or error is not None for status, error in response_states)
            ):
                raise LaunchError(
                    f"provider request audit is incomplete or out of order: {trajectory_path}"
                )
            request_sequences.extend(sequences)
        prefix_hash = _cacheable_first_request_sha256(first_body)
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
        total_requests += len(request_records)
        rows[task] = {
            "trajectory_sha256": _identity(trajectory_path)["sha256"],
            # The request audit was already read above under the explicit 64 MiB
            # bound.  Reuse that same safety contract for its identity; falling
            # back to _identity's 16 MiB default would reject a complete long
            # trajectory after successfully validating the exact same bytes.
            "requests_sha256": _identity(
                request_log, maximum=MAX_REQUEST_LOG_BYTES
            )["sha256"],
            "provider_requests": len(request_records),
            "cacheable_first_request_sha256": prefix_hash,
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "metered_tokens": metered_tokens,
            "cache_read_input_tokens": cache_read,
            "cache_creation_input_tokens": cache_create,
            "cost_usd": float(cost),
            "control_metrics": control_metrics,
            "progress_metrics": progress_metrics,
        }
        control_rows[task] = control_metrics
        if trial_result_path is not None and trial_result is not None:
            verifier_result = trial_result.get("verifier_result")
            rewards = (
                verifier_result.get("rewards")
                if isinstance(verifier_result, dict)
                else None
            )
            reward = rewards.get("reward") if isinstance(rewards, dict) else None
            if (
                not isinstance(reward, (int, float))
                or isinstance(reward, bool)
                or not math.isfinite(float(reward))
                or float(reward) < 0.0
                or float(reward) > 1.0
            ):
                raise LaunchError(
                    f"official WorkBuddy result has invalid verifier reward: {trial_result_path}"
                )
            reward = float(reward)
            total_reward += reward
            full_passes += int(reward == 1.0)
            rows[task].update(
                {
                    "trial_result_sha256": _identity(trial_result_path)["sha256"],
                    "task_checksum": trial_result["task_checksum"],
                    "verifier_reward": reward,
                    "full_pass": reward == 1.0,
                }
            )
    if set(rows) != set(selected):
        raise LaunchError("WorkBuddy result set differs from frozen task selection")
    if manifest.get("schema_version") == SCHEMA_VERSION and sorted(request_sequences) != list(
        range(1, total_requests + 1)
    ):
        raise LaunchError("provider request audit has a missing or duplicate wave sequence")
    result = {
        "tasks": rows,
        "provider_requests": total_requests,
        "cost_microusd": usd_to_microusd_ceiling(total_cost),
        "metered_tokens": total_tokens,
        "cache_read_input_tokens": total_cache_read,
        "cache_creation_input_tokens": total_cache_create,
        "control_metrics": _aggregate_control_metrics(control_rows),
    }
    if official_runner:
        result["quality"] = {
            "mean_verifier_reward": total_reward / len(selected),
            "full_passes": full_passes,
            "task_count": len(selected),
            "pass_rate": full_passes / len(selected),
        }
        result["runtime_contract"] = _runtime_contract(manifest)
    return result


def _receipt_quality_evidence(
    manifest: Mapping[str, Any], *, official_runner: bool
) -> bool:
    return official_runner and manifest["quality_evidence_on_commit"] is True


def _request_audit_summary(path: Path) -> Dict[str, object]:
    """Reduce a raw proxy request log without retaining any body or text."""

    payload = _read_regular(path, maximum=MAX_FAILURE_ARTIFACT_BYTES)
    lines = [line for line in payload.splitlines() if line.strip()]
    statuses: Dict[str, int] = {}
    duration_ms_total = 0.0
    duration_ms_max = 0.0
    response_raw_bytes = 0
    response_content_bytes = 0
    tool_calls = 0
    records_with_error = 0
    malformed_records = 0
    observed = min(len(lines), MAX_FAILURE_REQUEST_RECORDS)
    for line in lines[:observed]:
        try:
            row = json.loads(line.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            malformed_records += 1
            continue
        if not isinstance(row, dict):
            malformed_records += 1
            continue
        response = row.get("response")
        if not isinstance(response, dict):
            response = {}
            malformed_records += 1
        status = response.get("status")
        status_key = (
            str(status)
            if isinstance(status, int)
            and not isinstance(status, bool)
            and 100 <= status <= 599
            else "unknown"
        )
        statuses[status_key] = statuses.get(status_key, 0) + 1
        duration = row.get("duration_ms")
        if (
            isinstance(duration, (int, float))
            and not isinstance(duration, bool)
            and math.isfinite(duration)
            and duration >= 0
        ):
            duration_ms_total += float(duration)
            duration_ms_max = max(duration_ms_max, float(duration))
        for key, target in (
            ("raw_bytes", "raw"),
            ("content_len", "content"),
            ("tool_calls_count", "tools"),
        ):
            value = response.get(key)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                continue
            if target == "raw":
                response_raw_bytes += value
            elif target == "content":
                response_content_bytes += value
            else:
                tool_calls += value
        if row.get("error") is not None:
            records_with_error += 1
    return {
        "source_bytes": len(payload),
        "source_sha256": _sha256_bytes(payload),
        "records": len(lines),
        "records_observed": observed,
        "records_truncated": len(lines) > observed,
        "malformed_records": malformed_records,
        "response_status_counts": dict(sorted(statuses.items())),
        "records_with_error": records_with_error,
        "duration_ms_total": duration_ms_total,
        "duration_ms_max": duration_ms_max,
        "response_raw_bytes": response_raw_bytes,
        "response_content_bytes": response_content_bytes,
        "tool_calls": tool_calls,
        "request_body_retained": False,
        "response_body_retained": False,
        "error_text_retained": False,
    }


def _official_failure_roots(
    manifest: Mapping[str, Any], result_root: Path, *, started_ns: int
) -> tuple[list[Path], int]:
    """Return only trial roots cryptographically attributable to this run."""

    workbuddy = Path(manifest["workbuddy"]["checkout"]).resolve(strict=True)
    run_id = str(manifest["run_id"])
    instance = workbuddy / "scripts/logs/instances" / run_id
    roots: list[Path] = []
    rejected = 0
    try:
        resolved = _json(instance / "manifest.json")
        expected_route = resolved.get("model_route")
    except (LaunchError, OSError):
        expected_route = None
    if (
        isinstance(expected_route, str)
        and expected_route.startswith(run_id + "--")
        and "__" not in expected_route
        and _is_safe_directory_beneath(workbuddy, instance)
    ):
        roots.append(instance)
    else:
        expected_route = None

    launch = result_root / ".launches" / run_id
    if _is_safe_directory_beneath(workbuddy, launch):
        roots.append(launch)

    selected = set(manifest["cohort"]["selected_tasks"])
    dataset_root = Path(str(manifest["cohort"]["dataset"])).parent.name
    if not result_root.is_dir() or result_root.is_symlink() or expected_route is None:
        return roots, rejected
    for result_path in result_root.glob("*/*/result.json"):
        trial = result_path.parent
        try:
            if not _is_safe_directory_beneath(result_root, trial):
                rejected += 1
                continue
            if result_path.stat().st_mtime_ns < started_ns:
                continue
            result = _json(result_path)
            task_name = result.get("task_name")
            task_id = result.get("task_id")
            agent = result.get("agent_info")
            model = agent.get("model_info") if isinstance(agent, dict) else None
            task = (
                task_name.removeprefix("workbuddy/")
                if isinstance(task_name, str)
                else None
            )
            task_path = task_id.get("path") if isinstance(task_id, dict) else None
            expected_task_path = str(
                Path(".workspace/tmp/staged")
                / run_id
                / dataset_root
                / "tasks"
                / str(task)
            )
            checksum = result.get("task_checksum")
            if (
                task not in selected
                or result.get("source") != "tasks"
                or task_path != expected_task_path
                or not isinstance(agent, dict)
                or agent.get("name") != "metacodes"
                or not isinstance(model, dict)
                or model.get("name") != expected_route
                or result.get("trial_uri") != trial.as_uri()
                or not isinstance(checksum, str)
                or re.fullmatch(r"[0-9a-f]{64}", checksum) is None
            ):
                rejected += 1
                continue
            roots.append(trial)
        except (LaunchError, OSError, AttributeError):
            rejected += 1
    return roots, rejected


def _is_safe_directory_beneath(base: Path, candidate: Path) -> bool:
    try:
        relative = candidate.relative_to(base)
    except ValueError:
        return False
    current = base
    try:
        base_info = current.lstat()
        if not stat.S_ISDIR(base_info.st_mode):
            return False
        for part in relative.parts:
            current = current / part
            info = current.lstat()
            if not stat.S_ISDIR(info.st_mode):
                return False
    except OSError:
        return False
    return True


def _authorized_failure_artifacts(
    manifest: Mapping[str, Any], *, started_ns: int, official_runner: bool
) -> Dict[str, object]:
    workbuddy = Path(manifest["workbuddy"]["checkout"]).resolve(strict=True)
    result_root = workbuddy / "results" / str(manifest["job"]["slug"])
    roots: list[Path] = []
    unsafe_entries = 0
    identity_rejected_roots = 0
    if official_runner:
        roots, identity_rejected_roots = _official_failure_roots(
            manifest, result_root, started_ns=started_ns
        )
    elif result_root.is_dir() and not result_root.is_symlink():
        for entry in os.scandir(result_root):
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError:
                unsafe_entries += 1
                continue
            if not stat.S_ISDIR(info.st_mode):
                if entry.is_symlink():
                    unsafe_entries += 1
                continue
            if entry.name != ".launches" and info.st_mtime_ns >= started_ns:
                roots.append(Path(entry.path))

    accepted_names = {
        "exception.txt",
        "job.log",
        "metacodes-transcript.jsonl",
        "metacodes-runtime-contract.json",
        OBSERVATION_FILENAME,
        "proxy.yaml",
        "requests.jsonl",
        "result.json",
        "trial.log",
        "trajectory.json",
    }
    artifacts: list[Dict[str, object]] = []
    request_summaries: list[Dict[str, object]] = []
    # Accepted-name candidates that could not be frozen, BY NAME.  A bare
    # counter hides which artifact vanished; the one time this fired for real
    # it silently dropped the exact 88MB request log whose size had just
    # killed the audit — the single most forensically relevant file.
    skipped: list[Dict[str, object]] = []
    total_bytes = 0
    walked_entries = 0
    truncated = False
    seen: set[Path] = set()

    def _skip(candidate: Path, reason: str) -> None:
        nonlocal unsafe_entries
        unsafe_entries += 1
        if len(skipped) < 64:
            try:
                relative = candidate.relative_to(workbuddy).as_posix()
            except ValueError:
                relative = candidate.name
            row: Dict[str, object] = {"relative_path": relative, "reason": reason}
            try:
                row["bytes"] = candidate.lstat().st_size
            except OSError:
                pass
            skipped.append(row)
    for root in sorted(set(roots)):
        for directory, directories, files in os.walk(root, followlinks=False):
            walked_entries += len(directories) + len(files)
            if walked_entries > MAX_FAILURE_WALK_ENTRIES:
                truncated = True
                break
            safe_directories: list[str] = []
            for name in directories:
                candidate = Path(directory) / name
                try:
                    info = candidate.lstat()
                except OSError:
                    unsafe_entries += 1
                    continue
                if stat.S_ISDIR(info.st_mode):
                    safe_directories.append(name)
                else:
                    unsafe_entries += 1
            directories[:] = safe_directories
            for name in sorted(files):
                if name not in accepted_names and not (
                    name.startswith("shard-") and name.endswith(".log")
                ):
                    continue
                candidate = Path(directory) / name
                if candidate in seen:
                    continue
                seen.add(candidate)
                if len(artifacts) >= MAX_FAILURE_ARTIFACTS:
                    truncated = True
                    break
                try:
                    info = candidate.lstat()
                except OSError:
                    _skip(candidate, "unreadable")
                    continue
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    _skip(candidate, "not a single-link regular file")
                    continue
                if info.st_size <= 0:
                    _skip(candidate, "empty")
                    continue
                if info.st_size > MAX_FAILURE_ARTIFACT_BYTES:
                    _skip(candidate, "exceeds per-artifact freeze bound")
                    continue
                if total_bytes + info.st_size > MAX_FAILURE_ARTIFACT_TOTAL_BYTES:
                    _skip(candidate, "exceeds total freeze bound")
                    continue
                try:
                    identity = _identity(
                        candidate, maximum=MAX_FAILURE_ARTIFACT_BYTES
                    )
                except (LaunchError, OSError):
                    _skip(candidate, "identity hash failed")
                    continue
                relative = candidate.relative_to(workbuddy).as_posix()
                artifact: Dict[str, object] = {
                    "relative_path": relative,
                    "bytes": identity["bytes"],
                    "sha256": identity["sha256"],
                }
                if name == "requests.jsonl":
                    summary = _request_audit_summary(candidate)
                    current_identity = _identity(
                        candidate, maximum=MAX_FAILURE_ARTIFACT_BYTES
                    )
                    if (
                        summary["source_bytes"] != identity["bytes"]
                        or summary["source_sha256"] != identity["sha256"]
                        or current_identity != identity
                    ):
                        _skip(candidate, "changed during freeze")
                        continue
                    artifact["kind"] = "request_audit"
                    artifact["request_audit"] = summary
                    request_summaries.append(summary)
                else:
                    if _identity(
                        candidate, maximum=MAX_FAILURE_ARTIFACT_BYTES
                    ) != identity:
                        _skip(candidate, "changed during freeze")
                        continue
                    artifact["kind"] = "local_artifact"
                artifacts.append(artifact)
                total_bytes += int(identity["bytes"])
            if truncated:
                break
        if truncated:
            break

    status_counts: Dict[str, int] = {}
    request_records = 0
    malformed_records = 0
    for summary in request_summaries:
        request_records += int(summary["records"])
        malformed_records += int(summary["malformed_records"])
        for status, count in summary["response_status_counts"].items():
            status_counts[status] = status_counts.get(status, 0) + int(count)
    return {
        "artifacts": artifacts,
        "artifact_count": len(artifacts),
        "artifact_bytes": total_bytes,
        "truncated": truncated,
        "unsafe_entries": unsafe_entries,
        "skipped_artifacts": skipped,
        "identity_scope": (
            "official-run-id-and-task" if official_runner else "isolated-test-time"
        ),
        "identity_rejected_roots": identity_rejected_roots,
        "request_audit": {
            "files": len(request_summaries),
            "records": request_records,
            "malformed_records": malformed_records,
            "response_status_counts": dict(sorted(status_counts.items())),
            "request_body_retained": False,
            "response_body_retained": False,
            "error_text_retained": False,
        },
    }


def _validated_failure_transaction(
    checkpoint: bytes, transaction_id: str
) -> Mapping[str, Any]:
    replayed = validate_checkpoint_payload(checkpoint)
    transaction = replayed["transactions"].get(transaction_id)
    if transaction is None or transaction["state"] != "request_authorized":
        raise LaunchError("failure receipt does not reopen an authorized transaction")
    return transaction


def validate_authorized_failure_receipt(
    path: Path, *, journal_path: Path | None = None
) -> Dict[str, Any]:
    receipt = _json(path)
    schema_version = receipt.get("schema_version")
    expected_fields = {
        "schema_version",
        "state",
        "quality_evidence",
        "retry_allowed",
        "actual_usage_known",
        "remote_request_outcome",
        "launch_manifest_content_sha256",
        "run_id",
        "model",
        "harness_fingerprint",
        "cohort",
        "budget_transaction",
        "journal",
        "runner",
        "failure_evidence",
        "privacy",
    }
    if schema_version == AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION:
        expected_fields.update(("failure_stage", "receipt_mode"))
    elif schema_version != AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1:
        raise LaunchError("authorized failure receipt schema drifted")
    if set(receipt) != expected_fields:
        raise LaunchError("authorized failure receipt schema drifted")
    if (
        receipt.get("state") != "authorized_failure"
        or receipt.get("quality_evidence") is not False
        or receipt.get("retry_allowed") is not False
        or receipt.get("actual_usage_known") is not False
        or receipt.get("remote_request_outcome") != "unknown"
        or receipt.get("privacy")
        != {
            "credential_retained": False,
            "request_body_retained": False,
            "response_body_retained": False,
            "memory_text_retained": False,
        }
    ):
        raise LaunchError("authorized failure receipt safety classification drifted")
    transaction = receipt.get("budget_transaction")
    journal = receipt.get("journal")
    runner = receipt.get("runner")
    cohort = receipt.get("cohort")
    evidence = receipt.get("failure_evidence")
    if not all(
        isinstance(value, dict)
        for value in (transaction, journal, runner, cohort, evidence)
    ):
        raise LaunchError("authorized failure receipt budget binding is malformed")
    if (
        transaction.get("state") != "request_authorized"
        or transaction.get("actual_cost_microusd") is not None
        or transaction.get("actual_metered_tokens") is not None
        or receipt.get("run_id") != transaction.get("run_id")
        or receipt.get("launch_manifest_content_sha256")
        != transaction.get("manifest_sha256")
        or receipt.get("harness_fingerprint")
        != transaction.get("harness_fingerprint")
        or receipt.get("model")
        != {
            "fingerprint": transaction.get("model_fingerprint"),
            "provider_identity": transaction.get("provider_identity"),
        }
        or journal.get("journal_id") != transaction.get("journal_id")
        or journal.get("revision") != transaction.get("journal_revision")
        or journal.get("head_sha256") != transaction.get("journal_head_sha256")
        or not isinstance(journal.get("exposure_cost_microusd"), int)
        or isinstance(journal.get("exposure_cost_microusd"), bool)
        or journal["exposure_cost_microusd"] < transaction.get("max_cost_microusd", -1)
        or not isinstance(journal.get("exposure_metered_tokens"), int)
        or isinstance(journal.get("exposure_metered_tokens"), bool)
        or journal["exposure_metered_tokens"]
        < transaction.get("max_metered_tokens", -1)
    ):
        raise LaunchError("authorized failure receipt transaction binding drifted")
    returncode = runner.get("returncode")
    elapsed = runner.get("elapsed_seconds")
    expected_runner_fields = {"returncode", "elapsed_seconds"}
    if schema_version == AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION:
        expected_runner_fields.add("elapsed_seconds_semantics")
    if (
        set(runner) != expected_runner_fields
        or not isinstance(returncode, int)
        or isinstance(returncode, bool)
        or not isinstance(elapsed, (int, float))
        or isinstance(elapsed, bool)
        or not math.isfinite(elapsed)
        or elapsed < 0
    ):
        raise LaunchError("authorized failure receipt runner evidence is invalid")
    if schema_version == AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1:
        if returncode == 0:
            raise LaunchError("legacy authorized failure receipt cannot bind exit zero")
    else:
        failure_stage = receipt.get("failure_stage")
        receipt_mode = receipt.get("receipt_mode")
        expected_elapsed_semantics = (
            "runner_wall_clock"
            if receipt_mode == "in_band"
            else "authorization_to_receipt_upper_bound"
        )
        if (
            failure_stage not in AUTHORIZED_FAILURE_STAGES
            or receipt_mode not in AUTHORIZED_FAILURE_RECEIPT_MODES
            or runner.get("elapsed_seconds_semantics")
            != expected_elapsed_semantics
            or (failure_stage == "runner_nonzero" and returncode == 0)
            or (failure_stage == "post_run_evidence_audit" and returncode != 0)
        ):
            raise LaunchError("authorized failure receipt stage contradicts runner evidence")
    if (
        set(cohort)
        != {
            "subset",
            "cohort",
            "selected_tasks_sha256",
            "selected_task_count",
        }
        or not isinstance(cohort.get("subset"), str)
        or not isinstance(cohort.get("cohort"), str)
        or not isinstance(cohort.get("selected_task_count"), int)
        or isinstance(cohort.get("selected_task_count"), bool)
        or cohort["selected_task_count"] <= 0
        or not isinstance(cohort.get("selected_tasks_sha256"), str)
        or re.fullmatch(r"[0-9a-f]{64}", cohort["selected_tasks_sha256"])
        is None
    ):
        raise LaunchError("authorized failure receipt cohort binding is invalid")
    summary = evidence.get("request_audit")
    artifacts = evidence.get("artifacts")
    if (
        # skipped_artifacts is optional: receipts persisted before the freezer
        # learned to name its skips must stay readable (closed two-era roster,
        # not a moving pin).
        set(evidence) - {"skipped_artifacts"}
        != {
            "artifacts",
            "artifact_count",
            "artifact_bytes",
            "truncated",
            "unsafe_entries",
            "identity_scope",
            "identity_rejected_roots",
            "request_audit",
        }
        or not isinstance(artifacts, list)
        or not isinstance(evidence.get("skipped_artifacts", []), list)
        or evidence.get("artifact_count") != len(artifacts)
        or not isinstance(summary, dict)
        or summary.get("request_body_retained") is not False
        or summary.get("response_body_retained") is not False
        or summary.get("error_text_retained") is not False
    ):
        raise LaunchError("authorized failure receipt evidence schema drifted")
    for value, label in (
        (journal.get("journal_id"), "journal id"),
        (journal.get("head_sha256"), "journal head"),
        (journal.get("checkpoint_sha256"), "journal checkpoint"),
        (transaction.get("transaction_id"), "transaction id"),
    ):
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            raise LaunchError(f"authorized failure receipt {label} is invalid")
    if journal_path is not None:
        checkpoint = _read_regular(journal_path, maximum=8 * 1024 * 1024)
        if (
            len(checkpoint) != journal.get("checkpoint_bytes")
            or _sha256_bytes(checkpoint) != journal.get("checkpoint_sha256")
        ):
            raise LaunchError("authorized failure receipt journal checkpoint drifted")
        reopened = validate_checkpoint_payload(checkpoint)
        reopened_transaction = _validated_failure_transaction(
            checkpoint, str(transaction["transaction_id"])
        )
        if (
            reopened["journal_id"] != journal["journal_id"]
            or reopened["revision"] != journal["revision"]
            or reopened["head_sha256"] != journal["head_sha256"]
            or reopened_transaction["identity_sha256"]
            != transaction.get("identity_sha256")
        ):
            raise LaunchError("authorized failure receipt does not reopen from journal")
    return receipt


def _authorized_failure_receipt(
    *,
    manifest: Mapping[str, Any],
    journal: BudgetJournal,
    transaction_id: str,
    runner_returncode: int,
    failure_stage: str,
    receipt_mode: str,
    started_ns: int,
    official_runner: bool,
) -> Dict[str, object]:
    if failure_stage not in AUTHORIZED_FAILURE_STAGES:
        raise LaunchError("authorized failure receipt has an unknown failure stage")
    if receipt_mode not in AUTHORIZED_FAILURE_RECEIPT_MODES:
        raise LaunchError("authorized failure receipt has an unknown receipt mode")
    transaction = journal.transaction_receipt(transaction_id)
    if transaction["state"] != "request_authorized":
        raise LaunchError("authorized failure receipt requires durable authorization")
    checkpoint = journal.checkpoint_payload()
    reopened = validate_checkpoint_payload(checkpoint)
    reopened_transaction = _validated_failure_transaction(checkpoint, transaction_id)
    snapshot = journal.snapshot()
    if (
        reopened["journal_id"] != snapshot["journal_id"]
        or reopened["revision"] != snapshot["revision"]
        or reopened["head_sha256"] != snapshot["head_sha256"]
        or reopened_transaction["identity"]
        != {
            "run_id": transaction["run_id"],
            "manifest_sha256": transaction["manifest_sha256"],
            "model_fingerprint": transaction["model_fingerprint"],
            "harness_fingerprint": transaction["harness_fingerprint"],
            "provider_identity": transaction["provider_identity"],
            "max_cost_microusd": transaction["max_cost_microusd"],
            "max_metered_tokens": transaction["max_metered_tokens"],
        }
    ):
        raise LaunchError("budget journal changed while building failure receipt")
    evidence = _authorized_failure_artifacts(
        manifest, started_ns=started_ns, official_runner=official_runner
    )
    return {
        "schema_version": AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION,
        "state": "authorized_failure",
        "failure_stage": failure_stage,
        "receipt_mode": receipt_mode,
        "quality_evidence": False,
        "retry_allowed": False,
        "actual_usage_known": False,
        "remote_request_outcome": "unknown",
        "launch_manifest_content_sha256": manifest["content_sha256"],
        "run_id": manifest["run_id"],
        "model": {
            "fingerprint": manifest["model"]["fingerprint"],
            "provider_identity": manifest["model"]["provider_identity"],
        },
        "harness_fingerprint": manifest["harness_fingerprint"],
        "cohort": {
            "subset": manifest["cohort"]["subset"],
            "cohort": manifest["cohort"]["cohort"],
            "selected_tasks_sha256": manifest["cohort"][
                "selected_tasks_sha256"
            ],
            "selected_task_count": len(manifest["cohort"]["selected_tasks"]),
        },
        "budget_transaction": transaction,
        "journal": {
            "journal_id": snapshot["journal_id"],
            "revision": snapshot["revision"],
            "head_sha256": snapshot["head_sha256"],
            "checkpoint_bytes": len(checkpoint),
            "checkpoint_sha256": _sha256_bytes(checkpoint),
            "transaction_states": snapshot["transaction_states"],
            "exposure_cost_microusd": snapshot["exposure_cost_microusd"],
            "exposure_metered_tokens": snapshot["exposure_metered_tokens"],
        },
        "runner": {
            "returncode": runner_returncode,
            "elapsed_seconds": (time.time_ns() - started_ns) / 1_000_000_000,
            "elapsed_seconds_semantics": (
                "runner_wall_clock"
                if receipt_mode == "in_band"
                else "authorization_to_receipt_upper_bound"
            ),
        },
        "failure_evidence": evidence,
        "privacy": {
            "credential_retained": False,
            "request_body_retained": False,
            "response_body_retained": False,
            "memory_text_retained": False,
        },
    }


def _persist_authorized_failure_receipt(
    *,
    manifest: Mapping[str, Any],
    journal: BudgetJournal,
    transaction_id: str,
    runner_returncode: int,
    failure_stage: str,
    receipt_mode: str,
    started_ns: int,
    official_runner: bool,
    receipt_path: Path,
    receipt_parent_fd: int,
    journal_path: Path,
) -> None:
    """Publish one fail-closed receipt for any post-authorization failure.

    A runner exit code of zero only proves that the process returned normally;
    it does not prove that every selected task, provider audit, trajectory and
    scorer artifact passed the bound evidence contract.  In that case the
    receipt deliberately records returncode=0 while the transaction remains
    request_authorized at maximum exposure.
    """

    failure_receipt = _authorized_failure_receipt(
        manifest=manifest,
        journal=journal,
        transaction_id=transaction_id,
        runner_returncode=runner_returncode,
        failure_stage=failure_stage,
        receipt_mode=receipt_mode,
        started_ns=started_ns,
        official_runner=official_runner,
    )
    _write_private_new(
        receipt_path,
        (json.dumps(failure_receipt, sort_keys=True, indent=2) + "\n").encode(
            "utf-8"
        ),
        preopened_parent_fd=receipt_parent_fd,
    )
    validate_authorized_failure_receipt(
        receipt_path, journal_path=journal_path
    )


def resume_post_run_audit(
    *,
    manifest_path: Path,
    journal_path: Path,
    failure_receipt_path: Path,
    receipt_path: Path,
    started_ns: int,
) -> Dict[str, Any]:
    """Re-run the post-run evidence audit and commit an authorized failure.

    Retry-forbidden protects against paid re-exposure: re-running the model.
    It must not conflate that with re-reading artifacts.  When the runner
    exited 0 and only the audit failed (an instrument defect), the artifacts
    are intact, the money is spent, and refusing to account for it forever
    would punish fixing the auditor.  Succession is earned, not declared:
    every artifact the original failure receipt froze must still be
    byte-identical, anything the audit reads beyond that freeze is hashed
    and disclosed as late-frozen, and the committed receipt names the
    instrument that produced it.  No provider credential exists here and the
    runner is never invoked.
    """

    manifest = validate_launch_manifest(manifest_path)
    failure = validate_authorized_failure_receipt(
        failure_receipt_path, journal_path=journal_path
    )
    if (
        failure.get("failure_stage") != "post_run_evidence_audit"
        or (failure.get("runner") or {}).get("returncode") != 0
        or failure.get("launch_manifest_content_sha256")
        != manifest["content_sha256"]
        or failure.get("run_id") != manifest["run_id"]
        or failure.get("retry_allowed") is not False
    ):
        raise LaunchError(
            "audit resumption requires a post-run-audit failure receipt with "
            "runner exit 0 bound to this manifest"
        )
    try:
        started_ns = int(started_ns)
    except (TypeError, ValueError) as exc:
        raise LaunchError("audit resumption start time is invalid") from exc
    if started_ns <= 0 or started_ns > time.time_ns():
        raise LaunchError("audit resumption start time is invalid")
    # official_runner is an invocation property (runner_argv is None), not a
    # manifest property; the failure receipt's identity scope records which
    # mode actually ran.
    identity_scope = failure["failure_evidence"].get("identity_scope")
    if identity_scope == "official-run-id-and-task":
        official_runner = True
    elif identity_scope == "isolated-test-time":
        official_runner = False
    else:
        raise LaunchError("audit resumption cannot determine the runner mode")
    if official_runner:
        _reobserve_launch_inputs(manifest, include_host_control_plane=False)

    # Continuity is verified directly against the receipt's frozen rows: the
    # launcher's cleanup tears down live run state (instance manifests, proxy
    # routes), so a resumption must never re-derive roots from that state —
    # the freeze is the authority on what existed at failure time.
    checkout = Path(manifest["workbuddy"]["checkout"]).resolve(strict=True)
    frozen = {
        str(row["relative_path"]): row
        for row in failure["failure_evidence"]["artifacts"]
    }
    if not frozen:
        raise LaunchError("audit resumption requires frozen failure evidence")
    frozen_shas = set()
    for relative, row in sorted(frozen.items()):
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise LaunchError(
                f"audit resumption evidence path escapes checkout: {relative}"
            )
        try:
            identity = _identity(
                checkout / candidate, maximum=MAX_FAILURE_ARTIFACT_BYTES
            )
        except (LaunchError, OSError) as exc:
            raise LaunchError(
                f"audit resumption evidence drifted since the failure freeze: {relative}"
            ) from exc
        if (
            identity["sha256"] != row["sha256"]
            or identity["bytes"] != row["bytes"]
        ):
            raise LaunchError(
                f"audit resumption evidence drifted since the failure freeze: {relative}"
            )
        frozen_shas.add(str(row["sha256"]))

    usage = _collect_usage(
        manifest, started_ns=started_ns, official_runner=official_runner
    )

    # Everything the audit consumed is identity-pinned inside usage; disclose
    # what it read beyond the freeze (e.g. an artifact the old freezer's
    # bounds silently dropped) instead of pretending the freeze was complete.
    audited_shas: Dict[str, str] = {}
    for task, row in sorted((usage.get("tasks") or {}).items()):
        for key in (
            "requests_sha256",
            "trajectory_sha256",
            "trial_result_sha256",
        ):
            value = row.get(key)
            if isinstance(value, str):
                audited_shas.setdefault(value, f"{task}:{key}")
        source = ((row.get("control_metrics") or {}).get("source")) or {}
        for key in ("transcript_sha256", "observation_journal_sha256"):
            value = source.get(key)
            if isinstance(value, str):
                audited_shas.setdefault(value, f"{task}:{key}")
    late_frozen = [
        {"sha256": sha, "pinned_by": pin}
        for sha, pin in sorted(audited_shas.items())
        if sha not in frozen_shas
    ]

    failure_receipt_identity = _identity(failure_receipt_path)
    auditor_identity = {
        name: _identity(path.resolve(), maximum=16 * 1024 * 1024)["sha256"]
        for name, path in sorted(HOST_CONTROL_PLANE_MODULES.items())
    }

    budget = manifest["budget"]
    model = manifest["model"]
    authority = BudgetAuthority(
        manifest_sha256=manifest["content_sha256"],
        model_fingerprint=model["fingerprint"],
        provider_identity=model["provider_identity"],
        total_cost_microusd=budget["total_cost_microusd"],
        total_metered_tokens=budget["total_metered_tokens"],
    )
    receipt_parent, receipt_parent_fd = _open_private_artifact_parent(receipt_path)
    try:
        receipt_storage_path = receipt_parent / receipt_path.name
        if _entry_exists(receipt_parent_fd, receipt_path.name) or _entry_exists(
            receipt_parent_fd, receipt_path.name + ".tmp"
        ):
            raise LaunchError(
                "paid launch receipt path is already occupied or incomplete"
            )
        with BudgetJournal(journal_path, authority) as journal:
            matches = [
                transaction
                for transaction in journal.transaction_receipts()
                if transaction["run_id"] == manifest["run_id"]
                and transaction["manifest_sha256"] == manifest["content_sha256"]
            ]
            if (
                len(matches) != 1
                or matches[0]["state"] != "request_authorized"
                or str(matches[0]["transaction_id"])
                != str(failure["budget_transaction"]["transaction_id"])
            ):
                raise LaunchError(
                    "audit resumption requires the exact authorized transaction "
                    "from the failure receipt"
                )
            committed = journal.commit(
                str(matches[0]["transaction_id"]),
                actual_cost_microusd=usage["cost_microusd"],
                actual_metered_tokens=usage["metered_tokens"],
            )
            snapshot = journal.snapshot()
            receipt = {
                "schema_version": (
                    RECEIPT_SCHEMA_VERSION
                    if manifest["schema_version"]
                    in {PAIRED_SCHEMA_VERSION, SCHEMA_VERSION}
                    else LEGACY_RECEIPT_SCHEMA_VERSION
                ),
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
                "resume_audit": {
                    "original_failure_receipt_sha256": failure_receipt_identity[
                        "sha256"
                    ],
                    "original_failure_stage": "post_run_evidence_audit",
                    "evidence_verified": len(frozen),
                    "late_frozen": late_frozen,
                    "auditor": auditor_identity,
                },
            }
            if manifest["schema_version"] in {
                PAIRED_SCHEMA_VERSION,
                SCHEMA_VERSION,
            }:
                receipt["evaluation_treatment"] = manifest["evaluation_treatment"]
                receipt["comparison"] = manifest["comparison"]
            _write_private_new(
                receipt_storage_path,
                (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode(
                    "utf-8"
                ),
                preopened_parent_fd=receipt_parent_fd,
            )
            return receipt
    finally:
        os.close(receipt_parent_fd)


def recover_authorized_failure_receipt(
    *,
    manifest_path: Path,
    journal_path: Path,
    receipt_path: Path,
    runner_returncode: int,
    failure_stage: str,
    started_ns: int,
) -> Dict[str, Any]:
    """Offline-only receipt recovery for a previously authorized failed run.

    This deliberately has no provider credential parameter and never invokes
    the WorkBuddy runner.  It reopens the exact authorized transaction and
    publishes only bounded, privacy-reduced failure evidence.
    """

    manifest = validate_launch_manifest(manifest_path)
    if runner_returncode < 0 or failure_stage not in AUTHORIZED_FAILURE_STAGES:
        raise LaunchError("failure receipt recovery arguments are invalid")
    if (
        failure_stage == "runner_nonzero" and runner_returncode == 0
    ) or (
        failure_stage == "post_run_evidence_audit" and runner_returncode != 0
    ):
        raise LaunchError("failure receipt recovery stage contradicts runner evidence")
    try:
        started_ns = int(started_ns)
    except (TypeError, ValueError) as exc:
        raise LaunchError("failure receipt recovery start time is invalid") from exc
    if started_ns <= 0 or started_ns > time.time_ns():
        raise LaunchError("failure receipt recovery start time is invalid")

    budget = manifest["budget"]
    model = manifest["model"]
    authority = BudgetAuthority(
        manifest_sha256=manifest["content_sha256"],
        model_fingerprint=model["fingerprint"],
        provider_identity=model["provider_identity"],
        total_cost_microusd=budget["total_cost_microusd"],
        total_metered_tokens=budget["total_metered_tokens"],
    )
    receipt_parent, receipt_parent_fd = _open_private_artifact_parent(receipt_path)
    try:
        receipt_storage_path = receipt_parent / receipt_path.name
        if _entry_exists(receipt_parent_fd, receipt_path.name) or _entry_exists(
            receipt_parent_fd, receipt_path.name + ".tmp"
        ):
            raise LaunchError(
                "paid launch receipt path is already occupied or incomplete"
            )
        with BudgetJournal(journal_path, authority) as journal:
            matches = [
                transaction
                for transaction in journal.transaction_receipts()
                if transaction["run_id"] == manifest["run_id"]
                and transaction["manifest_sha256"] == manifest["content_sha256"]
            ]
            if len(matches) != 1 or matches[0]["state"] != "request_authorized":
                raise LaunchError(
                    "failure receipt recovery requires one exact authorized transaction"
                )
            _persist_authorized_failure_receipt(
                manifest=manifest,
                journal=journal,
                transaction_id=str(matches[0]["transaction_id"]),
                runner_returncode=runner_returncode,
                failure_stage=failure_stage,
                receipt_mode="offline_recovery",
                started_ns=started_ns,
                official_runner=True,
                receipt_path=receipt_storage_path,
                receipt_parent_fd=receipt_parent_fd,
                journal_path=journal_path,
            )
        return validate_authorized_failure_receipt(
            receipt_storage_path, journal_path=journal_path
        )
    finally:
        os.close(receipt_parent_fd)


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
    receipt_absolute = Path(os.path.abspath(os.fspath(receipt_path)))
    journal_absolute = Path(os.path.abspath(os.fspath(journal_path)))
    journal_internal = {
        journal_absolute,
        journal_absolute.with_name(journal_absolute.name + ".lock"),
        journal_absolute.with_name(journal_absolute.name + ".tmp"),
    }
    receipt_internal = {
        receipt_absolute,
        receipt_absolute.with_name(receipt_absolute.name + ".tmp"),
    }
    if journal_internal & receipt_internal:
        raise LaunchError(
            "paid launch receipt must not collide with budget journal internals"
        )
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
    receipt_parent_fd = -1
    try:
        receipt_parent, receipt_parent_fd = _open_private_artifact_parent(
            receipt_path
        )
        receipt_storage_path = receipt_parent / receipt_path.name
        try:
            journal_parent = journal_absolute.parent.resolve(strict=True)
        except OSError as exc:
            raise LaunchError(
                f"paid launch journal parent cannot be resolved: {exc}"
            ) from exc
        canonical_journal_internal = {
            journal_parent / journal_absolute.name,
            journal_parent / (journal_absolute.name + ".lock"),
            journal_parent / (journal_absolute.name + ".tmp"),
        }
        if {
            receipt_storage_path,
            receipt_parent / (receipt_path.name + ".tmp"),
        } & canonical_journal_internal:
            raise LaunchError(
                "paid launch receipt must not collide with budget journal internals"
            )
        if _entry_exists(receipt_parent_fd, receipt_path.name) or _entry_exists(
            receipt_parent_fd, receipt_path.name + ".tmp"
        ):
            raise LaunchError(
                "paid launch receipt path is already occupied or incomplete"
            )
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
                    _persist_authorized_failure_receipt(
                        manifest=manifest,
                        journal=journal,
                        transaction_id=transaction_id,
                        runner_returncode=completed.returncode,
                        failure_stage="runner_nonzero",
                        receipt_mode="in_band",
                        started_ns=started_ns,
                        official_runner=official_runner,
                        receipt_path=receipt_storage_path,
                        receipt_parent_fd=receipt_parent_fd,
                        journal_path=journal_path,
                    )
                    raise LaunchError(
                        f"WorkBuddy runner exited {completed.returncode}; "
                        "authorized maximum remains exposed and retry is forbidden; "
                        f"failure receipt: {receipt_path}"
                    )
                try:
                    usage = _collect_usage(
                        manifest,
                        started_ns=started_ns,
                        official_runner=official_runner,
                    )
                except Exception as exc:
                    _persist_authorized_failure_receipt(
                        manifest=manifest,
                        journal=journal,
                        transaction_id=transaction_id,
                        runner_returncode=completed.returncode,
                        failure_stage="post_run_evidence_audit",
                        receipt_mode="in_band",
                        started_ns=started_ns,
                        official_runner=official_runner,
                        receipt_path=receipt_storage_path,
                        receipt_parent_fd=receipt_parent_fd,
                        journal_path=journal_path,
                    )
                    raise LaunchError(
                        "WorkBuddy post-run evidence audit failed after runner exit 0; "
                        "authorized maximum remains exposed and retry is forbidden; "
                        f"failure receipt: {receipt_path}; "
                        f"audit_error={type(exc).__name__}: {str(exc)[:512]}"
                    ) from exc
                committed = journal.commit(
                    transaction_id,
                    actual_cost_microusd=usage["cost_microusd"],
                    actual_metered_tokens=usage["metered_tokens"],
                )
                snapshot = journal.snapshot()
                receipt = {
                    "schema_version": (
                        RECEIPT_SCHEMA_VERSION
                        if manifest["schema_version"]
                        in {PAIRED_SCHEMA_VERSION, SCHEMA_VERSION}
                        else LEGACY_RECEIPT_SCHEMA_VERSION
                    ),
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
                if manifest["schema_version"] in {
                    PAIRED_SCHEMA_VERSION,
                    SCHEMA_VERSION,
                }:
                    receipt["evaluation_treatment"] = manifest[
                        "evaluation_treatment"
                    ]
                    receipt["comparison"] = manifest["comparison"]
                _write_private_new(
                    receipt_path,
                    (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode(
                        "utf-8"
                    ),
                    preopened_parent_fd=receipt_parent_fd,
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
        if receipt_parent_fd >= 0:
            os.close(receipt_parent_fd)
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
    create.add_argument("--comparison-id")
    create.add_argument("--output", type=Path, required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--budget-journal", type=Path, required=True)
    run.add_argument("--receipt", type=Path, required=True)
    run.add_argument("--credential-fd", type=int, required=True)
    resume_audit = subparsers.add_parser("resume-audit")
    resume_audit.add_argument("--manifest", type=Path, required=True)
    resume_audit.add_argument("--budget-journal", type=Path, required=True)
    resume_audit.add_argument("--failure-receipt", type=Path, required=True)
    resume_audit.add_argument("--receipt", type=Path, required=True)
    resume_audit.add_argument("--started-ns", type=int, required=True)
    recover_failure = subparsers.add_parser("recover-failure-receipt")
    recover_failure.add_argument("--manifest", type=Path, required=True)
    recover_failure.add_argument("--budget-journal", type=Path, required=True)
    recover_failure.add_argument("--receipt", type=Path, required=True)
    recover_failure.add_argument("--runner-returncode", type=int, required=True)
    recover_failure.add_argument(
        "--failure-stage", choices=sorted(AUTHORIZED_FAILURE_STAGES), required=True
    )
    recover_failure.add_argument("--started-ns", type=int, required=True)
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
                comparison_id=args.comparison_id,
            )
            _write_private_new(
                args.output,
                (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8"),
            )
            print(json.dumps(manifest["dry_run"], sort_keys=True))
            return 0
        if args.command == "resume-audit":
            receipt = resume_post_run_audit(
                manifest_path=args.manifest,
                journal_path=args.budget_journal,
                failure_receipt_path=args.failure_receipt,
                receipt_path=args.receipt,
                started_ns=args.started_ns,
            )
            print(
                json.dumps(
                    {
                        "run_id": receipt["run_id"],
                        "state": "committed",
                        "resume_audit": {
                            "evidence_verified": receipt["resume_audit"][
                                "evidence_verified"
                            ],
                            "late_frozen": len(
                                receipt["resume_audit"]["late_frozen"]
                            ),
                        },
                    },
                    sort_keys=True,
                )
            )
            return 0
        if args.command == "recover-failure-receipt":
            receipt = recover_authorized_failure_receipt(
                manifest_path=args.manifest,
                journal_path=args.budget_journal,
                receipt_path=args.receipt,
                runner_returncode=args.runner_returncode,
                failure_stage=args.failure_stage,
                started_ns=args.started_ns,
            )
            print(
                json.dumps(
                    {
                        "run_id": receipt["run_id"],
                        "state": receipt["state"],
                        "retry_allowed": receipt["retry_allowed"],
                    },
                    sort_keys=True,
                )
            )
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
