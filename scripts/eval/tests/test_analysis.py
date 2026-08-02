import copy
import unittest

from scripts.eval.analysis import compare, gate, summarize, validate_release_contract
from scripts.eval.model import ValidationError


def rollout(task_id, success, harness="h1", policy_violations=0):
    return {
        "schema_version": 1,
        "run_id": f"run:{task_id}",
        "suite_id": "suite",
        "task_id": task_id,
        "task_fingerprint": f"task-fingerprint:{task_id}",
        "task_fingerprint_provenance": "recorded_at_execution",
        "trial": 0,
        "layers": ["T", "O", "V"],
        "model": {"provider": "test", "id": "model-a", "fingerprint": "model-a-fp"},
        "harness": {
            "config_id": harness,
            "revision": harness,
            "fingerprint": harness,
            "environment_fingerprint": "environment-a",
            "permission_mode": "default",
        },
        "readiness": {"status": "pass", "checks": []},
        "execution": {"status": "completed", "exit_code": 0, "invalid_reasons": []},
        "outcome": {"status": "pass" if success else "fail", "checks": []},
        "trajectory": {"status": "pass", "checks": [], "tool_failures": []},
        "evaluator": {
            "status": "ready",
            "kind": "deterministic",
            "version": "v1",
            "fingerprint": "grader-1",
            "errors": [],
        },
        "judgement": {"valid_for_scoring": True, "trustworthy_success": success},
        "metrics": {
            "input_tokens": 10,
            "output_tokens": 2,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "cost_usd": 0.01,
            "wall_time_ms": 100,
            "model_request_time_ms": 80,
            "tool_stage_time_ms": 10,
            "harness_time_ms": 10,
            "tool_calls": 1,
            "turns": 1,
            "retries": 0,
            "policy_violations": policy_violations,
            "model_tool_errors": 0,
        },
        "attribution": [],
        "artifacts": {},
    }


class AnalysisTest(unittest.TestCase):
    def test_summary_keeps_trustworthy_success_separate(self):
        good = rollout("a", True)
        unsafe = rollout("b", True)
        unsafe["trajectory"]["status"] = "fail"
        unsafe["judgement"]["trustworthy_success"] = False
        result = summarize([good, unsafe])
        self.assertEqual(result["outcome_success_rate"], 1.0)
        self.assertEqual(result["trustworthy_success_rate"], 0.5)

    def test_harness_comparison_is_paired_and_model_locked(self):
        baseline = [rollout(f"task-{index}", False, "old") for index in range(10)]
        candidate = [rollout(f"task-{index}", True, "new") for index in range(10)]
        result = compare(baseline, candidate, "harness")
        self.assertEqual(result["discordant_improvements"], 10)
        self.assertAlmostEqual(result["mcnemar_exact_p"], 2 / 1024)
        changed_model = copy.deepcopy(candidate)
        changed_model[0]["model"]["id"] = "model-b"
        changed_model[0]["model"]["fingerprint"] = "model-b-fp"
        with self.assertRaisesRegex(ValidationError, "same known model"):
            compare(baseline, changed_model, "harness")

    def test_multi_trial_comparison_reports_variance_ci_and_risk_frontier(self):
        baseline = []
        candidate = []
        for trial in range(3):
            before = rollout("task", True, "old")
            after = rollout("task", True, "new")
            before["trial"] = trial
            after["trial"] = trial
            after["metrics"]["cost_usd"] = 0.009 - trial * 0.001
            after["metrics"]["wall_time_ms"] = 90 - trial
            after["metrics"]["model_request_time_ms"] = 70 - trial
            baseline.append(before)
            candidate.append(after)
        result = compare(baseline, candidate, "harness")
        self.assertEqual(result["paired_rollouts"], 3)
        self.assertEqual(result["risk_frontier"], "candidate_dominates")
        self.assertIsNotNone(result["paired_delta"]["cost_usd"]["variance"])
        self.assertIsNotNone(result["paired_delta"]["cost_usd"]["ci95"][0])
        self.assertEqual(result["latency_attribution_pairs"], 3)
        self.assertEqual(len(result["task_trial_contributions"]), 3)
        self.assertEqual(result["task_contributions"][0]["task_id"], "task")

    def test_comparison_fails_closed_when_cost_or_latency_is_missing(self):
        baseline = [rollout("task", True, "old")]
        candidate = [rollout("task", True, "new")]
        candidate[0]["metrics"]["cost_usd"] = None
        with self.assertRaisesRegex(ValidationError, "requires cost_usd telemetry"):
            compare(baseline, candidate, "harness")

    def test_deterministic_tool_error_optimization_demo_is_paired_and_no_worse(self):
        baseline = []
        candidate = []
        for trial in range(10):
            before = rollout("task-empty-args", True, "generic-error")
            after = rollout("task-empty-args", True, "field-specific-error")
            before["trial"] = trial
            after["trial"] = trial
            before["metrics"].update(
                {"model_tool_errors": 3, "input_tokens": 30, "turns": 3, "cost_usd": 0.03}
            )
            after["metrics"].update(
                {"model_tool_errors": 1, "input_tokens": 20, "turns": 2, "cost_usd": 0.02}
            )
            baseline.append(before)
            candidate.append(after)
        result = compare(baseline, candidate, "harness")
        error_delta = result["paired_delta"]["model_tool_errors"]
        self.assertEqual(error_delta["mean"], -2.0)
        self.assertLess(error_delta["ci95"][1], 0.0)
        self.assertLessEqual(result["mean_paired_delta"]["total_tokens"], 0)
        self.assertEqual(result["risk_frontier"], "candidate_dominates")

    def test_gate_applies_paired_cost_latency_and_tool_error_limits(self):
        baseline = [rollout("task", True, "old")]
        candidate = [rollout("task", True, "new")]
        candidate[0]["metrics"]["cost_usd"] = 0.02
        candidate[0]["metrics"]["wall_time_ms"] = 150
        candidate[0]["metrics"]["model_tool_errors"] = 1
        result = gate(
            candidate,
            baseline=baseline,
            max_cost_increase_usd=0.0,
            max_latency_increase_ms=0.0,
            max_model_tool_error_increase=0.0,
        )
        self.assertFalse(result["passed"])
        failed = {item["name"] for item in result["checks"] if not item["passed"]}
        self.assertIn("paired_cost_increase_usd", failed)
        self.assertIn("paired_latency_increase_ms", failed)
        self.assertIn("paired_model_tool_error_increase", failed)

    def test_evaluator_change_is_rejected_as_confounder(self):
        baseline = [rollout("task", False, "old")]
        candidate = [rollout("task", True, "new")]
        candidate[0]["evaluator"]["fingerprint"] = "grader-2"
        with self.assertRaisesRegex(ValidationError, "evaluator changed"):
            compare(baseline, candidate, "harness")

    def test_comparison_rejects_missing_pairs(self):
        baseline = [rollout("a", True), rollout("b", False)]
        candidate = [rollout("a", True, "h2")]
        with self.assertRaisesRegex(ValidationError, "identical task/trial pairs"):
            compare(baseline, candidate, "harness")

    def test_comparison_rejects_environment_drift(self):
        baseline = [rollout("task", True, "old")]
        candidate = [rollout("task", True, "new")]
        candidate[0]["harness"]["environment_fingerprint"] = "environment-b"
        with self.assertRaisesRegex(ValidationError, "execution environment changed"):
            compare(baseline, candidate, "harness")

    def test_release_contract_rejects_cherry_picked_success_pair(self):
        candidate = [rollout("task", True, "candidate")]
        with self.assertRaisesRegex(ValidationError, "suite/trial contract"):
            validate_release_contract(
                candidate,
                label="candidate",
                suite_id="suite",
                task_ids=["task"],
                trials=2,
                model_provider="test",
                model_id="model-a",
                grounding={
                    "task": {
                        "task_fingerprint": "task-fingerprint:task",
                        "grader_fingerprint": "grader-1",
                        "environment_fingerprint": "environment-a",
                    }
                },
            )

    def test_comparison_rejects_post_hoc_task_fingerprint(self):
        baseline = [rollout("task", False, "old")]
        candidate = [rollout("task", True, "new")]
        baseline[0]["task_fingerprint_provenance"] = "inferred_from_current_suite"
        with self.assertRaisesRegex(ValidationError, "not recorded at execution time"):
            compare(baseline, candidate, "harness")

    def test_evaluator_invalid_counts_toward_invalid_rate(self):
        candidate = rollout("task", False)
        candidate["evaluator"]["status"] = "invalid"
        candidate["outcome"]["status"] = "unscored"
        candidate["judgement"]["valid_for_scoring"] = False
        result = summarize([candidate])
        self.assertEqual(result["invalid_rate"], 1.0)
        self.assertEqual(result["invalid_rollouts"], 1)

    def test_gate_fails_closed_when_policy_telemetry_is_missing(self):
        candidate = rollout("task", True)
        candidate["metrics"]["policy_violations"] = None
        result = gate([candidate], max_policy_violations=0)
        self.assertFalse(result["passed"])
        policy = next(item for item in result["checks"] if item["name"] == "policy_violations")
        self.assertEqual(policy["actual"], "telemetry_missing")

    def test_gate_fails_closed_when_latency_attribution_is_missing(self):
        baseline = [rollout("task", True, "old")]
        candidate = [rollout("task", True, "new")]
        candidate[0]["metrics"]["harness_time_ms"] = None
        result = gate(candidate, baseline=baseline)
        self.assertFalse(result["passed"])
        coverage = next(
            item for item in result["checks"]
            if item["name"] == "latency_attribution_coverage"
        )
        self.assertEqual(coverage["actual"], 0.0)


if __name__ == "__main__":
    unittest.main()
