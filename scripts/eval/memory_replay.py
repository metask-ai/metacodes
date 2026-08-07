"""Replay host-owned memory observations into immutable benchmark rows.

The case manifest owns gold answers, evidence ids, treatment fingerprints and
the complete schedule.  Observation JSONL owns only what the runner observed.
Joining them here prevents a model-generated artifact from choosing its own
gold data, identity, or denominator.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
import stat
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_benchmark import (
    BENCHMARKS,
    PROTOCOL_ID,
    SCHEMA_VERSION as RESULT_SCHEMA_VERSION,
    file_sha256,
    normalized_exact_match,
    validate_memory_row,
)
from .model import ValidationError, stable_json


REPLAY_SCHEMA_VERSION = 1
RUNTIME_RECEIPT_SCHEMA_VERSION = 2
HEX64 = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,127}$")
TREATMENT_LEAK_TERMS = (
    "tinykg",
    "codex",
    "claude",
    "no_memory",
    "markdown_memory",
    "tinykg_lexical",
    "treatment arm",
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _object(value: Any, where: str, keys: Iterable[str]) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    expected = frozenset(keys)
    missing = expected - set(value)
    unknown = set(value) - expected
    if missing:
        _fail(where, f"missing fields: {sorted(missing)}")
    if unknown:
        _fail(where, f"unknown fields: {sorted(unknown)}")
    return value


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected non-empty string")
    return value


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str):
        _fail(where, "expected a string")
    return value


def _identifier(value: Any, where: str) -> str:
    result = _string(value, where)
    if IDENTIFIER.fullmatch(result) is None:
        _fail(where, "expected a stable lowercase identifier")
    return result


def _hash(value: Any, where: str) -> str:
    result = _string(value, where)
    if HEX64.fullmatch(result) is None:
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _integer(value: Any, where: str, *, minimum: int = 0, maximum: int | None = None) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    if maximum is not None and value > maximum:
        _fail(where, f"expected integer <= {maximum}")
    return value


def _string_list(value: Any, where: str, *, allow_empty: bool) -> List[str]:
    if not isinstance(value, list):
        _fail(where, "expected an array")
    result = [_string(item, f"{where}[{index}]") for index, item in enumerate(value)]
    if not allow_empty and not result:
        _fail(where, "must not be empty")
    if len(set(result)) != len(result):
        _fail(where, "must not contain duplicates")
    return result


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _finite_number(value: Any, where: str, *, minimum: float = 0.0) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or float(value) < minimum
    ):
        _fail(where, f"expected finite number >= {minimum}")
    return float(value)


def _artifact_relative_path(value: Any, where: str) -> PurePosixPath:
    raw = _string(value, where)
    path = PurePosixPath(raw)
    if path.is_absolute() or raw != path.as_posix() or any(part in {"", ".", ".."} for part in path.parts):
        _fail(where, "expected a normalized relative POSIX path")
    return path


def _artifact_path(root: Path, value: Any, where: str, *, directory: bool) -> Path:
    relative = _artifact_relative_path(value, where)
    try:
        resolved_root = root.expanduser().resolve(strict=True)
    except OSError as exc:
        raise ValidationError(f"{where}: artifact root is unavailable: {exc}") from exc
    if not resolved_root.is_dir():
        _fail(where, "artifact root is not a directory")
    current = resolved_root
    try:
        for part in relative.parts:
            current = current / part
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode):
                _fail(where, "artifact path contains a symlink")
    except OSError as exc:
        raise ValidationError(f"{where}: artifact is unavailable: {exc}") from exc
    try:
        current.resolve(strict=True).relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        raise ValidationError(f"{where}: artifact escapes the receipt root") from exc
    if directory and not current.is_dir():
        _fail(where, "expected a directory artifact")
    if not directory and not current.is_file():
        _fail(where, "expected a file artifact")
    return current


def _artifact_tree_digest(
    root: Path,
    where: str = "runtime artifact",
    *,
    ignore_lock_files: bool = False,
) -> str:
    records: List[Mapping[str, Any]] = []
    try:
        if stat.S_ISLNK(root.lstat().st_mode) or not root.is_dir():
            _fail(where, "expected a non-symlink directory")
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                _fail(where, f"unexpected symlink {relative!r}")
            if path.is_dir():
                records.append({"path": relative, "type": "directory"})
                continue
            if not path.is_file() or (ignore_lock_files and path.name.endswith(".lock")):
                continue
            data = path.read_bytes()
            records.append(
                {
                    "path": relative,
                    "type": "file",
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
            )
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError(f"{where}: cannot re-observe artifact tree: {exc}") from exc
    return hashlib.sha256(stable_json(records).encode("utf-8")).hexdigest()


def _load_unique_json(path: Path, label: str) -> Mapping[str, Any]:
    def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(label, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read {label}: {exc}") from exc
    if not isinstance(value, dict):
        _fail(label, "expected one JSON object")
    return value


def load_observations(path: Path) -> List[Mapping[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValidationError(f"cannot read memory observations {path}: {exc}") from exc
    result: List[Mapping[str, Any]] = []
    for line_no, line in enumerate(lines, 1):
        if not line.strip():
            continue
        temporary = path.with_name(f"{path.name}:{line_no}")
        # Use the same duplicate-key rejection as top-level manifests without
        # manufacturing a second permissive JSON parser.
        def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
            value: Dict[str, Any] = {}
            for key, item in pairs:
                if key in value:
                    _fail(str(temporary), f"duplicate field {key!r}")
                value[key] = item
            return value

        try:
            row = json.loads(line, object_pairs_hook=reject_duplicates)
        except ValidationError:
            raise
        except json.JSONDecodeError as exc:
            raise ValidationError(f"{path}:{line_no}: invalid JSON: {exc}") from exc
        if not isinstance(row, dict):
            _fail(f"{path}:{line_no}", "expected one JSON object")
        result.append(row)
    if not result:
        raise ValidationError(f"memory observations {path} are empty")
    return result


def load_manifest(path: Path) -> Mapping[str, Any]:
    manifest = _load_unique_json(path, f"memory manifest {path}")
    validate_manifest(manifest, f"memory manifest {path}")
    return manifest


def load_runtime_receipt(path: Path) -> Mapping[str, Any]:
    return _load_unique_json(path, f"memory runtime receipt {path}")


def validate_runtime_receipt(
    receipt: Mapping[str, Any],
    manifest: Mapping[str, Any],
    observations: Sequence[Mapping[str, Any]],
    dataset_sha256: str,
    where: str = "memory runtime receipt",
) -> None:
    schema_version = receipt.get("schema_version")
    if schema_version not in {REPLAY_SCHEMA_VERSION, RUNTIME_RECEIPT_SCHEMA_VERSION}:
        _fail(
            f"{where}.schema_version",
            f"expected {REPLAY_SCHEMA_VERSION} or {RUNTIME_RECEIPT_SCHEMA_VERSION}",
        )
    v2_fields = (
        "execution_mode",
        "quality_evidence",
        "metacodes_binary_sha256",
        "tinykg_binary_sha256",
        "external_network_calls",
        "paid_cost_usd",
        "estimated_cost_usd",
        "rollouts",
    )
    value = _object(
        receipt,
        where,
        (
            "schema_version",
            "protocol_id",
            "manifest_sha256",
            "observations_sha256",
            "dataset_sha256",
            "adapter_id",
            "adapter_revision",
            "model_id",
            "model_fingerprint",
            "harness_revision",
            "arms",
            "graders",
            *(v2_fields if schema_version == RUNTIME_RECEIPT_SCHEMA_VERSION else ()),
        ),
    )
    if value["protocol_id"] != PROTOCOL_ID:
        _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
    expected_scalars = {
        "manifest_sha256": _canonical_sha256(manifest),
        "observations_sha256": _canonical_sha256(list(observations)),
        "dataset_sha256": dataset_sha256,
        "adapter_id": manifest["dataset"]["adapter_id"],
        "adapter_revision": manifest["dataset"]["adapter_revision"],
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_revision": manifest["execution"]["harness_revision"],
    }
    for key, expected in expected_scalars.items():
        observed = _string(value[key], f"{where}.{key}")
        if key.endswith("sha256") or key.endswith("fingerprint"):
            _hash(observed, f"{where}.{key}")
        if observed != expected:
            _fail(f"{where}.{key}", f"expected {expected!r}, observed {observed!r}")

    expected_arms = {
        arm["id"]: arm["fingerprint"]
        for arm in manifest["execution"]["arms"]
    }
    if not isinstance(value["arms"], list):
        _fail(f"{where}.arms", "expected an array")
    observed_arms: Dict[str, str] = {}
    for index, raw_arm in enumerate(value["arms"]):
        arm_where = f"{where}.arms[{index}]"
        arm = _object(raw_arm, arm_where, ("id", "fingerprint"))
        arm_id = _identifier(arm["id"], f"{arm_where}.id")
        if arm_id in observed_arms:
            _fail(f"{arm_where}.id", "duplicate arm")
        observed_arms[arm_id] = _hash(arm["fingerprint"], f"{arm_where}.fingerprint")
    if observed_arms != expected_arms:
        _fail(f"{where}.arms", "runtime arm identities do not match the manifest")

    expected_graders = {
        case["id"]: case["grader"]["fingerprint"]
        for case in manifest["cases"]
    }
    if not isinstance(value["graders"], list):
        _fail(f"{where}.graders", "expected an array")
    observed_graders: Dict[str, str] = {}
    for index, raw_grader in enumerate(value["graders"]):
        grader_where = f"{where}.graders[{index}]"
        grader = _object(raw_grader, grader_where, ("case_id", "fingerprint"))
        case_id = _identifier(grader["case_id"], f"{grader_where}.case_id")
        if case_id in observed_graders:
            _fail(f"{grader_where}.case_id", "duplicate case")
        observed_graders[case_id] = _hash(
            grader["fingerprint"],
            f"{grader_where}.fingerprint",
        )
    if observed_graders != expected_graders:
        _fail(f"{where}.graders", "runtime grader identities do not match the manifest")

    if schema_version != RUNTIME_RECEIPT_SCHEMA_VERSION:
        return
    if value["execution_mode"] != "native-agent-loop-scripted-wiring-smoke":
        _fail(f"{where}.execution_mode", "unsupported native execution mode")
    if value["quality_evidence"] is not False:
        _fail(
            f"{where}.quality_evidence",
            "scripted wiring smoke must never claim memory-quality evidence",
        )
    metacodes_sha256 = _hash(
        value["metacodes_binary_sha256"],
        f"{where}.metacodes_binary_sha256",
    )
    tinykg_sha256 = _hash(
        value["tinykg_binary_sha256"],
        f"{where}.tinykg_binary_sha256",
    )
    external_network_calls = _integer(
        value["external_network_calls"],
        f"{where}.external_network_calls",
    )
    if external_network_calls != 0:
        _fail(f"{where}.external_network_calls", "scripted wiring smoke must be zero")
    paid_cost_usd = _finite_number(value["paid_cost_usd"], f"{where}.paid_cost_usd")
    if paid_cost_usd != 0.0:
        _fail(f"{where}.paid_cost_usd", "scripted wiring smoke must be zero")
    estimated_cost_usd = _finite_number(
        value["estimated_cost_usd"],
        f"{where}.estimated_cost_usd",
    )
    rollouts = value["rollouts"]
    if not isinstance(rollouts, list) or len(rollouts) != len(observations):
        _fail(f"{where}.rollouts", f"expected exactly {len(observations)} entries")
    schedule = {entry["sequence"]: entry for entry in manifest["schedule"]}
    cases_by_id = {case["id"]: case for case in manifest["cases"]}
    seen_sequences: set[int] = set()
    seen_run_ids: set[str] = set()
    for index, raw_rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        rollout = _object(
            raw_rollout,
            rollout_where,
            (
                "sequence",
                "case_id",
                "trial",
                "arm",
                "run_id",
                "task_fingerprint",
                "metacodes_binary_sha256",
                "tinykg_binary_sha256",
                "native_events_sha256",
                "result_sha256",
                "stderr_sha256",
                "cassette_sha256",
                "transcript_sha256",
                "workspace_sha256",
                "artifact_paths",
                "store_revision_before",
                "store_revision_after",
                "raw_store_digest_before",
                "raw_store_digest_after",
                "stop_reason",
                "provider_mode",
                "provider_requests",
                "external_network_calls",
                "paid_cost_usd",
                "estimated_cost_usd",
                "observation_sha256",
                "host_elapsed_ms",
            ),
        )
        sequence = _integer(rollout["sequence"], f"{rollout_where}.sequence")
        if sequence != index or sequence in seen_sequences or sequence not in schedule:
            _fail(f"{rollout_where}.sequence", "must be unique, contiguous, and scheduled")
        seen_sequences.add(sequence)
        run_id = _string(rollout["run_id"], f"{rollout_where}.run_id")
        if run_id in seen_run_ids:
            _fail(f"{rollout_where}.run_id", "must be unique")
        seen_run_ids.add(run_id)
        scheduled = schedule[sequence]
        for key in ("case_id", "trial", "arm"):
            if rollout[key] != scheduled[key]:
                _fail(f"{rollout_where}.{key}", "does not match frozen schedule")
        case = cases_by_id[rollout["case_id"]]
        expected_task = _canonical_sha256(case)
        if _hash(rollout["task_fingerprint"], f"{rollout_where}.task_fingerprint") != expected_task:
            _fail(f"{rollout_where}.task_fingerprint", "does not bind the frozen case")
        if _hash(
            rollout["metacodes_binary_sha256"],
            f"{rollout_where}.metacodes_binary_sha256",
        ) != metacodes_sha256:
            _fail(f"{rollout_where}.metacodes_binary_sha256", "binary identity drift")
        tinykg_enabled = rollout["arm"] in {"tinykg", "tinykg_lexical"}
        observed_tinykg = rollout["tinykg_binary_sha256"]
        if tinykg_enabled:
            if _hash(observed_tinykg, f"{rollout_where}.tinykg_binary_sha256") != tinykg_sha256:
                _fail(f"{rollout_where}.tinykg_binary_sha256", "binary identity drift")
        elif observed_tinykg is not None:
            _fail(f"{rollout_where}.tinykg_binary_sha256", "control arm must use null")
        for key in (
            "native_events_sha256",
            "result_sha256",
            "stderr_sha256",
            "cassette_sha256",
            "transcript_sha256",
            "workspace_sha256",
        ):
            _hash(rollout[key], f"{rollout_where}.{key}")
        artifact_paths = _object(
            rollout["artifact_paths"],
            f"{rollout_where}.artifact_paths",
            (
                "native_events",
                "result",
                "stderr",
                "cassette",
                "transcript",
                "workspace",
                "store",
            ),
        )
        for key in ("native_events", "result", "stderr", "cassette", "transcript", "workspace"):
            _artifact_relative_path(
                artifact_paths[key],
                f"{rollout_where}.artifact_paths.{key}",
            )
        if tinykg_enabled:
            _artifact_relative_path(
                artifact_paths["store"],
                f"{rollout_where}.artifact_paths.store",
            )
        elif artifact_paths["store"] is not None:
            _fail(f"{rollout_where}.artifact_paths.store", "control arm must use null")
        if rollout["stop_reason"] not in {"end_turn", "max_turns", "tool_loop", "budget"}:
            _fail(f"{rollout_where}.stop_reason", "unsupported native stop reason")
        if rollout["provider_mode"] != "scripted-local":
            _fail(f"{rollout_where}.provider_mode", "must be scripted-local")
        provider_requests = _integer(
            rollout["provider_requests"],
            f"{rollout_where}.provider_requests",
            minimum=1,
        )
        rollout_external_calls = _integer(
            rollout["external_network_calls"],
            f"{rollout_where}.external_network_calls",
        )
        if rollout_external_calls != 0:
            _fail(f"{rollout_where}.external_network_calls", "must be zero")
        rollout_paid_cost = _finite_number(
            rollout["paid_cost_usd"],
            f"{rollout_where}.paid_cost_usd",
        )
        if rollout_paid_cost != 0.0:
            _fail(f"{rollout_where}.paid_cost_usd", "must be zero")
        _finite_number(
            rollout["estimated_cost_usd"],
            f"{rollout_where}.estimated_cost_usd",
        )
        _finite_number(rollout["host_elapsed_ms"], f"{rollout_where}.host_elapsed_ms")
        expected_observation = _canonical_sha256(observations[sequence])
        if _hash(
            rollout["observation_sha256"],
            f"{rollout_where}.observation_sha256",
        ) != expected_observation:
            _fail(f"{rollout_where}.observation_sha256", "does not bind observation")
        observation = observations[sequence]
        trajectory = observation.get("trajectory")
        retrieval = observation.get("retrieval")
        cost = observation.get("cost")
        if not isinstance(trajectory, dict):
            _fail(f"{rollout_where}.observation", "missing native trajectory")
        model_requests = _integer(
            trajectory.get("model_requests"),
            f"{rollout_where}.observation.trajectory.model_requests",
            minimum=1,
        )
        if model_requests != provider_requests:
            _fail(
                f"{rollout_where}.provider_requests",
                "does not match native observation trajectory",
            )
        if not isinstance(retrieval, dict) or retrieval.get("enabled") is not tinykg_enabled:
            _fail(f"{rollout_where}.observation.retrieval", "arm activation mismatch")
        if tinykg_enabled and not retrieval.get("query_variants"):
            _fail(
                f"{rollout_where}.observation.retrieval.query_variants",
                "native TinyKG rollout did not execute lexical retrieval",
            )
        if not isinstance(cost, dict) or cost.get("cost_usd") != rollout["paid_cost_usd"]:
            _fail(f"{rollout_where}.paid_cost_usd", "does not match observation cost")
        before = _string(
            rollout["store_revision_before"],
            f"{rollout_where}.store_revision_before",
        )
        after = _string(
            rollout["store_revision_after"],
            f"{rollout_where}.store_revision_after",
        )
        raw_before = _string(
            rollout["raw_store_digest_before"],
            f"{rollout_where}.raw_store_digest_before",
        )
        raw_after = _string(
            rollout["raw_store_digest_after"],
            f"{rollout_where}.raw_store_digest_after",
        )
        if tinykg_enabled:
            _hash(before, f"{rollout_where}.store_revision_before")
            _hash(after, f"{rollout_where}.store_revision_after")
            _hash(raw_before, f"{rollout_where}.raw_store_digest_before")
            _hash(raw_after, f"{rollout_where}.raw_store_digest_after")
            if before != after:
                _fail(rollout_where, "read-only rollout changed TinyKG store revision")
            if raw_before != raw_after:
                _fail(rollout_where, "read-only rollout changed raw TinyKG store bytes")
        elif (
            before != "none"
            or after != "none"
            or raw_before != "none"
            or raw_after != "none"
        ):
            _fail(rollout_where, "control arm must use none store digests")
    estimated_total = sum(float(item["estimated_cost_usd"]) for item in rollouts)
    if not math.isfinite(estimated_total) or abs(estimated_cost_usd - estimated_total) > 1e-12:
        _fail(f"{where}.estimated_cost_usd", "does not equal rollout total")


def validate_runtime_artifacts(
    receipt: Mapping[str, Any],
    artifact_root: Path,
    where: str = "memory runtime artifacts",
) -> None:
    """Re-open every v2 native artifact instead of trusting receipt-shaped hashes."""

    if receipt.get("schema_version") != RUNTIME_RECEIPT_SCHEMA_VERSION:
        return
    rollouts = receipt.get("rollouts")
    if not isinstance(rollouts, list):
        _fail(where, "receipt rollouts are unavailable")
    seen_paths: set[str] = set()
    file_specs = (
        ("native_events", "native_events_sha256"),
        ("result", "result_sha256"),
        ("stderr", "stderr_sha256"),
    )
    tree_specs = (
        ("cassette", "cassette_sha256"),
        ("transcript", "transcript_sha256"),
        ("workspace", "workspace_sha256"),
    )
    for index, raw_rollout in enumerate(rollouts):
        rollout_where = f"{where}.rollouts[{index}]"
        if not isinstance(raw_rollout, dict):
            _fail(rollout_where, "expected an object")
        paths = raw_rollout.get("artifact_paths")
        if not isinstance(paths, dict):
            _fail(f"{rollout_where}.artifact_paths", "expected an object")
        for path_key, digest_key in file_specs:
            raw_path = paths.get(path_key)
            relative = _artifact_relative_path(
                raw_path,
                f"{rollout_where}.artifact_paths.{path_key}",
            ).as_posix()
            if relative in seen_paths:
                _fail(f"{rollout_where}.artifact_paths.{path_key}", "reuses another rollout artifact")
            seen_paths.add(relative)
            path = _artifact_path(
                artifact_root,
                relative,
                f"{rollout_where}.artifact_paths.{path_key}",
                directory=False,
            )
            try:
                observed = file_sha256(path)
            except OSError as exc:
                raise ValidationError(f"{rollout_where}.{digest_key}: cannot hash artifact: {exc}") from exc
            expected = _hash(raw_rollout.get(digest_key), f"{rollout_where}.{digest_key}")
            if observed != expected:
                _fail(f"{rollout_where}.{digest_key}", "raw artifact SHA-256 mismatch")
        for path_key, digest_key in tree_specs:
            raw_path = paths.get(path_key)
            relative = _artifact_relative_path(
                raw_path,
                f"{rollout_where}.artifact_paths.{path_key}",
            ).as_posix()
            if relative in seen_paths:
                _fail(f"{rollout_where}.artifact_paths.{path_key}", "reuses another rollout artifact")
            seen_paths.add(relative)
            path = _artifact_path(
                artifact_root,
                relative,
                f"{rollout_where}.artifact_paths.{path_key}",
                directory=True,
            )
            observed = _artifact_tree_digest(path, f"{rollout_where}.artifact_paths.{path_key}")
            expected = _hash(raw_rollout.get(digest_key), f"{rollout_where}.{digest_key}")
            if observed != expected:
                _fail(f"{rollout_where}.{digest_key}", "raw artifact tree mismatch")
        store_path = paths.get("store")
        tinykg_enabled = raw_rollout.get("tinykg_binary_sha256") is not None
        if tinykg_enabled:
            relative = _artifact_relative_path(
                store_path,
                f"{rollout_where}.artifact_paths.store",
            ).as_posix()
            path = _artifact_path(
                artifact_root,
                relative,
                f"{rollout_where}.artifact_paths.store",
                directory=True,
            )
            observed = _artifact_tree_digest(
                path,
                f"{rollout_where}.artifact_paths.store",
                ignore_lock_files=True,
            )
            expected = _hash(
                raw_rollout.get("raw_store_digest_after"),
                f"{rollout_where}.raw_store_digest_after",
            )
            if observed != expected:
                _fail(
                    f"{rollout_where}.raw_store_digest_after",
                    "current store tree no longer matches the read-phase receipt",
                )
        elif store_path is not None:
            _fail(f"{rollout_where}.artifact_paths.store", "control arm must use null")


def validate_manifest(manifest: Mapping[str, Any], where: str = "memory manifest") -> None:
    value = _object(
        manifest,
        where,
        (
            "schema_version",
            "protocol_id",
            "manifest_id",
            "dataset",
            "execution",
            "cases",
            "schedule",
        ),
    )
    if value["schema_version"] != REPLAY_SCHEMA_VERSION:
        _fail(f"{where}.schema_version", f"expected {REPLAY_SCHEMA_VERSION}")
    if value["protocol_id"] != PROTOCOL_ID:
        _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
    _identifier(value["manifest_id"], f"{where}.manifest_id")

    dataset = _object(
        value["dataset"],
        f"{where}.dataset",
        ("id", "source_sha256", "adapter_id", "adapter_revision", "split_seed"),
    )
    _identifier(dataset["id"], f"{where}.dataset.id")
    _hash(dataset["source_sha256"], f"{where}.dataset.source_sha256")
    _identifier(dataset["adapter_id"], f"{where}.dataset.adapter_id")
    _string(dataset["adapter_revision"], f"{where}.dataset.adapter_revision")
    _integer(dataset["split_seed"], f"{where}.dataset.split_seed")

    execution = _object(
        value["execution"],
        f"{where}.execution",
        (
            "model_id",
            "model_fingerprint",
            "harness_revision",
            "arms",
            "trials",
            "retrieval_limits",
        ),
    )
    _string(execution["model_id"], f"{where}.execution.model_id")
    _hash(execution["model_fingerprint"], f"{where}.execution.model_fingerprint")
    _string(execution["harness_revision"], f"{where}.execution.harness_revision")
    trials = _integer(execution["trials"], f"{where}.execution.trials", minimum=1, maximum=100)
    if not isinstance(execution["arms"], list) or len(execution["arms"]) < 2:
        _fail(f"{where}.execution.arms", "expected at least two arms")
    arm_ids: set[str] = set()
    for index, raw_arm in enumerate(execution["arms"]):
        arm = _object(raw_arm, f"{where}.execution.arms[{index}]", ("id", "fingerprint"))
        arm_id = _identifier(arm["id"], f"{where}.execution.arms[{index}].id")
        if arm_id in arm_ids:
            _fail(f"{where}.execution.arms[{index}].id", "duplicate arm")
        arm_ids.add(arm_id)
        _hash(arm["fingerprint"], f"{where}.execution.arms[{index}].fingerprint")
    if "no_memory" not in arm_ids:
        _fail(f"{where}.execution.arms", "must include no_memory cold-start control")
    limits = _object(
        execution["retrieval_limits"],
        f"{where}.execution.retrieval_limits",
        ("max_k", "max_hops", "max_semantic_variants"),
    )
    _integer(limits["max_k"], f"{where}.execution.retrieval_limits.max_k", minimum=1, maximum=100)
    _integer(limits["max_hops"], f"{where}.execution.retrieval_limits.max_hops", minimum=1, maximum=16)
    _integer(
        limits["max_semantic_variants"],
        f"{where}.execution.retrieval_limits.max_semantic_variants",
        maximum=4,
    )

    if not isinstance(value["cases"], list) or not value["cases"]:
        _fail(f"{where}.cases", "expected at least one case")
    case_ids: set[str] = set()
    cases_by_id: Dict[str, Mapping[str, Any]] = {}
    family_splits: Dict[str, set[str]] = {}
    family_cases: Dict[str, List[str]] = {}
    for index, raw_case in enumerate(value["cases"]):
        case_where = f"{where}.cases[{index}]"
        case = _object(
            raw_case,
            case_where,
            (
                "id",
                "benchmark",
                "split",
                "prompt",
                "gold_answers",
                "expected_evidence_ids",
                "grader",
                "family_id",
            ),
        )
        case_id = _identifier(case["id"], f"{case_where}.id")
        if case_id in case_ids:
            _fail(f"{case_where}.id", "duplicate case")
        case_ids.add(case_id)
        cases_by_id[case_id] = case
        benchmark = _string(case["benchmark"], f"{case_where}.benchmark")
        if benchmark not in BENCHMARKS:
            _fail(f"{case_where}.benchmark", f"unsupported benchmark {benchmark!r}")
        split = _string(case["split"], f"{case_where}.split")
        if benchmark in {"episodic_recall", "multihop_retrieval"} and split != "test":
            _fail(f"{case_where}.split", "QA cases must use test")
        if benchmark == "procedural_transfer" and split not in {"online", "offline"}:
            _fail(f"{case_where}.split", "procedural cases must use online/offline")
        prompt = _string(case["prompt"], f"{case_where}.prompt")
        prompt_folded = prompt.casefold()
        leaked = {term for term in TREATMENT_LEAK_TERMS if term in prompt_folded}
        for arm_id in arm_ids:
            folded_arm = arm_id.casefold()
            if re.search(
                rf"(?<![a-z0-9_.:-]){re.escape(folded_arm)}(?![a-z0-9_.:-])",
                prompt_folded,
            ):
                leaked.add(folded_arm)
        leaked = sorted(leaked)
        if leaked:
            _fail(f"{case_where}.prompt", f"leaks treatment terms: {leaked}")
        gold = _string_list(
            case["gold_answers"],
            f"{case_where}.gold_answers",
            allow_empty=benchmark == "procedural_transfer",
        )
        supports = _string_list(
            case["expected_evidence_ids"],
            f"{case_where}.expected_evidence_ids",
            allow_empty=benchmark == "procedural_transfer",
        )
        if benchmark == "multihop_retrieval" and len(supports) < 2:
            _fail(f"{case_where}.expected_evidence_ids", "multi-hop cases require >=2 supports")
        grader = _object(case["grader"], f"{case_where}.grader", ("kind", "fingerprint"))
        grader_kind = _string(grader["kind"], f"{case_where}.grader.kind")
        _hash(grader["fingerprint"], f"{case_where}.grader.fingerprint")
        expected_grader = (
            "deterministic_validator"
            if benchmark == "procedural_transfer"
            else "normalized_exact_match"
        )
        if grader_kind != expected_grader:
            _fail(f"{case_where}.grader.kind", f"expected {expected_grader!r}")
        family_id = case["family_id"]
        if benchmark == "procedural_transfer":
            family = _identifier(family_id, f"{case_where}.family_id")
            family_splits.setdefault(family, set()).add(split)
            family_cases.setdefault(family, []).append(case_id)
            if gold:
                _fail(f"{case_where}.gold_answers", "procedural cases use validators, not answer gold")
        elif family_id is not None:
            _fail(f"{case_where}.family_id", "QA cases must use null")
    for family, splits in family_splits.items():
        if splits != {"online", "offline"}:
            _fail(
                f"{where}.cases",
                f"procedural family {family!r} must contain online and offline cases",
            )
        online_cases = [
            case_id
            for case_id in family_cases[family]
            if cases_by_id[case_id]["split"] == "online"
        ]
        if len(online_cases) != 1:
            _fail(
                f"{where}.cases",
                f"procedural family {family!r} must contain exactly one online case",
            )

    expected_count = trials * len(arm_ids) * len(case_ids)
    if expected_count > 100_000:
        _fail(f"{where}.execution", "schedule exceeds 100000 observations")
    if not isinstance(value["schedule"], list) or len(value["schedule"]) != expected_count:
        _fail(
            f"{where}.schedule",
            f"expected exactly {expected_count} case/trial/arm entries",
        )
    expected_schedule = {
        (case_id, trial, arm_id)
        for case_id in case_ids
        for trial in range(trials)
        for arm_id in arm_ids
    }
    scheduled: set[Tuple[str, int, str]] = set()
    schedule_positions: Dict[Tuple[str, int, str], int] = {}
    for index, raw_entry in enumerate(value["schedule"]):
        entry_where = f"{where}.schedule[{index}]"
        entry = _object(raw_entry, entry_where, ("sequence", "case_id", "trial", "arm"))
        sequence = _integer(entry["sequence"], f"{entry_where}.sequence")
        if sequence != index:
            _fail(f"{entry_where}.sequence", f"expected contiguous sequence {index}")
        case_id = _identifier(entry["case_id"], f"{entry_where}.case_id")
        trial = _integer(entry["trial"], f"{entry_where}.trial", maximum=trials - 1)
        arm_id = _identifier(entry["arm"], f"{entry_where}.arm")
        key = (case_id, trial, arm_id)
        if key not in expected_schedule:
            _fail(entry_where, f"unknown schedule tuple {key!r}")
        if key in scheduled:
            _fail(entry_where, f"duplicate schedule tuple {key!r}")
        scheduled.add(key)
        schedule_positions[key] = sequence
    missing_schedule = sorted(expected_schedule - scheduled)
    if missing_schedule:
        _fail(f"{where}.schedule", f"missing schedule tuples: {missing_schedule[:5]}")

    # Procedural transfer is only causal when the one online demonstration is
    # executed before every held-out sibling for each arm and trial.
    for family, case_ids_in_family in family_cases.items():
        online_case = next(
            case_id
            for case_id in case_ids_in_family
            if cases_by_id[case_id]["split"] == "online"
        )
        offline_cases = [
            case_id
            for case_id in case_ids_in_family
            if cases_by_id[case_id]["split"] == "offline"
        ]
        for trial in range(trials):
            for arm_id in arm_ids:
                online_position = schedule_positions[(online_case, trial, arm_id)]
                for offline_case in offline_cases:
                    if schedule_positions[(offline_case, trial, arm_id)] <= online_position:
                        _fail(
                            f"{where}.schedule",
                            f"procedural family {family!r} runs offline before online",
                        )


def _case_map(manifest: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    return {case["id"]: case for case in manifest["cases"]}


def _arm_map(manifest: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    return {arm["id"]: arm for arm in manifest["execution"]["arms"]}


def _schedule_map(manifest: Mapping[str, Any]) -> Dict[int, Mapping[str, Any]]:
    return {entry["sequence"]: entry for entry in manifest["schedule"]}


def _observation_shell(
    observation: Mapping[str, Any], where: str
) -> Mapping[str, Any]:
    return _object(
        observation,
        where,
        (
            "schema_version",
            "protocol_id",
            "case_id",
            "trial",
            "arm",
            "execution",
            "evaluator",
            "prediction",
            "retrieval",
            "memory",
            "graph",
            "governance",
            "cost",
            "trajectory",
        ),
    )


def replay_observations(
    manifest: Mapping[str, Any],
    observations: Sequence[Mapping[str, Any]],
    *,
    dataset_source: Path,
    runtime_receipt: Mapping[str, Any],
    runtime_artifact_root: Path | None = None,
) -> List[Dict[str, Any]]:
    validate_manifest(manifest)
    try:
        observed_source_sha = file_sha256(dataset_source)
    except OSError as exc:
        raise ValidationError(f"cannot read memory replay dataset source: {exc}") from exc
    expected_source_sha = manifest["dataset"]["source_sha256"]
    if observed_source_sha != expected_source_sha:
        _fail(
            "memory replay dataset source",
            f"SHA-256 mismatch: expected {expected_source_sha}, observed {observed_source_sha}",
        )
    validate_runtime_receipt(
        runtime_receipt,
        manifest,
        observations,
        observed_source_sha,
    )
    if runtime_receipt.get("schema_version") == RUNTIME_RECEIPT_SCHEMA_VERSION:
        if runtime_artifact_root is None:
            _fail(
                "memory runtime artifacts",
                "v2 replay requires the receipt directory for raw-artifact re-observation",
            )
        validate_runtime_artifacts(runtime_receipt, runtime_artifact_root)

    cases = _case_map(manifest)
    arms = _arm_map(manifest)
    schedule = _schedule_map(manifest)
    trials = manifest["execution"]["trials"]
    limits = manifest["execution"]["retrieval_limits"]
    expected_schedule = {
        (entry["case_id"], entry["trial"], entry["arm"])
        for entry in schedule.values()
    }
    seen: set[Tuple[str, int, str]] = set()
    rows: List[Dict[str, Any]] = []
    manifest_sha256 = _canonical_sha256(manifest)
    runtime_receipt_sha256 = _canonical_sha256(runtime_receipt)

    for index, raw_observation in enumerate(observations):
        where = f"memory observations[{index}]"
        observation = _observation_shell(raw_observation, where)
        if observation["schema_version"] != REPLAY_SCHEMA_VERSION:
            _fail(f"{where}.schema_version", f"expected {REPLAY_SCHEMA_VERSION}")
        if observation["protocol_id"] != PROTOCOL_ID:
            _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")
        case_id = _identifier(observation["case_id"], f"{where}.case_id")
        if case_id not in cases:
            _fail(f"{where}.case_id", f"not present in manifest: {case_id!r}")
        sequence = index
        trial = _integer(observation["trial"], f"{where}.trial", maximum=trials - 1)
        arm_id = _identifier(observation["arm"], f"{where}.arm")
        if arm_id not in arms:
            _fail(f"{where}.arm", f"not present in manifest: {arm_id!r}")
        schedule_key = (case_id, trial, arm_id)
        if schedule_key in seen:
            _fail(where, f"duplicate schedule row {schedule_key!r}")
        scheduled_entry = schedule.get(sequence)
        if scheduled_entry is None:
            _fail(where, "observation extends beyond the frozen schedule")
        scheduled_key = (
            scheduled_entry["case_id"],
            scheduled_entry["trial"],
            scheduled_entry["arm"],
        )
        if schedule_key != scheduled_key:
            _fail(
                where,
                f"observation tuple {schedule_key!r} does not match sequence {sequence} "
                f"tuple {scheduled_key!r}",
            )
        seen.add(schedule_key)

        case = cases[case_id]
        execution = _object(
            observation["execution"],
            f"{where}.execution",
            ("status", "invalid_reason"),
        )
        execution_status = _string(execution["status"], f"{where}.execution.status")
        if execution_status not in {"completed", "invalid"}:
            _fail(f"{where}.execution.status", "must be completed or invalid")
        if execution_status == "completed" and execution["invalid_reason"] is not None:
            _fail(f"{where}.execution.invalid_reason", "completed execution must use null")
        if execution_status == "invalid":
            _string(execution["invalid_reason"], f"{where}.execution.invalid_reason")

        evaluator = _object(
            observation["evaluator"],
            f"{where}.evaluator",
            ("status", "invalid_reason", "deterministic_success"),
        )
        evaluator_status = _string(evaluator["status"], f"{where}.evaluator.status")
        if evaluator_status not in {"ready", "invalid"}:
            _fail(f"{where}.evaluator.status", "must be ready or invalid")
        if evaluator_status == "invalid":
            _string(evaluator["invalid_reason"], f"{where}.evaluator.invalid_reason")
            if evaluator["deterministic_success"] is not None:
                _fail(f"{where}.evaluator.deterministic_success", "invalid evaluator must use null")
        elif evaluator["invalid_reason"] is not None:
            _fail(f"{where}.evaluator.invalid_reason", "ready evaluator must use null")

        grader_kind = case["grader"]["kind"]
        if evaluator_status == "ready" and grader_kind == "normalized_exact_match":
            if evaluator["deterministic_success"] is not None:
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "answer success is recomputed from hidden manifest gold",
                )
        elif evaluator_status == "ready":
            if execution_status == "completed" and not isinstance(
                evaluator["deterministic_success"], bool
            ):
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "completed deterministic validation must report a boolean",
                )
            if execution_status == "invalid" and evaluator["deterministic_success"] is not None:
                _fail(
                    f"{where}.evaluator.deterministic_success",
                    "invalid execution has no procedural success result",
                )

        retrieval = _object(
            observation["retrieval"],
            f"{where}.retrieval",
            (
                "enabled",
                "k",
                "hop_count",
                "query_variants",
                "retrieved_evidence_ids",
                "verified_evidence_ids",
                "graph_truncated",
            ),
        )
        k = retrieval.get("k")
        hops = retrieval.get("hop_count")
        variants = retrieval.get("query_variants")
        if isinstance(k, int) and not isinstance(k, bool) and k > limits["max_k"]:
            _fail(f"{where}.retrieval.k", "exceeds manifest max_k")
        if isinstance(hops, int) and not isinstance(hops, bool) and hops > limits["max_hops"]:
            _fail(f"{where}.retrieval.hop_count", "exceeds manifest max_hops")
        if isinstance(variants, list):
            semantic_count = sum(
                isinstance(item, dict) and item.get("kind") == "semantic"
                for item in variants
            )
            if semantic_count > limits["max_semantic_variants"]:
                _fail(
                    f"{where}.retrieval.query_variants",
                    "exceeds manifest semantic-variant cap",
                )

        prediction = _text(observation["prediction"], f"{where}.prediction")
        if execution_status == "completed" and evaluator_status == "ready":
            if grader_kind == "normalized_exact_match":
                success = normalized_exact_match(prediction, case["gold_answers"])
            else:
                success = bool(evaluator["deterministic_success"])
            outcome_status = "pass" if success else "fail"
        else:
            success = None
            outcome_status = "unscored"

        result: Dict[str, Any] = {
            "schema_version": RESULT_SCHEMA_VERSION,
            "protocol_id": PROTOCOL_ID,
            "benchmark": case["benchmark"],
            "case_id": case_id,
            "sequence": sequence,
            "trial": trial,
            "arm": arm_id,
            "split": case["split"],
            "identity": {
                "dataset_id": manifest["dataset"]["id"],
                "dataset_sha256": expected_source_sha,
                "adapter_id": manifest["dataset"]["adapter_id"],
                "adapter_revision": manifest["dataset"]["adapter_revision"],
                "split_seed": manifest["dataset"]["split_seed"],
                "manifest_sha256": manifest_sha256,
                "runtime_receipt_sha256": runtime_receipt_sha256,
                "task_fingerprint": _canonical_sha256(case),
                "model_id": manifest["execution"]["model_id"],
                "model_fingerprint": manifest["execution"]["model_fingerprint"],
                "harness_revision": manifest["execution"]["harness_revision"],
                "arm_fingerprint": arms[arm_id]["fingerprint"],
                "grader_fingerprint": case["grader"]["fingerprint"],
                "observation_sha256": _canonical_sha256(observation),
            },
            "execution": dict(execution),
            "evaluator": {
                "status": evaluator_status,
                "invalid_reason": evaluator["invalid_reason"],
            },
            "outcome": {
                "status": outcome_status,
                "success": success,
                "prediction": prediction,
                "gold_answers": list(case["gold_answers"]),
                "deterministic": True,
            },
            "retrieval": {
                **dict(observation["retrieval"]),
                "expected_evidence_ids": list(case["expected_evidence_ids"]),
            },
            "memory": dict(observation["memory"]),
            "graph": dict(observation["graph"]),
            "governance": dict(observation["governance"]),
            "cost": dict(observation["cost"]),
            "trajectory": dict(observation["trajectory"]),
        }
        validate_memory_row(result, f"{where} joined result")
        rows.append(result)

    missing = sorted(expected_schedule - seen)
    extras = sorted(seen - expected_schedule)
    if extras:
        _fail("memory observations", f"unexpected schedule rows: {extras[:5]}")
    if missing:
        _fail(
            "memory observations",
            f"incomplete schedule: missing {len(missing)} rows, first={missing[:5]}",
        )
    rows_by_key = {
        (row["case_id"], row["trial"], row["arm"]): row
        for row in rows
    }
    family_cases: Dict[str, List[Mapping[str, Any]]] = {}
    for case in cases.values():
        if case["benchmark"] == "procedural_transfer":
            family_cases.setdefault(case["family_id"], []).append(case)
    for family, members in family_cases.items():
        online_case = next(case for case in members if case["split"] == "online")
        offline_cases = [case for case in members if case["split"] == "offline"]
        for trial in range(trials):
            for arm_id in arms:
                if arm_id == "no_memory":
                    continue
                online = rows_by_key[(online_case["id"], trial, arm_id)]
                for offline_case in offline_cases:
                    offline = rows_by_key[(offline_case["id"], trial, arm_id)]
                    if offline["graph"]["revision"] != online["graph"]["revision"]:
                        _fail(
                            "memory observations",
                            f"procedural family {family!r} offline graph revision does not "
                            "match its online predecessor",
                        )
                    online_usable = (
                        online["execution"]["status"] == "completed"
                        and online["evaluator"]["status"] == "ready"
                    )
                    offline_scored = (
                        offline["execution"]["status"] == "completed"
                        and offline["evaluator"]["status"] == "ready"
                    )
                    if offline_scored and not online_usable:
                        _fail(
                            "memory observations",
                            f"procedural family {family!r} scores offline after an invalid "
                            "online predecessor",
                        )
    return sorted(rows, key=lambda row: row["sequence"])
