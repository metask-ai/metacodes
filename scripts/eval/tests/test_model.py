import copy
import hashlib
import unittest
from pathlib import Path

from scripts.eval.model import ValidationError, load_json, validate_rollout, validate_suite


ROOT = Path(__file__).resolve().parents[3]
SUITES = (
    ROOT / "evals" / "suites" / "core-e2e.json",
    ROOT / "evals" / "suites" / "agentdef-release.json",
    ROOT / "evals" / "suites" / "websearch-concurrency.json",
)


class SuiteValidationTest(unittest.TestCase):
    def test_checked_in_suite_is_fully_grounded(self):
        for path in SUITES:
            with self.subTest(path=path.name):
                suite = load_json(path)
                self.assertEqual(validate_suite(suite, ROOT), [])

    def test_agentdef_memory_grader_tracks_collision_resistant_runtime_identity(self):
        suite = load_json(SUITES[1])
        task = next(item for item in suite["tasks"] if item["id"] == "41_agentdef_memory")
        memory_check = task["success"]["checks"][0]
        suffix = hashlib.sha256(b"release-memory").hexdigest()[:32]
        self.assertEqual(
            memory_check["path"],
            f".metacodes/agent-memory/release-memory-{suffix}/MEMORY.md",
        )
        self.assertEqual(task["grader"]["version"], "agentdef-release-v2")

    def test_task_requires_trajectory_judgement(self):
        suite = load_json(SUITES[0])
        broken = copy.deepcopy(suite)
        broken["tasks"][0]["trajectory_constraints"] = {}
        with self.assertRaisesRegex(ValidationError, "trajectory check"):
            validate_suite(broken, ROOT)

    def test_every_trajectory_constraint_requires_a_product_rationale(self):
        suite = load_json(SUITES[0])
        broken = copy.deepcopy(suite)
        broken["tasks"][0]["trajectory_rationale"].pop("max_turns")
        with self.assertRaisesRegex(ValidationError, "missing product rationale"):
            validate_suite(broken, ROOT)

    def test_min_tool_counts_requires_positive_named_counts(self):
        suite = load_json(SUITES[0])
        for invalid in ({}, {"": 1}, {"WebSearch": 0}, {"WebSearch": True}):
            with self.subTest(invalid=invalid):
                broken = copy.deepcopy(suite)
                broken["tasks"][0]["trajectory_constraints"]["min_tool_counts"] = invalid
                broken["tasks"][0]["trajectory_rationale"]["min_tool_counts"] = "test"
                with self.assertRaisesRegex(ValidationError, "positive integer object"):
                    validate_suite(broken, ROOT)

    def test_workspace_check_cannot_escape(self):
        suite = load_json(SUITES[0])
        broken = copy.deepcopy(suite)
        broken["tasks"][0]["success"]["checks"][0]["path"] = "../secret"
        with self.assertRaisesRegex(ValidationError, "safe workspace-relative"):
            validate_suite(broken, ROOT)

    def test_fixture_path_cannot_escape_or_be_missing(self):
        suite = load_json(SUITES[1])
        escaped = copy.deepcopy(suite)
        escaped["tasks"][0]["environment"]["fixtures"] = ["../secret"]
        with self.assertRaisesRegex(ValidationError, "escapes repository root"):
            validate_suite(escaped, ROOT)
        missing = copy.deepcopy(suite)
        missing["tasks"][0]["environment"]["fixtures"] = ["tests/no-such-fixture"]
        with self.assertRaisesRegex(ValidationError, "file does not exist"):
            validate_suite(missing, ROOT)

    def test_rollout_rejects_inconsistent_trustworthy_success(self):
        from scripts.eval.tests.test_analysis import rollout

        broken = rollout("task", True)
        broken["trajectory"]["status"] = "fail"
        with self.assertRaisesRegex(ValidationError, "trustworthy_success"):
            validate_rollout(broken)

    def test_rollout_rejects_nonfinite_and_mistyped_metrics(self):
        from scripts.eval.tests.test_analysis import rollout

        nonfinite = rollout("task", True)
        nonfinite["metrics"]["cost_usd"] = float("nan")
        with self.assertRaisesRegex(ValidationError, "non-finite"):
            validate_rollout(nonfinite)

        mistyped = rollout("task", True)
        mistyped["metrics"]["wall_time_ms"] = "100"
        with self.assertRaisesRegex(ValidationError, "wall_time_ms"):
            validate_rollout(mistyped)

        boolean_count = rollout("task", True)
        boolean_count["metrics"]["tool_calls"] = True
        with self.assertRaisesRegex(ValidationError, "tool_calls"):
            validate_rollout(boolean_count)

    def test_rollout_rejects_boolean_trial(self):
        from scripts.eval.tests.test_analysis import rollout

        broken = rollout("task", True)
        broken["trial"] = True
        with self.assertRaisesRegex(ValidationError, "trial"):
            validate_rollout(broken)


if __name__ == "__main__":
    unittest.main()
