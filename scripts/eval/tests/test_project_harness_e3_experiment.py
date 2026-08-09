from __future__ import annotations

import json
import math
from pathlib import Path
import tempfile
import unittest

from scripts.eval.project_harness_e3_experiment import (
    ARMS,
    CASES,
    _schedule,
    _validate_execution_contract,
    analyze_journal,
    grade_workspace,
    E3_ALLOWED_TOOLS,
    E3_DISALLOWED_TOOLS,
    E3Error,
)
from scripts.eval.memory_agent_runtime import PRODUCTION_MODEL_FINGERPRINT
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
    def test_execution_contract_rejects_authority_or_identity_drift(self) -> None:
        execution = {
            "provider_identity": PRODUCTION_PROVIDER_ID,
            "model_provider": PRODUCTION_MODEL_PROVIDER,
            "model_id": PRODUCTION_MODEL_ID,
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "allowed_tools": list(E3_ALLOWED_TOOLS),
            "disallowed_tools": list(E3_DISALLOWED_TOOLS),
            "max_output_tokens": 4096,
            "max_rollout_cost_usd": 0.9,
            "max_rollout_metered_tokens": 300_000,
            "max_total_cost_usd": 20.0,
            "max_total_metered_tokens": 5_000_000,
            "serial_rollouts": True,
            "fresh_home_per_rollout": True,
            "stable_absolute_project_root": True,
        }
        self.assertIs(execution, _validate_execution_contract(execution, 16))
        mutations = (
            ("max_total_cost_usd", 1000.01),
            ("max_total_cost_usd", math.nan),
            ("max_total_cost_usd", False),
            ("max_total_metered_tokens", 4_800_000),
            ("model_provider", "drifted-provider"),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                drifted = {**execution, field: value}
                with self.assertRaises(E3Error):
                    _validate_execution_contract(drifted, 16)

    def test_schedule_balances_every_arm_position(self) -> None:
        schedule = _schedule()
        self.assertEqual(len(ARMS) * len(CASES), len(schedule))
        for position in range(len(ARMS)):
            self.assertEqual(
                set(ARMS),
                {row["arm"] for row in schedule if row["position"] == position},
            )
        self.assertEqual(list(range(len(schedule))), [row["sequence"] for row in schedule])

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
            "schema_version": "metacodes-project-formal-decision-batch-v2",
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
                "candidate_id": candidate,
                "result": "block",
                "request_sha256": "7" * 64,
                "verdict_sha256": "8" * 64,
                "checker_failure": None,
            }],
        }
        edit_pre = {
            **batch,
            "dispatch_id": "edit-1",
            "phase": "pre",
            "file_target_state": "unobserved",
            "decisions": [{
                **batch["decisions"][0],
                "result": "admit",
                "request_sha256": "9" * 64,
                "verdict_sha256": "a" * 64,
            }],
        }
        edit_post = {
            **edit_pre,
            "phase": "post",
            "checker_call_sha256": "b" * 64,
            "checker_verdict_sha256": "c" * 64,
            "decisions": [{
                **edit_pre["decisions"][0],
                "request_sha256": "d" * 64,
                "verdict_sha256": "e" * 64,
            }],
        }
        records = b"".join(
            [
                _record(0, {"run_started": {}}),
                _record(1, {"tool_observation": {"formal_decision_batch": batch}}),
                _record(2, {"tool_observation": {"formal_decision_batch": edit_pre}}),
                _record(3, {"tool_observation": {"dispatch_started": {
                    "id": "edit-1", "requested_name": "Edit", "dispatched_name": "Edit",
                    "origin": "authoritative", "file_target_state": "unobserved",
                }}}),
                _record(4, {"tool_observation": {"formal_decision_batch": edit_post}}),
                _record(5, {"tool_observation": {"dispatch_finished": {
                    "id": "edit-1", "requested_name": "Edit", "dispatched_name": "Edit",
                    "origin": "authoritative", "outcome": "succeeded", "effect_valid": True,
                    "effect": None,
                }}}),
                _record(6, {"run_finished": {"stop_reason": "end_turn"}}),
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
        self.assertTrue(result["trustworthy_task_success"])


if __name__ == "__main__":
    unittest.main()
