import contextlib
import copy
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.cli import main
from scripts.eval.memory_benchmark import (
    PROTOCOL_ID,
    render_memory_markdown,
    summarize_memory,
    validate_memory_row,
)
from scripts.eval.memory_query_plan import (
    MULTIPLE_DISTINCT_SEED_PLANS_REASON,
    QUERY_PLAN_INVALID_PREFIX,
)
from scripts.eval.model import ValidationError


def memory_row(
    *,
    benchmark="multihop_retrieval",
    arm="tinykg_lexical",
    split="test",
    case_id="case-1",
    success=True,
    retrieved=("e1", "e2"),
    verified=("e1",),
    write_mode="read_only",
):
    enabled = arm != "no_memory"
    expected = ["e1", "e2"] if benchmark == "multihop_retrieval" else ["e1"]
    if arm == "no_memory":
        write_mode = "disabled"
        retrieved = ()
        verified = ()
    return {
        "schema_version": 2,
        "protocol_id": PROTOCOL_ID,
        "benchmark": benchmark,
        "case_id": case_id,
        "sequence": 0,
        "trial": 0,
        "arm": arm,
        "split": split,
        "identity": {
            "dataset_id": "fixture",
            "dataset_sha256": "a" * 64,
            "adapter_id": "fixture-adapter",
            "adapter_revision": "fixture-adapter-v1",
            "split_seed": 20260806,
            "manifest_sha256": "d" * 64,
            "runtime_receipt_sha256": "1" * 64,
            "task_fingerprint": "b" * 64,
            "model_id": "fixture-model",
            "model_fingerprint": "e" * 64,
            "harness_revision": "fixture-revision",
            "arm_fingerprint": "f" * 64,
            "grader_fingerprint": "c" * 64,
            "observation_sha256": "0" * 64,
        },
        "execution": {"status": "completed", "invalid_reason": None},
        "evaluator": {"status": "ready", "invalid_reason": None},
        "outcome": {
            "status": "pass" if success else "fail",
            "success": success,
            "prediction": "William Shakespeare" if success else "Christopher Marlowe",
            "gold_answers": (
                ["Shakespeare", "William Shakespeare"]
                if benchmark != "procedural_transfer"
                else []
            ),
            "deterministic": True,
        },
        "retrieval": {
            "enabled": enabled,
            "k": 10 if enabled else 0,
            "hop_count": 2 if enabled else 0,
            "query_variants": (
                [
                    {"kind": "exact", "text": "author of Hamlet"},
                    {"kind": "semantic", "text": "Hamlet playwright"},
                ]
                if enabled
                else []
            ),
            "expected_evidence_ids": expected,
            "retrieved_evidence_ids": list(retrieved),
            "verified_evidence_ids": list(verified),
            "graph_truncated": False,
        },
        "memory": {
            "write_mode": write_mode,
            "exposed_tokens": 80 if enabled else 0,
            "internal_tokens": 25 if enabled else 0,
            "inserted_nodes": 4 if write_mode == "online" else 0,
            "active_nodes": 4 if enabled else 0,
            "provenance_links": 4 if enabled else 0,
            "abstraction_nodes": 4 if enabled else 0,
            "abstraction_nodes_with_provenance": 4 if enabled else 0,
            "candidate_fanout": 3.0 if enabled else 0.0,
        },
        "graph": {
            "revision": "fixture-graph-r1",
            "text_stale": False,
            "retrieval_excluded_nodes": 0,
            "contradiction_edges": 0,
        },
        "governance": {
            "stale_candidates": 1 if enabled else 0,
            "stale_rejected": 1 if enabled else 0,
            "contradictory_candidates": 1 if enabled else 0,
            "contradictory_rejected": 1 if enabled else 0,
            "retrieval_excluded_returned": 0,
            "provenance_missing_returned": 0,
            "offline_write_events": 0,
        },
        "cost": {"cost_usd": 0.01, "wall_time_ms": 100.0},
        "trajectory": {"model_requests": 1, "tool_calls": 2, "tool_errors": 0, "turns": 2},
    }


class MemoryBenchmarkTest(unittest.TestCase):
    def test_multihop_metrics_keep_answer_evidence_cost_and_governance_separate(self):
        baseline = memory_row(arm="no_memory", success=False)
        candidate = memory_row()
        summary = summarize_memory([baseline, candidate])
        group = summary["groups"]["multihop_retrieval/tinykg_lexical/test"]
        self.assertEqual(group["outcome_success_rate"], 1.0)
        self.assertEqual(group["answer_exact_match"], 1.0)
        self.assertEqual(group["answer_f1"], 1.0)
        self.assertEqual(group["evidence_recall_at_k"], 1.0)
        self.assertEqual(group["verified_evidence_recall_at_k"], 0.5)
        self.assertEqual(group["evidence_precision_at_k"], 1.0)
        self.assertEqual(group["provenance_coverage"], 1.0)
        self.assertEqual(group["stale_rejection_rate"], 1.0)
        self.assertGreater(
            summary["plugmem_style_density_bits_per_exposed_token"]["tinykg_lexical"],
            0.0,
        )
        self.assertIn("PMI density is secondary", render_memory_markdown(summary))

    def test_query_protocol_rejects_more_than_four_semantic_variants(self):
        row = memory_row()
        row["retrieval"]["query_variants"].extend(
            {"kind": "semantic", "text": f"variant {index}"}
            for index in range(4)
        )
        with self.assertRaisesRegex(ValidationError, "at most four semantic variants"):
            validate_memory_row(row)

    def test_multiple_seed_violation_is_audited_only_when_evaluator_invalid(self):
        row = memory_row()
        row["retrieval"]["query_variants"] = [
            {"kind": "exact", "text": "rollback ticket protocol"},
            {"kind": "exact", "text": "rollback registry Python"},
        ]
        with self.assertRaisesRegex(ValidationError, "exactly one exact query"):
            validate_memory_row(row)

        row["evaluator"] = {
            "status": "invalid",
            "invalid_reason": QUERY_PLAN_INVALID_PREFIX
            + MULTIPLE_DISTINCT_SEED_PLANS_REASON,
        }
        row["outcome"]["status"] = "unscored"
        row["outcome"]["success"] = None
        group = summarize_memory([row])["groups"][
            "multihop_retrieval/tinykg_lexical/test"
        ]
        self.assertEqual(group["invalid_rows"], 1)
        self.assertEqual(group["scored_rows"], 0)

        row["evaluator"]["invalid_reason"] = "unrelated evaluator failure"
        with self.assertRaisesRegex(ValidationError, "exactly one exact query"):
            validate_memory_row(row)

    def test_verified_evidence_must_have_been_retrieved(self):
        row = memory_row(verified=("not-retrieved",))
        with self.assertRaisesRegex(ValidationError, "subset of retrieved evidence"):
            validate_memory_row(row)

    def test_offline_procedural_rows_fail_closed_on_write_leakage(self):
        row = memory_row(
            benchmark="procedural_transfer",
            split="offline",
            case_id="offline-1",
        )
        row["governance"]["offline_write_events"] = 1
        with self.assertRaisesRegex(ValidationError, "offline write leakage"):
            validate_memory_row(row)

    def test_read_only_and_offline_rows_cannot_claim_inserted_nodes(self):
        row = memory_row(
            benchmark="procedural_transfer",
            split="offline",
            case_id="offline-1",
        )
        row["memory"]["inserted_nodes"] = 1
        with self.assertRaisesRegex(ValidationError, "must not insert nodes"):
            validate_memory_row(row)

    def test_disabled_retrieval_cannot_carry_evidence(self):
        row = memory_row(arm="no_memory", success=False, write_mode="disabled")
        row["retrieval"]["retrieved_evidence_ids"] = ["e1"]
        with self.assertRaisesRegex(ValidationError, "must not report retrieved"):
            validate_memory_row(row)

    def test_no_memory_arm_cannot_enable_retrieval_or_writes(self):
        row = memory_row(arm="no_memory", success=False, write_mode="disabled")
        row["retrieval"]["enabled"] = True
        row["retrieval"]["k"] = 10
        row["retrieval"]["hop_count"] = 1
        row["retrieval"]["query_variants"] = [
            {"kind": "exact", "text": "forbidden retrieval"}
        ]
        with self.assertRaisesRegex(ValidationError, "no_memory must disable retrieval"):
            validate_memory_row(row)

        row = memory_row(arm="no_memory", success=False, write_mode="disabled")
        row["memory"]["write_mode"] = "online"
        with self.assertRaisesRegex(ValidationError, "no_memory must disable memory writes"):
            validate_memory_row(row)

    def test_empty_prediction_is_a_scored_failure(self):
        row = memory_row(success=False)
        row["outcome"]["prediction"] = ""
        validate_memory_row(row)
        group = summarize_memory([row])["groups"]["multihop_retrieval/tinykg_lexical/test"]
        self.assertEqual(group["scored_rows"], 1)
        self.assertEqual(group["outcome_success_rate"], 0.0)

    def test_procedural_transfer_reports_gain_over_cold_start(self):
        cold = memory_row(
            benchmark="procedural_transfer",
            arm="no_memory",
            split="offline",
            case_id="offline-1",
            success=False,
        )
        candidate = memory_row(
            benchmark="procedural_transfer",
            arm="tinykg_lexical",
            split="offline",
            case_id="offline-1",
            success=True,
        )
        online = memory_row(
            benchmark="procedural_transfer",
            arm="tinykg_lexical",
            split="online",
            case_id="online-1",
            success=True,
            write_mode="online",
        )
        summary = summarize_memory([cold, candidate, online])
        transfer = summary["procedural_transfer"]["tinykg_lexical"]
        self.assertEqual(transfer["online_success_rate"], 1.0)
        self.assertEqual(transfer["offline_success_rate"], 1.0)
        self.assertEqual(transfer["cold_start_success_rate"], 0.0)
        self.assertEqual(transfer["offline_gain_over_cold_start"], 1.0)

    def test_invalid_execution_is_audited_but_not_scored(self):
        row = memory_row()
        row["execution"] = {"status": "invalid", "invalid_reason": "fixture unavailable"}
        row["outcome"] = {
            "status": "unscored",
            "success": None,
            "prediction": "<invalid>",
            "gold_answers": ["William Shakespeare"],
            "deterministic": True,
        }
        group = summarize_memory([row])["groups"]["multihop_retrieval/tinykg_lexical/test"]
        self.assertEqual(group["valid_rows"], 0)
        self.assertEqual(group["invalid_rows"], 1)
        self.assertEqual(group["scored_rows"], 0)
        self.assertIsNone(group["outcome_success_rate"])

    def test_evaluator_failure_is_audited_but_not_scored(self):
        row = memory_row()
        row["evaluator"] = {"status": "invalid", "invalid_reason": "grader unavailable"}
        row["outcome"] = {
            "status": "unscored",
            "success": None,
            "prediction": "William Shakespeare",
            "gold_answers": ["William Shakespeare"],
            "deterministic": True,
        }
        group = summarize_memory([row])["groups"]["multihop_retrieval/tinykg_lexical/test"]
        self.assertEqual(group["valid_rows"], 0)
        self.assertEqual(group["invalid_rows"], 1)
        self.assertEqual(group["scored_rows"], 0)

    def test_cli_validates_and_renders_a_smoke_result(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = root / "results.jsonl"
            results.write_text(json.dumps(memory_row(), sort_keys=True) + "\n", encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main(["validate-memory", str(results)]), 0)
            self.assertIn("valid (1 records)", output.getvalue())

            markdown = root / "report.md"
            result_json = root / "report.json"
            self.assertEqual(
                main(
                    [
                        "report-memory",
                        str(results),
                        "--markdown",
                        str(markdown),
                        "--json",
                        str(result_json),
                    ]
                ),
                0,
            )
            self.assertIn("multihop_retrieval/tinykg_lexical/test", markdown.read_text())
            self.assertEqual(json.loads(result_json.read_text())["rows"], 1)


if __name__ == "__main__":
    unittest.main()
