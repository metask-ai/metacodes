import contextlib
import copy
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.cli import main
from scripts.eval.e2e_adapter import EVALUATION_CONTRACT_VERSION, grounding_fingerprints
from scripts.eval.experiment import arm_config_ids
from scripts.eval.model import load_json, stable_json, write_rollouts
from scripts.eval.tests.test_analysis import rollout


ROOT = Path(__file__).resolve().parents[3]


class CliTest(unittest.TestCase):
    def test_experiment_rejects_escaped_suite_before_reading_it(self):
        experiment = load_json(
            ROOT / "evals/experiments/long-horizon-three-arm-v1.json"
        )
        experiment["suite"] = "../outside-repository-suite.json"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "experiment.json"
            path.write_text(json.dumps(experiment) + "\n", encoding="utf-8")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = main(
                    [
                        "validate-experiment",
                        str(path),
                        "--binary",
                        "/not-read/metacodes",
                        "--tinykg-binary",
                        "/not-read/tinykg",
                        "--revision",
                        "not-read",
                    ]
                )
        self.assertEqual(code, 2)
        self.assertIn("suite escapes repository root", stderr.getvalue())

    def _production_gate_config(self, directory: Path, *, all_suites: bool = False) -> Path:
        config = load_json(ROOT / "evals/gates/default.json")
        if not all_suites:
            config["release_contract"]["suites"] = [
                item
                for item in config["release_contract"]["suites"]
                if item["suite_id"] == "metacodes-core-e2e-v1"
            ]
        config["calibration"]["status"] = "production"
        config["calibration"][
            "evaluation_contract_version"
        ] = EVALUATION_CONTRACT_VERSION
        config["calibration"]["release_contract_fingerprint"] = hashlib.sha256(
            stable_json(config["release_contract"]).encode("utf-8")
        ).hexdigest()[:16]
        path = directory / "production-gate.json"
        path.write_text(json.dumps(config, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def _grounded_rollouts(self, suite_paths):
        release_contract = load_json(ROOT / "evals/gates/default.json")[
            "release_contract"
        ]
        contracted_models = {
            item["suite_id"]: item["model"]
            for item in release_contract["suites"]
        }
        rollouts = []
        for suite_path in suite_paths:
            suite = load_json(suite_path)
            model = contracted_models[suite["suite_id"]]
            model_fingerprint = hashlib.sha256(
                stable_json(model).encode("utf-8")
            ).hexdigest()[:16]
            for trial in range(6):
                for task in suite["tasks"]:
                    item = copy.deepcopy(rollout(task["id"], True, "candidate"))
                    identity = grounding_fingerprints(task, ROOT)
                    item["run_id"] = f"candidate:{suite['suite_id']}:{task['id']}:{trial}"
                    item["suite_id"] = suite["suite_id"]
                    item["trial"] = trial
                    item["task_fingerprint"] = identity["task_fingerprint"]
                    item["model"] = {**model, "fingerprint": model_fingerprint}
                    item["harness"].update(
                        {
                            "revision": "abc",
                            "environment_fingerprint": identity[
                                "environment_fingerprint"
                            ],
                            "permission_mode": identity["permission_mode"],
                        }
                    )
                    item["evaluator"]["fingerprint"] = identity[
                        "grader_fingerprint"
                    ]
                    rollouts.append(item)
        return rollouts

    def test_gate_loads_versioned_threshold_config(self):
        with tempfile.TemporaryDirectory() as directory:
            gate_config = self._production_gate_config(Path(directory))
            candidate = Path(directory) / "candidate.jsonl"
            baseline = Path(directory) / "baseline.jsonl"
            suite_path = ROOT / "evals/suites/core-e2e.json"
            rollouts = self._grounded_rollouts([suite_path])
            write_rollouts(candidate, rollouts)
            baseline_rollouts = copy.deepcopy(rollouts)
            for item in baseline_rollouts:
                item["run_id"] = item["run_id"].replace("candidate:", "baseline:", 1)
                item["harness"]["config_id"] = "baseline"
                item["harness"]["fingerprint"] = "baseline"
            write_rollouts(baseline, baseline_rollouts)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = main(
                    [
                        "gate",
                        str(candidate),
                        "--baseline",
                        str(baseline),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(suite_path),
                        "--expected-trials",
                        "6",
                    ]
                )
            self.assertEqual(code, 0, output.getvalue())

            self.assertIn("[PASS] policy_violations", output.getvalue())

    def test_report_multi_validates_frozen_three_arm_identity_and_writes_one_report(self):
        experiment_path = ROOT / "evals/experiments/long-horizon-three-arm-v1.json"
        suite_path = ROOT / "evals/suites/long-horizon-control-plane.json"
        experiment = load_json(experiment_path)
        suite = load_json(suite_path)
        config_ids = arm_config_ids(experiment, suite, "a" * 64, "b" * 64)
        model = experiment["model"]
        model_fingerprint = hashlib.sha256(stable_json(model).encode("utf-8")).hexdigest()[:16]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arm_paths = {}
            for arm_id in config_ids:
                rows = []
                for trial in range(experiment["trials"]):
                    for task in suite["tasks"]:
                        identity = grounding_fingerprints(task, ROOT)
                        item = copy.deepcopy(rollout(task["id"], True, config_ids[arm_id]))
                        item["run_id"] = f"{arm_id}:{task['id']}:{trial}"
                        item["suite_id"] = suite["suite_id"]
                        item["task_fingerprint"] = identity["task_fingerprint"]
                        item["trial"] = trial
                        item["layers"] = task["layers"]
                        item["model"] = {**model, "fingerprint": model_fingerprint}
                        item["harness"].update(
                            {
                                "config_id": config_ids[arm_id],
                                "revision": "same-revision",
                                "fingerprint": f"{arm_id}:{task['id']}",
                                "environment_fingerprint": identity["environment_fingerprint"],
                                "permission_mode": identity["permission_mode"],
                            }
                        )
                        item["evaluator"]["fingerprint"] = identity["grader_fingerprint"]
                        rows.append(item)
                path = root / f"{arm_id}.jsonl"
                write_rollouts(path, rows)
                arm_paths[arm_id] = path
            markdown = root / "report.md"
            result_json = root / "report.json"
            code = main(
                [
                    "report-multi",
                    "--experiment",
                    str(experiment_path),
                    "--codex-style",
                    str(arm_paths["codex_style"]),
                    "--claude-style",
                    str(arm_paths["claude_style"]),
                    "--tinykg",
                    str(arm_paths["tinykg"]),
                    "--markdown",
                    str(markdown),
                    "--json",
                    str(result_json),
                ]
            )
            self.assertEqual(code, 0)
            self.assertIn("三臂长程评估", markdown.read_text(encoding="utf-8"))
            result = load_json(result_json)
            self.assertEqual(result["metacodes_sha256"], "a" * 64)
            self.assertEqual(result["tinykg_sha256"], "b" * 64)
            self.assertEqual(len(result["pairwise"]), 3)

    def test_release_gate_rejects_incomplete_cherry_picked_rollouts(self):
        with tempfile.TemporaryDirectory() as directory:
            gate_config = self._production_gate_config(Path(directory))
            candidate = Path(directory) / "candidate.jsonl"
            baseline = Path(directory) / "baseline.jsonl"
            candidate_item = rollout("00_smoke", True, "candidate")
            baseline_item = rollout("00_smoke", True, "baseline")
            candidate_item["suite_id"] = "metacodes-core-e2e-v1"
            baseline_item["suite_id"] = "metacodes-core-e2e-v1"
            write_rollouts(candidate, [candidate_item])
            write_rollouts(baseline, [baseline_item])
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                code = main(
                    [
                        "gate",
                        str(candidate),
                        "--baseline",
                        str(baseline),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(ROOT / "evals/suites/core-e2e.json"),
                    ]
                )
            self.assertEqual(code, 2)
            self.assertIn("suite/trial contract", error.getvalue())

    def test_production_gate_rejects_uncalibrated_threshold_override(self):
        with tempfile.TemporaryDirectory() as directory:
            gate_config = self._production_gate_config(Path(directory))
            candidate = Path(directory) / "candidate.jsonl"
            write_rollouts(candidate, [rollout("00_smoke", True, "candidate")])
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                code = main(
                    [
                        "gate",
                        str(candidate),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(ROOT / "evals/suites/core-e2e.json"),
                        "--min-trustworthy-success",
                        "0",
                    ]
                )
            self.assertEqual(code, 2)
            self.assertIn("forbids uncalibrated threshold overrides", error.getvalue())

    def test_production_gate_requires_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            gate_config = self._production_gate_config(Path(directory))
            candidate = Path(directory) / "candidate.jsonl"
            write_rollouts(candidate, [rollout("00_smoke", True, "candidate")])
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                code = main(
                    [
                        "gate",
                        str(candidate),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(ROOT / "evals/suites/core-e2e.json"),
                    ]
                )
            self.assertEqual(code, 2)
            self.assertIn("requires --baseline", error.getvalue())

    def test_stale_calibration_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            stale_config = load_json(ROOT / "evals/gates/default.json")
            stale_config["calibration"]["status"] = "stale"
            stale_path = Path(directory) / "stale-gate.json"
            stale_path.write_text(
                json.dumps(stale_config, sort_keys=True) + "\n", encoding="utf-8"
            )
            candidate = Path(directory) / "candidate.jsonl"
            baseline = Path(directory) / "baseline.jsonl"
            write_rollouts(candidate, [rollout("00_smoke", True, "candidate")])
            write_rollouts(baseline, [rollout("00_smoke", True, "baseline")])
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                code = main(
                    [
                        "gate",
                        str(candidate),
                        "--baseline",
                        str(baseline),
                        "--thresholds",
                        str(stale_path),
                        "--suite",
                        str(ROOT / "evals/suites/core-e2e.json"),
                    ]
                )
            self.assertEqual(code, 2)
            self.assertIn("production calibration", error.getvalue())

    def test_production_gate_requires_and_accepts_all_contracted_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gate_config = self._production_gate_config(root, all_suites=True)
            suite_paths = [
                ROOT / "evals/suites/core-e2e.json",
                ROOT / "evals/suites/agentdef-release.json",
            ]
            candidate = root / "candidate.jsonl"
            baseline = root / "baseline.jsonl"
            candidate_rollouts = self._grounded_rollouts(suite_paths)
            baseline_rollouts = copy.deepcopy(candidate_rollouts)
            for item in baseline_rollouts:
                item["run_id"] = item["run_id"].replace("candidate:", "baseline:", 1)
                item["harness"]["config_id"] = "baseline"
                item["harness"]["fingerprint"] = "baseline"
            write_rollouts(candidate, candidate_rollouts)
            write_rollouts(baseline, baseline_rollouts)

            missing_error = io.StringIO()
            with contextlib.redirect_stderr(missing_error):
                missing_code = main(
                    [
                        "gate",
                        str(candidate),
                        "--baseline",
                        str(baseline),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(suite_paths[0]),
                    ]
                )
            self.assertEqual(missing_code, 2)
            self.assertIn("exactly all contracted suites", missing_error.getvalue())

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = main(
                    [
                        "gate",
                        str(candidate),
                        "--baseline",
                        str(baseline),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(suite_paths[0]),
                        "--suite",
                        str(suite_paths[1]),
                        "--expected-trials",
                        "6",
                    ]
                )
            self.assertEqual(code, 0, output.getvalue())

            for item in candidate_rollouts:
                if item["suite_id"] == "metacodes-agentdef-release-v1":
                    item["harness"]["revision"] = "different-candidate-revision"
            write_rollouts(candidate, candidate_rollouts)
            mixed_error = io.StringIO()
            with contextlib.redirect_stderr(mixed_error):
                mixed_code = main(
                    [
                        "gate",
                        str(candidate),
                        "--baseline",
                        str(baseline),
                        "--thresholds",
                        str(gate_config),
                        "--suite",
                        str(suite_paths[0]),
                        "--suite",
                        str(suite_paths[1]),
                        "--expected-trials",
                        "6",
                    ]
                )
            self.assertEqual(mixed_code, 2)
            self.assertIn("across contracted suites", mixed_error.getvalue())


if __name__ == "__main__":
    unittest.main()
