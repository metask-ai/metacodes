import copy
import hashlib
import os
import tempfile
import unittest
from pathlib import Path

from scripts.eval.memory_failed_run_analysis import (
    ANALYSIS_SOURCE_FILES,
    INPUT_DIGEST_FIELDS,
    OUTPUT_DIGEST_FILES,
    SCHEMA_VERSION,
    _load_failed_candidate,
    _prepare_output_directory,
    rebind_runtime_receipt,
    repair_observations,
    verify_reanalysis_bundle,
)
from scripts.eval.memory_query_plan import (
    LEXICAL_PLAN_SCHEMA_VERSION,
    MULTIPLE_DISTINCT_SEED_PLANS_REASON,
    QUERY_PLAN_INVALID_PREFIX,
    TRACE_SCHEMA_VERSION,
)
from scripts.eval.memory_agent_runtime import _query_plan_evaluator_invalid_reason
from scripts.eval.model import ValidationError
from scripts.eval.model import stable_json


def call(index, plan, query):
    return {
        "call_index": index,
        "schema_version": LEXICAL_PLAN_SCHEMA_VERSION,
        "plan_sha256": plan,
        "variants_sha256": str(index + 3) * 64,
        "intent": "fact_lookup",
        "stage": "seed",
        "variant_index": 0,
        "variant_count": 1,
        "variant_kind": "exact",
        "query": query,
        "seen_node_count": 0,
        "seen_state_verified": True,
        "ledger_scope": "agent_run_explicit",
        "new_hit_count": 0,
        "repeated_hit_count": 0,
    }


class FailedMemoryRunAnalysisTest(unittest.TestCase):
    def test_safe_pre_search_rejection_does_not_reclassify_quality(self):
        observation = {
            "evaluator": {
                "status": "ready",
                "invalid_reason": None,
                "deterministic_success": True,
            },
            "retrieval": {
                "query_variants": [{"kind": "exact", "text": "needle"}]
            },
        }
        trace = {
            "schema_version": TRACE_SCHEMA_VERSION,
            "run_id": "run-recovered",
            "arm": "tinykg_lexical",
            "memory_backend": "tinykg_integrated",
            "kg_recall_count": 2,
            "status": "invalid",
            "invalid_reasons": [
                "call 1: host rejected lexical plan before search (ledger)"
            ],
            "calls": [call(0, "a" * 64, "needle")],
        }

        repaired, changes, host_satisfied = repair_observations(
            [observation],
            [
                {
                    "run_id": "run-recovered",
                    "case_id": "case-recovered",
                    "arm": "tinykg_lexical",
                    "scoped_recall": None,
                }
            ],
            [trace],
        )

        self.assertEqual(repaired, [observation])
        self.assertEqual(changes, [])
        self.assertEqual(host_satisfied, [False])

    def test_host_seeded_parser_recovery_matches_live_quality_decision(self):
        observation = {
            "evaluator": {
                "status": "ready",
                "invalid_reason": None,
                "deterministic_success": True,
            },
            "retrieval": {
                "query_variants": [
                    {"kind": "semantic", "text": "graduation commencement"}
                ]
            },
        }
        scoped_recall = {"status": "injected"}
        recovered_call = call(4, "a" * 64, "graduation commencement")
        recovered_call.update(
            {
                "stage": "semantic_expansion",
                "variant_count": 2,
                "variant_kind": "paraphrase",
                "new_hit_count": 3,
            }
        )
        trace = {
            "schema_version": TRACE_SCHEMA_VERSION,
            "run_id": "run-host-parser-recovery",
            "arm": "tinykg_lexical",
            "memory_backend": "tinykg_integrated",
            "kg_recall_count": 5,
            "status": "invalid",
            "invalid_reasons": [
                "call 0: host rejected lexical plan before search (parser): unsupported kind",
                "call 1: host rejected lexical plan before search (parser): invalid expansion shape",
                "call 2: host rejected lexical plan before search (parser): unsupported kind",
                "call 3: host rejected lexical plan before search (ledger)",
            ],
            "calls": [recovered_call],
        }

        repaired, changes, host_satisfied = repair_observations(
            [observation],
            [
                {
                    "run_id": "run-host-parser-recovery",
                    "case_id": "case-host-parser-recovery",
                    "arm": "tinykg_lexical",
                    "scoped_recall": scoped_recall,
                }
            ],
            [trace],
        )

        self.assertIsNone(
            _query_plan_evaluator_invalid_reason(scoped_recall, trace)
        )
        self.assertEqual(repaired, [observation])
        self.assertEqual(changes, [])
        self.assertEqual(host_satisfied, [True])

    def test_repair_marks_only_protocol_invalid_row_and_preserves_seed_shape(self):
        observations = [
            {
                "evaluator": {
                    "status": "ready",
                    "invalid_reason": None,
                    "deterministic_success": True,
                },
                "retrieval": {
                    "query_variants": [
                        {"kind": "exact", "text": "first"},
                        {"kind": "exact", "text": "second"},
                    ]
                },
            },
            {
                "evaluator": {
                    "status": "ready",
                    "invalid_reason": None,
                    "deterministic_success": True,
                },
                "retrieval": {"query_variants": []},
            },
        ]
        rollouts = [
            {"run_id": "run-bad", "case_id": "case-bad", "arm": "tinykg_lexical", "scoped_recall": None},
            {"run_id": "run-host", "case_id": "case-host", "arm": "tinykg_lexical", "scoped_recall": {"status": "injected"}},
        ]
        traces = [
            {
                "schema_version": TRACE_SCHEMA_VERSION,
                "run_id": "run-bad",
                "arm": "tinykg_lexical",
                "memory_backend": "tinykg_integrated",
                "kg_recall_count": 2,
                "status": "invalid",
                "invalid_reasons": [MULTIPLE_DISTINCT_SEED_PLANS_REASON],
                "calls": [
                    call(0, "a" * 64, "first"),
                    call(1, "b" * 64, "second"),
                ],
            },
            {
                "schema_version": TRACE_SCHEMA_VERSION,
                "run_id": "run-host",
                "arm": "tinykg_lexical",
                "memory_backend": "tinykg_integrated",
                "kg_recall_count": 0,
                "status": "invalid",
                "invalid_reasons": ["TinyKG backend executed no KgRecall"],
                "calls": [],
            },
        ]

        repaired, changes, host_satisfied = repair_observations(
            observations, rollouts, traces
        )

        self.assertEqual([change["sequence"] for change in changes], [0])
        self.assertEqual(changes[0]["classification"], "newly_invalid")
        self.assertEqual(host_satisfied, [False, True])
        self.assertEqual(
            repaired[0]["evaluator"]["invalid_reason"],
            QUERY_PLAN_INVALID_PREFIX + MULTIPLE_DISTINCT_SEED_PLANS_REASON,
        )
        self.assertIsNone(repaired[0]["evaluator"]["deterministic_success"])
        self.assertEqual(
            [variant["kind"] for variant in repaired[0]["retrieval"]["query_variants"]],
            ["exact", "exact"],
        )
        self.assertEqual(repaired[1], observations[1])
        self.assertEqual(observations[0]["evaluator"]["status"], "ready")

    def test_runtime_rebinding_is_derived_and_does_not_mutate_candidate(self):
        candidate = {
            "observations_sha256": "0" * 64,
            "rollouts": [{"observation_sha256": "1" * 64}],
        }
        original = copy.deepcopy(candidate)
        rebound = rebind_runtime_receipt(candidate, [{"row": 1}])
        self.assertEqual(candidate, original)
        self.assertNotEqual(rebound["observations_sha256"], candidate["observations_sha256"])
        self.assertNotEqual(
            rebound["rollouts"][0]["observation_sha256"],
            candidate["rollouts"][0]["observation_sha256"],
        )

    def test_output_must_not_overlap_immutable_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "run"
            run.mkdir()
            with self.assertRaisesRegex(ValidationError, "must not overlap"):
                _prepare_output_directory(run / "analysis", run.resolve())
            self.assertFalse((run / "analysis").exists())

    def test_failed_observation_hash_tamper_stops_before_artifact_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            observations = b'{"row":1}\n'
            candidate = {
                "schema_version": "metacodes-memory-runtime-validation-failure-v1",
                "status": "invalid",
                "classification": "post-run-runtime-receipt-validation",
                "error_type": "ValidationError",
                "error_sha256": "a" * 64,
                "candidate_runtime_receipt": {"quality_evidence": False},
            }
            candidate_raw = (stable_json(candidate) + "\n").encode()
            (run / "failed-validation-observations.jsonl").write_bytes(observations)
            (run / "failed-validation-runtime-candidate.json").write_bytes(candidate_raw)
            diagnostic = {
                "schema_version": "metacodes-memory-runtime-validation-failure-v1",
                "status": "invalid",
                "classification": "post-run-runtime-receipt-validation",
                "error_type": "ValidationError",
                "error_sha256": "a" * 64,
                "observations_file": "failed-validation-observations.jsonl",
                "observations_sha256": "0" * 64,
                "runtime_candidate_file": "failed-validation-runtime-candidate.json",
                "runtime_candidate_sha256": hashlib.sha256(candidate_raw).hexdigest(),
            }
            (run / "failed-validation-diagnostic.json").write_text(
                stable_json(diagnostic) + "\n"
            )
            with self.assertRaisesRegex(ValidationError, "SHA-256"):
                _load_failed_candidate(run)

    def test_analysis_bundle_verifier_rejects_output_tamper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            payloads = {}
            for field, name in OUTPUT_DIGEST_FILES.items():
                if name == "reanalysis-report.json":
                    value = {
                        "schema_version": SCHEMA_VERSION,
                        "status": "analysis_only",
                        "quality_evidence": False,
                        "promotion": False,
                        "provider_requests_during_reanalysis": 0,
                        "paid_retry_performed": False,
                        "changed_sequences": [],
                        "newly_invalid_sequences": [],
                        "reprojected_invalid_sequences": [],
                        "query_plan_invalid_sequences": [],
                    }
                    payload = (stable_json(value) + "\n").encode()
                elif name == "derived-runtime-view.json":
                    payload = (
                        stable_json(
                            {
                                "schema_version": SCHEMA_VERSION,
                                "status": "analysis_only",
                                "canonical_runtime_receipt": False,
                                "source_candidate_sha256": "a" * 64,
                                "derived_runtime_view": {},
                            }
                        )
                        + "\n"
                    ).encode()
                else:
                    payload = b"fixture\n"
                path = root / name
                path.write_bytes(payload)
                os.chmod(path, 0o600)
                payloads[field] = hashlib.sha256(payload).hexdigest()
            receipt = {
                "schema_version": SCHEMA_VERSION,
                "status": "analysis_only",
                "quality_evidence": False,
                "promotion": False,
                "provider_requests_during_reanalysis": 0,
                "paid_retry_performed": False,
                "inputs": {field: "a" * 64 for field in INPUT_DIGEST_FIELDS},
                "analysis_sources": {
                    field: "b" * 64 for field in ANALYSIS_SOURCE_FILES
                },
                "changed_sequences": [],
                "newly_invalid_sequences": [],
                "reprojected_invalid_sequences": [],
                "query_plan_invalid_sequences": [],
                "outputs": payloads,
            }
            receipt_path = root / "reanalysis-receipt.json"
            receipt_path.write_text(stable_json(receipt) + "\n")
            os.chmod(receipt_path, 0o600)
            verify_reanalysis_bundle(root)
            unexpected = root / "raw-provider-cassette.json"
            unexpected.write_text("must not be bundled\n")
            with self.assertRaisesRegex(ValidationError, "allowlist"):
                verify_reanalysis_bundle(root)
            unexpected.unlink()
            (root / "reanalysis-report.md").write_text("tampered\n")
            with self.assertRaisesRegex(ValidationError, "SHA-256"):
                verify_reanalysis_bundle(root)


if __name__ == "__main__":
    unittest.main()
