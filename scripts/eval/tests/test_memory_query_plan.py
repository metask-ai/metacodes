import copy
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.memory_query_plan import (
    SIDECAR_NAME,
    _plan_fingerprint,
    build_query_plan_trace,
    load_and_verify_query_plan_sidecar,
    summarize_query_plan_traces,
)
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
    ):
        plan_sha = _plan_fingerprint(intent, stage, variants, None)
        tool_input = {
            "query": variants[variant_index]["text"],
            "lexical_plan": {
                "schema_version": "lexical-query-plan-v1",
                "intent": intent,
                "stage": stage,
                "variants": variants,
                "variant_index": variant_index,
                "seen_node_ids": list(seen),
            },
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
                "schema_version": "lexical-query-plan-v1",
                "plan_sha256": plan_sha,
                "intent": intent,
                "stage": stage,
                "variant_index": variant_index,
                "variant_count": len(variants),
                "variant_kind": variants[variant_index]["kind"],
                "seen_node_count": len(seen),
                "seen_state_verified": True,
                "ledger_scope": "agent_run_plan",
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
            self.assertEqual(summary["status_counts"]["legacy_unavailable"], 1)
            self.assertEqual(summary["status_counts"]["not_applicable"], 1)

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
            self.assertEqual(summary["status_counts"]["host_recall_satisfied"], 1)
            self.assertEqual(summary["status_counts"]["invalid"], 0)
            self.assertEqual(
                summary["rollout_status"][0]["trace_status"],
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
            self.assertEqual(summary["status_counts"]["invalid"], 1)
            self.assertEqual(summary["status_counts"]["host_recall_satisfied"], 0)

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
