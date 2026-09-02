#!/usr/bin/env python3
"""Zero-provider release gate and receipt for the metacodes plugin contract.

This command never loads a provider credential and never emits quality
evidence. The paid coding pair is frozen in the protocol but remains a separate
explicitly authorized operation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
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
        check=False,
    )
    if completed.returncode != 0:
        raise PluginGateError(f"cannot resolve Git identity for {path}")
    return completed.stdout.strip()


@dataclass(frozen=True)
class _GateSnapshot:
    """What a zero-provider receipt describes.

    ``open`` reads the protocol file **once** and returns both the validated
    object the gate will run with and the hash of the very bytes it was parsed
    from. An earlier draft loaded the object and then hashed the file in a
    second read, which let an atomic replacement between the two produce a
    receipt whose ``protocol_sha256`` named one protocol while the checks had
    run with another's parameters.

    ``require_unchanged`` is the gate's last act before the receipt exists:
    the file must still hold the same bytes, those bytes must still pass the
    full strict validation against the tree (every pin, not only the
    implementation fingerprint), and the Git HEAD must be the one captured.
    What this does *not* detect is any mutation after an input's **last
    observation**: a pinned input changed and restored between the two
    observations while a subprocess consumed the changed version (ABA); a
    pinned input changed *during* either validation scan after its bytes were
    already hashed (the scan reads ~130 files one by one and is not atomic);
    and any input changed after the final read but before the receipt is
    returned and persisted. All of these need the subprocesses and the
    hashing to run inside a materialized checkout of the snapshot, and the
    receipt to be sealed there (issue #49).
    """

    protocol_sha256: str
    git_head: str
    implementation_fingerprint: str

    @classmethod
    def open(cls, root: Path, protocol_path: Path) -> tuple[dict[str, Any], "_GateSnapshot"]:
        try:
            raw = protocol_path.read_bytes()
        except OSError as exc:
            raise PluginGateError(f"cannot read plugin evaluation protocol: {exc}") from exc
        protocol = validate_protocol_payload(root, raw)
        snapshot = cls(
            protocol_sha256=_sha256_bytes(raw),
            git_head=_git_head(root),
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
        if _git_head(root) != self.git_head:
            raise PluginGateError("git HEAD moved while the gate was running")


def run_gate(
    root: Path,
    protocol_path: Path,
    dsh: Path,
    runtime_binary: Path,
) -> dict[str, Any]:
    # One read: the object the gate runs with and the hash the receipt will
    # carry come from the same bytes. The receipt is built minutes of
    # subprocesses later; it must describe this snapshot and nothing else.
    protocol, snapshot = _GateSnapshot.open(root, protocol_path)
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
        result = _run(root, argv, env=clean_env)
        checks.append({key: value for key, value in result.items() if key != "output"} | {"name": name})

    benchmark_rows = []
    for _ in range(protocol["deterministic_gate"]["benchmark_repetitions"]):
        result = _run(
            root,
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
            root,
            [str(root / "scripts/eval/fixtures/plugin_baseline.py"), "--dump-plugins"],
            env=inventory_env,
        )
        candidate = _run(
            root,
            [str(root / "scripts/eval/fixtures/plugin_candidate.py"), "--dump-plugins"],
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
    snapshot.require_unchanged(root, protocol_path)

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
    with path.open("x", encoding="utf-8") as handle:
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
            staged.write_text(raw.replace(pinned, fresh), encoding="utf-8")
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
