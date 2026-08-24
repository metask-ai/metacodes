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
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
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
    if pair.get("implementation_fingerprint") != implementation_fingerprint(root, value):
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


def run_gate(
    root: Path,
    protocol_path: Path,
    dsh: Path,
    runtime_binary: Path,
) -> dict[str, Any]:
    protocol = load_protocol(root, protocol_path)
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

    overheads = [int(row["static_plugin_p95_overhead_ns"]) for row in benchmark_rows]
    inventories = [int(row["inventory_avg_ns"]) for row in benchmark_rows]
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "quality_evidence": False,
        "provider_requests": 0,
        "protocol_sha256": _sha256(protocol_path),
        "metacodes_git_head": _git_head(root),
        "implementation_fingerprint": implementation_fingerprint(root, protocol),
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
    args = parser.parse_args(argv)
    try:
        protocol = load_protocol(root, args.protocol.resolve())
        if args.validate_only:
            print(
                json.dumps(
                    {
                        "schema": protocol["schema"],
                        "status": protocol["status"],
                        "quality_evidence": False,
                        "provider_requests": 0,
                        "implementation_fingerprint": implementation_fingerprint(root, protocol),
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
