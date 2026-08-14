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


TRACE_SCHEMA_VERSION = "metacodes-memory-query-plan-trace-v2"
LEGACY_TRACE_SCHEMA_VERSION = "metacodes-memory-query-plan-trace-v1"
TRACE_SCHEMA_VERSIONS = frozenset({TRACE_SCHEMA_VERSION, LEGACY_TRACE_SCHEMA_VERSION})
REPORT_SCHEMA_VERSION = "metacodes-memory-query-plan-report-v4"
LEXICAL_PLAN_SCHEMA_VERSION = "lexical-query-plan-v2"
BATCH_LEXICAL_PLAN_SCHEMA_VERSION = "lexical-query-plan-v3"
AUTO_CONTEXT_SCHEMA_VERSION = "metacodes-auto-context-v1"
AUTO_CONTEXT_SELECTION_POLICY = "first_new_evidence_then_new_then_merged_v1"
BOUNDED_RECALL_SCHEMA_VERSION = "metacodes-bounded-recall-v1"
BOUNDED_RECALL_MAX_RESULT_BYTES = 24 * 1024
BOUNDED_RECALL_EXCERPT_POLICY = "utf8_head_tail_v1"
LEGACY_LEXICAL_PLAN_SCHEMA_VERSION = "lexical-query-plan-v1"
LEXICAL_PLAN_SCHEMA_VERSIONS = frozenset(
    {
        BATCH_LEXICAL_PLAN_SCHEMA_VERSION,
        LEXICAL_PLAN_SCHEMA_VERSION,
        LEGACY_LEXICAL_PLAN_SCHEMA_VERSION,
    }
)
SIDECAR_NAME = "query-plan.json"
QUERY_PLAN_INVALID_PREFIX = "query-plan trace invalid: "
MULTIPLE_DISTINCT_SEED_PLANS_REASON = "multiple distinct seed plans in one run"
V2_SEMANTIC_EXPANSION_BUDGET_REASON = (
    "more than four host-executed semantic expansion probes in one run"
)
MAX_V2_SEMANTIC_EXPANSION_CALLS = 4
PRE_SEARCH_REJECTION_REASON = re.compile(
    r"^call (?P<call_index>[0-9]+): host rejected lexical plan before search "
    r"\((?:parser|ledger)\)(?:: .+)?$"
)
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
        "synonym",
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
CALL_V2_KEYS = frozenset(
    {
        "call_index",
        "schema_version",
        "plan_sha256",
        "variants_sha256",
        "intent",
        "stage",
        "execution",
        "variant_count",
        "seen_node_count",
        "seen_state_verified",
        "ledger_scope",
        "new_hit_count",
        "repeated_hit_count",
        "probes",
    }
)
PROBE_KEYS = frozenset(
    {
        "variant_index",
        "variant_kind",
        "query",
        "new_hit_count",
        "repeated_hit_count",
        "hit_node_ids",
    }
)
LEGACY_PLAN_KEYS = frozenset(
    {"schema_version", "intent", "stage", "variants", "variant_index", "seen_node_ids"}
)
PLAN_KEYS = frozenset(
    {"schema_version", "intent", "stage", "variants", "variant_index"}
)
BATCH_PLAN_KEYS = frozenset({"schema_version", "intent", "stage", "variants"})
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
BATCH_RECEIPT_KEYS = frozenset(
    {
        "schema_version",
        "plan_sha256",
        "intent",
        "stage",
        "variant_count",
        "executed_variant_count",
        "all_variants_executed",
        "seen_node_count",
        "seen_state_verified",
        "ledger_scope",
        "merged_hit_count",
        "merged_new_hit_count",
        "merged_previously_seen_count",
        "probe_new_hit_count",
        "probe_repeated_hit_count",
        "variant_receipts",
        "execution",
    }
)
BATCH_RECEIPT_ANCHOR_KEYS = frozenset(
    {
        "query_anchor_rewritten",
        "query_anchor_input_sha256",
        "query_anchor_effective_sha256",
    }
)
BATCH_VARIANT_RECEIPT_KEYS = frozenset(
    {"variant_index", "variant_kind", "node_ids", "new_hit_count", "repeated_hit_count"}
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
    *,
    schema_version: str,
) -> str:
    digest = hashlib.sha256()
    for value in (schema_version, intent, stage, type_filter or ""):
        _hash_field(digest, value)
    for variant in variants:
        _hash_field(digest, variant["kind"])
        _hash_field(digest, variant["text"])
    return digest.hexdigest()


def _parse_plan(tool_input: Mapping[str, Any], where: str) -> Mapping[str, Any]:
    # Match the native Zig protocol exactly.  Python's parameterless strip()
    # removes additional Unicode whitespace that the host intentionally keeps
    # as query content, which would make receipt hashes non-replayable.
    query = _string(tool_input.get("query"), f"{where}.query").strip(" \t\r\n")
    if (
        not query
        or len(query.encode("utf-8")) > 400
        or any(ord(char) < 0x20 or ord(char) == 0x7F for char in query)
    ):
        _fail(f"{where}.query", "invalid compact query")
    raw_plan = tool_input.get("lexical_plan")
    if not isinstance(raw_plan, dict):
        _fail(f"{where}.lexical_plan", "expected an object")
    schema_version = raw_plan.get("schema_version")
    if schema_version not in LEXICAL_PLAN_SCHEMA_VERSIONS:
        _fail(f"{where}.lexical_plan.schema_version", "unsupported schema")
    plan = _object(
        raw_plan,
        f"{where}.lexical_plan",
        (
            LEGACY_PLAN_KEYS
            if schema_version == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
            else BATCH_PLAN_KEYS
            if schema_version == BATCH_LEXICAL_PLAN_SCHEMA_VERSION
            else PLAN_KEYS
        ),
    )
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
        text = _string(
            variant["text"], f"{where}.lexical_plan.variants[{index}].text"
        ).strip(" \t\r\n")
        if kind not in VARIANT_KINDS or (
            schema_version == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
            and kind == "synonym"
        ):
            _fail(f"{where}.lexical_plan.variants[{index}].kind", "unsupported kind")
        if (
            not text
            or len(text.encode("utf-8")) > 400
            or any(ord(char) < 0x20 or ord(char) == 0x7F for char in text)
        ):
            _fail(f"{where}.lexical_plan.variants[{index}].text", "invalid compact query")
        if text in seen_text:
            _fail(f"{where}.lexical_plan.variants", "duplicate variant text")
        seen_text.add(text)
        variants.append({"kind": kind, "text": text})
    batch_all = schema_version == BATCH_LEXICAL_PLAN_SCHEMA_VERSION
    variant_index = (
        None
        if batch_all
        else _integer(
            plan["variant_index"],
            f"{where}.lexical_plan.variant_index",
        )
    )
    if variant_index is not None and variant_index >= len(variants):
        _fail(f"{where}.lexical_plan.variant_index", "outside variants")
    query_index = 0 if variant_index is None else variant_index
    query_anchor_rewritten = query != variants[query_index]["text"]
    if query_anchor_rewritten and schema_version != BATCH_LEXICAL_PLAN_SCHEMA_VERSION:
        _fail(where, "query does not match the selected variant")
    if stage == "seed" and (
        len(variants) != 1
        or query_index != 0
        or variants[0]["kind"] not in {"exact", "alias"}
        or "type" in tool_input
    ):
        _fail(f"{where}.lexical_plan", "invalid seed shape")
    if stage == "semantic_expansion" and (
        (
            schema_version
            in {
                LEGACY_LEXICAL_PLAN_SCHEMA_VERSION,
                BATCH_LEXICAL_PLAN_SCHEMA_VERSION,
            }
            and len(variants) < 2
        )
        or any(variant["kind"] == "exact" for variant in variants)
    ):
        _fail(f"{where}.lexical_plan", "invalid semantic expansion shape")
    if batch_all and stage == "focused_refinement" and len(variants) != 1:
        _fail(f"{where}.lexical_plan", "invalid focused refinement shape")
    seen_ids: List[int] | None = None
    if schema_version == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION:
        raw_seen = plan["seen_node_ids"]
        if not isinstance(raw_seen, list) or len(raw_seen) > 32:
            _fail(f"{where}.lexical_plan.seen_node_ids", "expected at most 32 ids")
        seen_ids = []
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
        "schema_version": schema_version,
        "intent": intent,
        "stage": stage,
        "variants": variants,
        "variant_index": variant_index,
        "execution": "host_batch_all" if batch_all else "single",
        "seen_node_ids": seen_ids,
        "type_filter": type_filter,
        "query_anchor_rewritten": query_anchor_rewritten,
        "query_anchor_input_sha256": hashlib.sha256(query.encode("utf-8")).hexdigest(),
        "query_anchor_effective_sha256": hashlib.sha256(
            variants[query_index]["text"].encode("utf-8")
        ).hexdigest(),
        "plan_sha256": _plan_fingerprint(
            intent,
            stage,
            variants,
            type_filter,
            schema_version=schema_version,
        ),
        "variants_sha256": hashlib.sha256(stable_json(variants).encode("utf-8")).hexdigest(),
    }


def _parse_batch_receipt(
    result: Mapping[str, Any],
    parsed_plan: Mapping[str, Any],
    expected_seen: set[int],
    where: str,
    raw_result: str,
) -> Mapping[str, Any]:
    raw_receipt = result.get("lexical_query_plan")
    if not isinstance(raw_receipt, dict):
        _fail(f"{where}.lexical_query_plan", "expected an object")
    present_anchor_keys = set(raw_receipt) & BATCH_RECEIPT_ANCHOR_KEYS
    if present_anchor_keys and present_anchor_keys != BATCH_RECEIPT_ANCHOR_KEYS:
        _fail(
            f"{where}.lexical_query_plan",
            "query-anchor audit fields must be complete",
        )
    receipt_keys = (
        BATCH_RECEIPT_KEYS | BATCH_RECEIPT_ANCHOR_KEYS
        if present_anchor_keys
        else BATCH_RECEIPT_KEYS
    )
    receipt = _object(raw_receipt, f"{where}.lexical_query_plan", receipt_keys)
    if present_anchor_keys:
        expected_anchor = {
            "query_anchor_rewritten": parsed_plan["query_anchor_rewritten"],
            "query_anchor_input_sha256": parsed_plan["query_anchor_input_sha256"],
            "query_anchor_effective_sha256": parsed_plan[
                "query_anchor_effective_sha256"
            ],
        }
        for key, expected_value in expected_anchor.items():
            if receipt[key] != expected_value:
                _fail(
                    f"{where}.lexical_query_plan.{key}",
                    "does not match the observed compatibility anchor",
                )
        _hash(
            receipt["query_anchor_input_sha256"],
            f"{where}.lexical_query_plan.query_anchor_input_sha256",
        )
        _hash(
            receipt["query_anchor_effective_sha256"],
            f"{where}.lexical_query_plan.query_anchor_effective_sha256",
        )
    elif parsed_plan["query_anchor_rewritten"]:
        _fail(
            f"{where}.lexical_query_plan",
            "rewritten query anchor lacks a host audit receipt",
        )
    expected = {
        "schema_version": BATCH_LEXICAL_PLAN_SCHEMA_VERSION,
        "plan_sha256": parsed_plan["plan_sha256"],
        "intent": parsed_plan["intent"],
        "stage": parsed_plan["stage"],
        "variant_count": len(parsed_plan["variants"]),
        "executed_variant_count": len(parsed_plan["variants"]),
        "all_variants_executed": True,
        "seen_node_count": len(expected_seen),
        "seen_state_verified": True,
        "ledger_scope": "agent_run_batch",
        "execution": "host_batch_all",
    }
    for key, expected_value in expected.items():
        if receipt[key] != expected_value:
            _fail(f"{where}.lexical_query_plan.{key}", "does not match the batch input")
    _hash(receipt["plan_sha256"], f"{where}.lexical_query_plan.plan_sha256")

    raw_variant_receipts = receipt["variant_receipts"]
    if not isinstance(raw_variant_receipts, list) or len(raw_variant_receipts) != len(
        parsed_plan["variants"]
    ):
        _fail(f"{where}.lexical_query_plan.variant_receipts", "must cover every variant")
    probe_seen = set(expected_seen)
    ordered_merged: List[int] = []
    probes: List[Mapping[str, Any]] = []
    probe_new_total = 0
    probe_repeated_total = 0
    for variant_index, (raw_receipt, variant) in enumerate(
        zip(raw_variant_receipts, parsed_plan["variants"])
    ):
        variant_receipt = _object(
            raw_receipt,
            f"{where}.lexical_query_plan.variant_receipts[{variant_index}]",
            BATCH_VARIANT_RECEIPT_KEYS,
        )
        if variant_receipt["variant_index"] != variant_index:
            _fail(
                f"{where}.lexical_query_plan.variant_receipts[{variant_index}].variant_index",
                "does not preserve declared order",
            )
        if variant_receipt["variant_kind"] != variant["kind"]:
            _fail(
                f"{where}.lexical_query_plan.variant_receipts[{variant_index}].variant_kind",
                "does not match the declared variant",
            )
        raw_node_ids = variant_receipt["node_ids"]
        if not isinstance(raw_node_ids, list) or len(raw_node_ids) > 8:
            _fail(
                f"{where}.lexical_query_plan.variant_receipts[{variant_index}].node_ids",
                "expected at most eight node ids",
            )
        node_ids: List[int] = []
        observed_new = 0
        observed_repeated = 0
        for node_index, raw_node_id in enumerate(raw_node_ids):
            node_id = _integer(
                raw_node_id,
                f"{where}.lexical_query_plan.variant_receipts[{variant_index}].node_ids[{node_index}]",
                minimum=1,
            )
            if node_id in node_ids:
                _fail(
                    f"{where}.lexical_query_plan.variant_receipts[{variant_index}].node_ids",
                    "duplicate node id",
                )
            node_ids.append(node_id)
            if node_id in probe_seen:
                observed_repeated += 1
            else:
                observed_new += 1
                probe_seen.add(node_id)
            if node_id not in ordered_merged:
                ordered_merged.append(node_id)
        new_count = _integer(
            variant_receipt["new_hit_count"],
            f"{where}.lexical_query_plan.variant_receipts[{variant_index}].new_hit_count",
        )
        repeated_count = _integer(
            variant_receipt["repeated_hit_count"],
            f"{where}.lexical_query_plan.variant_receipts[{variant_index}].repeated_hit_count",
        )
        if (new_count, repeated_count) != (observed_new, observed_repeated):
            _fail(
                f"{where}.lexical_query_plan.variant_receipts[{variant_index}]",
                "gain counts do not match host node ids",
            )
        probe_new_total += new_count
        probe_repeated_total += repeated_count
        probes.append(
            {
                "variant_index": variant_index,
                "variant_kind": variant["kind"],
                "query": variant["text"],
                "new_hit_count": new_count,
                "repeated_hit_count": repeated_count,
                "hit_node_ids": node_ids,
            }
        )

    hits = result.get("hits")
    if not isinstance(hits, list):
        _fail(f"{where}.hits", "expected an array")
    merged_hit_ids: List[int] = []
    for index, raw_hit in enumerate(hits):
        if not isinstance(raw_hit, dict):
            _fail(f"{where}.hits[{index}]", "expected an object")
        node_id = _integer(raw_hit.get("node_id"), f"{where}.hits[{index}].node_id", minimum=1)
        if node_id in merged_hit_ids:
            _fail(f"{where}.hits", "batch merged result contains a duplicate node id")
        seen_before = node_id in expected_seen
        if raw_hit.get("seen_before") is not seen_before:
            _fail(f"{where}.hits[{index}].seen_before", "does not match pre-batch host state")
        if seen_before:
            if raw_hit.get("content_ref") != "exposed_elsewhere_in_run" or "text" in raw_hit:
                _fail(f"{where}.hits[{index}]", "previously exposed node is not a compact reference")
        elif not isinstance(raw_hit.get("text"), str):
            _fail(f"{where}.hits[{index}].text", "new node must expose its body")
        merged_hit_ids.append(node_id)
    if merged_hit_ids != ordered_merged:
        _fail(where, "merged hits do not match first-seen per-variant receipt order")

    raw_envelope = result.get("recall_envelope")
    if raw_envelope is not None:
        envelope = _object(
            raw_envelope,
            f"{where}.recall_envelope",
            frozenset(
                {
                    "schema_version",
                    "complete_json",
                    "max_result_bytes",
                    "text_excerpt_policy",
                }
            ),
        )
        expected_envelope = {
            "schema_version": BOUNDED_RECALL_SCHEMA_VERSION,
            "complete_json": True,
            "max_result_bytes": BOUNDED_RECALL_MAX_RESULT_BYTES,
            "text_excerpt_policy": BOUNDED_RECALL_EXCERPT_POLICY,
        }
        for key, expected_value in expected_envelope.items():
            if envelope[key] != expected_value:
                _fail(f"{where}.recall_envelope.{key}", "unsupported bounded-recall contract")
        if len(raw_result.encode("utf-8")) > BOUNDED_RECALL_MAX_RESULT_BYTES:
            _fail(where, "bounded KgRecall result exceeds its declared byte cap")
        for index, raw_hit in enumerate(hits):
            if raw_hit.get("seen_before") is True:
                continue
            text = raw_hit.get("text")
            returned = _integer(
                raw_hit.get("text_returned_bytes"),
                f"{where}.hits[{index}].text_returned_bytes",
            )
            total = _integer(
                raw_hit.get("text_total_bytes"),
                f"{where}.hits[{index}].text_total_bytes",
            )
            truncated = raw_hit.get("text_truncated")
            policy = raw_hit.get("text_excerpt_policy")
            if (
                not isinstance(text, str)
                or returned != len(text.encode("utf-8"))
                or total < returned
                or not isinstance(truncated, bool)
                or truncated != (total > returned)
                or policy != BOUNDED_RECALL_EXCERPT_POLICY
            ):
                _fail(f"{where}.hits[{index}]", "invalid bounded text excerpt receipt")

    auto_context_node_id: int | None = None
    raw_auto_context = result.get("auto_context")
    if raw_auto_context is not None:
        auto_context = _object(
            raw_auto_context,
            f"{where}.auto_context",
            frozenset({"schema_version", "selection_policy", "context"}),
        )
        if auto_context["schema_version"] != AUTO_CONTEXT_SCHEMA_VERSION:
            _fail(f"{where}.auto_context.schema_version", "unsupported auto-context schema")
        if auto_context["selection_policy"] != AUTO_CONTEXT_SELECTION_POLICY:
            _fail(f"{where}.auto_context.selection_policy", "unsupported selection policy")
        if not (
            parsed_plan["intent"] == "enumeration"
            and parsed_plan["stage"] == "semantic_expansion"
            and ordered_merged
        ):
            _fail(where, "auto-context is only valid for a non-empty enumeration batch")
        context = auto_context["context"]
        if not isinstance(context, dict):
            _fail(f"{where}.auto_context.context", "expected an object")
        auto_context_node_id = _integer(
            context.get("node_id"),
            f"{where}.auto_context.context.node_id",
            minimum=1,
        )
        first_new_evidence = next(
            (
                _integer(hit.get("node_id"), f"{where}.hits.node_id", minimum=1)
                for hit in hits
                if hit.get("seen_before") is False and hit.get("type") == "evidence"
            ),
            None,
        )
        first_new = next(
            (
                _integer(hit.get("node_id"), f"{where}.hits.node_id", minimum=1)
                for hit in hits
                if hit.get("seen_before") is False
            ),
            None,
        )
        expected_context_node_id = first_new_evidence or first_new or ordered_merged[0]
        if auto_context_node_id != expected_context_node_id:
            _fail(f"{where}.auto_context.context.node_id", "does not match deterministic selection")
        graph = context.get("graph")
        governance = context.get("knowledge_governance")
        if not isinstance(graph, dict) or not isinstance(governance, dict):
            _fail(f"{where}.auto_context.context", "missing graph governance receipt")
        query = graph.get("query")
        if not isinstance(query, dict) or query.get("root_id") != auto_context_node_id:
            _fail(f"{where}.auto_context.context.graph", "root does not bind selected node")
        if governance.get("schema_version") != "metacodes-knowledge-governance-v1":
            _fail(f"{where}.auto_context.context.knowledge_governance", "unsupported governance receipt")

    merged_new = sum(node_id not in expected_seen for node_id in ordered_merged)
    merged_seen = len(ordered_merged) - merged_new
    summary_expected = {
        "merged_hit_count": len(ordered_merged),
        "merged_new_hit_count": merged_new,
        "merged_previously_seen_count": merged_seen,
        "probe_new_hit_count": probe_new_total,
        "probe_repeated_hit_count": probe_repeated_total,
    }
    for key, expected_value in summary_expected.items():
        if _integer(receipt[key], f"{where}.lexical_query_plan.{key}") != expected_value:
            _fail(f"{where}.lexical_query_plan.{key}", "does not match replayed batch")
    return {
        "seen_node_count": len(expected_seen),
        "ledger_scope": "agent_run_batch",
        "new_hit_count": probe_new_total,
        "repeated_hit_count": probe_repeated_total,
        "hit_node_ids": ordered_merged,
        "probes": probes,
        "auto_context_node_id": auto_context_node_id,
    }


def _parse_receipt(
    raw_result: str,
    parsed_plan: Mapping[str, Any],
    expected_seen: set[int],
    where: str,
) -> Mapping[str, Any]:
    try:
        result = json.loads(raw_result)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"{where}: KgRecall result is not JSON: {exc}") from exc
    if not isinstance(result, dict):
        _fail(where, "KgRecall result is not an object")
    if parsed_plan["schema_version"] == BATCH_LEXICAL_PLAN_SCHEMA_VERSION:
        return _parse_batch_receipt(result, parsed_plan, expected_seen, where, raw_result)
    receipt = _object(result.get("lexical_query_plan"), f"{where}.lexical_query_plan", RECEIPT_KEYS)
    expected = {
        "schema_version": parsed_plan["schema_version"],
        "plan_sha256": parsed_plan["plan_sha256"],
        "intent": parsed_plan["intent"],
        "stage": parsed_plan["stage"],
        "variant_index": parsed_plan["variant_index"],
        "variant_count": len(parsed_plan["variants"]),
        "variant_kind": parsed_plan["variants"][parsed_plan["variant_index"]]["kind"],
        "seen_node_count": len(expected_seen),
        "seen_state_verified": True,
        "ledger_scope": (
            "agent_run_plan"
            if parsed_plan["schema_version"] == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
            else "agent_run_explicit"
        ),
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
    for index, raw_hit in enumerate(hits):
        if not isinstance(raw_hit, dict):
            _fail(f"{where}.hits[{index}]", "expected an object")
        node_id = _integer(raw_hit.get("node_id"), f"{where}.hits[{index}].node_id", minimum=1)
        was_seen = node_id in expected_seen
        if raw_hit.get("seen_before") is not was_seen:
            _fail(f"{where}.hits[{index}].seen_before", "does not match host seen state")
        if node_id in distinct_hits:
            continue
        distinct_hits.append(node_id)
        if was_seen:
            observed_repeated += 1
        else:
            observed_new += 1
    if (new_count, repeated_count) != (observed_new, observed_repeated):
        _fail(where, "host gain counts do not match distinct returned hits")
    return {
        "seen_node_count": len(expected_seen),
        "ledger_scope": receipt["ledger_scope"],
        "new_hit_count": new_count,
        "repeated_hit_count": repeated_count,
        "hit_node_ids": distinct_hits,
        "probes": [
            {
                "variant_index": parsed_plan["variant_index"],
                "variant_kind": parsed_plan["variants"][parsed_plan["variant_index"]]["kind"],
                "query": parsed_plan["query"],
                "new_hit_count": new_count,
                "repeated_hit_count": repeated_count,
                "hit_node_ids": distinct_hits,
            }
        ],
    }


def _pre_search_rejection_stage(raw_result: str) -> str | None:
    """Recognize only native fail-closed errors emitted before TinyKG search.

    The matching Zig path rejects before it invokes TinyKG.  Do not broaden
    this to arbitrary ``invalid_args`` or recoverable tool failures: those can
    describe malformed input, permission policy, transport failure, or an
    unavailable store and must continue to invalidate quality evidence.
    """

    try:
        result = json.loads(raw_result)
    except json.JSONDecodeError:
        return None
    error = result.get("error") if isinstance(result, dict) else None
    if not isinstance(error, dict) or set(error) != {
        "code",
        "category",
        "detail",
        "recoverable",
    }:
        return None
    detail = error.get("detail")
    if not (
        error.get("code") == "invalid_args"
        and error.get("category") == "user_error"
        and error.get("recoverable") is True
        and isinstance(detail, str)
    ):
        return None
    if detail.startswith("KgRecall lexical_plan 非法: "):
        return "parser"
    if detail.startswith("KgRecall lexical_plan host ledger rejected the call: "):
        return "ledger"
    return None


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
    trace_schema_version: str | None = None,
) -> Dict[str, Any]:
    """Derive a trace from raw requests without trusting an existing sidecar."""

    _string(run_id, f"{where}.run_id")
    _string(arm, f"{where}.arm")
    _string(memory_backend, f"{where}.memory_backend")
    recall_tools = [item for item in _cassette_tools(cassette, where) if item[1] == "KgRecall"]
    if trace_schema_version is None:
        trace_schema_version = (
            TRACE_SCHEMA_VERSION
            if any(
                isinstance(tool_input.get("lexical_plan"), dict)
                and tool_input["lexical_plan"].get("schema_version")
                == BATCH_LEXICAL_PLAN_SCHEMA_VERSION
                for _tool_id, _name, tool_input, _result, _is_error in recall_tools
            )
            else LEGACY_TRACE_SCHEMA_VERSION
        )
    if trace_schema_version not in TRACE_SCHEMA_VERSIONS:
        _fail(f"{where}.schema_version", "unsupported requested trace schema")
    if memory_backend not in TINYKG_BACKENDS:
        status = "not_applicable" if not recall_tools else "invalid"
        reasons = [] if not recall_tools else ["non_tinykg_backend_executed_kg_recall"]
        return {
            "schema_version": trace_schema_version,
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
    run_seen: set[int] = set()
    declared_seed_plans: set[str] = set()
    for call_index, (_tool_id, _name, tool_input, raw_result, is_error) in enumerate(recall_tools):
        # Invalid reasons are persisted evidence. Keep them independent from
        # caller diagnostics and model-controlled ids so later replay is
        # byte-stable and bounded.
        call_where = f"KgRecall[{call_index}]"
        rejection_stage = _pre_search_rejection_stage(raw_result) if is_error else None
        try:
            parsed_plan = _parse_plan(tool_input, call_where)
            plan_sha = str(parsed_plan["plan_sha256"])
            if parsed_plan["stage"] == "seed":
                declared_seed_plans.add(plan_sha)
            if is_error:
                if rejection_stage == "ledger":
                    reasons.append(
                        f"call {call_index}: host rejected lexical plan before search "
                        f"({rejection_stage})"
                    )
                elif rejection_stage == "parser":
                    reasons.append(
                        f"call {call_index}: parser rejection envelope contradicts "
                        "a valid lexical plan"
                    )
                else:
                    reasons.append(
                        f"call {call_index}: KgRecall has no successful observable result"
                    )
                continue
            expected_seen = (
                plan_seen[plan_sha]
                if parsed_plan["schema_version"]
                == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
                else run_seen
            )
            declared_seen = parsed_plan["seen_node_ids"]
            if declared_seen is not None and set(declared_seen) != expected_seen:
                _fail(call_where, "declared seen ids do not match prior hits for this plan")
            receipt = _parse_receipt(
                raw_result,
                parsed_plan,
                expected_seen,
                call_where,
            )
            expected_seen.update(receipt["hit_node_ids"])
            if trace_schema_version == LEGACY_TRACE_SCHEMA_VERSION:
                if parsed_plan["schema_version"] == BATCH_LEXICAL_PLAN_SCHEMA_VERSION:
                    _fail(call_where, "batch plan cannot be represented by legacy trace-v1")
                calls.append({
                    "call_index": call_index,
                    "schema_version": parsed_plan["schema_version"],
                    "plan_sha256": plan_sha,
                    "variants_sha256": parsed_plan["variants_sha256"],
                    "intent": parsed_plan["intent"],
                    "stage": parsed_plan["stage"],
                    "variant_index": parsed_plan["variant_index"],
                    "variant_count": len(parsed_plan["variants"]),
                    "variant_kind": parsed_plan["variants"][parsed_plan["variant_index"]]["kind"],
                    "query": parsed_plan["query"],
                    "seen_node_count": int(receipt["seen_node_count"]),
                    "seen_state_verified": True,
                    "ledger_scope": receipt["ledger_scope"],
                    "new_hit_count": receipt["new_hit_count"],
                    "repeated_hit_count": receipt["repeated_hit_count"],
                })
            else:
                calls.append({
                    "call_index": call_index,
                    "schema_version": parsed_plan["schema_version"],
                    "plan_sha256": plan_sha,
                    "variants_sha256": parsed_plan["variants_sha256"],
                    "intent": parsed_plan["intent"],
                    "stage": parsed_plan["stage"],
                    "execution": parsed_plan["execution"],
                    "variant_count": len(parsed_plan["variants"]),
                    "seen_node_count": int(receipt["seen_node_count"]),
                    "seen_state_verified": True,
                    "ledger_scope": receipt["ledger_scope"],
                    "new_hit_count": receipt["new_hit_count"],
                    "repeated_hit_count": receipt["repeated_hit_count"],
                    "probes": receipt["probes"],
                })
        except ValidationError as exc:
            if rejection_stage == "parser":
                reasons.append(
                    f"call {call_index}: host rejected lexical plan before search "
                    f"(parser): {exc}"
                )
            else:
                reasons.append(f"call {call_index}: {exc}")
    if len(declared_seed_plans) > 1:
        reasons.append(MULTIPLE_DISTINCT_SEED_PLANS_REASON)
    semantic_probe_count = sum(
        (
            len(call["probes"])
            if trace_schema_version == TRACE_SCHEMA_VERSION
            else 1
        )
        for call in calls
        if call["schema_version"]
        in {LEXICAL_PLAN_SCHEMA_VERSION, BATCH_LEXICAL_PLAN_SCHEMA_VERSION}
        and call["stage"] != "seed"
    )
    if semantic_probe_count > MAX_V2_SEMANTIC_EXPANSION_CALLS:
        reasons.append(V2_SEMANTIC_EXPANSION_BUDGET_REASON)
    if not recall_tools:
        reasons.append("TinyKG backend executed no KgRecall")
    status = "verified" if not reasons and len(calls) == len(recall_tools) else "invalid"
    return {
        "schema_version": trace_schema_version,
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
        probes = (
            call["probes"]
            if trace["schema_version"] == TRACE_SCHEMA_VERSION
            else [{"query": call["query"]}]
        )
        for probe in probes:
            text = str(probe["query"])
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
                return projected
    return projected


def quality_scoreable_with_pre_search_rejections(
    trace: Mapping[str, Any],
    *,
    host_recall_satisfied: bool = False,
) -> bool:
    """Keep task quality separate from recoverable tool-protocol mistakes.

    A model-issued KgRecall can be rejected without exposing any memory and
    the run can still retain a host-receipted retrieval path.  That rejected
    attempt is real trajectory evidence: the trace remains ``invalid`` and the
    native tool-error/time/token counters retain its cost.  It is not,
    however, an infrastructure failure that should erase an otherwise
    scoreable answer.

    This exception is intentionally narrow.  Either a successful explicit seed
    or an independently verified host-scoped recall must remain, and every
    trace-level reason must describe a rejected attempt.  Receipt drift, forged
    gain counts, successful-call ledger mismatches, multiple seed plans, and a
    run with no verified host or explicit recall continue to fail closed.
    """

    validate_query_plan_trace(trace)
    if not isinstance(host_recall_satisfied, bool):
        _fail("query-plan quality eligibility", "host recall status must be boolean")
    if trace["memory_backend"] not in TINYKG_BACKENDS:
        return False
    if trace["status"] != "invalid" or (
        not trace["calls"] and not host_recall_satisfied
    ):
        return False
    rejection_indices: List[int] = []
    for reason in trace["invalid_reasons"]:
        match = PRE_SEARCH_REJECTION_REASON.fullmatch(reason)
        if match is None:
            return False
        rejection_indices.append(int(match.group("call_index")))
    if len(rejection_indices) != len(set(rejection_indices)):
        return False
    successful_indices = {int(call["call_index"]) for call in trace["calls"]}
    expected_rejections = set(range(int(trace["kg_recall_count"]))) - successful_indices
    if set(rejection_indices) != expected_rejections:
        return False
    return host_recall_satisfied or any(
        call["stage"] == "seed" for call in trace["calls"]
    )


def validate_query_plan_trace(trace: Mapping[str, Any], where: str = "query-plan sidecar") -> None:
    value = _object(trace, where, TRACE_KEYS)
    trace_version = value["schema_version"]
    if trace_version not in TRACE_SCHEMA_VERSIONS:
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
        call = _object(
            raw_call,
            f"{where}.calls[{index}]",
            CALL_V2_KEYS if trace_version == TRACE_SCHEMA_VERSION else CALL_KEYS,
        )
        call_index = _integer(call["call_index"], f"{where}.calls[{index}].call_index")
        if call_index <= prior_index:
            _fail(f"{where}.calls[{index}].call_index", "must be strictly increasing")
        prior_index = call_index
        if call["schema_version"] not in LEXICAL_PLAN_SCHEMA_VERSIONS:
            _fail(f"{where}.calls[{index}].schema_version", "unsupported plan schema")
        _hash(call["plan_sha256"], f"{where}.calls[{index}].plan_sha256")
        _hash(call["variants_sha256"], f"{where}.calls[{index}].variants_sha256")
        if call["intent"] not in INTENTS or call["stage"] not in STAGES:
            _fail(f"{where}.calls[{index}]", "unsupported intent or stage")
        variant_count = _integer(call["variant_count"], f"{where}.calls[{index}].variant_count", minimum=1)
        if variant_count > 4:
            _fail(f"{where}.calls[{index}]", "invalid variant bounds")
        if (
            call["schema_version"] == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
            and call["stage"] == "semantic_expansion"
            and variant_count < 2
        ):
            _fail(f"{where}.calls[{index}]", "invalid legacy expansion bounds")
        for key in ("seen_node_count", "new_hit_count", "repeated_hit_count"):
            _integer(call[key], f"{where}.calls[{index}].{key}")
        expected_scope = (
            "agent_run_plan"
            if call["schema_version"] == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
            else "agent_run_batch"
            if call["schema_version"] == BATCH_LEXICAL_PLAN_SCHEMA_VERSION
            else "agent_run_explicit"
        )
        if call["seen_state_verified"] is not True or call["ledger_scope"] != expected_scope:
            _fail(f"{where}.calls[{index}]", "host verification claim is absent")
        if trace_version == LEGACY_TRACE_SCHEMA_VERSION:
            variant_kind = call["variant_kind"]
            if variant_kind not in VARIANT_KINDS or (
                call["schema_version"] == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
                and variant_kind == "synonym"
            ):
                _fail(f"{where}.calls[{index}].variant_kind", "unsupported kind")
            variant_index = _integer(call["variant_index"], f"{where}.calls[{index}].variant_index")
            if variant_index >= variant_count:
                _fail(f"{where}.calls[{index}]", "invalid variant bounds")
            _string(call["query"], f"{where}.calls[{index}].query")
            continue

        execution = _string(call["execution"], f"{where}.calls[{index}].execution")
        expected_execution = (
            "host_batch_all"
            if call["schema_version"] == BATCH_LEXICAL_PLAN_SCHEMA_VERSION
            else "single"
        )
        if execution != expected_execution:
            _fail(f"{where}.calls[{index}].execution", "does not match plan schema")
        probes = call["probes"]
        expected_probe_count = variant_count if execution == "host_batch_all" else 1
        if not isinstance(probes, list) or len(probes) != expected_probe_count:
            _fail(f"{where}.calls[{index}].probes", "does not cover executed variants")
        if call["schema_version"] == BATCH_LEXICAL_PLAN_SCHEMA_VERSION:
            if call["stage"] == "seed" and variant_count != 1:
                _fail(f"{where}.calls[{index}]", "v3 seed must contain one variant")
            if call["stage"] == "semantic_expansion" and not 2 <= variant_count <= 4:
                _fail(f"{where}.calls[{index}]", "v3 semantic batch must contain 2-4 variants")
            if call["stage"] == "focused_refinement" and variant_count != 1:
                _fail(f"{where}.calls[{index}]", "v3 focused refinement must contain one variant")
        probe_new = 0
        probe_repeated = 0
        for probe_offset, raw_probe in enumerate(probes):
            probe = _object(
                raw_probe,
                f"{where}.calls[{index}].probes[{probe_offset}]",
                PROBE_KEYS,
            )
            probe_index = _integer(
                probe["variant_index"],
                f"{where}.calls[{index}].probes[{probe_offset}].variant_index",
            )
            if probe_index >= variant_count or (
                execution == "host_batch_all" and probe_index != probe_offset
            ):
                _fail(f"{where}.calls[{index}].probes[{probe_offset}]", "invalid variant order")
            variant_kind = probe["variant_kind"]
            if variant_kind not in VARIANT_KINDS or (
                call["schema_version"] == LEGACY_LEXICAL_PLAN_SCHEMA_VERSION
                and variant_kind == "synonym"
            ):
                _fail(f"{where}.calls[{index}].probes[{probe_offset}].variant_kind", "unsupported kind")
            _string(probe["query"], f"{where}.calls[{index}].probes[{probe_offset}].query")
            probe_new += _integer(
                probe["new_hit_count"],
                f"{where}.calls[{index}].probes[{probe_offset}].new_hit_count",
            )
            probe_repeated += _integer(
                probe["repeated_hit_count"],
                f"{where}.calls[{index}].probes[{probe_offset}].repeated_hit_count",
            )
            node_ids = probe["hit_node_ids"]
            if not isinstance(node_ids, list) or len(node_ids) > 8:
                _fail(f"{where}.calls[{index}].probes[{probe_offset}].hit_node_ids", "invalid node-id list")
            validated_ids = [
                _integer(
                    node_id,
                    f"{where}.calls[{index}].probes[{probe_offset}].hit_node_ids[{node_offset}]",
                    minimum=1,
                )
                for node_offset, node_id in enumerate(node_ids)
            ]
            if len(validated_ids) != len(set(validated_ids)):
                _fail(f"{where}.calls[{index}].probes[{probe_offset}].hit_node_ids", "duplicate node id")
        if (probe_new, probe_repeated) != (
            call["new_hit_count"],
            call["repeated_hit_count"],
        ):
            _fail(f"{where}.calls[{index}]", "call gain totals do not match probes")
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
    semantic_expansion_probes = sum(
        (
            len(call["probes"])
            if trace_version == TRACE_SCHEMA_VERSION
            else 1
        )
        for call in calls
        if call["schema_version"]
        in {LEXICAL_PLAN_SCHEMA_VERSION, BATCH_LEXICAL_PLAN_SCHEMA_VERSION}
        and call["stage"] != "seed"
    )
    if semantic_expansion_probes > MAX_V2_SEMANTIC_EXPANSION_CALLS:
        if status == "verified":
            _fail(where, "verified trace exceeds the semantic expansion budget (probe count)")
        if V2_SEMANTIC_EXPANSION_BUDGET_REASON not in reasons:
            _fail(where, "semantic expansion overflow is missing its invalid reason")
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
        trace_schema_version=str(value["schema_version"]),
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
    protocol_status_counts = {
        key: 0
        for key in (
            "verified",
            "invalid",
            "not_applicable",
            "legacy_unavailable",
        )
    }
    quality_eligibility_counts = {
        key: 0
        for key in (
            "explicit_plan_verified",
            "scoreable_with_pre_search_rejections",
            "host_recall_satisfied",
            "ineligible",
            "not_applicable",
            "legacy_unavailable",
        )
    }
    calls: List[Mapping[str, Any]] = []
    probes: List[Mapping[str, Any]] = []
    plans: set[Tuple[str, str]] = set()
    rollout_rows: List[Mapping[str, Any]] = []
    for trace, host_satisfied in zip(traces, host_recall_satisfied):
        if trace is None:
            if host_satisfied:
                _fail("memory query-plan summary", "legacy trace cannot claim host recall")
            protocol_status_counts["legacy_unavailable"] += 1
            quality_eligibility_counts["legacy_unavailable"] += 1
            rollout_rows.append(
                {
                    "protocol_status": "legacy_unavailable",
                    "quality_eligibility": "legacy_unavailable",
                }
            )
            continue
        validate_query_plan_trace(trace)
        trace_status = str(trace["status"])
        if host_satisfied and trace["memory_backend"] not in TINYKG_BACKENDS:
            _fail(
                "memory query-plan summary",
                "non-TinyKG trace cannot claim host recall",
            )
        protocol_status_counts[trace_status] += 1
        if trace_status == "verified":
            quality_eligibility = "explicit_plan_verified"
        elif quality_scoreable_with_pre_search_rejections(
            trace,
            host_recall_satisfied=host_satisfied,
        ):
            quality_eligibility = "scoreable_with_pre_search_rejections"
        elif (
            trace_status == "invalid"
            and host_satisfied
            and trace["invalid_reasons"] == ["TinyKG backend executed no KgRecall"]
        ):
            quality_eligibility = "host_recall_satisfied"
        elif trace_status == "not_applicable":
            quality_eligibility = "not_applicable"
        else:
            quality_eligibility = "ineligible"
        quality_eligibility_counts[quality_eligibility] += 1
        rollout_rows.append(
            {
                "run_id": trace["run_id"],
                "arm": trace["arm"],
                "memory_backend": trace["memory_backend"],
                "protocol_status": trace_status,
                "quality_eligibility": quality_eligibility,
                "host_recall_satisfied": host_satisfied,
                "kg_recall_count": trace["kg_recall_count"],
                "invalid_reasons": trace["invalid_reasons"],
            }
        )
        if quality_eligibility not in {
            "explicit_plan_verified",
            "scoreable_with_pre_search_rejections",
        }:
            continue
        for call in trace["calls"]:
            calls.append(call)
            plans.add((str(trace["run_id"]), str(call["plan_sha256"])))
            if trace["schema_version"] == TRACE_SCHEMA_VERSION:
                for probe in call["probes"]:
                    probes.append({**probe, "stage": call["stage"]})
            else:
                probes.append(
                    {
                        "variant_index": call["variant_index"],
                        "variant_kind": call["variant_kind"],
                        "query": call["query"],
                        "new_hit_count": call["new_hit_count"],
                        "repeated_hit_count": call["repeated_hit_count"],
                        "hit_node_ids": [],
                        "stage": call["stage"],
                    }
                )
    new_total = sum(int(call["new_hit_count"]) for call in calls)
    repeated_total = sum(int(call["repeated_hit_count"]) for call in calls)

    def grouped(
        rows: Sequence[Mapping[str, Any]],
        key: str,
    ) -> Mapping[str, Mapping[str, float | int | None]]:
        buckets: MutableMapping[str, List[Mapping[str, Any]]] = defaultdict(list)
        for row in rows:
            buckets[str(row[key])].append(row)
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

    verified_call_counts = []
    for trace, host_satisfied in zip(traces, host_recall_satisfied):
        if trace is None:
            continue
        if trace["status"] == "verified" or quality_scoreable_with_pre_search_rejections(
            trace,
            host_recall_satisfied=host_satisfied,
        ):
            verified_call_counts.append(int(trace["kg_recall_count"]))
    denominator = new_total + repeated_total
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "rollouts": len(traces),
        "protocol_status_counts": protocol_status_counts,
        "quality_eligibility_counts": quality_eligibility_counts,
        "explicit_verified_calls": len(calls),
        "explicit_verified_probes": len(probes),
        "explicit_verified_plans": len(plans),
        "new_hit_count": new_total,
        "repeated_hit_count": repeated_total,
        "unique_gain_ratio": new_total / denominator if denominator else None,
        "mean_calls_before_stopping": (
            sum(verified_call_counts) / len(verified_call_counts)
            if verified_call_counts
            else None
        ),
        "by_stage": grouped(calls, "stage"),
        "by_variant_kind": grouped(probes, "variant_kind"),
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
        f"- Host-executed probes: {summary['explicit_verified_probes']}",
        f"- Explicit verified plans: {summary['explicit_verified_plans']}",
        f"- New/repeated hits: {summary['new_hit_count']} / {summary['repeated_hit_count']}",
        f"- Unique gain ratio: {number(summary['unique_gain_ratio'])}",
        f"- Mean calls before stopping: {number(summary['mean_calls_before_stopping'])}",
        "",
        "## Protocol status",
        "",
        "```json",
        json.dumps(
            summary["protocol_status_counts"],
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ),
        "```",
        "",
        "## Quality eligibility",
        "",
        "```json",
        json.dumps(
            summary["quality_eligibility_counts"],
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ),
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
