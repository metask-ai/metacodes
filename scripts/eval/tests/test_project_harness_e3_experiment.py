from __future__ import annotations

import json
import math
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.eval.project_harness_e3_experiment import (
    ARMS,
    ANALYSIS_PLAN,
    ABANDONED_EXACT_RECOVERY_CASE_IDS,
    ABANDONED_OBSERVED_CASE_IDS,
    CASES,
    LEGACY_ANALYSIS_PLAN,
    LEGACY_CASES,
    LEGACY_ROLLOUT_SCHEMA,
    LEGACY_SCHEDULE_SEED,
    ROLLOUT_SCHEMA,
    CORRECTION_FAMILY,
    _canonical_sha256,
    _harness_fingerprint,
    _schedule,
    _efficiency_lte,
    _nearest_rank,
    _validate_committed_budget_receipt,
    _validate_execution_contract,
    analyze_journal,
    build_report,
    grade_workspace,
    rollout_schema_for_manifest,
    E3_ALLOWED_TOOLS,
    E3_AUTO_MEMORY_POLICY,
    E3_LONG_HORIZON_ARM,
    E3_ROLLOUT_TIMEOUT_SECONDS,
    E3_DISALLOWED_TOOLS,
    E3Error,
)
from scripts.eval.memory_agent_runtime import PRODUCTION_MODEL_FINGERPRINT
from scripts.eval.memory_budget_journal import JOURNAL_SCHEMA_VERSION, usd_to_microusd
from scripts.eval.memory_replay import (
    PRODUCTION_MODEL_ID,
    PRODUCTION_MODEL_PROVIDER,
    PRODUCTION_PROVIDER_ID,
)


def _record(sequence: int, event: dict) -> bytes:
    return (
        json.dumps(
            {
                "sequence": sequence,
                "session_id": "0123456789abcdef01234567",
                "run_id": "fedcba9876543210fedcba98",
                "event": event,
            },
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


class ProjectHarnessE3ExperimentTest(unittest.TestCase):
    def test_harness_fingerprint_binds_frozen_timeout_and_treatment(self) -> None:
        templates = {
            "templates": {
                "evolved": {"bundle_sha256": "4" * 64, "candidate_id": "5" * 64}
            }
        }
        manifest = {
            "manifest_id": "1" * 64,
            "arms": {
                "evolved_enforced": {
                    "binary": "production_binary",
                    "rule_flavor": "evolved",
                    "actuation": "enforced",
                }
            },
            "artifacts": {
                "production_binary": {"sha256": "2" * 64},
                "kernel": {"sha256": "3" * 64},
            },
            "execution": {"rollout_timeout_seconds": E3_ROLLOUT_TIMEOUT_SECONDS},
            "repository": {"commit": "6" * 40, "dirty": False},
        }
        baseline = _harness_fingerprint(
            manifest,
            "evolved_enforced",
            templates,
            "7" * 64,
        )
        drifted = {
            **manifest,
            "execution": {"rollout_timeout_seconds": E3_ROLLOUT_TIMEOUT_SECONDS - 1},
        }
        self.assertNotEqual(
            baseline,
            _harness_fingerprint(
                drifted,
                "evolved_enforced",
                templates,
                "7" * 64,
            ),
        )

    def test_committed_budget_receipt_binds_authority_identity_and_transition_order(self) -> None:
        execution = {
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "max_rollout_cost_usd": 0.9,
            "max_rollout_metered_tokens": 300_000,
            "max_total_cost_usd": 20.0,
            "max_total_metered_tokens": 5_000_000,
        }
        manifest = {
            "manifest_id": "1" * 64,
            "execution": execution,
            "frozen": "receipt-test",
        }
        expected_run_id = "run:0:case:evolved_enforced"
        harness_fingerprint = "2" * 64
        identity = {
            "run_id": expected_run_id,
            "manifest_sha256": _canonical_sha256(manifest),
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "harness_fingerprint": harness_fingerprint,
            "provider_identity": PRODUCTION_PROVIDER_ID,
            "max_cost_microusd": usd_to_microusd(0.9),
            "max_metered_tokens": 300_000,
        }
        authority = {
            "manifest_sha256": _canonical_sha256(manifest),
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "provider_identity": PRODUCTION_PROVIDER_ID,
            "total_cost_microusd": usd_to_microusd(20.0),
            "total_metered_tokens": 5_000_000,
        }
        journal_id = _canonical_sha256(
            {"schema_version": JOURNAL_SCHEMA_VERSION, "authority": authority}
        )
        receipt = {
            "journal_id": journal_id,
            "journal_revision": 9,
            "journal_head_sha256": "c" * 64,
            "transaction_id": _canonical_sha256(
                {
                    "journal_id": journal_id,
                    "reservation_revision": 7,
                    "identity": identity,
                }
            ),
            "state": "committed",
            "identity_sha256": _canonical_sha256(identity),
            **identity,
            "reservation_revision": 7,
            "reservation_head_sha256": "a" * 64,
            "authorization_revision": 8,
            "authorization_head_sha256": "b" * 64,
            "commit_revision": 9,
            "commit_head_sha256": "c" * 64,
            "actual_cost_microusd": 1234,
            "actual_metered_tokens": 4321,
        }
        _validate_committed_budget_receipt(
            receipt,
            manifest=manifest,
            expected_run_id=expected_run_id,
            expected_harness_fingerprint=harness_fingerprint,
            actual_cost_microusd=1234,
            actual_metered_tokens=4321,
        )
        mutations = (
            ("extra_field", "forged"),
            ("identity_sha256", "0" * 64),
            ("transaction_id", "0" * 64),
            ("journal_id", "0" * 64),
            ("authorization_revision", 9),
            ("commit_revision", 10),
            ("journal_revision", 10),
            ("journal_head_sha256", "d" * 64),
            ("authorization_head_sha256", "a" * 64),
            ("actual_metered_tokens", True),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                tampered = {**receipt, key: value}
                with self.assertRaises(E3Error):
                    _validate_committed_budget_receipt(
                        tampered,
                        manifest=manifest,
                        expected_run_id=expected_run_id,
                        expected_harness_fingerprint=harness_fingerprint,
                        actual_cost_microusd=1234,
                        actual_metered_tokens=4321,
                    )

    def test_execution_contract_rejects_authority_or_identity_drift(self) -> None:
        execution = {
            "provider_identity": PRODUCTION_PROVIDER_ID,
            "model_provider": PRODUCTION_MODEL_PROVIDER,
            "model_id": PRODUCTION_MODEL_ID,
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "allowed_tools": list(E3_ALLOWED_TOOLS),
            "disallowed_tools": list(E3_DISALLOWED_TOOLS),
            "max_output_tokens": 4096,
            "rollout_timeout_seconds": E3_ROLLOUT_TIMEOUT_SECONDS,
            "max_rollout_cost_usd": 0.9,
            "max_rollout_metered_tokens": 300_000,
            "max_total_cost_usd": 20.0,
            "max_total_metered_tokens": 5_000_000,
            "serial_rollouts": True,
            "fresh_home_per_rollout": True,
            "stable_absolute_project_root": True,
            "auto_memory_policy": E3_AUTO_MEMORY_POLICY,
            "long_horizon_arm": E3_LONG_HORIZON_ARM,
        }
        self.assertIs(execution, _validate_execution_contract(execution, 16))
        mutations = (
            ("max_rollout_cost_usd", 0.89),
            ("max_rollout_metered_tokens", 299_999),
            ("max_total_cost_usd", 1000.01),
            ("max_total_cost_usd", math.nan),
            ("max_total_cost_usd", False),
            ("max_total_metered_tokens", 4_800_000),
            ("rollout_timeout_seconds", E3_ROLLOUT_TIMEOUT_SECONDS - 1),
            ("model_provider", "drifted-provider"),
            ("auto_memory_policy", "enabled"),
            ("long_horizon_arm", "tinykg"),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                drifted = {**execution, field: value}
                with self.assertRaises(E3Error):
                    _validate_execution_contract(drifted, 16)

    def test_schedule_balances_every_arm_position(self) -> None:
        schedule = _schedule()
        self.assertEqual(len(ARMS) * len(CASES), len(schedule))
        self.assertEqual(48, len(schedule))
        self.assertEqual(8, sum(case["oracle_class"] == "hazard_recurrence" for case in CASES))
        self.assertEqual(4, sum(case["oracle_class"].startswith("safe_") for case in CASES))
        self.assertEqual({CORRECTION_FAMILY}, {case["correction_family"] for case in CASES})
        self.assertEqual("complete-frozen-schedule-no-early-stop", ANALYSIS_PLAN["stopping_rule"])
        self.assertTrue(ANALYSIS_PLAN["prospective_case_cohort"])
        self.assertEqual(8, ANALYSIS_PLAN["expected_exact_edit_recovery_directions"])
        self.assertEqual(8, ANALYSIS_PLAN["expected_exact_edit_recovery_pre_admits"])
        self.assertEqual(8, ANALYSIS_PLAN["expected_exact_edit_recovery_post_admits"])
        self.assertTrue(
            {case["id"] for case in CASES}.isdisjoint(
                {case["id"] for case in LEGACY_CASES}
            )
        )
        self.assertTrue(
            {case["id"] for case in CASES}.isdisjoint(
                ABANDONED_EXACT_RECOVERY_CASE_IDS
            )
        )
        self.assertEqual(
            {"canonicalize_logging_toml"},
            ABANDONED_OBSERVED_CASE_IDS,
        )
        self.assertEqual(
            48,
            len(_schedule(LEGACY_CASES, LEGACY_SCHEDULE_SEED)),
        )
        self.assertNotEqual(ANALYSIS_PLAN, LEGACY_ANALYSIS_PLAN)
        self.assertEqual(
            ROLLOUT_SCHEMA,
            rollout_schema_for_manifest({"analysis_plan": ANALYSIS_PLAN}),
        )
        self.assertEqual(
            LEGACY_ROLLOUT_SCHEMA,
            rollout_schema_for_manifest({"analysis_plan": LEGACY_ANALYSIS_PLAN}),
        )
        with self.assertRaisesRegex(E3Error, "analysis plan is unknown"):
            rollout_schema_for_manifest({"analysis_plan": {"study_phase": "forged"}})
        for position in range(len(ARMS)):
            self.assertEqual(
                set(ARMS),
                {row["arm"] for row in schedule if row["position"] == position},
            )
            for arm in ARMS:
                self.assertEqual(
                    3,
                    sum(
                        row["arm"] == arm and row["position"] == position
                        for row in schedule
                    ),
                )
        self.assertEqual(list(range(len(schedule))), [row["sequence"] for row in schedule])

    def test_exact_efficiency_helpers_do_not_hide_failed_tasks(self) -> None:
        self.assertEqual(20, _nearest_rank([20, 10, 30], 1, 2))
        self.assertEqual(30, _nearest_rank([20, 10, 30], 95, 100))
        self.assertTrue(_efficiency_lte(240, 12, 120, 4))
        self.assertFalse(_efficiency_lte(361, 12, 120, 4))
        self.assertFalse(_efficiency_lte(1, 0, 1, 1))

    def test_workspace_grader_keeps_task_outcome_separate(self) -> None:
        case = CASES[0]
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            for name, content in case["grader"]["expected_files"].items():
                (workspace / name).write_text(content, encoding="utf-8")
            self.assertTrue(grade_workspace(case, workspace)["passed"])
            (workspace / "extra.txt").write_text("not allowed", encoding="utf-8")
            result = grade_workspace(case, workspace)
            self.assertFalse(result["passed"])
            self.assertEqual(["extra.txt"], result["extra_files"])

    def test_confirmatory_report_prefers_reliable_efficiency_not_raw_speed(self) -> None:
        schedule = _schedule()
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            paths = []
            rows = []
            case_by_id = {case["id"]: case for case in CASES}
            for expected in schedule:
                sequence = int(expected["sequence"])
                case = case_by_id[expected["case_id"]]
                arm = expected["arm"]
                hazard = case["oracle_class"] == "hazard_recurrence"
                evolved = arm == "evolved_enforced"
                governed = arm != "signal_only"
                trustworthy = not hazard or evolved
                request = run_dir / f"request-{case['id']}-{arm}.json"
                request.write_bytes(f"frozen-first-request:{case['id']}\n".encode())
                receipt = run_dir / f"receipt-{sequence:05d}.json"
                receipt.write_text("{}\n", encoding="utf-8")
                paths.append(receipt)
                cost = 20 if evolved else 10
                wall = 150 if evolved else 100
                requests = 6 if evolved else 4
                rows.append(
                    {
                        **expected,
                        "case_id": case["id"],
                        "oracle_class": case["oracle_class"],
                        "horizon_class": case["horizon_class"],
                        "quality_evidence": True,
                        "result": {"stop_reason": "end_turn"},
                        "grader": {"passed": True},
                        "provider_requests": requests,
                        "usage": {
                            "cost_usd": cost / 1_000_000,
                            "wall_time_ms": wall,
                            "input_tokens": 10,
                            "output_tokens": 5,
                            "cache_read_tokens": 20,
                            "cache_write_tokens": 0,
                        },
                        "context_cache": {
                            "cacheable_prefix_sha256": "f" * 64,
                        },
                        "budget_transaction": {"actual_cost_microusd": cost},
                        "artifacts": {"first_request": str(request)},
                        "governance": {
                            "existing_file_write_recurrence": hazard,
                            "existing_file_write_dispatch": hazard and not evolved,
                            "realized_existing_file_write_effect": hazard and not evolved,
                            "trustworthy_task_success": trustworthy,
                            "safe_action_false_intervention": False,
                            "safe_case_intervention": False,
                            "enforced_hazard_blocks": 1 if hazard and evolved else 0,
                            "successful_recovery_after_block": hazard and evolved,
                            "recovery_failed_after_block": False,
                            "repeated_prohibited_attempts_after_block": 0,
                            "settling_observation_events": 4 if hazard and evolved else None,
                            "physical_checker_calls": 1 if governed else 0,
                            "checker_elapsed_ns_max": 10_000_000 if governed else 0,
                            "checker_elapsed_ns_samples": [10_000_000] if governed else [],
                            "exact_edit_recovery_directions": 1 if hazard and evolved else 0,
                            "exact_edit_recovery_pre_admits": 1 if hazard and evolved else 0,
                            # A side-effect-free rejected recovery attempt is
                            # useful control-plane work, not a false
                            # intervention. It remains reported for cost and
                            # settling analysis but must not poison outcome
                            # stability when the exact retry later admits.
                            "exact_edit_recovery_pre_blocks": 1 if hazard and evolved else 0,
                            "exact_edit_recovery_post_admits": 1 if hazard and evolved else 0,
                            "exact_edit_recovery_post_blocks": 0,
                        },
                    }
                )
            manifest = {
                "manifest_id": "1" * 64,
                "cases": list(CASES),
                "schedule": schedule,
                "analysis_plan": ANALYSIS_PLAN,
                "claim_boundary": {"confirmatory": "bounded", "forbidden": "general"},
            }
            with (
                mock.patch(
                    "scripts.eval.project_harness_e3_experiment.validate_manifest",
                    return_value=manifest,
                ),
                mock.patch(
                    "scripts.eval.project_harness_e3_experiment._rollout_paths",
                    return_value=paths,
                ),
                mock.patch(
                    "scripts.eval.project_harness_e3_experiment._reopen_rollout_receipt",
                    side_effect=lambda **kwargs: rows[int(kwargs["expected"]["sequence"])],
                ),
            ):
                report = build_report(
                    run_dir / "manifest.json",
                    run_dir,
                    run_dir,
                )
        self.assertEqual(8, report["paired_trustworthy_success"]["evolved_enforced_improvements"])
        self.assertEqual(0, report["paired_trustworthy_success"]["signal_only_regressions"])
        self.assertLess(report["paired_trustworthy_success"]["exact_mcnemar_p"], 0.05)
        self.assertTrue(report["significant_benefit"])
        self.assertTrue(report["production_preference_supported"])
        self.assertTrue(report["gates"]["cacheable_prefix_equal_within_every_case"])
        self.assertTrue(report["outcome_checks"]["zero_prohibited_hazard_dispatches"])
        self.assertTrue(report["outcome_checks"]["zero_hazard_realized_effects"])
        self.assertEqual(
            30,
            report["arms"]["signal_only"]["cost_microusd_per_trustworthy_success"],
        )
        self.assertEqual(
            20,
            report["arms"]["evolved_enforced"]["cost_microusd_per_trustworthy_success"],
        )
        self.assertEqual(
            150,
            report["arms"]["evolved_enforced"]["wall_ms_per_trustworthy_success"],
        )
        self.assertTrue(all(report["efficiency_checks"].values()))

    def test_signal_journal_distinguishes_dispatch_effect_and_trust(self) -> None:
        project = "1" * 64
        kernel = "2" * 64
        effect = {
            "file_mutation_v2": {
                "mutation": {"change": "changed"},
                "reobservation": {"state": "matched"},
            }
        }
        records = b"".join(
            [
                _record(0, {"run_started": {}}),
                _record(1, {"tool_observation": {"dispatch_started": {
                    "id": "write-1", "requested_name": "Write", "dispatched_name": "Write",
                    "origin": "authoritative", "file_target_state": "regular_existing",
                }}}),
                _record(2, {"tool_observation": {"dispatch_finished": {
                    "id": "write-1", "requested_name": "Write", "dispatched_name": "Write",
                    "origin": "authoritative", "outcome": "succeeded", "effect_valid": True,
                    "effect": effect,
                }}}),
                _record(3, {"run_finished": {"stop_reason": "end_turn"}}),
            ]
        )
        with tempfile.TemporaryDirectory() as temporary:
            journal = Path(temporary) / "tool-observations.jsonl"
            journal.write_bytes(records)
            result = analyze_journal(
                path=journal,
                arm="signal_only",
                oracle_class="hazard_recurrence",
                project_sha256=project,
                kernel_sha256=kernel,
                candidate_id=None,
                task_success=True,
            )
        self.assertTrue(result["existing_file_write_recurrence"])
        self.assertTrue(result["existing_file_write_dispatch"])
        self.assertTrue(result["realized_existing_file_write_effect"])
        self.assertTrue(result["task_success"])
        self.assertFalse(result["trustworthy_task_success"])

    def test_enforced_block_and_edit_recovery_are_distinct_events(self) -> None:
        project = "1" * 64
        kernel = "2" * 64
        candidate = "3" * 64
        batch = {
            "schema_version": "metacodes-project-formal-decision-batch-v4",
            "dispatch_id": "write-1",
            "phase": "pre",
            "actuation": "enforced",
            "file_target_state": "regular_existing",
            "project_sha256": project,
            "bundle_sha256": "4" * 64,
            "bundle_revision": 1,
            "kernel_sha256": kernel,
            "checker_call_sha256": "5" * 64,
            "checker_verdict_sha256": "6" * 64,
            "checker_batch_size": 1,
            "checker_elapsed_ns": 1,
            "checker_bytes": 1,
            "decisions": [{
                "operation": "pre_decision",
                "candidate_id": candidate,
                "result": "block",
                "recovery_action": "edit_existing_file_exact",
                "request_sha256": "7" * 64,
                "verdict_sha256": "8" * 64,
                "checker_failure": None,
            }],
        }
        edit_pre = {
            **batch,
            "dispatch_id": "edit-1",
            "phase": "pre",
            "file_target_state": "regular_existing",
            "decisions": [{
                **batch["decisions"][0],
                "operation": "recovery_pre_decision",
                "result": "admit",
                "recovery_action": "none",
                "request_sha256": "9" * 64,
                "verdict_sha256": "a" * 64,
            }],
        }
        edit_retry_block = {
            **edit_pre,
            "dispatch_id": "edit-retry-1",
            "checker_call_sha256": "f" * 64,
            "checker_verdict_sha256": "0" * 64,
            "decisions": [{
                **edit_pre["decisions"][0],
                "result": "block",
                "recovery_action": "edit_existing_file_exact",
                "request_sha256": "1" * 64,
                "verdict_sha256": "2" * 64,
            }],
        }
        edit_post = {
            **edit_pre,
            "phase": "post",
            "checker_call_sha256": "b" * 64,
            "checker_verdict_sha256": "c" * 64,
            "decisions": [{
                **edit_pre["decisions"][0],
                "operation": "recovery_post_decision",
                "request_sha256": "d" * 64,
                "verdict_sha256": "e" * 64,
            }],
        }
        records = b"".join(
            [
                _record(0, {"run_started": {}}),
                _record(1, {"tool_observation": {"formal_decision_batch": batch}}),
                _record(2, {"tool_observation": {"formal_decision_batch": edit_retry_block}}),
                _record(3, {"tool_observation": {"formal_decision_batch": edit_pre}}),
                _record(4, {"tool_observation": {"dispatch_started": {
                    "id": "edit-1", "requested_name": "Edit", "dispatched_name": "Edit",
                    "origin": "authoritative", "file_target_state": "regular_existing",
                }}}),
                _record(5, {"tool_observation": {"formal_decision_batch": edit_post}}),
                _record(6, {"tool_observation": {"dispatch_finished": {
                    "id": "edit-1", "requested_name": "Edit", "dispatched_name": "Edit",
                    "origin": "authoritative", "outcome": "succeeded", "effect_valid": True,
                    "effect": None,
                }}}),
                _record(7, {"run_finished": {"stop_reason": "end_turn"}}),
            ]
        )
        with tempfile.TemporaryDirectory() as temporary:
            journal = Path(temporary) / "tool-observations.jsonl"
            journal.write_bytes(records)
            result = analyze_journal(
                path=journal,
                arm="evolved_enforced",
                oracle_class="hazard_recurrence",
                project_sha256=project,
                kernel_sha256=kernel,
                candidate_id=candidate,
                task_success=True,
            )
        self.assertTrue(result["formal_block"])
        self.assertTrue(result["enforced_block"])
        self.assertFalse(result["existing_file_write_dispatch"])
        self.assertFalse(result["realized_existing_file_write_effect"])
        self.assertTrue(result["recovery_after_block"])
        self.assertEqual(1, result["exact_edit_recovery_directions"])
        self.assertEqual(1, result["exact_edit_recovery_pre_admits"])
        self.assertEqual(1, result["exact_edit_recovery_pre_blocks"])
        self.assertEqual(1, result["exact_edit_recovery_post_admits"])
        self.assertEqual(1, result["enforced_hazard_blocks"])
        self.assertEqual(0, result["repeated_prohibited_attempts_after_block"])
        self.assertTrue(result["trustworthy_task_success"])


if __name__ == "__main__":
    unittest.main()
