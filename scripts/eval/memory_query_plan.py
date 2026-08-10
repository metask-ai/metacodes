"""Replayable evidence for governed TinyKG lexical query plans.

The native runtime stores complete provider requests in a cassette.  This
module derives a compact sidecar from those raw requests, validates the Zig
host receipt instead of trusting model-declared fields, and can later
recompute the sidecar byte-for-byte.  It never calls TinyKG or a model.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Mapping, MutableMapping, Sequence, Tuple

from .model import ValidationError, stable_json


TRACE_SCHEMA_VERSION = "metacodes-memory-query-plan-trace-v1"
REPORT_SCHEMA_VERSION = "metacodes-memory-query-plan-report-v2"
LEXICAL_PLAN_SCHEMA_VERSION = "lexical-query-plan-v1"
SIDECAR_NAME = "query-plan.json"
QUERY_PLAN_INVALID_PREFIX = "query-plan trace invalid: "
MULTIPLE_DISTINCT_SEED_PLANS_REASON = "multiple distinct seed plans in one run"
MAX_OBSERVATION_QUERY_VARIANTS = 5
HEX64 = re.compile(r"^[0-9a-f]{64}$")
INTENTS = frozenset(
    {
        "fact_lookup",
        "procedure_reuse",
        "task_recovery",
        "enumeration",
        "temporal",
        "causal",
        "entity",
        "other",
    }
)
STAGES = frozenset({"seed", "semantic_expansion", "focused_refinement"})
VARIANT_KINDS = frozenset(
    {
        "exact",
        "alias",
        "paraphrase",
        "mechanism",
        "symptom",
        "outcome",
        "broader",
        "narrower",
        "relation",
        "type",
        "time",
    }
)
TINYKG_BACKENDS = frozenset({"tinykg", "tinykg_integrated"})
TRACE_KEYS = frozenset(
    {
        "schema_version",
        "run_id",
        "arm",
        "memory_backend",
        "kg_recall_count",
        "status",
        "invalid_reasons",
        "calls",
    }
)
CALL_KEYS = frozenset(
    {
        "call_index",
        "schema_version",
        "plan_sha256",
        "variants_sha256",
        "intent",
        "stage",
        "variant_index",
        "variant_count",
        "variant_kind",
        "query",
        "seen_node_count",
        "seen_state_verified",
        "ledger_scope",
        "new_hit_count",
        "repeated_hit_count",
    }
)
PLAN_KEYS = frozenset(
    {"schema_version", "intent", "stage", "variants", "variant_index", "seen_node_ids"}
)
RECEIPT_KEYS = frozenset(
    {
        "schema_version",
        "plan_sha256",
        "intent",
        "stage",
        "variant_index",
        "variant_count",
        "variant_kind",
        "seen_node_count",
        "seen_state_verified",
        "ledger_scope",
        "new_hit_count",
        "repeated_hit_count",
    }
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _object(value: Any, where: str, keys: Sequence[str] | frozenset[str]) -> Mapping[str, Any]:
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


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected a non-empty string")
    return value


def _integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def _hash(value: Any, where: str) -> str:
    result = _string(value, where)
    if HEX64.fullmatch(result) is None:
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _hash_field(digest: Any, value: str) -> None:
    encoded = value.encode("utf-8")
    digest.update(f"{len(encoded)}:".encode("ascii"))
    digest.update(encoded)


def _canonical_type(raw: Any, where: str) -> str:
    value = _string(raw, where).strip()
    folded = value.casefold()
    if folded in {"observation", "decision", "user_preference", "module", "bug"}:
        return folded
    if (
        len(value.encode("utf-8")) > 64
        or value in {"schema_scope", "project", "concept"}
        or re.fullmatch(r"[A-Za-z0-9_\-:.]+", value) is None
    ):
        _fail(where, "invalid TinyKG type filter")
    return value


def _plan_fingerprint(
    intent: str,
    stage: str,
    variants: Sequence[Mapping[str, str]],
    type_filter: str | None,
) -> str:
    digest = hashlib.sha256()
    for value in (LEXICAL_PLAN_SCHEMA_VERSION, intent, stage, type_filter or ""):
        _hash_field(digest, value)
    for variant in variants:
        _hash_field(digest, variant["kind"])
        _hash_field(digest, variant["text"])
    return digest.hexdigest()


def _parse_plan(tool_input: Mapping[str, Any], where: str) -> Mapping[str, Any]:
    query = _string(tool_input.get("query"), f"{where}.query").strip()
    raw_plan = tool_input.get("lexical_plan")
    plan = _object(raw_plan, f"{where}.lexical_plan", PLAN_KEYS)
    if plan["schema_version"] != LEXICAL_PLAN_SCHEMA_VERSION:
        _fail(f"{where}.lexical_plan.schema_version", "unsupported schema")
    intent = _string(plan["intent"], f"{where}.lexical_plan.intent")
    if intent not in INTENTS:
        _fail(f"{where}.lexical_plan.intent", "unsupported intent")
    stage = _string(plan["stage"], f"{where}.lexical_plan.stage")
    if stage not in STAGES:
        _fail(f"{where}.lexical_plan.stage", "unsupported stage")
    raw_variants = plan["variants"]
    if not isinstance(raw_variants, list) or not 1 <= len(raw_variants) <= 4:
        _fail(f"{where}.lexical_plan.variants", "expected 1-4 variants")
    variants: List[Mapping[str, str]] = []
    seen_text: set[str] = set()
    for index, raw_variant in enumerate(raw_variants):
        variant = _object(
            raw_variant,
            f"{where}.lexical_plan.variants[{index}]",
            ("kind", "text"),
        )
        kind = _string(variant["kind"], f"{where}.lexical_plan.variants[{index}].kind")
        text = _string(variant["text"], f"{where}.lexical_plan.variants[{index}].text").strip()
        if kind not in VARIANT_KINDS:
            _fail(f"{where}.lexical_plan.variants[{index}].kind", "unsupported kind")
        if len(text.encode("utf-8")) > 400 or any(ord(char) < 0x20 or ord(char) == 0x7F for char in text):
            _fail(f"{where}.lexical_plan.variants[{index}].text", "invalid compact query")
        if text in seen_text:
            _fail(f"{where}.lexical_plan.variants", "duplicate variant text")
        seen_text.add(text)
        variants.append({"kind": kind, "text": text})
    variant_index = _integer(
        plan["variant_index"],
        f"{where}.lexical_plan.variant_index",
    )
    if variant_index >= len(variants):
        _fail(f"{where}.lexical_plan.variant_index", "outside variants")
    if query != variants[variant_index]["text"]:
        _fail(where, "query does not match the selected variant")
    if stage == "seed" and (
        len(variants) != 1
        or variant_index != 0
        or variants[0]["kind"] not in {"exact", "alias"}
        or "type" in tool_input
    ):
        _fail(f"{where}.lexical_plan", "invalid seed shape")
    if stage == "semantic_expansion" and (
        len(variants) < 2 or any(variant["kind"] == "exact" for variant in variants)
    ):
        _fail(f"{where}.lexical_plan", "invalid semantic expansion shape")
    raw_seen = plan["seen_node_ids"]
    if not isinstance(raw_seen, list) or len(raw_seen) > 32:
        _fail(f"{where}.lexical_plan.seen_node_ids", "expected at most 32 ids")
    seen_ids: List[int] = []
    for index, raw_id in enumerate(raw_seen):
        node_id = _integer(raw_id, f"{where}.lexical_plan.seen_node_ids[{index}]", minimum=1)
        if node_id in seen_ids:
            _fail(f"{where}.lexical_plan.seen_node_ids", "duplicate node id")
        seen_ids.append(node_id)
    type_filter = (
        _canonical_type(tool_input["type"], f"{where}.type")
        if "type" in tool_input
        else None
    )
    return {
        "query": query,
        "intent": intent,
        "stage": stage,
        "variants": variants,
        "variant_index": variant_index,
        "seen_node_ids": seen_ids,
        "type_filter": type_filter,
        "plan_sha256": _plan_fingerprint(intent, stage, variants, type_filter),
        "variants_sha256": hashlib.sha256(stable_json(variants).encode("utf-8")).hexdigest(),
    }


def _parse_receipt(raw_result: str, parsed_plan: Mapping[str, Any], where: str) -> Mapping[str, Any]:
    try:
        result = json.loads(raw_result)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{where}: KgRecall result is not JSON: {exc}") from exc
    if not isinstance(result, dict):
        _fail(where, "KgRecall result is not an object")
    receipt = _object(result.get("lexical_query_plan"), f"{where}.lexical_query_plan", RECEIPT_KEYS)
    expected = {
        "schema_version": LEXICAL_PLAN_SCHEMA_VERSION,
        "plan_sha256": parsed_plan["plan_sha256"],
        "intent": parsed_plan["intent"],
        "stage": parsed_plan["stage"],
        "variant_index": parsed_plan["variant_index"],
        "variant_count": len(parsed_plan["variants"]),
        "variant_kind": parsed_plan["variants"][parsed_plan["variant_index"]]["kind"],
        "seen_node_count": len(parsed_plan["seen_node_ids"]),
        "seen_state_verified": True,
        "ledger_scope": "agent_run_plan",
    }
    for key, expected_value in expected.items():
        if receipt[key] != expected_value:
            _fail(f"{where}.lexical_query_plan.{key}", "does not match the tool input")
    _hash(receipt["plan_sha256"], f"{where}.lexical_query_plan.plan_sha256")
    new_count = _integer(
        receipt["new_hit_count"],
        f"{where}.lexical_query_plan.new_hit_count",
    )
    repeated_count = _integer(
        receipt["repeated_hit_count"],
        f"{where}.lexical_query_plan.repeated_hit_count",
    )
    hits = result.get("hits")
    if not isinstance(hits, list):
        _fail(f"{where}.hits", "expected an array")
    distinct_hits: List[int] = []
    observed_new = 0
    observed_repeated = 0
    declared_seen = set(parsed_plan["seen_node_ids"])
    for index, raw_hit in enumerate(hits):
        if not isinstance(raw_hit, dict):
            _fail(f"{where}.hits[{index}]", "expected an object")
        node_id = _integer(raw_hit.get("node_id"), f"{where}.hits[{index}].node_id", minimum=1)
        expected_seen = node_id in declared_seen
        if raw_hit.get("seen_before") is not expected_seen:
            _fail(f"{where}.hits[{index}].seen_before", "does not match declared seen state")
        if node_id in distinct_hits:
            continue
        distinct_hits.append(node_id)
        if expected_seen:
            observed_repeated += 1
        else:
            observed_new += 1
    if (new_count, repeated_count) != (observed_new, observed_repeated):
        _fail(where, "host gain counts do not match distinct returned hits")
    return {
        "new_hit_count": new_count,
        "repeated_hit_count": repeated_count,
        "hit_node_ids": distinct_hits,
    }


def _cassette_tools(root: Path, where: str) -> Sequence[Tuple[str, str, Mapping[str, Any], str, bool]]:
    request_paths = sorted(root.glob("req-*.json"))
    if not request_paths:
        _fail(where, "provider cassette has no request artifacts")
    numbers: List[int] = []
    definitions: MutableMapping[str, Tuple[str, str, Mapping[str, Any]]] = {}
    results: MutableMapping[str, Tuple[str, bool]] = {}
    order: List[str] = []
    for request_path in request_paths:
        match = re.fullmatch(r"req-([0-9]+)\.json", request_path.name)
        if match is None:
            _fail(where, f"malformed request artifact {request_path.name!r}")
        numbers.append(int(match.group(1)))
        try:
            body = json.loads(request_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ValidationError(f"{where}.{request_path.name}: cannot read unique JSON: {exc}") from exc
        if not isinstance(body, dict) or not isinstance(body.get("messages"), list):
            _fail(f"{where}.{request_path.name}", "messages must be an array")
        for message in body["messages"]:
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "tool_use":
                    tool_id = item.get("id")
                    name = item.get("name")
                    tool_input = item.get("input")
                    if not isinstance(tool_id, str) or not tool_id:
                        _fail(where, "tool_use has no stable id")
                    if not isinstance(name, str) or not isinstance(tool_input, dict):
                        _fail(where, f"tool_use {tool_id!r} is malformed")
                    signature = (name, stable_json(tool_input))
                    prior = definitions.get(tool_id)
                    if prior is not None and prior[:2] != signature:
                        _fail(where, f"tool id {tool_id!r} changed semantics across requests")
                    if prior is None:
                        order.append(tool_id)
                        definitions[tool_id] = (name, signature[1], tool_input)
                elif item.get("type") == "tool_result":
                    tool_id = item.get("tool_use_id")
                    content_value = item.get("content")
                    if isinstance(tool_id, str) and isinstance(content_value, str):
                        observed = (content_value, item.get("is_error") is True)
                        prior_result = results.get(tool_id)
                        if prior_result is not None and prior_result != observed:
                            _fail(where, f"tool result {tool_id!r} changed across requests")
                        results[tool_id] = observed
    if numbers != list(range(1, len(request_paths) + 1)):
        _fail(where, "provider request sequence is not contiguous from one")
    completed: List[Tuple[str, str, Mapping[str, Any], str, bool]] = []
    for tool_id in order:
        name, _raw_input, tool_input = definitions[tool_id]
        result = results.get(tool_id)
        if result is not None:
            completed.append((tool_id, name, tool_input, result[0], result[1]))
        elif name == "KgRecall":
            completed.append((tool_id, name, tool_input, "", True))
    return completed


def build_query_plan_trace(
    cassette: Path,
    *,
    run_id: str,
    arm: str,
    memory_backend: str,
    where: str = "memory query-plan trace",
) -> Dict[str, Any]:
    """Derive a trace from raw requests without trusting an existing sidecar."""

    _string(run_id, f"{where}.run_id")
    _string(arm, f"{where}.arm")
    _string(memory_backend, f"{where}.memory_backend")
    recall_tools = [item for item in _cassette_tools(cassette, where) if item[1] == "KgRecall"]
    if memory_backend not in TINYKG_BACKENDS:
        status = "not_applicable" if not recall_tools else "invalid"
        reasons = [] if not recall_tools else ["non_tinykg_backend_executed_kg_recall"]
        return {
            "schema_version": TRACE_SCHEMA_VERSION,
            "run_id": run_id,
            "arm": arm,
            "memory_backend": memory_backend,
            "kg_recall_count": len(recall_tools),
            "status": status,
            "invalid_reasons": reasons,
            "calls": [],
        }

    reasons: List[str] = []
    calls: List[Mapping[str, Any]] = []
    plan_seen: MutableMapping[str, set[int]] = defaultdict(set)
    declared_seed_plans: set[str] = set()
    for call_index, (_tool_id, _name, tool_input, raw_result, is_error) in enumerate(recall_tools):
        # Invalid reasons are persisted evidence. Keep them independent from
        # caller diagnostics and model-controlled ids so later replay is
        # byte-stable and bounded.
        call_where = f"KgRecall[{call_index}]"
        try:
            parsed_plan = _parse_plan(tool_input, call_where)
            plan_sha = str(parsed_plan["plan_sha256"])
            if parsed_plan["stage"] == "seed":
                declared_seed_plans.add(plan_sha)
            if is_error:
                reasons.append(
                    f"call {call_index}: KgRecall has no successful observable result"
                )
                continue
            expected_seen = plan_seen[plan_sha]
            if set(parsed_plan["seen_node_ids"]) != expected_seen:
                _fail(call_where, "declared seen ids do not match prior hits for this plan")
            receipt = _parse_receipt(raw_result, parsed_plan, call_where)
            expected_seen.update(receipt["hit_node_ids"])
            calls.append(
                {
                    "call_index": call_index,
                    "schema_version": LEXICAL_PLAN_SCHEMA_VERSION,
                    "plan_sha256": plan_sha,
                    "variants_sha256": parsed_plan["variants_sha256"],
                    "intent": parsed_plan["intent"],
                    "stage": parsed_plan["stage"],
                    "variant_index": parsed_plan["variant_index"],
                    "variant_count": len(parsed_plan["variants"]),
                    "variant_kind": parsed_plan["variants"][parsed_plan["variant_index"]]["kind"],
                    "query": parsed_plan["query"],
                    "seen_node_count": len(parsed_plan["seen_node_ids"]),
                    "seen_state_verified": True,
                    "ledger_scope": "agent_run_plan",
                    "new_hit_count": receipt["new_hit_count"],
                    "repeated_hit_count": receipt["repeated_hit_count"],
                }
            )
        except ValidationError as exc:
            reasons.append(f"call {call_index}: {exc}")
    if len(declared_seed_plans) > 1:
        reasons.append(MULTIPLE_DISTINCT_SEED_PLANS_REASON)
    if not recall_tools:
        reasons.append("TinyKG backend executed no KgRecall")
    status = "verified" if not reasons and len(calls) == len(recall_tools) else "invalid"
    return {
        "schema_version": TRACE_SCHEMA_VERSION,
        "run_id": run_id,
        "arm": arm,
        "memory_backend": memory_backend,
        "kg_recall_count": len(recall_tools),
        "status": status,
        "invalid_reasons": reasons,
        "calls": calls,
    }


def project_query_variants(
    trace: Mapping[str, Any],
    *,
    limit: int = MAX_OBSERVATION_QUERY_VARIANTS,
) -> List[Mapping[str, str]]:
    """Project a bounded audit view without relabeling protocol violations.

    The complete call sequence remains in ``query-plan.json``.  Observation
    rows intentionally carry at most the result protocol's five variants.
    Multiple distinct seed plans therefore remain multiple ``exact`` entries;
    the caller must pair that shape with an evaluator-invalid verdict rather
    than laundering later seeds into semantic expansions.
    """

    validate_query_plan_trace(trace)
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
        _fail("memory query-plan projection limit", "expected an integer >= 1")
    projected: List[Mapping[str, str]] = []
    seen_text: set[str] = set()
    for call in trace["calls"]:
        text = str(call["query"])
        normalized = " ".join(text.casefold().split())
        if not normalized or normalized in seen_text:
            continue
        seen_text.add(normalized)
        projected.append(
            {
                "kind": "exact" if call["stage"] == "seed" else "semantic",
                "text": text,
            }
        )
        if len(projected) == limit:
            break
    return projected


def validate_query_plan_trace(trace: Mapping[str, Any], where: str = "query-plan sidecar") -> None:
    value = _object(trace, where, TRACE_KEYS)
    if value["schema_version"] != TRACE_SCHEMA_VERSION:
        _fail(f"{where}.schema_version", "unsupported trace schema")
    _string(value["run_id"], f"{where}.run_id")
    _string(value["arm"], f"{where}.arm")
    backend = _string(value["memory_backend"], f"{where}.memory_backend")
    recall_count = _integer(value["kg_recall_count"], f"{where}.kg_recall_count")
    status = _string(value["status"], f"{where}.status")
    if status not in {"verified", "invalid", "not_applicable"}:
        _fail(f"{where}.status", "unsupported status")
    reasons = value["invalid_reasons"]
    if not isinstance(reasons, list) or any(not isinstance(reason, str) or not reason for reason in reasons):
        _fail(f"{where}.invalid_reasons", "expected non-empty strings")
    calls = value["calls"]
    if not isinstance(calls, list):
        _fail(f"{where}.calls", "expected an array")
    prior_index = -1
    for index, raw_call in enumerate(calls):
        call = _object(raw_call, f"{where}.calls[{index}]", CALL_KEYS)
        call_index = _integer(call["call_index"], f"{where}.calls[{index}].call_index")
        if call_index <= prior_index:
            _fail(f"{where}.calls[{index}].call_index", "must be strictly increasing")
        prior_index = call_index
        if call["schema_version"] != LEXICAL_PLAN_SCHEMA_VERSION:
            _fail(f"{where}.calls[{index}].schema_version", "unsupported plan schema")
        _hash(call["plan_sha256"], f"{where}.calls[{index}].plan_sha256")
        _hash(call["variants_sha256"], f"{where}.calls[{index}].variants_sha256")
        if call["intent"] not in INTENTS or call["stage"] not in STAGES:
            _fail(f"{where}.calls[{index}]", "unsupported intent or stage")
        if call["variant_kind"] not in VARIANT_KINDS:
            _fail(f"{where}.calls[{index}].variant_kind", "unsupported kind")
        variant_count = _integer(call["variant_count"], f"{where}.calls[{index}].variant_count", minimum=1)
        variant_index = _integer(call["variant_index"], f"{where}.calls[{index}].variant_index")
        if variant_count > 4 or variant_index >= variant_count:
            _fail(f"{where}.calls[{index}]", "invalid variant bounds")
        _string(call["query"], f"{where}.calls[{index}].query")
        for key in ("seen_node_count", "new_hit_count", "repeated_hit_count"):
            _integer(call[key], f"{where}.calls[{index}].{key}")
        if call["seen_state_verified"] is not True or call["ledger_scope"] != "agent_run_plan":
            _fail(f"{where}.calls[{index}]", "host verification claim is absent")
    distinct_seed_plans = {
        str(call["plan_sha256"])
        for call in calls
        if call["stage"] == "seed"
    }
    if len(distinct_seed_plans) > 1:
        if status == "verified":
            _fail(where, "verified trace contains multiple distinct seed plans")
        if MULTIPLE_DISTINCT_SEED_PLANS_REASON not in reasons:
            _fail(where, "multiple seed plans are missing their invalid reason")
    if status == "verified" and (
        backend not in TINYKG_BACKENDS
        or reasons
        or recall_count != len(calls)
        or not calls
    ):
        _fail(where, "verified trace has contradictory coverage")
    if status == "not_applicable" and (backend in TINYKG_BACKENDS or reasons or recall_count or calls):
        _fail(where, "not_applicable trace has contradictory activity")
    if status == "invalid" and not reasons:
        _fail(where, "invalid trace must explain why")


def load_and_verify_query_plan_sidecar(
    cassette: Path,
    *,
    run_id: str,
    arm: str,
    memory_backend: str,
    required: bool,
    where: str,
) -> Mapping[str, Any] | None:
    path = cassette / SIDECAR_NAME
    if not path.exists():
        if required:
            _fail(where, f"required {SIDECAR_NAME} is missing")
        return None
    if not path.is_file() or path.is_symlink():
        _fail(where, f"{SIDECAR_NAME} must be a regular file")
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"{where}: cannot read {SIDECAR_NAME}: {exc}") from exc
    if stable_json(value).encode("utf-8") + b"\n" != raw:
        _fail(where, f"{SIDECAR_NAME} is not canonical JSON with one trailing newline")
    validate_query_plan_trace(value, where)
    recomputed = build_query_plan_trace(
        cassette,
        run_id=run_id,
        arm=arm,
        memory_backend=memory_backend,
        where=f"{where}.recomputed",
    )
    if stable_json(value) != stable_json(recomputed):
        _fail(where, f"{SIDECAR_NAME} does not match raw provider requests")
    return value


def summarize_query_plan_traces(
    traces: Sequence[Mapping[str, Any] | None],
    *,
    host_recall_satisfied: Sequence[bool] | None = None,
) -> Dict[str, Any]:
    """Summarize explicit plans without erasing host-scoped recall.

    Query-plan sidecars deliberately describe only model-issued ``KgRecall``
    calls.  A production runtime may already have completed and committed a
    host-scoped lookup before the model starts.  The caller may provide that
    independently verified fact here; it only reclassifies the exact
    no-explicit-call gap and can never launder a malformed explicit plan.
    """

    if host_recall_satisfied is None:
        host_recall_satisfied = [False] * len(traces)
    if len(host_recall_satisfied) != len(traces):
        _fail("memory query-plan summary", "host recall status length mismatch")
    status_counts = {
        key: 0
        for key in (
            "explicit_plan_verified",
            "host_recall_satisfied",
            "invalid",
            "not_applicable",
            "legacy_unavailable",
        )
    }
    calls: List[Mapping[str, Any]] = []
    plans: set[Tuple[str, str]] = set()
    rollout_rows: List[Mapping[str, Any]] = []
    for trace, host_satisfied in zip(traces, host_recall_satisfied):
        if trace is None:
            if host_satisfied:
                _fail("memory query-plan summary", "legacy trace cannot claim host recall")
            status_counts["legacy_unavailable"] += 1
            rollout_rows.append({"status": "legacy_unavailable"})
            continue
        validate_query_plan_trace(trace)
        trace_status = str(trace["status"])
        if host_satisfied and trace["memory_backend"] not in TINYKG_BACKENDS:
            _fail(
                "memory query-plan summary",
                "non-TinyKG trace cannot claim host recall",
            )
        if trace_status == "verified":
            status = "explicit_plan_verified"
        elif (
            trace_status == "invalid"
            and host_satisfied
            and trace["invalid_reasons"] == ["TinyKG backend executed no KgRecall"]
        ):
            status = "host_recall_satisfied"
        else:
            status = trace_status
        status_counts[status] += 1
        rollout_rows.append(
            {
                "run_id": trace["run_id"],
                "arm": trace["arm"],
                "memory_backend": trace["memory_backend"],
                "status": status,
                "trace_status": trace_status,
                "host_recall_satisfied": host_satisfied,
                "kg_recall_count": trace["kg_recall_count"],
                "invalid_reasons": trace["invalid_reasons"],
            }
        )
        if status != "explicit_plan_verified":
            continue
        for call in trace["calls"]:
            calls.append(call)
            plans.add((str(trace["run_id"]), str(call["plan_sha256"])))
    new_total = sum(int(call["new_hit_count"]) for call in calls)
    repeated_total = sum(int(call["repeated_hit_count"]) for call in calls)

    def grouped(key: str) -> Mapping[str, Mapping[str, float | int | None]]:
        buckets: MutableMapping[str, List[Mapping[str, Any]]] = defaultdict(list)
        for call in calls:
            buckets[str(call[key])].append(call)
        result: Dict[str, Mapping[str, float | int | None]] = {}
        for name, bucket in sorted(buckets.items()):
            fresh = sum(int(call["new_hit_count"]) for call in bucket)
            repeated = sum(int(call["repeated_hit_count"]) for call in bucket)
            result[name] = {
                "calls": len(bucket),
                "new_hits": fresh,
                "repeated_hits": repeated,
                "new_hits_per_call": fresh / len(bucket),
            }
        return result

    verified_call_counts = [
        int(trace["kg_recall_count"])
        for trace in traces
        if trace is not None and trace["status"] == "verified"
    ]
    denominator = new_total + repeated_total
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "rollouts": len(traces),
        "status_counts": status_counts,
        "explicit_verified_calls": len(calls),
        "explicit_verified_plans": len(plans),
        "new_hit_count": new_total,
        "repeated_hit_count": repeated_total,
        "unique_gain_ratio": new_total / denominator if denominator else None,
        "mean_calls_before_stopping": (
            sum(verified_call_counts) / len(verified_call_counts)
            if verified_call_counts
            else None
        ),
        "by_stage": grouped("stage"),
        "by_variant_kind": grouped("variant_kind"),
        "rollout_status": rollout_rows,
    }


def render_query_plan_markdown(summary: Mapping[str, Any], title: str) -> str:
    def number(value: Any, digits: int = 3) -> str:
        if value is None:
            return "-"
        if isinstance(value, int):
            return str(value)
        if isinstance(value, float) and math.isfinite(value):
            return f"{value:.{digits}f}"
        return "-"

    lines = [
        f"# {title}",
        "",
        f"Schema: `{summary['schema_version']}`",
        f"Rollouts: {summary['rollouts']}",
        "",
        "## Governed retrieval",
        "",
        f"- Explicit verified calls: {summary['explicit_verified_calls']}",
        f"- Explicit verified plans: {summary['explicit_verified_plans']}",
        f"- New/repeated hits: {summary['new_hit_count']} / {summary['repeated_hit_count']}",
        f"- Unique gain ratio: {number(summary['unique_gain_ratio'])}",
        f"- Mean calls before stopping: {number(summary['mean_calls_before_stopping'])}",
        "",
        "## Status",
        "",
        "```json",
        json.dumps(summary["status_counts"], ensure_ascii=False, indent=2, sort_keys=True),
        "```",
        "",
        "## Stage and typed-variant diagnostics",
        "",
        "```json",
        json.dumps(
            {"by_stage": summary["by_stage"], "by_variant_kind": summary["by_variant_kind"]},
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ),
        "```",
        "",
    ]
    return "\n".join(lines)
