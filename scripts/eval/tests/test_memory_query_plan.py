import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.memory_query_plan import (
    MULTIPLE_DISTINCT_SEED_PLANS_REASON,
    V2_SEMANTIC_EXPANSION_BUDGET_REASON,
    SIDECAR_NAME,
    _plan_fingerprint,
    build_query_plan_trace,
    load_and_verify_query_plan_sidecar,
    project_query_variants,
    quality_scoreable_with_pre_search_rejections,
    summarize_query_plan_traces,
    validate_query_plan_trace,
)
from scripts.eval.memory_agent_runtime import _query_plan_evaluator_invalid_reason
from scripts.eval.model import ValidationError, stable_json


class MemoryQueryPlanTraceTest(unittest.TestCase):
    def _call(
        self,
        tool_id,
        *,
        variants,
        variant_index=0,
        seen=(),
        hits=(),
        intent="fact_lookup",
        stage="seed",
        count_override=None,
        schema_version="lexical-query-plan-v1",
    ):
        plan_sha = _plan_fingerprint(
            intent,
            stage,
            variants,
            None,
            schema_version=schema_version,
        )
        lexical_plan = {
            "schema_version": schema_version,
            "intent": intent,
            "stage": stage,
            "variants": variants,
            "variant_index": variant_index,
        }
        if schema_version == "lexical-query-plan-v1":
            lexical_plan["seen_node_ids"] = list(seen)
        tool_input = {
            "query": variants[variant_index]["text"],
            "lexical_plan": lexical_plan,
        }
        distinct = []
        new_count = 0
        repeated_count = 0
        result_hits = []
        for node_id in hits:
            was_seen = node_id in seen
            result_hits.append({"node_id": node_id, "seen_before": was_seen})
            if node_id in distinct:
                continue
            distinct.append(node_id)
            if was_seen:
                repeated_count += 1
            else:
                new_count += 1
        if count_override is not None:
            new_count, repeated_count = count_override
        result = {
            "hits": result_hits,
            "lexical_query_plan": {
                "schema_version": schema_version,
                "plan_sha256": plan_sha,
                "intent": intent,
                "stage": stage,
                "variant_index": variant_index,
                "variant_count": len(variants),
                "variant_kind": variants[variant_index]["kind"],
                "seen_node_count": len(seen),
                "seen_state_verified": True,
                "ledger_scope": (
                    "agent_run_plan"
                    if schema_version == "lexical-query-plan-v1"
                    else "agent_run_explicit"
                ),
                "new_hit_count": new_count,
                "repeated_hit_count": repeated_count,
            },
        }
        return (
            {
                "type": "tool_use",
                "id": tool_id,
                "name": "KgRecall",
                "input": tool_input,
            },
            {
                "type": "tool_result",
                "tool_use_id": tool_id,
                "content": stable_json(result),
            },
        )

    def _batch_call(
        self,
        tool_id,
        *,
        variants,
        variant_hits,
        seen=(),
        intent="enumeration",
        query=None,
        audited_anchor=False,
        auto_context_node_id=None,
    ):
        plan_sha = _plan_fingerprint(
            intent,
            "semantic_expansion",
            variants,
            None,
            schema_version="lexical-query-plan-v3",
        )
        lexical_plan = {
            "schema_version": "lexical-query-plan-v3",
            "intent": intent,
            "stage": "semantic_expansion",
            "variants": variants,
        }
        probe_seen = set(seen)
        merged = []
        receipts = []
        new_total = 0
        repeated_total = 0
        for index, (variant, node_ids) in enumerate(zip(variants, variant_hits)):
            new_count = 0
            repeated_count = 0
            for node_id in node_ids:
                if node_id in probe_seen:
                    repeated_count += 1
                else:
                    new_count += 1
                    probe_seen.add(node_id)
                if node_id not in merged:
                    merged.append(node_id)
            new_total += new_count
            repeated_total += repeated_count
            receipts.append(
                {
                    "variant_index": index,
                    "variant_kind": variant["kind"],
                    "node_ids": list(node_ids),
                    "new_hit_count": new_count,
                    "repeated_hit_count": repeated_count,
                }
            )
        result_hits = []
        for node_id in merged:
            if node_id in seen:
                result_hits.append(
                    {
                        "node_id": node_id,
                        "seen_before": True,
                        "content_ref": "exposed_elsewhere_in_run",
                    }
                )
            else:
                result_hits.append(
                    {
                        "node_id": node_id,
                        "seen_before": False,
                        "text": f"node {node_id}",
                        **({"type": "evidence"} if node_id == auto_context_node_id else {}),
                    }
                )
        merged_new = sum(node_id not in seen for node_id in merged)
        effective_query = variants[0]["text"].strip(" \t\r\n")
        input_query = effective_query if query is None else query
        normalized_input_query = input_query.strip(" \t\r\n")
        result = {
            "hits": result_hits,
            "lexical_query_plan": {
                "schema_version": "lexical-query-plan-v3",
                "plan_sha256": plan_sha,
                "intent": intent,
                "stage": "semantic_expansion",
                "variant_count": len(variants),
                "executed_variant_count": len(variants),
                "all_variants_executed": True,
                "seen_node_count": len(seen),
                "seen_state_verified": True,
                "ledger_scope": "agent_run_batch",
                "merged_hit_count": len(merged),
                "merged_new_hit_count": merged_new,
                "merged_previously_seen_count": len(merged) - merged_new,
                "probe_new_hit_count": new_total,
                "probe_repeated_hit_count": repeated_total,
                "variant_receipts": receipts,
                "execution": "host_batch_all",
            },
        }
        if audited_anchor:
            result["lexical_query_plan"].update(
                {
                    "query_anchor_rewritten": normalized_input_query != effective_query,
                    "query_anchor_input_sha256": hashlib.sha256(
                        normalized_input_query.encode("utf-8")
                    ).hexdigest(),
                    "query_anchor_effective_sha256": hashlib.sha256(
                        effective_query.encode("utf-8")
                    ).hexdigest(),
                }
            )
        if auto_context_node_id is not None:
            result["auto_context"] = {
                "schema_version": "metacodes-auto-context-v1",
                "selection_policy": "first_new_evidence_then_new_then_merged_v1",
                "context": {
                    "node_id": auto_context_node_id,
                    "graph": {
                        "query": {"root_id": auto_context_node_id},
                        "summary": {"truncated": False},
                    },
                    "knowledge_governance": {
                        "schema_version": "metacodes-knowledge-governance-v1",
                    },
                },
            }
        return (
            {
                "type": "tool_use",
                "id": tool_id,
                "name": "KgRecall",
                "input": {"query": input_query, "lexical_plan": lexical_plan},
            },
            {
                "type": "tool_result",
                "tool_use_id": tool_id,
                "content": stable_json(result),
            },
        )

    def _write_requests(self, root, calls):
        observed = []
        for request_index, call in enumerate(calls, start=1):
            observed.append(call)
            messages = [
                {
                    "role": "assistant",
                    "content": [item[0] for item in observed],
                },
                {
                    "role": "user",
                    "content": [item[1] for item in observed],
                },
            ]
            (root / f"req-{request_index:03d}.json").write_text(
                stable_json({"messages": messages}) + "\n",
                encoding="utf-8",
            )

    def test_verified_trace_replays_host_gain_and_seen_progression(self):
        variants = [{"kind": "exact", "text": "needle"}]
        first = self._call("kg-1", variants=variants, seen=(), hits=(7, 9))
        second = self._call("kg-2", variants=variants, seen=(7, 9), hits=(7, 11))
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [first, second])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-1",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )
            self.assertEqual(trace["status"], "verified")
            self.assertEqual(trace["kg_recall_count"], 2)
            self.assertEqual(
                [
                    (call["new_hit_count"], call["repeated_hit_count"])
                    for call in trace["calls"]
                ],
                [(2, 0), (1, 1)],
            )
            self.assertEqual(trace["calls"][1]["seen_node_count"], 2)
            (cassette / SIDECAR_NAME).write_text(
                stable_json(trace) + "\n",
                encoding="utf-8",
            )
            replayed = load_and_verify_query_plan_sidecar(
                cassette,
                run_id="run-1",
                arm="tinykg_lexical",
                memory_backend="tinykg",
                required=True,
                where="test trace",
            )
            self.assertEqual(replayed, trace)
            summary = summarize_query_plan_traces([trace])
            self.assertEqual(summary["explicit_verified_calls"], 2)
            self.assertEqual(summary["new_hit_count"], 3)
            self.assertEqual(summary["repeated_hit_count"], 1)
            self.assertEqual(summary["unique_gain_ratio"], 0.75)

    def test_v2_host_owned_seen_state_accepts_single_synonym_expansion(self):
        variants = [{"kind": "synonym", "text": "commencement"}]
        first = self._call(
            "kg-1",
            variants=variants,
            hits=(7, 9),
            stage="semantic_expansion",
            schema_version="lexical-query-plan-v2",
        )
        second = self._call(
            "kg-2",
            variants=variants,
            seen=(7, 9),
            hits=(7, 11),
            stage="semantic_expansion",
            schema_version="lexical-query-plan-v2",
        )
        cross_plan = self._call(
            "kg-3",
            variants=[{"kind": "paraphrase", "text": "graduation event"}],
            seen=(7, 9, 11),
            hits=(7, 13),
            stage="semantic_expansion",
            schema_version="lexical-query-plan-v2",
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [first, second, cross_plan])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v2-host-seen",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )

        self.assertEqual(trace["status"], "verified")
        self.assertEqual(
            [call["schema_version"] for call in trace["calls"]],
            [
                "lexical-query-plan-v2",
                "lexical-query-plan-v2",
                "lexical-query-plan-v2",
            ],
        )
        self.assertEqual(
            [call["seen_node_count"] for call in trace["calls"]],
            [0, 2, 3],
        )
        self.assertEqual(
            [call["variant_kind"] for call in trace["calls"]],
            ["synonym", "synonym", "paraphrase"],
        )
        self.assertEqual(trace["calls"][2]["repeated_hit_count"], 1)

    def test_v3_batch_replays_all_probes_and_one_merged_result(self):
        variants = [
            {"kind": "synonym", "text": "graduation ceremony"},
            {"kind": "broader", "text": "education milestone events"},
        ]
        batch = self._batch_call(
            "kg-batch",
            variants=variants,
            variant_hits=[(7, 9), (9, 11)],
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [batch])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-batch",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(
                trace["schema_version"],
                "metacodes-memory-query-plan-trace-v2",
            )
            self.assertEqual(trace["status"], "verified")
            self.assertEqual(trace["kg_recall_count"], 1)
            self.assertEqual(len(trace["calls"]), 1)
            call = trace["calls"][0]
            self.assertEqual(call["execution"], "host_batch_all")
            self.assertEqual(
                [
                    (probe["new_hit_count"], probe["repeated_hit_count"])
                    for probe in call["probes"]
                ],
                [(2, 0), (1, 1)],
            )
            self.assertEqual(project_query_variants(trace), [
                {"kind": "semantic", "text": "graduation ceremony"},
                {"kind": "semantic", "text": "education milestone events"},
            ])
            summary = summarize_query_plan_traces([trace])
            self.assertEqual(summary["explicit_verified_calls"], 1)
            self.assertEqual(summary["explicit_verified_probes"], 2)
            self.assertEqual(summary["new_hit_count"], 3)
            self.assertEqual(summary["repeated_hit_count"], 1)

            (cassette / SIDECAR_NAME).write_text(
                stable_json(trace) + "\n",
                encoding="utf-8",
            )
            self.assertEqual(
                load_and_verify_query_plan_sidecar(
                    cassette,
                    run_id="run-v3-batch",
                    arm="tinykg_lexical",
                    memory_backend="tinykg_integrated",
                    required=True,
                    where="v3 batch",
                ),
                trace,
            )

    def test_v3_auto_context_is_bound_to_deterministic_batch_selection(self):
        variants = [
            {"kind": "synonym", "text": "attended commencement"},
            {"kind": "relation", "text": "degree conferral I went to"},
        ]
        batch = self._batch_call(
            "kg-auto-context",
            variants=variants,
            variant_hits=[(7, 9), (11,)],
            auto_context_node_id=7,
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [batch])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-auto-context",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(trace["status"], "verified")

            request = json.loads((cassette / "req-001.json").read_text(encoding="utf-8"))
            result_item = request["messages"][1]["content"][0]
            result = json.loads(result_item["content"])
            result["auto_context"]["context"]["node_id"] = 9
            result["auto_context"]["context"]["graph"]["query"]["root_id"] = 9
            result_item["content"] = stable_json(result)
            (cassette / "req-001.json").write_text(
                stable_json(request) + "\n",
                encoding="utf-8",
            )
            tampered = build_query_plan_trace(
                cassette,
                run_id="run-v3-auto-context",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(tampered["status"], "invalid")
            self.assertTrue(
                any("deterministic selection" in reason for reason in tampered["invalid_reasons"])
            )

            tampered_use, tampered_result = copy.deepcopy(batch)
            tampered_payload = json.loads(tampered_result["content"])
            tampered_payload["lexical_query_plan"]["variant_receipts"][1][
                "new_hit_count"
            ] = 0
            tampered_result["content"] = stable_json(tampered_payload)
            self._write_requests(cassette, [(tampered_use, tampered_result)])
            tampered_trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-tampered",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(tampered_trace["status"], "invalid")
            self.assertRegex(tampered_trace["invalid_reasons"][0], "gain counts")

    def test_v3_bounded_recall_envelope_is_replayed_not_trusted(self):
        call = self._batch_call(
            "kg-bounded",
            variants=[
                {"kind": "synonym", "text": "alpha evidence"},
                {"kind": "relation", "text": "beta evidence"},
            ],
            variant_hits=[(7, 9), (11,)],
            auto_context_node_id=7,
        )
        use, result_block = copy.deepcopy(call)
        payload = json.loads(result_block["content"])
        payload["recall_envelope"] = {
            "schema_version": "metacodes-bounded-recall-v1",
            "complete_json": True,
            "max_result_bytes": 24 * 1024,
            "text_excerpt_policy": "utf8_head_tail_v1",
        }
        for hit in payload["hits"]:
            if hit["seen_before"]:
                continue
            returned = len(hit["text"].encode("utf-8"))
            hit.update(
                {
                    "text_returned_bytes": returned,
                    "text_total_bytes": returned + 100,
                    "text_truncated": True,
                    "text_excerpt_policy": "utf8_head_tail_v1",
                }
            )
        result_block["content"] = stable_json(payload)

        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [(use, result_block)])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-bounded",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(trace["status"], "verified")

            tampered = copy.deepcopy(payload)
            tampered["hits"][0]["text_returned_bytes"] += 1
            result_block["content"] = stable_json(tampered)
            self._write_requests(cassette, [(use, result_block)])
            invalid = build_query_plan_trace(
                cassette,
                run_id="run-v3-bounded-tampered",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(invalid["status"], "invalid")
            self.assertTrue(
                any("bounded text excerpt" in reason for reason in invalid["invalid_reasons"])
            )

    def test_v3_stale_query_anchor_requires_and_accepts_host_audit_receipt(self):
        variants = [
            {"kind": "synonym", "text": "commencement"},
            {"kind": "paraphrase", "text": "degree conferral"},
        ]
        rewritten = self._batch_call(
            "kg-rewritten",
            variants=variants,
            variant_hits=[(7,), (9,)],
            query="old graduation seed",
            audited_anchor=True,
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [rewritten])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-rewritten-anchor",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(trace["status"], "verified")
            self.assertEqual(trace["kg_recall_count"], 1)

            unaudited_use, unaudited_result = copy.deepcopy(rewritten)
            payload = json.loads(unaudited_result["content"])
            for key in (
                "query_anchor_rewritten",
                "query_anchor_input_sha256",
                "query_anchor_effective_sha256",
            ):
                payload["lexical_query_plan"].pop(key)
            unaudited_result["content"] = stable_json(payload)
            self._write_requests(cassette, [(unaudited_use, unaudited_result)])
            rejected = build_query_plan_trace(
                cassette,
                run_id="run-v3-unaudited-anchor",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(rejected["status"], "invalid")
            self.assertRegex(rejected["invalid_reasons"][0], "lacks a host audit")

            for field, forged_value in (
                ("query_anchor_rewritten", False),
                ("query_anchor_input_sha256", "0" * 64),
                ("query_anchor_effective_sha256", "f" * 64),
            ):
                forged_use, forged_result = copy.deepcopy(rewritten)
                forged_payload = json.loads(forged_result["content"])
                forged_payload["lexical_query_plan"][field] = forged_value
                forged_result["content"] = stable_json(forged_payload)
                self._write_requests(cassette, [(forged_use, forged_result)])
                forged = build_query_plan_trace(
                    cassette,
                    run_id=f"run-v3-forged-{field}",
                    arm="tinykg_lexical",
                    memory_backend="tinykg_integrated",
                )
                self.assertEqual(forged["status"], "invalid")
                self.assertRegex(
                    forged["invalid_reasons"][0],
                    "does not match the observed compatibility anchor",
                )

    def test_v3_query_anchor_hashes_use_native_ascii_trim_semantics(self):
        variants = [
            {"kind": "synonym", "text": "commencement"},
            {"kind": "paraphrase", "text": "degree conferral"},
        ]
        ascii_padded = self._batch_call(
            "kg-ascii-trimmed",
            variants=variants,
            variant_hits=[(7,), (9,)],
            query="  old graduation seed\r\n",
            audited_anchor=True,
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [ascii_padded])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-ascii-trimmed-anchor",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(trace["status"], "verified")

            non_breaking_space = "\u00a0old graduation seed\u00a0"
            unicode_padded = self._batch_call(
                "kg-unicode-whitespace",
                variants=variants,
                variant_hits=[(7,), (9,)],
                query=non_breaking_space,
                audited_anchor=True,
            )
            self._write_requests(cassette, [unicode_padded])
            unicode_trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-unicode-whitespace-anchor",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(unicode_trace["status"], "verified")

    def test_query_plan_rejects_invalid_compact_query_before_receipt_replay(self):
        variants = [
            {"kind": "synonym", "text": "commencement"},
            {"kind": "paraphrase", "text": "degree conferral"},
        ]
        invalid = self._batch_call(
            "kg-invalid-query",
            variants=variants,
            variant_hits=[(7,), (9,)],
            query="invalid\u0001query",
            audited_anchor=True,
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [invalid])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v3-invalid-query",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(trace["status"], "invalid")
            self.assertRegex(trace["invalid_reasons"][0], "invalid compact query")

    def test_distinct_seed_plans_are_invalid_and_preserved_as_exact(self):
        first = self._call(
            "kg-1",
            variants=[{"kind": "exact", "text": "rollback ticket protocol"}],
            hits=(7,),
        )
        second = self._call(
            "kg-2",
            variants=[{"kind": "exact", "text": "rollback registry Python"}],
            hits=(11,),
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [first, second])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-multiple-seeds",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertIn(MULTIPLE_DISTINCT_SEED_PLANS_REASON, trace["invalid_reasons"])
        self.assertEqual(len(trace["calls"]), 2)
        self.assertEqual(
            project_query_variants(trace),
            [
                {"kind": "exact", "text": "rollback ticket protocol"},
                {"kind": "exact", "text": "rollback registry Python"},
            ],
        )
        forged = copy.deepcopy(trace)
        forged["status"] = "verified"
        forged["invalid_reasons"] = []
        with self.assertRaisesRegex(ValidationError, "multiple distinct seed plans"):
            validate_query_plan_trace(forged)

    def test_more_than_four_successful_v2_expansions_are_invalid(self):
        calls = [
            self._call(
                f"kg-{index}",
                variants=[{"kind": "synonym", "text": f"probe {index}"}],
                seen=tuple(range(1, index)),
                hits=(index,),
                stage="semantic_expansion",
                schema_version="lexical-query-plan-v2",
            )
            for index in range(1, 6)
        ]
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, calls)
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v2-expansion-overflow",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertIn(V2_SEMANTIC_EXPANSION_BUDGET_REASON, trace["invalid_reasons"])
        forged = copy.deepcopy(trace)
        forged["status"] = "verified"
        forged["invalid_reasons"] = []
        with self.assertRaisesRegex(ValidationError, "semantic expansion budget"):
            validate_query_plan_trace(forged)

    def test_focused_refinement_cannot_bypass_post_seed_probe_budget(self):
        calls = [
            self._call(
                f"kg-focused-{index}",
                variants=[{"kind": "type", "text": f"decision probe {index}"}],
                seen=tuple(range(1, index)),
                hits=(index,),
                stage="focused_refinement",
                schema_version="lexical-query-plan-v2",
            )
            for index in range(1, 6)
        ]
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, calls)
            trace = build_query_plan_trace(
                cassette,
                run_id="run-v2-focused-overflow",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertIn(V2_SEMANTIC_EXPANSION_BUDGET_REASON, trace["invalid_reasons"])
        forged = copy.deepcopy(trace)
        forged["status"] = "verified"
        forged["invalid_reasons"] = []
        with self.assertRaisesRegex(ValidationError, "semantic expansion budget"):
            validate_query_plan_trace(forged)

    def test_forged_gain_receipt_is_invalid_not_zero_gain(self):
        variants = [{"kind": "exact", "text": "needle"}]
        forged = self._call(
            "kg-1",
            variants=variants,
            hits=(7,),
            count_override=(0, 0),
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [forged])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-forged",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )
            self.assertEqual(trace["status"], "invalid")
            self.assertEqual(trace["calls"], [])
            self.assertRegex(trace["invalid_reasons"][0], "gain counts")

    def test_failed_second_distinct_seed_still_invalidates_the_run(self):
        first = self._call(
            "kg-1",
            variants=[{"kind": "exact", "text": "first seed"}],
            hits=(7,),
        )
        second_use, second_result = self._call(
            "kg-2",
            variants=[{"kind": "exact", "text": "second seed"}],
        )
        second_result["is_error"] = True
        second_result["content"] = '{"error":{"code":"permission_denied"}}'
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [first, (second_use, second_result)])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-failed-second-seed",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertIn(MULTIPLE_DISTINCT_SEED_PLANS_REASON, trace["invalid_reasons"])
        self.assertRegex(trace["invalid_reasons"][0], "no successful observable result")
        self.assertFalse(quality_scoreable_with_pre_search_rejections(trace))

    def test_rejected_expansion_then_verified_recovery_keeps_quality_scoreable(self):
        seed = self._call(
            "kg-1",
            variants=[{"kind": "exact", "text": "cuisines learned"}],
            hits=(7, 9),
        )
        expansion_variants = [
            {"kind": "alias", "text": "cooking class cuisine"},
            {"kind": "paraphrase", "text": "tried new dishes"},
        ]
        rejected_use, rejected_result = self._call(
            "kg-2",
            variants=expansion_variants,
            seen=(7, 9),
            stage="semantic_expansion",
        )
        rejected_result["is_error"] = True
        rejected_result["content"] = stable_json(
            {
                "error": {
                    "code": "invalid_args",
                    "category": "user_error",
                    "detail": (
                        "KgRecall lexical_plan host ledger rejected the call: "
                        "lexical_plan.seen_node_ids does not exactly match the host ledger "
                        "for this plan"
                    ),
                    "recoverable": True,
                }
            }
        )
        recovered = self._call(
            "kg-3",
            variants=expansion_variants,
            seen=(),
            hits=(11,),
            stage="semantic_expansion",
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(
                cassette,
                [seed, (rejected_use, rejected_result), recovered],
            )
            trace = build_query_plan_trace(
                cassette,
                run_id="run-recovered",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertEqual(len(trace["calls"]), 2)
        self.assertTrue(quality_scoreable_with_pre_search_rejections(trace))
        summary = summarize_query_plan_traces([trace])
        self.assertEqual(
            summary["quality_eligibility_counts"][
                "scoreable_with_pre_search_rejections"
            ],
            1,
        )
        self.assertEqual(summary["protocol_status_counts"]["invalid"], 1)
        self.assertEqual(summary["quality_eligibility_counts"]["ineligible"], 0)
        self.assertEqual(summary["explicit_verified_calls"], 2)
        self.assertEqual(summary["mean_calls_before_stopping"], 3.0)
        self.assertIsNone(_query_plan_evaluator_invalid_reason(None, trace))

    def test_parser_rejections_with_host_seed_and_verified_expansion_remain_scoreable(self):
        invalid_variants = [{"kind": "synonym", "text": "graduation ceremony"}]
        rejected_use, rejected_result = self._call(
            "kg-1",
            variants=invalid_variants,
            stage="semantic_expansion",
        )
        rejected_result["is_error"] = True
        rejected_result["content"] = stable_json(
            {
                "error": {
                    "code": "invalid_args",
                    "category": "user_error",
                    "detail": "KgRecall lexical_plan 非法: unsupported variant kind",
                    "recoverable": True,
                }
            }
        )
        recovered = self._call(
            "kg-2",
            variants=[
                {"kind": "alias", "text": "commencement"},
                {"kind": "paraphrase", "text": "attended graduation events"},
            ],
            stage="semantic_expansion",
            hits=(11,),
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(
                cassette,
                [(rejected_use, rejected_result), recovered],
            )
            trace = build_query_plan_trace(
                cassette,
                run_id="run-host-seed-parser-recovery",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertEqual([call["call_index"] for call in trace["calls"]], [1])
        self.assertRegex(
            trace["invalid_reasons"][0],
            r"^call 0: host rejected lexical plan before search \(parser\): ",
        )
        self.assertFalse(quality_scoreable_with_pre_search_rejections(trace))
        self.assertTrue(
            quality_scoreable_with_pre_search_rejections(
                trace,
                host_recall_satisfied=True,
            )
        )
        self.assertIsNotNone(_query_plan_evaluator_invalid_reason(None, trace))
        self.assertIsNone(
            _query_plan_evaluator_invalid_reason({"status": "injected"}, trace)
        )
        summary = summarize_query_plan_traces(
            [trace],
            host_recall_satisfied=[True],
        )
        self.assertEqual(summary["protocol_status_counts"]["invalid"], 1)
        self.assertEqual(
            summary["quality_eligibility_counts"][
                "scoreable_with_pre_search_rejections"
            ],
            1,
        )

    def test_parser_rejection_without_verified_host_or_seed_fails_closed(self):
        rejected_use, rejected_result = self._call(
            "kg-1",
            variants=[{"kind": "synonym", "text": "needle synonym"}],
            stage="semantic_expansion",
        )
        rejected_result["is_error"] = True
        rejected_result["content"] = stable_json(
            {
                "error": {
                    "code": "invalid_args",
                    "category": "user_error",
                    "detail": "KgRecall lexical_plan 非法: unsupported variant kind",
                    "recoverable": True,
                }
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [(rejected_use, rejected_result)])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-parser-only",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertEqual(trace["calls"], [])
        self.assertFalse(quality_scoreable_with_pre_search_rejections(trace))
        self.assertRegex(
            _query_plan_evaluator_invalid_reason(None, trace) or "",
            "query-plan trace invalid",
        )

    def test_parser_rejection_envelope_cannot_wrap_a_valid_plan(self):
        rejected_use, rejected_result = self._call(
            "kg-1",
            variants=[{"kind": "exact", "text": "valid seed"}],
        )
        rejected_result["is_error"] = True
        rejected_result["content"] = stable_json(
            {
                "error": {
                    "code": "invalid_args",
                    "category": "user_error",
                    "detail": "KgRecall lexical_plan 非法: forged parser stage",
                    "recoverable": True,
                }
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [(rejected_use, rejected_result)])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-parser-envelope-mismatch",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )

        self.assertEqual(
            trace["invalid_reasons"],
            ["call 0: parser rejection envelope contradicts a valid lexical plan"],
        )
        self.assertFalse(
            quality_scoreable_with_pre_search_rejections(
                trace,
                host_recall_satisfied=True,
            )
        )

    def test_rejected_call_indices_must_exactly_cover_unsuccessful_calls(self):
        trace = {
            "schema_version": "metacodes-memory-query-plan-trace-v1",
            "run_id": "run-index-gap",
            "arm": "tinykg_lexical",
            "memory_backend": "tinykg_integrated",
            "kg_recall_count": 3,
            "status": "invalid",
            "invalid_reasons": [
                "call 1: host rejected lexical plan before search (ledger)"
            ],
            "calls": [],
        }
        self.assertFalse(
            quality_scoreable_with_pre_search_rejections(
                trace,
                host_recall_satisfied=True,
            )
        )

    def test_arbitrary_recoverable_tool_error_cannot_keep_quality_scoreable(self):
        seed = self._call(
            "kg-1",
            variants=[{"kind": "exact", "text": "needle"}],
            hits=(7,),
        )
        failed_use, failed_result = self._call(
            "kg-2",
            variants=[
                {"kind": "alias", "text": "needle alias"},
                {"kind": "mechanism", "text": "needle mechanism"},
            ],
            stage="semantic_expansion",
        )
        failed_result["is_error"] = True
        failed_result["content"] = stable_json(
            {
                "error": {
                    "code": "invalid_args",
                    "category": "user_error",
                    "detail": "some other recoverable failure",
                    "recoverable": True,
                }
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [seed, (failed_use, failed_result)])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-arbitrary-error",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )

        self.assertEqual(trace["status"], "invalid")
        self.assertFalse(quality_scoreable_with_pre_search_rejections(trace))
        summary = summarize_query_plan_traces([trace])
        self.assertEqual(summary["protocol_status_counts"]["invalid"], 1)
        self.assertEqual(summary["quality_eligibility_counts"]["ineligible"], 1)
        self.assertRegex(
            _query_plan_evaluator_invalid_reason(None, trace) or "",
            "query-plan trace invalid",
        )

    def test_missing_receipt_and_plan_sha_drift_are_invalid(self):
        variants = [{"kind": "exact", "text": "needle"}]
        for mutation, expected in (("missing", "expected an object"), ("drift", "plan_sha256")):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                cassette = Path(directory)
                tool_use, tool_result = self._call("kg-1", variants=variants, hits=(7,))
                payload = json.loads(tool_result["content"])
                if mutation == "missing":
                    payload.pop("lexical_query_plan")
                else:
                    payload["lexical_query_plan"]["plan_sha256"] = "0" * 64
                tool_result["content"] = stable_json(payload)
                self._write_requests(cassette, [(tool_use, tool_result)])
                trace = build_query_plan_trace(
                    cassette,
                    run_id=f"run-{mutation}",
                    arm="tinykg_lexical",
                    memory_backend="tinykg",
                )
                self.assertEqual(trace["status"], "invalid")
                self.assertRegex(trace["invalid_reasons"][0], expected)
                self.assertFalse(quality_scoreable_with_pre_search_rejections(trace))

    def test_missing_seen_progression_is_invalid(self):
        variants = [
            {"kind": "paraphrase", "text": "needle alias"},
            {"kind": "mechanism", "text": "needle mechanism"},
        ]
        first = self._call(
            "kg-1",
            variants=variants,
            variant_index=0,
            seen=(),
            hits=(7,),
            stage="semantic_expansion",
        )
        omitted = self._call(
            "kg-2",
            variants=variants,
            variant_index=1,
            seen=(),
            hits=(11,),
            stage="semantic_expansion",
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [first, omitted])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-stale",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )
            self.assertEqual(trace["status"], "invalid")
            self.assertRegex(trace["invalid_reasons"][0], "prior hits")
            self.assertFalse(quality_scoreable_with_pre_search_rejections(trace))

    def test_sidecar_tamper_and_missing_fail_closed_when_bound(self):
        variants = [{"kind": "exact", "text": "needle"}]
        call = self._call("kg-1", variants=variants, hits=(7,))
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [call])
            with self.assertRaisesRegex(ValidationError, "required query-plan.json is missing"):
                load_and_verify_query_plan_sidecar(
                    cassette,
                    run_id="run-1",
                    arm="tinykg_lexical",
                    memory_backend="tinykg",
                    required=True,
                    where="test trace",
                )
            trace = build_query_plan_trace(
                cassette,
                run_id="run-1",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )
            tampered = copy.deepcopy(trace)
            tampered["calls"][0]["new_hit_count"] = 0
            (cassette / SIDECAR_NAME).write_text(
                stable_json(tampered) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValidationError, "does not match raw provider requests"):
                load_and_verify_query_plan_sidecar(
                    cassette,
                    run_id="run-1",
                    arm="tinykg_lexical",
                    memory_backend="tinykg",
                    required=True,
                    where="test trace",
                )

    def test_non_tinykg_trace_is_explicitly_not_applicable(self):
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            (cassette / "req-001.json").write_text(
                json.dumps({"messages": []}) + "\n",
                encoding="utf-8",
            )
            trace = build_query_plan_trace(
                cassette,
                run_id="run-control",
                arm="no_memory",
                memory_backend="none",
            )
            self.assertEqual(trace["status"], "not_applicable")
            summary = summarize_query_plan_traces([None, trace])
            self.assertEqual(
                summary["protocol_status_counts"]["legacy_unavailable"], 1
            )
            self.assertEqual(summary["protocol_status_counts"]["not_applicable"], 1)

    def test_verified_host_recall_only_covers_missing_explicit_call(self):
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            (cassette / "req-001.json").write_text(
                json.dumps({"messages": []}) + "\n",
                encoding="utf-8",
            )
            trace = build_query_plan_trace(
                cassette,
                run_id="run-host-recall",
                arm="tinykg_lexical",
                memory_backend="tinykg_integrated",
            )
            self.assertEqual(trace["status"], "invalid")
            summary = summarize_query_plan_traces(
                [trace],
                host_recall_satisfied=[True],
            )
            self.assertEqual(
                summary["quality_eligibility_counts"]["host_recall_satisfied"], 1
            )
            self.assertEqual(summary["protocol_status_counts"]["invalid"], 1)
            self.assertEqual(summary["quality_eligibility_counts"]["ineligible"], 0)
            self.assertEqual(
                summary["rollout_status"][0]["protocol_status"],
                "invalid",
            )

    def test_host_recall_cannot_launder_malformed_explicit_plan(self):
        variants = [{"kind": "exact", "text": "needle"}]
        forged = self._call(
            "kg-1",
            variants=variants,
            hits=(7,),
            count_override=(0, 0),
        )
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            self._write_requests(cassette, [forged])
            trace = build_query_plan_trace(
                cassette,
                run_id="run-forged-host",
                arm="tinykg_lexical",
                memory_backend="tinykg",
            )
            summary = summarize_query_plan_traces(
                [trace],
                host_recall_satisfied=[True],
            )
            self.assertEqual(summary["protocol_status_counts"]["invalid"], 1)
            self.assertEqual(summary["quality_eligibility_counts"]["ineligible"], 1)
            self.assertEqual(
                summary["quality_eligibility_counts"]["host_recall_satisfied"], 0
            )

    def test_host_recall_vector_must_align_with_traces(self):
        with self.assertRaisesRegex(ValidationError, "status length mismatch"):
            summarize_query_plan_traces([], host_recall_satisfied=[True])

    def test_non_tinykg_trace_cannot_claim_host_recall(self):
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            (cassette / "req-001.json").write_text(
                json.dumps({"messages": []}) + "\n",
                encoding="utf-8",
            )
            trace = build_query_plan_trace(
                cassette,
                run_id="run-control",
                arm="no_memory",
                memory_backend="none",
            )
            with self.assertRaisesRegex(ValidationError, "non-TinyKG"):
                summarize_query_plan_traces(
                    [trace],
                    host_recall_satisfied=[True],
                )


if __name__ == "__main__":
    unittest.main()
