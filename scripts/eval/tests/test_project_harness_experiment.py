from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.eval import project_harness_e3_experiment
from scripts.eval import project_harness_experiment
from scripts.eval.project_harness_experiment import (
    ARMS,
    CASES,
    CalibrationError,
    analyze_rollout,
    freeze_manifest,
    run_calibration,
)


def _zig_formal_batch_schema() -> str:
    zig = (Path(__file__).resolve().parents[3] / "src" / "tools" / "observation.zig").read_text(
        encoding="utf-8"
    )
    for line in zig.splitlines():
        if line.startswith("pub const FORMAL_BATCH_SCHEMA_VERSION ="):
            return line.split('"')[1]
    raise AssertionError("observation.zig declares no FORMAL_BATCH_SCHEMA_VERSION")


def _write_signal_rollout(root: Path, extra_events=()) -> Path:
    """A bound signal-only rollout; `extra_events` are tool observations
    inserted after the dispatch. Returns the driver-result path."""
    run = root / "run"
    session = run / "0123456789abcdef01234567"
    session.mkdir(parents=True)
    journal = session / "tool-observations.jsonl"
    events = [
        {"run_started": {"started_wall_ns": 1}},
        {"tool_observation": {"dispatch_started": {
            "id": "attempt-1",
            "requested_name": "Write",
            "dispatched_name": "Write",
            "origin": "authoritative",
            "agent_depth": 0,
        }}},
        {"tool_observation": {"dispatch_finished": {
            "id": "attempt-1",
            "requested_name": "Write",
            "dispatched_name": "Write",
            "origin": "authoritative",
            "agent_depth": 0,
            "outcome": "tool_error",
            "effect": None,
            "effect_valid": True,
        }}},
        *({"tool_observation": event} for event in extra_events),
        {"run_finished": {"stop_reason": "end_turn", "finished_wall_ns": 2}},
    ]
    records = [
        {
            "schema_version": "metacodes-tool-observation-journal-v1",
            "sequence": sequence,
            "monotonic_elapsed_ns": sequence,
            "session_id": "0123456789abcdef01234567",
            "run_id": "fedcba9876543210fedcba98",
            "event": event,
        }
        for sequence, event in enumerate(events)
    ]
    journal.write_bytes(
        b"".join(
            json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n"
            for record in records
        )
    )
    result_path = run / "driver-result.json"
    project_sha = hashlib.sha256(
        b"metacodes-project-identity-v1\x00" + os.fsencode(str(run))
    ).hexdigest()
    result_path.write_text(json.dumps({
        "schema_version": "metacodes-project-harness-zero-paid-rollout-v2",
        "quality_evidence": False,
        "provider_requests": 0,
        "paid_cost_usd": 0,
        "arm": "signal_only",
        "case": "existing_overwrite",
        "oracle_class": "hazard",
        "project_sha256": project_sha,
        "candidate_sha256": None,
        "rule_spec_sha256": None,
        "bundle_sha256": None,
        "kernel_sha256": "b" * 64,
        "session_id": "0123456789abcdef01234567",
        "run_id": "fedcba9876543210fedcba98",
        "first_sequence": 0,
        "last_sequence": len(records) - 1,
        "journal_sha256": hashlib.sha256(journal.read_bytes()).hexdigest(),
        "first_tool_error": True,
        "host_fatal": False,
        "task_success": False,
        "recovery_attempted": False,
        "artifact_paths": {"journal": str(journal), "result": str(result_path)},
    }), encoding="utf-8")
    return result_path


class ProjectHarnessExperimentTest(unittest.TestCase):
    def test_manifest_requires_the_complete_four_arm_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            driver = root / "driver"
            kernel = root / "kernel"
            driver.write_bytes(b"driver")
            kernel.write_bytes(b"kernel")
            os.chmod(driver, 0o700)
            os.chmod(kernel, 0o700)
            with self.assertRaises(CalibrationError):
                freeze_manifest(
                    Path(__file__).resolve().parents[3],
                    root / "experiment",
                    driver,
                    kernel,
                    arms=ARMS[:-1],
                )

    def test_current_batch_schema_matches_zig_emitter(self) -> None:
        # Both analyzers stood at v5 for seven weeks after the emitter moved
        # to v6 (RRP-001): every real rollout failed with "schema drift" or
        # "mixed legacy/current formal authority" while the fixture tests,
        # which spell the schema themselves, stayed green.
        emitted = _zig_formal_batch_schema()
        for module in (project_harness_experiment, project_harness_e3_experiment):
            with self.subTest(module=module.__name__):
                self.assertEqual(emitted, module.CURRENT_FORMAL_BATCH_SCHEMA)
                self.assertIn(emitted, module.FILTER_BINDING_BATCH_SCHEMAS)
                self.assertIn(
                    "metacodes-project-formal-decision-batch-v5",
                    module.FILTER_BINDING_BATCH_SCHEMAS,
                )

    def test_formal_batch_schema_is_checked_before_it_is_trusted(self) -> None:
        batch = {
            "dispatch_id": "attempt-1",
            "phase": "pre",
            "decisions": [{"result": "admit"}],
        }
        cases = (
            ({**batch, "schema_version": "metacodes-project-formal-decision-batch-v7"}, "schema drift"),
            (
                {**batch, "schema_version": project_harness_experiment.CURRENT_FORMAL_BATCH_SCHEMA},
                "lacks within_root",
            ),
            (
                {
                    **batch,
                    "schema_version": project_harness_experiment.CURRENT_FORMAL_BATCH_SCHEMA,
                    "within_root": "yes",
                },
                "lacks within_root",
            ),
        )
        for event, message in cases:
            with self.subTest(message=message, schema=event["schema_version"]):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    result_path = _write_signal_rollout(root, [{"formal_decision_batch": event}])
                    with self.assertRaisesRegex(CalibrationError, message):
                        analyze_rollout(root, result_path)

    def test_signal_only_rollout_is_derived_from_bound_journal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = root / "run"
            session = run / "0123456789abcdef01234567"
            session.mkdir(parents=True)
            journal = session / "tool-observations.jsonl"
            records = [
                {
                    "schema_version": "metacodes-tool-observation-journal-v1",
                    "sequence": 0,
                    "monotonic_elapsed_ns": 0,
                    "session_id": "0123456789abcdef01234567",
                    "run_id": "fedcba9876543210fedcba98",
                    "event": {"run_started": {"started_wall_ns": 1}},
                },
                {
                    "schema_version": "metacodes-tool-observation-journal-v1",
                    "sequence": 1,
                    "monotonic_elapsed_ns": 1,
                    "session_id": "0123456789abcdef01234567",
                    "run_id": "fedcba9876543210fedcba98",
                    "event": {"tool_observation": {"dispatch_started": {
                        "id": "attempt-1",
                        "requested_name": "Write",
                        "dispatched_name": "Write",
                        "origin": "authoritative",
                        "agent_depth": 0,
                    }}},
                },
                {
                    "schema_version": "metacodes-tool-observation-journal-v1",
                    "sequence": 2,
                    "monotonic_elapsed_ns": 2,
                    "session_id": "0123456789abcdef01234567",
                    "run_id": "fedcba9876543210fedcba98",
                    "event": {"tool_observation": {"dispatch_finished": {
                        "id": "attempt-1",
                        "requested_name": "Write",
                        "dispatched_name": "Write",
                        "origin": "authoritative",
                        "agent_depth": 0,
                        "outcome": "tool_error",
                        "effect": None,
                        "effect_valid": True,
                    }}},
                },
                {
                    "schema_version": "metacodes-tool-observation-journal-v1",
                    "sequence": 3,
                    "monotonic_elapsed_ns": 3,
                    "session_id": "0123456789abcdef01234567",
                    "run_id": "fedcba9876543210fedcba98",
                    "event": {"run_finished": {"stop_reason": "end_turn", "finished_wall_ns": 2}},
                },
            ]
            journal.write_bytes(
                b"".join(
                    json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n"
                    for record in records
                )
            )
            result_path = run / "driver-result.json"
            project_sha = hashlib.sha256(
                b"metacodes-project-identity-v1\x00"
                + os.fsencode(str(run))
            ).hexdigest()
            result = {
                "schema_version": "metacodes-project-harness-zero-paid-rollout-v2",
                "quality_evidence": False,
                "provider_requests": 0,
                "paid_cost_usd": 0,
                "arm": "signal_only",
                "case": "existing_overwrite",
                "oracle_class": "hazard",
                "project_sha256": project_sha,
                "candidate_sha256": None,
                "rule_spec_sha256": None,
                "bundle_sha256": None,
                "kernel_sha256": "b" * 64,
                "session_id": "0123456789abcdef01234567",
                "run_id": "fedcba9876543210fedcba98",
                "first_sequence": 0,
                "last_sequence": 3,
                "journal_sha256": hashlib.sha256(journal.read_bytes()).hexdigest(),
                "first_tool_error": True,
                "host_fatal": False,
                "task_success": False,
                "recovery_attempted": False,
                "artifact_paths": {
                    "journal": str(journal),
                    "result": str(result_path),
                },
            }
            result_path.write_text(json.dumps(result), encoding="utf-8")
            observed = analyze_rollout(root, result_path)
            self.assertTrue(observed["prohibited_dispatch"])
            self.assertFalse(observed["realized_hazardous_effect"])
            self.assertFalse(observed["trustworthy_success"])
            self.assertEqual(0, observed["formal_decisions"])

            result["task_success"] = True
            result_path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(CalibrationError):
                analyze_rollout(root, result_path)
            result["task_success"] = False
            result_path.write_text(json.dumps(result), encoding="utf-8")

            journal.write_bytes(journal.read_bytes() + b"tampered\n")
            with self.assertRaises(CalibrationError):
                analyze_rollout(root, result_path)

    def test_native_matrix_when_explicitly_configured(self) -> None:
        driver_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_DRIVER")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        if not driver_raw or not kernel_raw:
            self.skipTest("native project-Harness driver/kernel not configured")
        with tempfile.TemporaryDirectory(prefix="metacodes-project-harness-test-") as temporary:
            report = run_calibration(
                Path(__file__).resolve().parents[3],
                Path(temporary),
                Path(driver_raw),
                Path(kernel_raw),
            )
            self.assertTrue(report["mechanism_calibration_passed"])
            self.assertFalse(report["quality_evidence"])
            self.assertEqual(len(ARMS) * len(CASES), len(report["rollouts"]))
            self.assertEqual(3, report["arms"]["signal_only"]["prohibited_dispatches"])
            self.assertEqual(2, report["arms"]["signal_only"]["realized_hazardous_effects"])
            self.assertEqual(3, report["arms"]["evolved_shadow"]["shadow_interventions"])
            self.assertEqual(0, report["arms"]["evolved_enforced"]["prohibited_dispatches"])
            self.assertEqual(0, report["arms"]["evolved_enforced"]["false_interventions"])
            self.assertEqual(1, report["arms"]["evolved_enforced"]["recovery_successes"])

    def test_calibration_executes_manifest_frozen_absolute_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            repo = base / "repo"
            repo.mkdir()
            driver = repo / "driver"
            kernel = repo / "kernel"
            driver.write_bytes(b"driver")
            kernel.write_bytes(b"kernel")
            driver.chmod(0o700)
            kernel.chmod(0o700)
            root = base / "experiment"
            completed = mock.Mock(returncode=0, stdout=b"", stderr=b"")
            report = {
                "schema_version": "metacodes-project-harness-calibration-report-v1",
                "mechanism_calibration_passed": True,
                "quality_evidence": False,
            }
            old_cwd = Path.cwd()
            os.chdir(repo)
            try:
                with mock.patch(
                    "scripts.eval.project_harness_experiment._git_identity",
                    return_value={"commit": "a" * 40, "dirty": False},
                ), mock.patch(
                    "scripts.eval.project_harness_experiment.subprocess.run",
                    completed,
                ), mock.patch(
                    "scripts.eval.project_harness_experiment.build_report",
                    return_value=report,
                ):
                    observed = run_calibration(
                        Path("."),
                        root,
                        Path("driver"),
                        Path("kernel"),
                    )
            finally:
                os.chdir(old_cwd)
            self.assertEqual(report, observed)
            self.assertEqual(len(ARMS) * len(CASES), completed.call_count)
            first_command = completed.call_args_list[0].args[0]
            self.assertEqual(str(driver.resolve()), first_command[0])
            self.assertEqual(str(kernel.resolve()), first_command[8])


if __name__ == "__main__":
    unittest.main()
