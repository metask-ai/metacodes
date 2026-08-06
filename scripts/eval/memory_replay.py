"""Replay host-owned memory observations into immutable benchmark rows.

The case manifest owns gold answers, evidence ids, treatment fingerprints and
the complete schedule.  Observation JSONL owns only what the runner observed.
Joining them here prevents a model-generated artifact from choosing its own
gold data, identity, or denominator.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
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
        ),
    )
    if value["schema_version"] != REPLAY_SCHEMA_VERSION:
        _fail(f"{where}.schema_version", f"expected {REPLAY_SCHEMA_VERSION}")
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
