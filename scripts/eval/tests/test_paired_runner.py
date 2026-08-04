import math
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.e2e_adapter import comparison_fingerprints
from scripts.eval.model import ValidationError
from scripts.eval.paired_runner import (
    InfrastructureRunError,
    _require_budget,
    _run_once,
    alternating_schedule,
    run_paired,
    scenario_selector,
)


class PairedRunnerTest(unittest.TestCase):
    def test_cumulative_budget_counts_offsets_and_all_token_classes(self):
        collected = {
            "baseline": [
                {
                    "metrics": {
                        "cost_usd": 0.25,
                        "input_tokens": 10,
                        "output_tokens": 5,
                        "cache_read_tokens": 20,
                        "cache_write_tokens": 2,
                    }
                }
            ],
            "candidate": [],
        }
        with self.assertRaisesRegex(ValidationError, "cost budget reached"):
            _require_budget(
                collected,
                used_cost_usd=0.75,
                used_tokens=0,
                max_cumulative_cost_usd=1.0,
                max_cumulative_tokens=None,
            )
        with self.assertRaisesRegex(ValidationError, "token budget reached"):
            _require_budget(
                collected,
                used_cost_usd=0,
                used_tokens=63,
                max_cumulative_cost_usd=None,
                max_cumulative_tokens=100,
            )

    def test_budget_fails_closed_when_cost_or_token_telemetry_is_missing(self):
        collected = {"arm": [{"run_id": "r1", "metrics": {}}]}
        with self.assertRaisesRegex(ValidationError, "cost budget telemetry missing"):
            _require_budget(
                collected,
                used_cost_usd=0,
                used_tokens=0,
                max_cumulative_cost_usd=1.0,
                max_cumulative_tokens=None,
            )
        with self.assertRaisesRegex(ValidationError, "token budget telemetry missing"):
            _require_budget(
                collected,
                used_cost_usd=0,
                used_tokens=0,
                max_cumulative_cost_usd=None,
                max_cumulative_tokens=100,
            )

    def test_paired_runner_rejects_nonfinite_budget_inputs(self):
        kwargs = dict(
            suite={},
            repo_root=Path("."),
            baseline_binary=Path("missing-a"),
            candidate_binary=Path("missing-b"),
            trials=1,
            scenario_glob="*",
            model_provider="test",
            model_id="test",
            baseline_output=Path("a.jsonl"),
            candidate_output=Path("b.jsonl"),
            baseline_revision="a",
            candidate_revision="b",
        )
        with self.assertRaisesRegex(ValidationError, "budget usage offsets"):
            run_paired(
                **kwargs,
                budget_used_cost_usd=math.nan,
            )
        with self.assertRaisesRegex(ValidationError, "max cumulative cost"):
            run_paired(
                **kwargs,
                max_cumulative_cost_usd=math.inf,
            )

    def test_checkpoint_with_unscorable_rollout_fails_closed(self):
        rollout = {
            "task_id": "task-a",
            "trial": 0,
            "execution": {"invalid_reasons": ["nonzero_exit:124"]},
            "evaluator": {"status": "invalid"},
            "judgement": {"valid_for_scoring": False},
        }
        from scripts.eval.paired_runner import _require_scoring_rollout

        with self.assertRaisesRegex(ValidationError, "fail-closed"):
            _require_scoring_rollout(rollout, variant="baseline")

    def test_run_once_accepts_hard_assertion_failure_as_scored_rollout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runs = root / "tests" / "e2e" / "runs"
            runs.mkdir(parents=True)
            runner = root / "tests" / "e2e" / "run_e2e.sh"
            runner.write_text("#!/bin/sh\n", encoding="utf-8")
            runner.chmod(0o755)
            binary = root / "metacodes"
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            suite_path = root / "suite.json"
            suite_path.write_text("{}\n", encoding="utf-8")

            def fake_run(*_args, **_kwargs):
                created = runs / "scored-failure"
                created.mkdir()
                return mock.Mock(returncode=2)

            with mock.patch.dict(
                os.environ,
                {
                    "METACODES_LONG_HORIZON_ARM": "host-leak",
                    "METACODES_NO_AUTO_RECALL": "1",
                    "TINYKG_STORE": "/host/store",
                    "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                    "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
                    "CLAUDE_CODE_MAX_RETRIES": "99",
                    "RG_BIN": "/host/rg",
                    "E2E_BASE_URL": "http://host-leak.invalid",
                    "E2E_RECORD": "1",
                    "E2E_TIMEOUT": "9999",
                },
            ), mock.patch(
                "scripts.eval.paired_runner.subprocess.run", side_effect=fake_run
            ) as patched_run:
                observed = _run_once(
                    root,
                    binary,
                    "baseline",
                    0,
                    "task-a",
                    "anthropic",
                    "glm-5.2",
                    suite_path,
                    "baseline-rev",
                    timeout_seconds=123,
                )
            observed_env = patched_run.call_args.kwargs["env"]
            self.assertEqual(observed_env["E2E_HARNESS_REVISION"], "baseline-rev")
            self.assertEqual(observed_env["E2E_RUN_LABEL"], "evaluation")
            self.assertNotIn("METACODES_LONG_HORIZON_ARM", observed_env)
            self.assertNotIn("METACODES_NO_AUTO_RECALL", observed_env)
            self.assertNotIn("TINYKG_STORE", observed_env)
            self.assertNotIn("CLAUDE_CODE_DISABLE_AUTO_MEMORY", observed_env)
            self.assertNotIn("CLAUDE_CODE_DISABLE_CLAUDE_MDS", observed_env)
            self.assertNotIn("CLAUDE_CODE_MAX_RETRIES", observed_env)
            self.assertNotIn("RG_BIN", observed_env)
            self.assertNotIn("E2E_BASE_URL", observed_env)
            self.assertNotIn("E2E_RECORD", observed_env)
            self.assertEqual(observed_env["E2E_TIMEOUT"], "123")
            self.assertEqual(observed, (runs / "scored-failure").resolve())

    def test_run_once_rejects_infrastructure_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runs = root / "tests" / "e2e" / "runs"
            runs.mkdir(parents=True)
            runner = root / "tests" / "e2e" / "run_e2e.sh"
            runner.write_text("#!/bin/sh\n", encoding="utf-8")
            runner.chmod(0o755)
            binary = root / "metacodes"
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            suite_path = root / "suite.json"
            suite_path.write_text("{}\n", encoding="utf-8")

            with mock.patch(
                "scripts.eval.paired_runner.subprocess.run",
                return_value=mock.Mock(returncode=1),
            ):
                with self.assertRaisesRegex(ValidationError, "E2E runner exited 1"):
                    _run_once(
                        root,
                        binary,
                        "candidate",
                        0,
                        "task-a",
                        "anthropic",
                        "glm-5.2",
                        suite_path,
                        "candidate-rev",
                    )

    def test_run_once_returns_auditable_infrastructure_failure_when_requested(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runs = root / "tests" / "e2e" / "runs"
            runs.mkdir(parents=True)
            runner = root / "tests" / "e2e" / "run_e2e.sh"
            runner.write_text("#!/bin/sh\n", encoding="utf-8")
            runner.chmod(0o755)
            binary = root / "metacodes"
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            suite_path = root / "suite.json"
            suite_path.write_text("{}\n", encoding="utf-8")

            def fake_run(*_args, **_kwargs):
                (runs / "invalid-evidence").mkdir()
                return mock.Mock(returncode=1)

            with mock.patch(
                "scripts.eval.paired_runner.subprocess.run", side_effect=fake_run
            ):
                with self.assertRaises(InfrastructureRunError) as raised:
                    _run_once(
                        root,
                        binary,
                        "tinykg",
                        2,
                        "task-a",
                        "anthropic",
                        "glm-5.2",
                        suite_path,
                        "candidate-rev",
                        allow_invalid_run=True,
                    )
            self.assertEqual(raised.exception.returncode, 1)
            self.assertEqual(raised.exception.run_dir, (runs / "invalid-evidence").resolve())

    def test_schedule_balances_order_across_trials(self):
        self.assertEqual(
            alternating_schedule(3),
            [
                (0, "baseline"),
                (0, "candidate"),
                (1, "candidate"),
                (1, "baseline"),
                (2, "baseline"),
                (2, "candidate"),
            ],
        )

    def test_schedule_rejects_zero_trials(self):
        with self.assertRaisesRegex(ValidationError, "trials must be"):
            alternating_schedule(0)

    def test_selector_is_exact_and_deterministic(self):
        self.assertEqual(
            scenario_selector(["20_subagent_explore", "00_smoke", "12_deny_rule"]),
            "00_smoke,12_deny_rule,20_subagent_explore",
        )

    def test_selector_rejects_ambiguous_ids(self):
        with self.assertRaisesRegex(ValidationError, "cannot contain commas"):
            scenario_selector(["00_smoke,02_html_game"])

    def test_single_task_atomic_checkpoints_resume_without_repeating_paid_rollouts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tasks = []
            for task_id in ("a_task", "b_task"):
                scenario = root / f"{task_id}.txt"
                scenario.write_text(f"run {task_id}\n", encoding="utf-8")
                tasks.append(
                    {
                        "id": task_id,
                        "scenario": scenario.name,
                        "layers": ["E", "T", "L", "O", "V"],
                        "environment": {"reset": "fresh"},
                        "tools": {"profile": "test-tools", "required": []},
                        "constraints": {"timeout_seconds": 10, "permission_mode": "default"},
                        "success": {"checks": [{"type": "file_exists", "path": "answer.txt"}]},
                        "trajectory_constraints": {"max_turns": 2},
                        "trajectory_rationale": {"max_turns": "bounded test"},
                        "grader": {"kind": "deterministic_workspace", "version": "v1"},
                    }
                )
            suite = {"schema_version": 1, "suite_id": "resume-suite", "tasks": tasks}
            suite_path = root / "suite.json"
            suite_path.write_text("{}\n", encoding="utf-8")
            task_by_id = {task["id"]: task for task in tasks}
            baseline_binary = root / "baseline"
            candidate_binary = root / "candidate"
            baseline_binary.write_bytes(b"baseline-v1")
            candidate_binary.write_bytes(b"candidate-v1")
            baseline_binary.chmod(0o755)
            candidate_binary.chmod(0o755)
            baseline_output = root / "baseline.jsonl"
            candidate_output = root / "candidate.jsonl"

            invocations = []
            run_state = {}
            fail_after = [2]

            def fake_run_once(
                _repo_root,
                binary,
                variant,
                trial,
                selector,
                model_provider,
                model_id,
                observed_suite_path,
                harness_revision,
                *,
                timeout_seconds=None,
            ):
                self.assertEqual(observed_suite_path, suite_path)
                self.assertEqual(timeout_seconds, 10)
                if fail_after[0] is not None and len(invocations) >= fail_after[0]:
                    raise RuntimeError("simulated interruption")
                task_id = selector
                token = root / f"run-{len(invocations)}"
                invocations.append((variant, trial, task_id))
                run_state[token] = (
                    binary,
                    variant,
                    trial,
                    task_id,
                    model_provider,
                    model_id,
                    harness_revision,
                )
                return token

            def fake_import(_suite, _repo_root, run_dir):
                (
                    binary,
                    variant,
                    trial,
                    task_id,
                    model_provider,
                    model_id,
                    harness_revision,
                ) = run_state[run_dir]
                task = task_by_id[task_id]
                identity = comparison_fingerprints(
                    task,
                    root,
                    model_provider=model_provider,
                    model_id=model_id,
                    harness_config_id=variant,
                    harness_revision=harness_revision,
                    permission_mode=task["constraints"]["permission_mode"],
                    binary_path=binary,
                )
                return [
                    {
                        "schema_version": 1,
                        "run_id": f"{variant}:{task_id}:{trial}",
                        "suite_id": suite["suite_id"],
                        "task_id": task_id,
                        "task_fingerprint": identity["task_fingerprint"],
                        "task_fingerprint_provenance": "recorded_at_execution",
                        "trial": trial,
                        "layers": task["layers"],
                        "model": {"provider": model_provider, "id": model_id, "fingerprint": identity["model_fingerprint"]},
                        "harness": {
                            "config_id": variant,
                            "revision": harness_revision,
                            "fingerprint": identity["harness_fingerprint"],
                            "permission_mode": identity["permission_mode"],
                            "environment_fingerprint": identity["environment_fingerprint"],
                        },
                        "readiness": {"status": "pass", "checks": []},
                        "execution": {"status": "completed", "exit_code": 0, "invalid_reasons": []},
                        "outcome": {"status": "pass", "checks": []},
                        "trajectory": {"status": "pass", "checks": [], "tool_failures": []},
                        "evaluator": {"status": "ready", "kind": "deterministic_workspace", "version": "v1", "fingerprint": identity["grader_fingerprint"], "errors": []},
                        "judgement": {"valid_for_scoring": True, "trustworthy_success": True},
                        "metrics": {"cost_usd": 0.0, "wall_time_ms": 1, "policy_violations": 0},
                        "attribution": [],
                        "artifacts": {},
                    }
                ]

            patches = (
                mock.patch("scripts.eval.paired_runner._run_once", side_effect=fake_run_once),
                mock.patch("scripts.eval.paired_runner.import_run", side_effect=fake_import),
            )
            with patches[0], patches[1]:
                with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                    run_paired(
                        suite,
                        root,
                        baseline_binary,
                        candidate_binary,
                        trials=1,
                        scenario_glob="*",
                        model_provider="test",
                        model_id="model-a",
                        baseline_output=baseline_output,
                        candidate_output=candidate_output,
                        baseline_revision="baseline-rev",
                        candidate_revision="candidate-rev",
                        suite_path=suite_path,
                    )
                self.assertTrue(baseline_output.is_file())
                self.assertFalse(candidate_output.exists())
                self.assertEqual(
                    invocations,
                    [("baseline", 0, "a_task"), ("baseline", 0, "b_task")],
                )

                fail_after[0] = None
                invocations.clear()
                baseline, candidate = run_paired(
                    suite,
                    root,
                    baseline_binary,
                    candidate_binary,
                    trials=1,
                    scenario_glob="*",
                    model_provider="test",
                    model_id="model-a",
                    baseline_output=baseline_output,
                    candidate_output=candidate_output,
                    baseline_revision="baseline-rev",
                    candidate_revision="candidate-rev",
                    suite_path=suite_path,
                )
                self.assertEqual(invocations, [("candidate", 0, "a_task"), ("candidate", 0, "b_task")])
                self.assertEqual(len(baseline), 2)
                self.assertEqual(len(candidate), 2)

                candidate_binary.write_bytes(b"candidate-v2")
                candidate_binary.chmod(0o755)
                with self.assertRaisesRegex(ValidationError, "identity mismatch"):
                    run_paired(
                        suite,
                        root,
                        baseline_binary,
                        candidate_binary,
                        trials=1,
                        scenario_glob="*",
                        model_provider="test",
                        model_id="model-a",
                        baseline_output=baseline_output,
                        candidate_output=candidate_output,
                        baseline_revision="baseline-rev",
                        candidate_revision="candidate-rev",
                        suite_path=suite_path,
                    )

    def test_rejects_empty_variant_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            suite_path = root / "suite.json"
            suite_path.write_text("{}\n", encoding="utf-8")
            scenario = root / "task.txt"
            scenario.write_text("test\n", encoding="utf-8")
            suite = {
                "schema_version": 1,
                "suite_id": "revision-suite",
                "tasks": [
                    {
                        "id": "task",
                        "scenario": scenario.name,
                        "constraints": {"permission_mode": "default"},
                    }
                ],
            }
            with self.assertRaisesRegex(ValidationError, "baseline revision must be non-empty"):
                run_paired(
                    suite,
                    root,
                    binary,
                    binary,
                    trials=1,
                    scenario_glob="*",
                    model_provider="test",
                    model_id="model",
                    baseline_output=root / "baseline.jsonl",
                    candidate_output=root / "candidate.jsonl",
                    baseline_revision=" ",
                    candidate_revision="candidate-rev",
                    suite_path=suite_path,
                )
