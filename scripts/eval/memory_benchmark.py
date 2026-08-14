"""Deterministic metrics and validation for ``memory-maturation-v1``.

This module deliberately does not call an LLM.  It consumes an execution
trace produced by a benchmark adapter and keeps three questions separate:
answer quality, evidence retrieval, and memory governance/cost.  The schema is
strict so a missing trace cannot silently become a zero score.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import string
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_query_plan import (
    MAX_OBSERVATION_QUERY_VARIANTS,
    MULTIPLE_DISTINCT_SEED_PLANS_REASON,
    QUERY_PLAN_INVALID_PREFIX,
)
from .model import ValidationError


PROTOCOL_ID = "metacodes-memory-maturation-v1"
SCHEMA_VERSION = 2
BENCHMARKS = frozenset({"episodic_recall", "multihop_retrieval", "procedural_transfer"})
WRITE_MODES = frozenset({"disabled", "online", "read_only"})
QA_EXECUTION_INSTRUCTIONS = (
    "Answer only from context exposed by the harness. Do not inspect or modify "
    "the workspace, and do not use workspace tools. Dedicated recall tools may "
    "be used when available. Return only the shortest final answer, without "
    "explanation or supporting details. If the evidence is unavailable, answer "
    "only that it is unavailable."
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TOP_LEVEL_KEYS = frozenset(
    {
        "schema_version",
        "protocol_id",
        "benchmark",
        "case_id",
        "sequence",
        "trial",
        "arm",
        "split",
        "identity",
        "execution",
        "evaluator",
        "outcome",
        "retrieval",
        "memory",
        "graph",
        "governance",
        "cost",
        "trajectory",
    }
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def is_online_memory_case(case: Mapping[str, Any]) -> bool:
    """Return the sole lifecycle phase allowed to mutate durable memory.

    QA datasets use ``split=test`` and are read-only.  Keeping this predicate
    centralized prevents callers from accidentally equating read-only with the
    procedural benchmark's historical ``offline`` spelling.
    """

    return case.get("benchmark") == "procedural_transfer" and case.get("split") == "online"


def qa_execution_prompt(question: str) -> str:
    """Apply the arm-independent QA execution boundary frozen by adapters."""

    # Keep the evidence-bearing question first: host-scoped TinyKG recall uses
    # the first bounded prompt bytes as its exact lexical seed.  The common
    # execution boundary belongs after that seed and remains identical in all
    # arms.
    return f"{question}\n\n{QA_EXECUTION_INSTRUCTIONS}"


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected non-empty string")
    return value


def _text(value: Any, where: str) -> str:
    """Validate host/model text while preserving an observable empty output."""

    if not isinstance(value, str):
        _fail(where, "expected a string")
    return value


def _integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def _number(value: Any, where: str, *, minimum: float = 0.0) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(float(value))
        or float(value) < minimum
    ):
        _fail(where, f"expected finite number >= {minimum}")
    return float(value)


def _hash(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if HEX64.fullmatch(result) is None:
        _fail(where, "expected a lowercase SHA-256 hex digest")
    return result


def _object(value: Any, where: str, keys: Iterable[str]) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    expected = frozenset(keys)
    unknown = set(value) - expected
    missing = expected - set(value)
    if unknown:
        _fail(where, f"unknown fields: {sorted(unknown)}")
    if missing:
        _fail(where, f"missing fields: {sorted(missing)}")
    return value


def _string_list(value: Any, where: str) -> List[str]:
    if not isinstance(value, list):
        _fail(where, "expected an array")
    result: List[str] = []
    for index, item in enumerate(value):
        result.append(_string(item, f"{where}[{index}]"))
    if len(set(result)) != len(result):
        _fail(where, "must not contain duplicate ids")
    return result


def validate_memory_row(row: Mapping[str, Any], where: str = "memory row") -> None:
    """Validate one immutable benchmark result row.

    The checks intentionally reject contradictory instrumentation (for
    example, a read-only offline row that reports a write) before scoring.
    """

    if not isinstance(row, dict):
        _fail(where, "expected an object")
    unknown = set(row) - TOP_LEVEL_KEYS
    missing = TOP_LEVEL_KEYS - set(row)
    if unknown:
        _fail(where, f"unknown fields: {sorted(unknown)}")
    if missing:
        _fail(where, f"missing fields: {sorted(missing)}")
    if row["schema_version"] != SCHEMA_VERSION:
        _fail(f"{where}.schema_version", f"expected {SCHEMA_VERSION}")
    if row["protocol_id"] != PROTOCOL_ID:
        _fail(f"{where}.protocol_id", f"expected {PROTOCOL_ID!r}")

    benchmark = _string(row["benchmark"], f"{where}.benchmark")
    if benchmark not in BENCHMARKS:
        _fail(f"{where}.benchmark", f"unsupported benchmark {benchmark!r}")
    _string(row["case_id"], f"{where}.case_id")
    _integer(row["sequence"], f"{where}.sequence")
    _integer(row["trial"], f"{where}.trial")
    _string(row["arm"], f"{where}.arm")
    split = _string(row["split"], f"{where}.split")
    if benchmark in {"episodic_recall", "multihop_retrieval"} and split != "test":
        _fail(f"{where}.split", "must be 'test' for this benchmark")
    if benchmark == "procedural_transfer" and split not in {"online", "offline"}:
        _fail(f"{where}.split", "must be online or offline")

    identity = _object(
        row["identity"],
        f"{where}.identity",
        (
            "dataset_id",
            "dataset_sha256",
            "adapter_id",
            "adapter_revision",
            "split_seed",
            "manifest_sha256",
            "runtime_receipt_sha256",
            "task_fingerprint",
            "model_id",
            "model_fingerprint",
            "harness_revision",
            "arm_fingerprint",
            "grader_fingerprint",
            "observation_sha256",
        ),
    )
    for key in (
        "dataset_id",
        "adapter_id",
        "adapter_revision",
        "model_id",
        "harness_revision",
    ):
        _string(identity[key], f"{where}.identity.{key}")
    _integer(identity["split_seed"], f"{where}.identity.split_seed")
    for key in (
        "dataset_sha256",
        "manifest_sha256",
        "runtime_receipt_sha256",
        "task_fingerprint",
        "model_fingerprint",
        "arm_fingerprint",
        "grader_fingerprint",
        "observation_sha256",
    ):
        _hash(identity[key], f"{where}.identity.{key}")

    execution = _object(row["execution"], f"{where}.execution", ("status", "invalid_reason"))
    execution_status = _string(execution["status"], f"{where}.execution.status")
    if execution_status not in {"completed", "invalid"}:
        _fail(f"{where}.execution.status", "must be completed or invalid")
    if execution_status == "completed" and execution["invalid_reason"] is not None:
        _fail(f"{where}.execution.invalid_reason", "completed rows must use null")
    if execution_status == "invalid":
        _string(execution["invalid_reason"], f"{where}.execution.invalid_reason")

    evaluator = _object(row["evaluator"], f"{where}.evaluator", ("status", "invalid_reason"))
    evaluator_status = _string(evaluator["status"], f"{where}.evaluator.status")
    if evaluator_status not in {"ready", "invalid"}:
        _fail(f"{where}.evaluator.status", "must be ready or invalid")
    if evaluator_status == "ready" and evaluator["invalid_reason"] is not None:
        _fail(f"{where}.evaluator.invalid_reason", "ready evaluators must use null")
    if evaluator_status == "invalid":
        _string(evaluator["invalid_reason"], f"{where}.evaluator.invalid_reason")

    outcome = _object(
        row["outcome"],
        f"{where}.outcome",
        ("status", "success", "prediction", "gold_answers", "deterministic"),
    )
    outcome_status = _string(outcome["status"], f"{where}.outcome.status")
    if outcome_status not in {"pass", "fail", "unscored"}:
        _fail(f"{where}.outcome.status", "must be pass, fail, or unscored")
    success = outcome["success"]
    if success is not None and (not isinstance(success, bool)):
        _fail(f"{where}.outcome.success", "expected boolean or null")
    if execution_status == "completed" and evaluator_status == "ready" and outcome_status in {"pass", "fail"}:
        if success is not (outcome_status == "pass"):
            _fail(f"{where}.outcome", "status and success disagree")
    if (execution_status == "invalid" or evaluator_status == "invalid") and (
        outcome_status != "unscored" or success is not None
    ):
        _fail(
            f"{where}.outcome",
            "invalid execution/evaluator rows must be unscored with null success",
        )
    if execution_status == "completed" and evaluator_status == "ready" and outcome_status == "unscored":
        _fail(f"{where}.outcome", "ready completed rows must be scored")
    # Empty output is a real scored failure, not an infrastructure-invalid row.
    # Keeping it in the denominator prevents adapters from laundering silence.
    _text(outcome["prediction"], f"{where}.outcome.prediction")
    gold_answers = _string_list(outcome["gold_answers"], f"{where}.outcome.gold_answers")
    if benchmark in {"episodic_recall", "multihop_retrieval"} and not gold_answers:
        _fail(f"{where}.outcome.gold_answers", "cannot be empty for QA benchmarks")
    if not isinstance(outcome["deterministic"], bool):
        _fail(f"{where}.outcome.deterministic", "expected boolean")

    retrieval = _object(
        row["retrieval"],
        f"{where}.retrieval",
        (
            "enabled",
            "k",
            "hop_count",
            "query_variants",
            "expected_evidence_ids",
            "retrieved_evidence_ids",
            "verified_evidence_ids",
            "graph_truncated",
        ),
    )
    if not isinstance(retrieval["enabled"], bool):
        _fail(f"{where}.retrieval.enabled", "expected boolean")
    k = _integer(retrieval["k"], f"{where}.retrieval.k")
    hop_count = _integer(retrieval["hop_count"], f"{where}.retrieval.hop_count")
    if k > 100 or hop_count > 16:
        _fail(f"{where}.retrieval", "k/hop_count exceed protocol bounds")
    variants = retrieval["query_variants"]
    if not isinstance(variants, list):
        _fail(f"{where}.retrieval.query_variants", "expected an array")
    seen_variant_text: set[str] = set()
    exact_count = 0
    semantic_count = 0
    for index, variant in enumerate(variants):
        item = _object(variant, f"{where}.retrieval.query_variants[{index}]", ("kind", "text"))
        kind = _string(item["kind"], f"{where}.retrieval.query_variants[{index}].kind")
        if kind not in {"exact", "semantic"}:
            _fail(f"{where}.retrieval.query_variants[{index}].kind", "must be exact or semantic")
        text = _string(item["text"], f"{where}.retrieval.query_variants[{index}].text")
        normalized = " ".join(text.casefold().split())
        if normalized in seen_variant_text:
            _fail(f"{where}.retrieval.query_variants", "must not repeat equivalent text")
        seen_variant_text.add(normalized)
        exact_count += kind == "exact"
        semantic_count += kind == "semantic"
    if retrieval["enabled"]:
        if not variants or variants[0]["kind"] != "exact":
            _fail(f"{where}.retrieval.query_variants", "enabled retrieval must start with one exact query")
        invalid_reasons = (
            evaluator["invalid_reason"][len(QUERY_PLAN_INVALID_PREFIX) :].split("; ")
            if evaluator_status == "invalid"
            and isinstance(evaluator["invalid_reason"], str)
            and evaluator["invalid_reason"].startswith(QUERY_PLAN_INVALID_PREFIX)
            else []
        )
        preserves_multiple_seed_violation = (
            exact_count > 1
            and MULTIPLE_DISTINCT_SEED_PLANS_REASON in invalid_reasons
        )
        if exact_count != 1 and not preserves_multiple_seed_violation:
            _fail(f"{where}.retrieval.query_variants", "must contain exactly one exact query")
        if semantic_count > 4:
            _fail(f"{where}.retrieval.query_variants", "at most four semantic variants are allowed")
        if len(variants) > MAX_OBSERVATION_QUERY_VARIANTS:
            _fail(
                f"{where}.retrieval.query_variants",
                f"at most {MAX_OBSERVATION_QUERY_VARIANTS} audit variants are allowed",
            )
    elif variants or k != 0 or hop_count != 0:
        _fail(f"{where}.retrieval", "disabled retrieval must have empty queries and zero k/hops")
    expected = _string_list(retrieval["expected_evidence_ids"], f"{where}.retrieval.expected_evidence_ids")
    retrieved = _string_list(retrieval["retrieved_evidence_ids"], f"{where}.retrieval.retrieved_evidence_ids")
    verified = _string_list(retrieval["verified_evidence_ids"], f"{where}.retrieval.verified_evidence_ids")
    if not retrieval["enabled"] and (retrieved or verified):
        _fail(
            f"{where}.retrieval",
            "disabled retrieval must not report retrieved or verified evidence",
        )
    if not set(verified).issubset(set(retrieved)):
        _fail(f"{where}.retrieval.verified_evidence_ids", "must be a subset of retrieved evidence")
    if benchmark == "multihop_retrieval" and retrieval["enabled"] and len(expected) < 2:
        _fail(f"{where}.retrieval.expected_evidence_ids", "HotpotQA-shaped cases require >=2 supports")
    if not isinstance(retrieval["graph_truncated"], bool):
        _fail(f"{where}.retrieval.graph_truncated", "expected boolean")

    memory = _object(
        row["memory"],
        f"{where}.memory",
        (
            "write_mode",
            "exposed_tokens",
            "internal_tokens",
            "inserted_nodes",
            "active_nodes",
            "provenance_links",
            "abstraction_nodes",
            "abstraction_nodes_with_provenance",
            "candidate_fanout",
        ),
    )
    write_mode = _string(memory["write_mode"], f"{where}.memory.write_mode")
    if write_mode not in WRITE_MODES:
        _fail(f"{where}.memory.write_mode", "must be disabled, online, or read_only")
    for key in (
        "exposed_tokens",
        "internal_tokens",
        "inserted_nodes",
        "active_nodes",
        "provenance_links",
        "abstraction_nodes",
        "abstraction_nodes_with_provenance",
    ):
        _integer(memory[key], f"{where}.memory.{key}")
    _number(memory["candidate_fanout"], f"{where}.memory.candidate_fanout")
    if memory["abstraction_nodes_with_provenance"] > memory["abstraction_nodes"]:
        _fail(f"{where}.memory", "provenance-bearing abstractions exceed abstractions")
    if write_mode in {"disabled", "read_only"} and memory["inserted_nodes"] != 0:
        _fail(
            f"{where}.memory.inserted_nodes",
            f"{write_mode} memory must not insert nodes",
        )
    online_memory = benchmark == "procedural_transfer" and split == "online"
    if (
        row["arm"] != "no_memory"
        and not online_memory
        and write_mode not in {"read_only", "disabled"}
    ):
        _fail(
            f"{where}.memory.write_mode",
            "read-only evaluation must use read_only or disabled memory",
        )
    if split == "offline" and memory["inserted_nodes"] != 0:
        _fail(f"{where}.memory.inserted_nodes", "offline evaluation must not insert nodes")
    if row["arm"] == "no_memory":
        if retrieval["enabled"]:
            _fail(f"{where}.retrieval.enabled", "no_memory must disable retrieval")
        if write_mode != "disabled":
            _fail(f"{where}.memory.write_mode", "no_memory must disable memory writes")
        for key in (
            "exposed_tokens",
            "internal_tokens",
            "inserted_nodes",
            "active_nodes",
            "provenance_links",
            "abstraction_nodes",
            "abstraction_nodes_with_provenance",
        ):
            if memory[key] != 0:
                _fail(f"{where}.memory.{key}", "no_memory counters must be zero")
        if float(memory["candidate_fanout"]) != 0.0:
            _fail(f"{where}.memory.candidate_fanout", "no_memory fanout must be zero")

    graph = _object(row["graph"], f"{where}.graph", ("revision", "text_stale", "retrieval_excluded_nodes", "contradiction_edges"))
    _string(graph["revision"], f"{where}.graph.revision")
    if not isinstance(graph["text_stale"], bool):
        _fail(f"{where}.graph.text_stale", "expected boolean")
    _integer(graph["retrieval_excluded_nodes"], f"{where}.graph.retrieval_excluded_nodes")
    _integer(graph["contradiction_edges"], f"{where}.graph.contradiction_edges")

    governance = _object(
        row["governance"],
        f"{where}.governance",
        (
            "stale_candidates",
            "stale_rejected",
            "contradictory_candidates",
            "contradictory_rejected",
            "retrieval_excluded_returned",
            "provenance_missing_returned",
            "offline_write_events",
        ),
    )
    for key in governance:
        _integer(governance[key], f"{where}.governance.{key}")
    if governance["stale_rejected"] > governance["stale_candidates"]:
        _fail(f"{where}.governance", "stale rejections exceed stale candidates")
    if governance["contradictory_rejected"] > governance["contradictory_candidates"]:
        _fail(f"{where}.governance", "contradiction rejections exceed candidates")
    if not online_memory and governance["offline_write_events"] != 0:
        _fail(
            f"{where}.governance.offline_write_events",
            "offline write leakage is invalid for every read-only lifecycle",
        )

    cost = _object(row["cost"], f"{where}.cost", ("cost_usd", "wall_time_ms"))
    _number(cost["cost_usd"], f"{where}.cost.cost_usd")
    _number(cost["wall_time_ms"], f"{where}.cost.wall_time_ms")
    trajectory = _object(row["trajectory"], f"{where}.trajectory", ("model_requests", "tool_calls", "tool_errors", "turns"))
    for key in trajectory:
        _integer(trajectory[key], f"{where}.trajectory.{key}")


def _parse_json_line(raw: str, where: str) -> Mapping[str, Any]:
    def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(where, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(raw, object_pairs_hook=reject_duplicates)
    except json.JSONDecodeError as exc:
        _fail(where, f"invalid JSON: {exc}")
    if not isinstance(value, dict):
        _fail(where, "expected one JSON object")
    return value


def load_memory_rows(path: Path) -> List[Mapping[str, Any]]:
    try:
        payload = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValidationError(f"cannot read memory results {path}: {exc}") from exc
    rows: List[Mapping[str, Any]] = []
    for line_no, raw in enumerate(payload.splitlines(), 1):
        if not raw.strip():
            continue
        row = _parse_json_line(raw, f"{path}:{line_no}")
        validate_memory_row(row, f"{path}:{line_no}")
        rows.append(row)
    if not rows:
        raise ValidationError(f"memory results {path} are empty")
    return rows


def _normalize_answer(value: str) -> str:
    value = value.casefold()
    value = value.translate(str.maketrans("", "", string.punctuation))
    value = re.sub(r"\b(a|an|the)\b", " ", value)
    return " ".join(value.split())


def normalized_exact_match(prediction: str, references: Sequence[str]) -> bool:
    normalized = _normalize_answer(prediction)
    return any(normalized == _normalize_answer(reference) for reference in references)


def _f1(prediction: str, reference: str) -> float:
    from collections import Counter

    predicted = _normalize_answer(prediction).split()
    gold = _normalize_answer(reference).split()
    if not predicted or not gold:
        return float(predicted == gold)
    common = sum((Counter(predicted) & Counter(gold)).values())
    if not common:
        return 0.0
    precision = common / len(predicted)
    recall = common / len(gold)
    return 2.0 * precision * recall / (precision + recall)


def _answer_scores(row: Mapping[str, Any]) -> Tuple[float, float]:
    prediction = row["outcome"]["prediction"]
    references = row["outcome"]["gold_answers"]
    if not references:
        return float("nan"), float("nan")
    normalized = _normalize_answer(prediction)
    em = max(float(normalized == _normalize_answer(ref)) for ref in references)
    f1 = max(_f1(prediction, ref) for ref in references)
    return em, f1


def _ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def _mean(values: Sequence[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _percentile(values: Sequence[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * fraction
    low = math.floor(index)
    high = math.ceil(index)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def _group_key(row: Mapping[str, Any]) -> Tuple[str, str, str]:
    return (row["benchmark"], row["arm"], row["split"])


def _group_summary(rows: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    valid = [
        row
        for row in rows
        if row["execution"]["status"] == "completed"
        and row["evaluator"]["status"] == "ready"
    ]
    scored = [row for row in valid if row["outcome"]["status"] in {"pass", "fail"}]
    ems: List[float] = []
    f1s: List[float] = []
    recalls: List[float] = []
    precisions: List[float] = []
    verified_recalls: List[float] = []
    exposed: List[float] = []
    internal: List[float] = []
    costs: List[float] = []
    fanouts: List[float] = []
    provenance_ratios: List[float] = []
    for row in scored:
        em, f1 = _answer_scores(row)
        if not math.isnan(em):
            ems.append(em)
            f1s.append(f1)
        retrieval = row["retrieval"]
        expected = set(retrieval["expected_evidence_ids"])
        retrieved = set(retrieval["retrieved_evidence_ids"])
        verified = set(retrieval["verified_evidence_ids"])
        if expected:
            recalls.append(len(expected & retrieved) / len(expected))
            verified_recalls.append(len(expected & verified) / len(expected))
        if retrieved:
            precisions.append(len(expected & retrieved) / len(retrieved))
        memory = row["memory"]
        exposed.append(float(memory["exposed_tokens"]))
        internal.append(float(memory["internal_tokens"]))
        costs.append(float(row["cost"]["cost_usd"]))
        fanouts.append(float(memory["candidate_fanout"]))
        if memory["abstraction_nodes"]:
            provenance_ratios.append(
                memory["abstraction_nodes_with_provenance"] / memory["abstraction_nodes"]
            )
    success = [float(row["outcome"]["success"]) for row in scored if row["outcome"]["success"] is not None]
    return {
        "rows": len(rows),
        "valid_rows": len(valid),
        "invalid_rows": len(rows) - len(valid),
        "scored_rows": len(scored),
        "outcome_success_rate": _mean(success),
        "answer_exact_match": _mean(ems),
        "answer_f1": _mean(f1s),
        "evidence_recall_at_k": _mean(recalls),
        "verified_evidence_recall_at_k": _mean(verified_recalls),
        "evidence_precision_at_k": _mean(precisions),
        "mean_exposed_tokens": _mean(exposed),
        "p95_exposed_tokens": _percentile(exposed, 0.95),
        "mean_internal_tokens": _mean(internal),
        "mean_cost_usd": _mean(costs),
        "mean_candidate_fanout": _mean(fanouts),
        "provenance_coverage": _mean(provenance_ratios),
        "offline_write_leaks": sum(row["governance"]["offline_write_events"] for row in rows),
        "stale_rejection_rate": _ratio(
            sum(row["governance"]["stale_rejected"] for row in rows),
            sum(row["governance"]["stale_candidates"] for row in rows),
        ),
        "contradiction_rejection_rate": _ratio(
            sum(row["governance"]["contradictory_rejected"] for row in rows),
            sum(row["governance"]["contradictory_candidates"] for row in rows),
        ),
    }


def _density(rows: Sequence[Mapping[str, Any]], base_arm: str) -> Dict[str, float | None]:
    """Compute PlugMem-style PMI density as a clearly secondary statistic."""

    grouped: Dict[Tuple[str, int, str, str], Dict[str, Mapping[str, Any]]] = defaultdict(dict)
    for row in rows:
        if (
            row["execution"]["status"] != "completed"
            or row["evaluator"]["status"] != "ready"
            or row["outcome"]["status"] not in {"pass", "fail"}
        ):
            continue
        grouped[(row["benchmark"], row["trial"], row["case_id"], row["split"])][row["arm"]] = row
    by_arm: Dict[str, List[Tuple[float, float, int]]] = defaultdict(list)
    for pair in grouped.values():
        base = pair.get(base_arm)
        if base is None:
            continue
        base_score = _answer_scores(base)[1] if base["outcome"]["gold_answers"] else float(base["outcome"]["success"])
        for arm, candidate in pair.items():
            if arm == base_arm:
                continue
            candidate_score = _answer_scores(candidate)[1] if candidate["outcome"]["gold_answers"] else float(candidate["outcome"]["success"])
            by_arm[arm].append(
                (
                    base_score,
                    candidate_score,
                    int(candidate["memory"]["exposed_tokens"]),
                )
            )
    result: Dict[str, float | None] = {}
    for arm, values in by_arm.items():
        if not values:
            result[arm] = None
            continue
        base_rate = _mean([base_score for base_score, _candidate, _tokens in values]) or 0.0
        epsilon = max(1e-6, 0.01 * base_rate)
        total_bits = 0.0
        total_tokens = 0
        for base_score, candidate_score, tokens in values:
            total_bits += math.log2((candidate_score + epsilon) / (base_score + epsilon))
            total_tokens += tokens
        result[arm] = _ratio(total_bits, float(total_tokens))
    return result


def summarize_memory(rows: Sequence[Mapping[str, Any]], *, base_arm: str = "no_memory") -> Dict[str, Any]:
    for index, row in enumerate(rows):
        validate_memory_row(row, f"memory row {index}")
    groups: Dict[Tuple[str, str, str], List[Mapping[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[_group_key(row)].append(row)
    grouped = {
        f"{benchmark}/{arm}/{split}": _group_summary(group_rows)
        for (benchmark, arm, split), group_rows in sorted(groups.items())
    }
    transfer: Dict[str, Dict[str, float | None]] = {}
    procedural = [row for row in rows if row["benchmark"] == "procedural_transfer"]
    for arm in sorted({row["arm"] for row in procedural}):
        online = [row for row in procedural if row["arm"] == arm and row["split"] == "online" and row["execution"]["status"] == "completed" and row["evaluator"]["status"] == "ready"]
        offline = [row for row in procedural if row["arm"] == arm and row["split"] == "offline" and row["execution"]["status"] == "completed" and row["evaluator"]["status"] == "ready"]
        cold = [row for row in procedural if row["arm"] == base_arm and row["split"] == "offline" and row["execution"]["status"] == "completed" and row["evaluator"]["status"] == "ready"]
        online_rate = _mean([float(row["outcome"]["success"]) for row in online]) if online else None
        offline_rate = _mean([float(row["outcome"]["success"]) for row in offline]) if offline else None
        cold_rate = _mean([float(row["outcome"]["success"]) for row in cold]) if cold else None
        transfer[arm] = {
            "online_success_rate": online_rate,
            "offline_success_rate": offline_rate,
            "cold_start_success_rate": cold_rate,
            "offline_gain_over_cold_start": (
                offline_rate - cold_rate
                if offline_rate is not None and cold_rate is not None
                else None
            ),
        }
    return {
        "schema_version": SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "rows": len(rows),
        "groups": grouped,
        "plugmem_style_density_bits_per_exposed_token": _density(rows, base_arm),
        "procedural_transfer": transfer,
    }


def render_memory_markdown(summary: Mapping[str, Any], title: str = "metacodes memory maturation") -> str:
    lines = [f"# {title}", "", f"Protocol: `{summary['protocol_id']}`", f"Rows: {summary['rows']}", "", "## Result groups", "", "| Group | Valid | Scored | Success | EM | F1 | Evidence R@K | Verified R@K | Exposed tok | Cost USD |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for group, metrics in summary["groups"].items():
        def fmt(key: str, digits: int = 3) -> str:
            value = metrics.get(key)
            return "-" if value is None else f"{value:.{digits}f}"

        lines.append(
            f"| `{group}` | {metrics['valid_rows']} | {metrics['scored_rows']} | "
            f"{fmt('outcome_success_rate')} | {fmt('answer_exact_match')} | {fmt('answer_f1')} | "
            f"{fmt('evidence_recall_at_k')} | {fmt('verified_evidence_recall_at_k')} | "
            f"{fmt('mean_exposed_tokens', 1)} | {fmt('mean_cost_usd', 4)} |"
        )
    lines.extend(["", "## Secondary diagnostics", "", "PlugMem-style PMI density is secondary and must not replace outcome/evidence metrics.", "", "```json", json.dumps({"density": summary["plugmem_style_density_bits_per_exposed_token"], "procedural_transfer": summary["procedural_transfer"]}, ensure_ascii=False, indent=2, sort_keys=True), "```", ""])
    return "\n".join(lines)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write_memory_rows(path: Path, rows: Iterable[Mapping[str, Any]]) -> None:
    materialized = [dict(row) for row in rows]
    for index, row in enumerate(materialized):
        validate_memory_row(row, f"memory rows[{index}]")
    text = "".join(
        json.dumps(row, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        for row in materialized
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        temp_path = None
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
