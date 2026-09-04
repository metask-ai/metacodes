#!/usr/bin/env python3
"""Zero-provider release gate and receipt for the metacodes plugin contract.

This command never loads a provider credential and never emits quality
evidence. The paid coding pair is frozen in the protocol but remains a separate
explicitly authorized operation.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import stat
import subprocess
import tempfile
import tarfile
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence


SCHEMA = "metacodes.plugin-evaluation/v1"
RECEIPT_SCHEMA = "metacodes.plugin-zero-provider-receipt/v1"


class PluginGateError(ValueError):
    pass


@dataclass(frozen=True)
class RuntimeArtifactAttestation:
    """A protocol-pinned executable observed at an explicit host path."""

    path: Path
    sha256: str


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _median_int(values: Sequence[int]) -> int:
    if not values:
        raise PluginGateError("cannot summarize an empty benchmark series")
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) // 2


def _safe_file(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if (
        not relative
        or path.is_absolute()
        or path.as_posix() != relative
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise PluginGateError(f"unsafe protocol path: {relative!r}")
    unresolved = root / path
    cursor = root
    for part in path.parts:
        cursor /= part
        if cursor.is_symlink():
            raise PluginGateError(f"protocol path contains a symlink: {relative}")
    resolved = unresolved.resolve(strict=True)
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise PluginGateError(f"protocol path escapes repository: {relative}") from exc
    if not resolved.is_file():
        raise PluginGateError(f"protocol path is not a regular file: {relative}")
    return resolved


def _require_hashes(root: Path, rows: Mapping[str, Any], label: str) -> None:
    if not isinstance(rows, dict) or not rows:
        raise PluginGateError(f"{label} must be a non-empty path/hash mapping")
    for relative, expected in sorted(rows.items()):
        if not isinstance(relative, str) or not isinstance(expected, str):
            raise PluginGateError(f"{label} contains a malformed row")
        observed = _sha256(_safe_file(root, relative))
        if observed != expected:
            raise PluginGateError(
                f"{label} drifted for {relative}: expected {expected}, observed {observed}"
            )


def _require_exact_tree(
    root: Path,
    relative: str,
    pinned: Mapping[str, Any],
    label: str,
) -> None:
    """The directory holds exactly the pinned regular files - nothing added,
    nothing missing, nothing executable, no symlinks anywhere beneath it -
    and exactly the directories those files imply.

    ``_require_hashes`` proves the pinned files are what they were; this
    proves they are all there is. Without it a file dropped next to a pinned
    Skill needs no protocol edit at all, so no pin, no fingerprint and no
    frozen-manifest field would notice a candidate that executes differently.
    Directory names and each file's executable bit go into the runtime's
    Skill content revision (``computeContentRevision``), so an empty extra
    directory or a ``chmod +x`` is a different candidate to the runtime even
    with identical bytes; a data package is read, never run.
    """
    path = PurePosixPath(relative)
    if (
        not relative
        or path.is_absolute()
        or path.as_posix() != relative
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise PluginGateError(f"unsafe protocol path: {relative!r}")
    cursor = root
    for part in path.parts:
        cursor /= part
        if cursor.is_symlink():
            raise PluginGateError(f"protocol path contains a symlink: {relative}")
    directory = root / path
    if not directory.is_dir():
        raise PluginGateError(f"{label} root is not a directory: {relative}")
    present: set[str] = set()
    present_dirs: set[str] = set()
    for current, dirnames, filenames in os.walk(directory, followlinks=False):
        current_path = Path(current)
        for name in [*dirnames, *filenames]:
            entry = current_path / name
            if entry.is_symlink():
                raise PluginGateError(
                    f"{label} root contains a symlink: {entry.relative_to(root).as_posix()}"
                )
        for name in dirnames:
            present_dirs.add((current_path / name).relative_to(root).as_posix())
        for name in filenames:
            entry = current_path / name
            relative_name = entry.relative_to(root).as_posix()
            mode = entry.lstat().st_mode
            if not stat.S_ISREG(mode) or mode & 0o111:
                raise PluginGateError(
                    f"{label} root contains an executable or special file: {relative_name}"
                )
            present.add(relative_name)
    expected = set(pinned)
    if present != expected:
        raise PluginGateError(
            f"{label} root does not match its pins: "
            f"unpinned {sorted(present - expected)}, missing {sorted(expected - present)}"
        )
    prefix = relative + "/"
    expected_dirs = {
        parent.as_posix()
        for name in expected
        for parent in PurePosixPath(name).parents
        if parent.as_posix().startswith(prefix)
    }
    if present_dirs != expected_dirs:
        raise PluginGateError(
            f"{label} root has directories its pins do not imply: "
            f"unpinned {sorted(present_dirs - expected_dirs)}, "
            f"missing {sorted(expected_dirs - present_dirs)}"
        )


def _require_sha256(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise PluginGateError(f"{label} must be a lowercase SHA-256 digest")
    return value


def attest_runtime_artifact(
    protocol: Mapping[str, Any],
    runtime_binary: Path,
) -> RuntimeArtifactAttestation:
    """Bind a caller-selected ReleaseSmall executable to the frozen protocol.

    The path is intentionally not inferred from ``zig-out``. Release and paid
    callers must name the artifact they intend to execute, so stale build-tree
    state cannot silently select or reject a runtime.
    """

    if runtime_binary.is_symlink():
        raise PluginGateError("plugin runtime artifact must not be a symlink")
    try:
        resolved = runtime_binary.resolve(strict=True)
    except OSError as exc:
        raise PluginGateError(f"cannot resolve plugin runtime artifact: {exc}") from exc
    if not resolved.is_file():
        raise PluginGateError("plugin runtime artifact is not a regular file")
    if not os.access(resolved, os.X_OK):
        raise PluginGateError("plugin ReleaseSmall runtime is not executable")
    expected = _require_sha256(
        protocol.get("coding_pair", {}).get("runtime_binary_sha256"),
        "coding pair runtime_binary_sha256",
    )
    observed = _sha256(resolved)
    if observed != expected:
        raise PluginGateError(
            "coding pair ReleaseSmall runtime drifted: "
            f"expected {expected}, observed {observed}"
        )
    return RuntimeArtifactAttestation(path=resolved, sha256=observed)


def load_protocol(root: Path, path: Path) -> dict[str, Any]:
    """Load the protocol and fail closed on *every* pin, including the
    implementation fingerprint against the live tree.

    The path-taking form of ``validate_protocol_payload``. Everything that is
    about to run, measure or judge - ``run_gate``, ``plugin_pair_runner``
    (``build_plan``, and ``_observe`` behind freeze / paid run / analysis) -
    calls ``validate_protocol_payload`` directly, because each must hash the
    exact bytes it validated. Both are strict by construction rather than by a
    flag a caller could forget.
    """
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PluginGateError(f"cannot read plugin evaluation protocol: {exc}") from exc
    return validate_protocol_payload(root, raw)


def load_protocol_structure(root: Path, path: Path) -> dict[str, Any]:
    """Load the protocol and validate everything except implementation drift.

    The implementation fingerprint pins ~130 source, test, SDK and doc paths,
    and is meant to be refreshed only when a release or paid run is *frozen*
    (see ``refresh_implementation_fingerprint``). Between freezes the pin is
    stale by design. Routine tests and inspection tools that only need a valid
    protocol object must therefore not compare it against the moving tree -
    doing so made every commit that touched a pinned path repin the protocol,
    which is how 30 consecutive commits on main came to edit this file and why
    two parallel branches could not auto-merge (each carried a pin correct
    only for its own tree). Every other check - schema, status, cost
    authority, candidate, scenario and evaluator hashes - still fails closed.

    Never use this from a path that executes, measures or publishes.
    """
    return _load_and_validate(root, path, check_implementation=False)


def _load_and_validate(root: Path, path: Path, *, check_implementation: bool) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PluginGateError(f"cannot read plugin evaluation protocol: {exc}") from exc
    return _validate_payload(root, raw, check_implementation=check_implementation)


def validate_protocol_payload(root: Path, raw: bytes) -> dict[str, Any]:
    """Strictly validate one exact byte payload - every pin, including the
    implementation fingerprint against the live tree.

    This is `load_protocol` for callers that already hold the bytes and need
    the hash of *those* bytes to describe what they validated: the release
    gate's snapshot. Strict by construction, like `load_protocol`; there is
    no flag to forget.
    """
    return _validate_payload(root, raw, check_implementation=True)


def _validate_payload(root: Path, raw: bytes, *, check_implementation: bool) -> dict[str, Any]:
    """Validate one exact byte payload. Callers that need the payload's hash to
    describe the same object they validated - the gate's receipt - hash `raw`
    themselves rather than re-reading the file, so there is no second read
    for a concurrent writer to slip between."""
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise PluginGateError(f"cannot read plugin evaluation protocol: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise PluginGateError("unsupported plugin evaluation protocol")
    if value.get("quality_evidence") is not False:
        raise PluginGateError("zero-provider protocol cannot carry quality evidence")
    if value.get("status") != "pre_registered_zero_provider_only":
        raise PluginGateError("plugin evaluation protocol status is not pre-registered")

    deterministic = value.get("deterministic_gate")
    if not isinstance(deterministic, dict):
        raise PluginGateError("deterministic gate is missing")
    repeats = deterministic.get("benchmark_repetitions")
    if not isinstance(repeats, int) or isinstance(repeats, bool) or not 3 <= repeats <= 20:
        raise PluginGateError("benchmark repetitions must be in [3, 20]")
    if deterministic.get("provider_requests") != 0 or deterministic.get("quality_evidence") is not False:
        raise PluginGateError("deterministic gate must remain zero-provider/non-quality")

    candidate = value.get("candidate")
    if not isinstance(candidate, dict):
        raise PluginGateError("candidate is missing")
    _require_hashes(root, candidate.get("files"), "candidate files")
    candidate_root = candidate.get("root")
    if not isinstance(candidate_root, str):
        raise PluginGateError("candidate root must be a repository-relative path")
    _require_exact_tree(root, candidate_root, candidate["files"], "candidate")

    pair = value.get("coding_pair")
    if not isinstance(pair, dict):
        raise PluginGateError("coding pair is missing")
    if pair.get("request_input_reserve") != {
        "strategy": "max_double_estimate_or_ceil_bytes_div_2_plus_framing",
        "estimate_multiplier": 2,
        "serialized_bytes_per_token": 2,
        "provider_framing_tokens": 4096,
    }:
        raise PluginGateError("coding pair request input reserve is not frozen")
    if pair.get("provider_retry_policy") != (
        "three_connect_attempts_exponential_backoff_plus_two_midstream_same_turn_replays"
    ):
        raise PluginGateError("coding pair provider retry policy changed")
    if pair.get("evaluation_contract_version") != 4:
        raise PluginGateError("coding pair evaluation contract changed")
    if pair.get("status") != "blocked_pending_explicit_paid_authority":
        raise PluginGateError("coding pair cannot be marked runnable by the zero-provider gate")
    if pair.get("rollouts") != pair.get("trials") * len(pair.get("task_ids", [])) * 2:
        raise PluginGateError("coding pair rollout count is inconsistent")
    if pair.get("max_rollout_cost_usd") != 2.0:
        raise PluginGateError("coding pair rollout cost authority changed")
    if pair.get("max_rollout_metered_tokens") != 2_000_000:
        raise PluginGateError("coding pair rollout token authority changed")
    if pair.get("max_cumulative_cost_usd") != 72.0:
        raise PluginGateError("coding pair cost authority changed")
    if pair.get("max_cumulative_metered_tokens") != 72_000_000:
        raise PluginGateError("coding pair token authority changed")
    _require_sha256(pair.get("implementation_fingerprint"), "coding pair implementation_fingerprint")
    if check_implementation and pair.get("implementation_fingerprint") != implementation_fingerprint(root, value):
        raise PluginGateError("coding pair implementation fingerprint drifted")
    _require_sha256(
        pair.get("runtime_binary_sha256"),
        "coding pair runtime_binary_sha256",
    )
    pinned_pair_files = {
        str(pair.get("suite")): pair.get("suite_sha256"),
        str(pair.get("baseline_executable")): pair.get("baseline_executable_sha256"),
        str(pair.get("treatment_executable")): pair.get("treatment_executable_sha256"),
    }
    _require_hashes(root, pinned_pair_files, "coding pair files")
    scenario_paths = {
        f"tests/e2e/scenarios/{task}.txt": digest
        for task, digest in (pair.get("scenario_sha256") or {}).items()
    }
    if sorted((pair.get("scenario_sha256") or {}).keys()) != sorted(pair.get("task_ids", [])):
        raise PluginGateError("coding pair scenario pins do not match task ids")
    _require_hashes(root, scenario_paths, "coding scenarios")
    _require_hashes(root, value.get("pinned_evaluator_files"), "evaluator files")

    paths = value.get("implementation_paths")
    if (
        not isinstance(paths, list)
        or not paths
        or len(paths) != len(set(paths))
        or not all(isinstance(item, str) for item in paths)
    ):
        raise PluginGateError("implementation_paths must be distinct path strings")
    for relative in paths:
        _safe_file(root, relative)
    return value


def implementation_fingerprint(root: Path, protocol: Mapping[str, Any]) -> str:
    digest = hashlib.sha256()
    for relative in sorted(protocol["implementation_paths"]):
        payload = _safe_file(root, relative).read_bytes()
        encoded = relative.encode("utf-8")
        digest.update(len(encoded).to_bytes(4, "big"))
        digest.update(encoded)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def _run(
    root: Path,
    args: Sequence[str],
    *,
    env: Mapping[str, str],
    timeout: int = 600,
) -> dict[str, Any]:
    started = time.monotonic_ns()
    completed = subprocess.run(
        list(args),
        cwd=root,
        env=dict(env),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
    )
    output = completed.stdout
    if completed.returncode != 0:
        raise PluginGateError(
            f"zero-provider check failed ({completed.returncode}): {' '.join(args)}\n"
            + output[-4000:]
        )
    return {
        "argv": list(args),
        "elapsed_ms": (time.monotonic_ns() - started) // 1_000_000,
        "output_sha256": _sha256_bytes(output.encode("utf-8")),
        "output": output,
    }


def _benchmark_row(
    output: str,
    deterministic: Mapping[str, Any],
) -> dict[str, Any]:
    for line in reversed(output.splitlines()):
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and row.get("schema") == "metacodes.plugin-benchmark/v1":
            expected_thresholds = {
                "max_static_plugin_p95_overhead_ns": deterministic[
                    "max_static_plugin_p95_overhead_ns"
                ],
                "max_inventory_avg_ns": deterministic["max_inventory_avg_ns"],
            }
            if (
                row.get("quality_evidence") is not False
                or row.get("passed") is not True
                or row.get("thresholds") != expected_thresholds
                or int(row.get("static_plugin_p95_overhead_ns", -1))
                > expected_thresholds["max_static_plugin_p95_overhead_ns"]
                or int(row.get("inventory_avg_ns", -1))
                > expected_thresholds["max_inventory_avg_ns"]
            ):
                raise PluginGateError("plugin benchmark is not a passing non-quality result")
            return row
    raise PluginGateError("plugin benchmark output has no result row")


def _inventory(output: str) -> dict[str, Any]:
    for line in reversed(output.splitlines()):
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and row.get("schema") == "metacodes.plugin-inventory/v1":
            return row
    raise PluginGateError("CLI output has no plugin inventory")


def _git_head(path: Path) -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=path,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if completed.returncode != 0:
        raise PluginGateError(f"cannot resolve Git identity for {path}")
    return completed.stdout.strip()


def _materialize_head(root: Path, head: str, destination: Path) -> Path:
    completed = subprocess.run(
        ["git", "-C", str(root), "archive", "--format=tar", head],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode != 0:
        stderr = completed.stderr.decode("utf-8", "replace")
        raise PluginGateError(f"cannot materialize Git HEAD: {stderr.strip()}")
    destination.mkdir(parents=True, exist_ok=False)
    try:
        with tarfile.open(fileobj=io.BytesIO(completed.stdout), mode="r:") as archive:
            members = archive.getmembers()
            for member in members:
                name = member.name
                path = PurePosixPath(name)
                if path.is_absolute() or any(part == ".." for part in path.parts):
                    raise PluginGateError(f"unsafe archive member: {name!r}")
                if not (member.isdir() or member.isreg()):
                    raise PluginGateError(f"unsafe archive member type: {name!r}")
            regular_files = sum(member.isreg() for member in members)
            if not regular_files:
                raise PluginGateError("Git archive contains no regular files")
            if hasattr(tarfile, "data_filter"):
                archive.extractall(destination, filter=tarfile.data_filter)
            else:
                archive.extractall(destination)
    except (tarfile.TarError, OSError) as exc:
        raise PluginGateError(f"cannot extract Git archive: {exc}") from exc
    fixture = destination / "scripts/eval/fixtures/plugin_baseline.py"
    if os.name != "nt" and fixture.exists() and not (fixture.stat().st_mode & stat.S_IXUSR):
        raise PluginGateError("materialized plugin_baseline.py is not owner-executable")
    return destination


def _require_clean_pinned_inputs(root: Path, protocol: Mapping[str, Any], protocol_path: Path) -> None:
    paths: set[str] = set()
    for item in protocol.get("implementation_paths", []):
        if isinstance(item, str):
            paths.add(item)
    evaluator = protocol.get("pinned_evaluator_files", {})
    if isinstance(evaluator, Mapping):
        paths.update(str(item) for item in evaluator if isinstance(item, str))
    candidate = protocol.get("candidate", {})
    if isinstance(candidate, Mapping) and isinstance(candidate.get("files"), Mapping):
        paths.update(str(item) for item in candidate["files"] if isinstance(item, str))
    pair = protocol.get("coding_pair", {})
    for key in ("suite", "baseline_executable", "treatment_executable"):
        if isinstance(pair.get(key), str):
            paths.add(pair[key])
    for task in (pair.get("scenario_sha256") or {}):
        paths.add(f"tests/e2e/scenarios/{task}.txt")
    try:
        rel = protocol_path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        rel = None
    if rel is not None:
        tracked = subprocess.run(["git", "-C", str(root), "ls-files", "--error-unmatch", "--", rel], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if tracked.returncode != 0:
            raise PluginGateError(f"protocol path {rel} is not tracked by Git")
        paths.add(rel)
    if not paths:
        return
    completed = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "-z", "--untracked-files=no"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if completed.returncode != 0:
        raise PluginGateError("cannot inspect pinned inputs")
    if completed.stdout:
        fields = completed.stdout.decode("utf-8", "replace").split("\0")
        changed: set[str] = set()
        index = 0
        while index < len(fields) and fields[index]:
            entry = fields[index]
            changed.add(entry[3:])
            if entry[:2].strip() and (entry[:2][0] in "RC" or entry[:2][1] in "RC"):
                index += 1
                if index < len(fields) and fields[index]:
                    changed.add(fields[index])
            index += 1
        listed = " ".join(sorted(changed & paths))
        if not listed:
            return
        raise PluginGateError(f"pinned inputs modified in the working tree: {listed}")


@dataclass(frozen=True)
class _GateSnapshot:
    """What a zero-provider receipt describes.

    ``open`` validates the raw bytes read once by ``run_gate`` against the
    materialized checkout and records their hash plus the live HEAD captured
    before materialization. ``require_unchanged`` re-reads the protocol,
    requires identical bytes, and validates them against the materialized
    tree; the caller then compares live HEAD. Runtime and DeepSeek Harness
    remain external inputs attested by hash/commit, and the receipt is written
    after the final check like any file.

    """

    protocol_sha256: str
    git_head: str
    implementation_fingerprint: str

    @classmethod
    def open(cls, root: Path, raw: bytes, head: str) -> tuple[dict[str, Any], "_GateSnapshot"]:
        protocol = validate_protocol_payload(root, raw)
        snapshot = cls(
            protocol_sha256=_sha256_bytes(raw),
            git_head=head,
            implementation_fingerprint=protocol["coding_pair"]["implementation_fingerprint"],
        )
        return protocol, snapshot

    def require_unchanged(self, root: Path, protocol_path: Path) -> None:
        try:
            final_raw = protocol_path.read_bytes()
        except OSError as exc:
            raise PluginGateError(f"cannot re-read plugin evaluation protocol: {exc}") from exc
        if _sha256_bytes(final_raw) != self.protocol_sha256:
            raise PluginGateError("protocol changed while the gate was running")
        # Same bytes; now the same bytes must still hold against the tree.
        validate_protocol_payload(root, final_raw)


def run_gate(
    root: Path,
    protocol_path: Path,
    dsh: Path,
    runtime_binary: Path,
) -> dict[str, Any]:
    head = _git_head(root)
    try:
        raw = protocol_path.read_bytes()
        structure = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PluginGateError(f"cannot read plugin evaluation protocol: {exc}") from exc
    if not isinstance(structure, dict):
        raise PluginGateError("unsupported plugin evaluation protocol")
    # Run this before strict validation so dirty pins get a clear diagnosis.
    _require_clean_pinned_inputs(root, structure, protocol_path)
    with tempfile.TemporaryDirectory(prefix="metacodes-plugin-gate-tree-") as temp:
        tree_root = _materialize_head(root, head, Path(temp) / "tree")
        protocol, snapshot = _GateSnapshot.open(tree_root, raw, head)
        return _run_gate_materialized(root, protocol_path, dsh, runtime_binary, tree_root, protocol, snapshot)


def _run_gate_materialized(
    root: Path,
    protocol_path: Path,
    dsh: Path,
    runtime_binary: Path,
    tree_root: Path,
    protocol: Mapping[str, Any],
    snapshot: _GateSnapshot,
) -> dict[str, Any]:
    # One read: the object the gate runs with and the hash the receipt will
    # carry come from the same bytes. The receipt is built minutes of
    # subprocesses later; it must describe this snapshot and nothing else.
    runtime = attest_runtime_artifact(protocol, runtime_binary)
    expected_dsh = protocol["upstream"]["deepseek_harness_commit"]
    observed_dsh = _git_head(dsh)
    if observed_dsh != expected_dsh:
        raise PluginGateError(
            f"DeepSeek Harness revision drifted: expected {expected_dsh}, observed {observed_dsh}"
        )

    clean_env = {
        key: value
        for key, value in os.environ.items()
        if key
        not in {
            "METASK_API_KEY",
            "METACODES_API_KEY",
            "METACODES_API_KEY_FD",
            "METACODES_RUNTIME_CREDENTIAL_FD",
        }
    }
    clean_env["METACODES_NO_PROBE"] = "1"
    checks: list[dict[str, Any]] = []
    for name, argv in (
        ("plugin_component_l2", ["zig", "build", "test:new", "-Dtfilter=plugin"]),
        (
            "plugin_effect_lifecycle",
            ["zig", "build", "test:new", "-Dtfilter=plugin effect lifecycle"],
        ),
        (
            "plugin_service_graph",
            ["zig", "build", "test:new", "-Dtfilter=plugin service graph"],
        ),
        (
            "plugin_advisory_hook",
            ["zig", "build", "test:new", "-Dtfilter=static advisory hook"],
        ),
        (
            "plugin_runtime_generation",
            [
                "zig",
                "build",
                "test:new",
                "-Dtfilter=RuntimeHost atomically replaces plugin generations",
            ],
        ),
        (
            "core_profile_hot_swap",
            [
                "zig",
                "build",
                "test:new",
                "-Dtfilter=RuntimeHost hot-swaps first-party core profiles",
            ],
        ),
        ("plugin_library_isolation", ["zig", "build", "test:lib", "-Dtfilter=plugin"]),
        (
            "agentcore_process_plugin_abi",
            ["zig", "build", "agentcore:test", "-Dtfilter=process plugin"],
        ),
        ("independent_zig_host", ["zig", "build", "example"]),
    ):
        result = _run(tree_root, argv, env=clean_env)
        checks.append({key: value for key, value in result.items() if key != "output"} | {"name": name})

    benchmark_rows = []
    for _ in range(protocol["deterministic_gate"]["benchmark_repetitions"]):
        result = _run(
            tree_root,
            ["zig", "build", "plugin:bench", "-Doptimize=ReleaseSafe"],
            env=clean_env,
        )
        benchmark_rows.append(
            _benchmark_row(result["output"], protocol["deterministic_gate"])
        )

    with tempfile.TemporaryDirectory(prefix="metacodes-plugin-gate-home-") as home:
        runtime = attest_runtime_artifact(protocol, runtime.path)
        inventory_env = dict(clean_env)
        inventory_env["HOME"] = home
        inventory_env["METACODES_PLUGIN_RUNTIME_BINARY"] = str(runtime.path)
        baseline = _run(
            tree_root,
            [str(tree_root / "scripts/eval/fixtures/plugin_baseline.py"), "--dump-plugins"],
            env=inventory_env,
        )
        candidate = _run(
            tree_root,
            [str(tree_root / "scripts/eval/fixtures/plugin_candidate.py"), "--dump-plugins"],
            env=inventory_env,
        )
        runtime = attest_runtime_artifact(protocol, runtime.path)
    baseline_inventory = _inventory(baseline["output"])
    candidate_inventory = _inventory(candidate["output"])
    if baseline_inventory.get("plugins") != []:
        raise PluginGateError("baseline inventory is not empty")
    plugins = candidate_inventory.get("plugins")
    if (
        not isinstance(plugins, list)
        or len(plugins) != 1
        or plugins[0].get("id") != protocol["candidate"]["plugin_id"]
        or plugins[0].get("capabilities") != ["skill_bundle"]
    ):
        raise PluginGateError("candidate inventory does not match the frozen plugin")
    for name, result in (
        ("baseline_empty_inventory", baseline),
        ("candidate_namespaced_inventory", candidate),
    ):
        checks.append({key: value for key, value in result.items() if key != "output"} | {"name": name})
    checks.append(
        {
            "name": "credential_free_cli_inventory",
            "elapsed_ms": baseline["elapsed_ms"] + candidate["elapsed_ms"],
            "output_sha256": _sha256_bytes(
                (baseline["output"] + candidate["output"]).encode("utf-8")
            ),
        }
    )
    checks.append(
        {
            "name": "snapshot_microbenchmark",
            "repetitions": len(benchmark_rows),
            "output_sha256": _sha256_bytes(
                json.dumps(
                    benchmark_rows, sort_keys=True, separators=(",", ":")
                ).encode("utf-8")
            ),
        }
    )
    observed_checks = {str(row["name"]) for row in checks}
    required_checks = set(protocol["deterministic_gate"]["required_checks"])
    if not required_checks.issubset(observed_checks):
        missing = sorted(required_checks - observed_checks)
        raise PluginGateError(f"zero-provider receipt is missing required checks: {missing}")

    # Every pin was checked once, before any subprocess ran. Re-run the whole
    # strict load now - not just the implementation fingerprint: candidate,
    # scenario and evaluator hashes are pins too - and require the protocol
    # bytes and the tree identity to be the ones captured at the start, so
    # the receipt cannot describe a different snapshot than the checks did.
    snapshot.require_unchanged(tree_root, protocol_path)
    if _git_head(root) != snapshot.git_head:
        raise PluginGateError("git HEAD moved while the gate was running")

    overheads = [int(row["static_plugin_p95_overhead_ns"]) for row in benchmark_rows]
    inventories = [int(row["inventory_avg_ns"]) for row in benchmark_rows]
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "quality_evidence": False,
        "provider_requests": 0,
        "protocol_sha256": snapshot.protocol_sha256,
        "metacodes_git_head": snapshot.git_head,
        "implementation_fingerprint": snapshot.implementation_fingerprint,
        "deepseek_harness_commit": observed_dsh,
        "candidate": {
            "plugin_id": protocol["candidate"]["plugin_id"],
            "plugin_version": protocol["candidate"]["plugin_version"],
            "inventory": candidate_inventory,
        },
        "checks": checks,
        "performance": {
            "runs": benchmark_rows,
            "static_plugin_p95_overhead_ns_median": _median_int(overheads),
            "static_plugin_p95_overhead_ns_max": max(overheads),
            "inventory_avg_ns_median": _median_int(inventories),
            "inventory_avg_ns_max": max(inventories),
        },
        "coding_pair": {
            "status": protocol["coding_pair"]["status"],
            "quality_claim": "none",
            "authorized_cost_usd": 0.0,
            "provider_requests": 0,
            "runtime_binary_sha256": runtime.sha256,
        },
        "release_status": "blocked_pending_paid_coding_pair",
    }
    receipt["content_sha256"] = _sha256_bytes(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode("utf-8")
    )
    return receipt


def _write_new(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def refresh_implementation_fingerprint(root: Path, protocol_path: Path) -> dict[str, Any]:
    """Explicitly repin coding_pair.implementation_fingerprint in place.

    The supported write path after an intentional implementation change.  It
    reads the protocol leniently (load_protocol fails closed on the stale pin
    before it could report the fresh value), recomputes the fingerprint over
    implementation_paths, and text-replaces the single pinned digest so the
    file keeps its exact formatting.  It never runs implicitly and never
    weakens the gate: the repinned candidate is verified with load_protocol in
    a staging file before atomically replacing the real one, so a protocol
    with any other drift is left untouched.
    pinned_evaluator_files stays deliberately out of scope — a gate that
    repins its own code hash would be a self-attestation loophole.
    """

    try:
        raw = protocol_path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PluginGateError(f"cannot read plugin evaluation protocol: {exc}") from exc
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise PluginGateError("unsupported plugin evaluation protocol")
    pair = value.get("coding_pair")
    if not isinstance(pair, dict):
        raise PluginGateError("coding pair is missing")
    pinned = _require_sha256(
        pair.get("implementation_fingerprint"),
        "coding pair implementation_fingerprint",
    )
    paths = value.get("implementation_paths")
    if (
        not isinstance(paths, list)
        or not paths
        or len(paths) != len(set(paths))
        or not all(isinstance(item, str) for item in paths)
    ):
        raise PluginGateError("implementation_paths must be distinct path strings")
    fresh = implementation_fingerprint(root, value)
    result: dict[str, Any] = {
        "status": "already_current",
        "implementation_fingerprint": fresh,
        "protocol": str(protocol_path),
    }
    if fresh != pinned:
        if raw.count(pinned) != 1:
            raise PluginGateError(
                "refusing to rewrite: pinned fingerprint occurs "
                f"{raw.count(pinned)} times in {protocol_path}"
            )
        # Verify the repinned candidate BEFORE touching the real file: if
        # anything else in the protocol still drifts (e.g. a stale
        # pinned_evaluator_files hash), the caller's working tree keeps the
        # original protocol untouched instead of a half-refreshed state.
        staged = protocol_path.with_name(protocol_path.name + ".refresh-staging")
        try:
            # keep LF on Windows; Path.write_text(newline=) exists only since Python 3.10 (issue #59)
            with open(staged, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(raw.replace(pinned, fresh))
            load_protocol(root, staged)
            os.replace(staged, protocol_path)
        finally:
            staged.unlink(missing_ok=True)
        result = {
            "status": "refreshed",
            "previous_implementation_fingerprint": pinned,
            "implementation_fingerprint": fresh,
            "protocol": str(protocol_path),
        }
        return result
    # Already current: still fail closed if anything else in the pinned
    # protocol drifts; refresh must never report already_current for a file
    # the gate loader would reject.
    load_protocol(root, protocol_path)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--protocol",
        type=Path,
        default=root / "evals/plugin-v1/protocol.json",
    )
    parser.add_argument(
        "--deepseek-harness",
        type=Path,
        default=(
            Path(os.environ["DEEPSEEK_HARNESS_ROOT"])
            if os.environ.get("DEEPSEEK_HARNESS_ROOT")
            else None
        ),
        help="explicit DeepSeek Harness checkout (or DEEPSEEK_HARNESS_ROOT)",
    )
    parser.add_argument(
        "--runtime-binary",
        type=Path,
        help="explicit protocol-pinned ReleaseSmall metacodes artifact",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument(
        "--refresh-implementation-fingerprint",
        action="store_true",
        help=(
            "repin coding_pair.implementation_fingerprint in the protocol "
            "file after an intentional implementation change; rewrites the "
            "file in place and never runs the gate"
        ),
    )
    args = parser.parse_args(argv)
    try:
        if args.refresh_implementation_fingerprint:
            if args.validate_only or args.output is not None or args.runtime_binary is not None:
                raise PluginGateError(
                    "--refresh-implementation-fingerprint cannot be combined "
                    "with --validate-only, --output, or --runtime-binary"
                )
            print(
                json.dumps(
                    refresh_implementation_fingerprint(root, args.protocol.resolve()),
                    sort_keys=True,
                )
            )
            return 0
        if args.validate_only:
            # Inspection, not certification. Between freezes the committed pin
            # is stale by design, so this loads structurally and *reports* the
            # pin's state instead of failing on it. Exit 0 here says "the
            # protocol is well-formed and every other pin holds"; it does not
            # say the tree is frozen - `implementation_pin` does.
            protocol = load_protocol_structure(root, args.protocol.resolve())
            pinned = protocol["coding_pair"]["implementation_fingerprint"]
            observed = implementation_fingerprint(root, protocol)
            print(
                json.dumps(
                    {
                        "schema": protocol["schema"],
                        "status": protocol["status"],
                        "quality_evidence": False,
                        "provider_requests": 0,
                        "pinned_implementation_fingerprint": pinned,
                        "observed_implementation_fingerprint": observed,
                        "implementation_pin": "current" if pinned == observed else "stale",
                        "freeze_ready": pinned == observed,
                    },
                    sort_keys=True,
                )
            )
            return 0
        if args.output is None:
            raise PluginGateError("--output is required unless --validate-only is used")
        if args.runtime_binary is None:
            raise PluginGateError(
                "--runtime-binary is required unless --validate-only is used"
            )
        if args.deepseek_harness is None:
            raise PluginGateError(
                "--deepseek-harness is required unless --validate-only is used"
            )
        receipt = run_gate(
            root,
            args.protocol.resolve(),
            args.deepseek_harness.resolve(),
            args.runtime_binary.expanduser(),
        )
        _write_new(args.output.resolve(), receipt)
    except (OSError, subprocess.SubprocessError, PluginGateError) as exc:
        parser.error(str(exc))
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
