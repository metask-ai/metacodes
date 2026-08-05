import copy
import hashlib
import os
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

from scripts.eval.e2e_adapter import comparison_fingerprints
from scripts.eval.experiment import (
    ARM_IDS,
    build_dry_run_plan,
    counterbalanced_schedule,
    tinykg_binary_identity,
    validate_experiment,
)
from scripts.eval.model import ValidationError, load_json, load_rollouts, write_rollouts
from scripts.eval.paired_runner import InfrastructureRunError, run_multi_arm
from scripts.eval.promotion import build_promotion_receipt
from scripts.eval.tests.multi_arm_fixture import write_multi_arm_checkpoints


ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_PATH = ROOT / "evals/experiments/long-horizon-three-arm-calibration-v2.json"
SUITE_PATH = ROOT / "evals/suites/long-horizon-calibration.json"
CONFIRMATORY_EXPERIMENT_PATH = (
    ROOT / "evals/experiments/long-horizon-three-arm-confirmatory-v2.json"
)
CONFIRMATORY_SUITE_PATH = ROOT / "evals/suites/long-horizon-repository-pk.json"


class LongHorizonExperimentTest(unittest.TestCase):
    def setUp(self):
        self.experiment = load_json(EXPERIMENT_PATH)
        self.suite = load_json(SUITE_PATH)
        self.confirmatory_experiment = load_json(CONFIRMATORY_EXPERIMENT_PATH)
        self.confirmatory_suite = load_json(CONFIRMATORY_SUITE_PATH)

    def test_checked_in_contract_is_valid_and_zero_cost(self):
        validate_experiment(self.experiment, ROOT, self.suite)
        validate_experiment(
            self.confirmatory_experiment, ROOT, self.confirmatory_suite
        )
        self.assertFalse(self.experiment["budget"]["paid_rollouts_enabled"])
        self.assertFalse(
            self.confirmatory_experiment["budget"]["paid_rollouts_enabled"]
        )
        self.assertEqual(self.experiment["stage"]["id"], "calibration")
        self.assertEqual(
            self.confirmatory_experiment["stage"]["id"], "confirmatory"
        )
        self.assertEqual([arm["id"] for arm in self.experiment["arms"]], list(ARM_IDS))

    def test_schedule_balances_every_position_and_ordered_carryover(self):
        schedule = counterbalanced_schedule(ARM_IDS, 6)
        rows = [tuple(arm for trial_id, arm in schedule if trial_id == trial) for trial in range(6)]
        positions = Counter((position, arm) for row in rows for position, arm in enumerate(row))
        self.assertEqual(set(positions.values()), {2})
        carryover = Counter((row[index], row[index + 1]) for row in rows for index in range(2))
        self.assertEqual(set(carryover.values()), {2})
        with self.assertRaisesRegex(ValidationError, "positive multiple of 6"):
            counterbalanced_schedule(ARM_IDS, 5)

    def test_manifest_rejects_label_only_or_confounded_arm(self):
        broken = copy.deepcopy(self.experiment)
        broken["arms"][0]["treatment"]["tinykg"] = True
        with self.assertRaisesRegex(ValidationError, "does not match arm"):
            validate_experiment(broken, ROOT, self.suite)
        confounded = copy.deepcopy(self.experiment)
        confounded["common_runtime"]["agent_teams"] = True
        with self.assertRaisesRegex(ValidationError, "agent_teams=false"):
            validate_experiment(confounded, ROOT, self.suite)
        hidden_knob = copy.deepcopy(self.experiment)
        hidden_knob["temperature"] = 0.7
        with self.assertRaisesRegex(ValidationError, "unknown=.*temperature"):
            validate_experiment(hidden_knob, ROOT, self.suite)
        wrong_provider = copy.deepcopy(self.experiment)
        wrong_provider["model"]["provider"] = "openai"
        with self.assertRaisesRegex(ValidationError, "anthropic/glm-5.2"):
            validate_experiment(wrong_provider, ROOT, self.suite)
        non_blind_suite = copy.deepcopy(self.suite)
        non_blind_suite["tasks"][0]["success"]["checks"].append(
            {"type": "debug_log_contains", "text": "codex_style"}
        )
        with self.assertRaisesRegex(ValidationError, "workspace artifacts only"):
            validate_experiment(self.experiment, ROOT, non_blind_suite)

    def test_confirmatory_manifest_freezes_calibration_source_fingerprint(self):
        replayed = copy.deepcopy(self.confirmatory_experiment)
        replayed["promotion"]["source_experiment_fingerprint"] = "0" * 16
        with self.assertRaisesRegex(
            ValidationError, "source manifest identity or fingerprint mismatch"
        ):
            validate_experiment(replayed, ROOT, self.confirmatory_suite)

    def test_tinykg_dependency_probe_freezes_hash_and_store_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            tinykg = Path(directory) / "tinykg"
            tinykg.write_bytes(b"frozen dependency")
            tinykg.chmod(0o755)
            responses = [
                mock.Mock(returncode=0, stdout="tinykg 0.1.0\n", stderr=""),
                mock.Mock(returncode=0, stdout="ready\n", stderr=""),
                mock.Mock(
                    returncode=0,
                    stdout="storage_format_version=2\nschema_version=3\n",
                    stderr="",
                ),
            ]
            with mock.patch.dict(
                os.environ,
                {"METACODES_KG_BIN": "/host/leak", "TINYKG_STORE": "/host/store"},
            ), mock.patch(
                "scripts.eval.experiment.subprocess.run", side_effect=responses
            ) as run:
                identity = tinykg_binary_identity(tinykg)
        self.assertEqual(identity["path"], str(tinykg.resolve()))
        self.assertEqual(identity["sha256"], hashlib.sha256(b"frozen dependency").hexdigest())
        self.assertEqual(identity["version"], "tinykg 0.1.0")
        self.assertEqual(run.call_count, 3)
        for call in run.call_args_list:
            self.assertNotIn("METACODES_KG_BIN", call.kwargs["env"])
            self.assertNotIn("TINYKG_STORE", call.kwargs["env"])

    def test_dry_run_freezes_binary_revision_arm_env_and_all_rollouts(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "metacodes"
            binary.write_bytes(b"same-binary-for-all-arms")
            binary.chmod(0o755)
            tinykg = Path(directory) / "tinykg"
            tinykg.write_bytes(b"frozen-tinykg")
            tinykg.chmod(0o755)
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": hashlib.sha256(tinykg.read_bytes()).hexdigest(),
                "version": "tinykg test",
            }
            with mock.patch(
                "scripts.eval.experiment.tinykg_binary_identity",
                return_value=tinykg_identity,
            ):
                first = build_dry_run_plan(
                    self.experiment,
                    self.suite,
                    binary=binary,
                    tinykg_binary=tinykg,
                    revision="abc123",
                )
                second = build_dry_run_plan(
                    self.experiment,
                    self.suite,
                    binary=binary,
                    tinykg_binary=tinykg,
                    revision="abc123",
                )
        self.assertEqual(first, second)
        self.assertEqual(first["rollout_count"], 18)
        self.assertEqual(first["execution_identity"]["revision"], "abc123")
        self.assertEqual(first["execution_identity"]["tinykg"], tinykg_identity)
        self.assertEqual(len({row["harness_config_id"] for row in first["rows"]}), 3)
        for row in first["rows"]:
            self.assertEqual(
                row["runtime_env"]["METACODES_LONG_HORIZON_ARM"], row["arm_id"]
            )
            self.assertEqual(row["timeout_seconds"], 900)
            if row["arm_id"] == "tinykg":
                self.assertEqual(
                    row["runtime_env"]["METACODES_KG_BIN"], str(tinykg.resolve())
                )
            else:
                self.assertNotIn("METACODES_KG_BIN", row["runtime_env"])

    def test_multi_arm_checkpoints_resume_without_repeating_rollouts(self):
        experiment = copy.deepcopy(self.experiment)
        experiment["budget"]["paid_rollouts_enabled"] = True
        task_by_id = {task["id"]: task for task in self.suite["tasks"]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"one-revision")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"one-tinykg-revision")
            tinykg.chmod(0o755)
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": hashlib.sha256(tinykg.read_bytes()).hexdigest(),
                "version": "tinykg test",
            }
            output_dir = root / "checkpoints"
            invocations = []
            run_state = {}
            fail_after = [2]

            def fake_run_once(
                _repo_root,
                observed_binary,
                arm_id,
                trial,
                selector,
                model_provider,
                model_id,
                _suite_path,
                revision,
                *,
                harness_config_id=None,
                runtime_env=None,
                allow_invalid_run=False,
                timeout_seconds=None,
            ):
                if fail_after[0] is not None and len(invocations) >= fail_after[0]:
                    raise RuntimeError("simulated interruption")
                token = root / f"run-{len(invocations)}"
                invocations.append((arm_id, trial, selector))
                run_state[token] = (
                    observed_binary,
                    arm_id,
                    trial,
                    selector,
                    model_provider,
                    model_id,
                    revision,
                    harness_config_id,
                    runtime_env,
                    allow_invalid_run,
                    timeout_seconds,
                )
                return token

            def fake_import(_suite, _repo_root, run_dir):
                (
                    observed_binary,
                    arm_id,
                    trial,
                    task_id,
                    model_provider,
                    model_id,
                    revision,
                    harness_config_id,
                    runtime_env,
                    allow_invalid_run,
                    timeout_seconds,
                ) = run_state[run_dir]
                self.assertEqual(runtime_env["METACODES_LONG_HORIZON_ARM"], arm_id)
                if arm_id == "tinykg":
                    self.assertEqual(runtime_env["METACODES_KG_BIN"], str(tinykg.resolve()))
                else:
                    self.assertNotIn("METACODES_KG_BIN", runtime_env)
                self.assertTrue(allow_invalid_run)
                self.assertEqual(timeout_seconds, 900)
                task = task_by_id[task_id]
                identity = comparison_fingerprints(
                    task,
                    ROOT,
                    model_provider=model_provider,
                    model_id=model_id,
                    harness_config_id=harness_config_id,
                    harness_revision=revision,
                    permission_mode=task["constraints"]["permission_mode"],
                    binary_path=observed_binary,
                )
                return [
                    {
                        "schema_version": 1,
                        "run_id": f"{arm_id}:{task_id}:{trial}",
                        "suite_id": self.suite["suite_id"],
                        "task_id": task_id,
                        "task_fingerprint": identity["task_fingerprint"],
                        "task_fingerprint_provenance": "recorded_at_execution",
                        "trial": trial,
                        "layers": task["layers"],
                        "model": {"provider": model_provider, "id": model_id, "fingerprint": identity["model_fingerprint"]},
                        "harness": {"config_id": harness_config_id, "revision": revision, "fingerprint": identity["harness_fingerprint"], "permission_mode": identity["permission_mode"], "environment_fingerprint": identity["environment_fingerprint"]},
                        "readiness": {"status": "pass", "checks": []},
                        "execution": {"status": "completed", "exit_code": 0, "invalid_reasons": []},
                        "outcome": {"status": "pass", "checks": []},
                        "trajectory": {"status": "pass", "checks": [], "tool_failures": []},
                        "evaluator": {"status": "ready", "kind": "deterministic_workspace", "version": "long-horizon-v1", "fingerprint": identity["grader_fingerprint"], "errors": []},
                        "judgement": {"valid_for_scoring": True, "trustworthy_success": True},
                        "metrics": {
                            "cost_usd": 0.0,
                            "input_tokens": 0,
                            "output_tokens": 0,
                            "cache_read_tokens": 0,
                            "cache_write_tokens": 0,
                            "wall_time_ms": 1,
                            "policy_violations": 0,
                        },
                        "attribution": [],
                        "artifacts": {},
                    }
                ]

            patches = (
                mock.patch("scripts.eval.paired_runner._run_once", side_effect=fake_run_once),
                mock.patch("scripts.eval.paired_runner.import_run", side_effect=fake_import),
                mock.patch(
                    "scripts.eval.paired_runner.tinykg_binary_identity",
                    return_value=tinykg_identity,
                ),
            )
            with patches[0], patches[1], patches[2]:
                with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="abc123",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
                self.assertEqual(len(invocations), 2)
                fail_after[0] = None
                invocations.clear()
                result = run_multi_arm(
                    experiment,
                    self.suite,
                    ROOT,
                    binary,
                    tinykg_binary=tinykg,
                    revision="abc123",
                    output_dir=output_dir,
                    suite_path=SUITE_PATH,
                    allow_paid_rollouts=True,
                )
            self.assertEqual(len(invocations), 16)
            self.assertEqual(sum(len(rows) for rows in result.values()), 18)

    def test_multi_arm_rechecks_binary_after_each_rollout(self):
        experiment = copy.deepcopy(self.experiment)
        experiment["budget"]["paid_rollouts_enabled"] = True
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"frozen")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"tinykg")
            tinykg.chmod(0o755)
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": hashlib.sha256(tinykg.read_bytes()).hexdigest(),
                "version": "tinykg test",
            }

            def replace_binary(*_args, **_kwargs):
                binary.write_bytes(b"replaced-during-rollout")
                run_dir = root / "run"
                run_dir.mkdir()
                return run_dir

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner._run_once", side_effect=replace_binary
            ), mock.patch("scripts.eval.paired_runner.import_run") as imported:
                with self.assertRaisesRegex(
                    ValidationError, "changed after experiment identity was frozen"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="abc123",
                        output_dir=root / "checkpoints",
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
            imported.assert_not_called()

    def test_multi_arm_checkpoints_infrastructure_failure_before_abort(self):
        experiment = copy.deepcopy(self.experiment)
        experiment["budget"]["paid_rollouts_enabled"] = True
        task = sorted(self.suite["tasks"], key=lambda item: item["id"])[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"one-revision")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"one-tinykg-revision")
            tinykg.chmod(0o755)
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": hashlib.sha256(tinykg.read_bytes()).hexdigest(),
                "version": "tinykg test",
            }
            output_dir = root / "checkpoints"
            run_dir = root / "invalid-run"
            run_dir.mkdir()

            def fake_run_once(
                _repo_root,
                observed_binary,
                arm_id,
                trial,
                selector,
                model_provider,
                model_id,
                _suite_path,
                revision,
                *,
                harness_config_id=None,
                runtime_env=None,
                allow_invalid_run=False,
                timeout_seconds=None,
            ):
                _ = (
                    observed_binary,
                    selector,
                    model_provider,
                    model_id,
                    revision,
                    harness_config_id,
                    runtime_env,
                )
                self.assertTrue(allow_invalid_run)
                self.assertEqual(timeout_seconds, 900)
                raise InfrastructureRunError(arm_id, trial, 1, run_dir)

            def fake_import(_suite, _repo_root, _run_dir):
                raise ValidationError("partial REPORT is not importable")

            with mock.patch(
                "scripts.eval.paired_runner._run_once", side_effect=fake_run_once
            ), mock.patch(
                "scripts.eval.paired_runner.import_run", side_effect=fake_import
            ), mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ):
                with self.assertRaisesRegex(InfrastructureRunError, "invalid evidence retained"):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="abc123",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
            checkpoint = load_rollouts(output_dir / "codex_style.jsonl")
            self.assertEqual(len(checkpoint), 1)
            self.assertFalse(checkpoint[0]["judgement"]["valid_for_scoring"])
            self.assertIn("e2e_runner_exit:1", checkpoint[0]["execution"]["invalid_reasons"])
            self.assertIn(
                "evidence_import_failed", checkpoint[0]["execution"]["invalid_reasons"]
            )
            self.assertEqual(
                checkpoint[0]["task_fingerprint_provenance"],
                "runner_frozen_before_execution",
            )

    def test_confirmatory_runner_requires_and_wires_calibration_receipt(self):
        experiment = copy.deepcopy(self.confirmatory_experiment)
        experiment["budget"]["paid_rollouts_enabled"] = True
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"confirmatory-metacodes")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"confirmatory-tinykg")
            tinykg.chmod(0o755)
            metacodes_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": tinykg_sha,
                "version": "tinykg test",
            }
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ):
                with self.assertRaisesRegex(
                    ValidationError, "requires a calibration promotion receipt"
                ):
                    run_multi_arm(
                        experiment,
                        self.confirmatory_suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="confirmatory-revision",
                        output_dir=root / "missing-receipt",
                        suite_path=CONFIRMATORY_SUITE_PATH,
                        allow_paid_rollouts=True,
                    )

            calibration_paths = write_multi_arm_checkpoints(
                root / "calibration",
                self.experiment,
                self.suite,
                ROOT,
                metacodes_sha256=metacodes_sha,
                tinykg_sha256=tinykg_sha,
                revision="confirmatory-revision",
            )
            receipt = build_promotion_receipt(
                self.experiment, self.suite, ROOT, calibration_paths
            )
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ):
                with self.assertRaisesRegex(
                    ValidationError, "authoritative calibration checkpoints"
                ):
                    run_multi_arm(
                        experiment,
                        self.confirmatory_suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="confirmatory-revision",
                        output_dir=root / "missing-checkpoints",
                        suite_path=CONFIRMATORY_SUITE_PATH,
                        allow_paid_rollouts=True,
                        promotion_receipt=receipt,
                    )
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner._run_once",
                side_effect=RuntimeError("receipt accepted before paid rollout seam"),
            ):
                with self.assertRaisesRegex(RuntimeError, "receipt accepted"):
                    run_multi_arm(
                        experiment,
                        self.confirmatory_suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="confirmatory-revision",
                        output_dir=root / "accepted-receipt",
                        suite_path=CONFIRMATORY_SUITE_PATH,
                        allow_paid_rollouts=True,
                        promotion_receipt=receipt,
                        calibration_checkpoints=calibration_paths,
                    )

            broken = copy.deepcopy(receipt)
            broken["identity"]["harness_revision"] = "wrong"
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ):
                with self.assertRaisesRegex(
                    ValidationError, "does not match authoritative calibration"
                ):
                    run_multi_arm(
                        experiment,
                        self.confirmatory_suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="confirmatory-revision",
                        output_dir=root / "bad-receipt",
                        suite_path=CONFIRMATORY_SUITE_PATH,
                        allow_paid_rollouts=True,
                        promotion_receipt=broken,
                        calibration_checkpoints=calibration_paths,
                    )

            tampered = load_rollouts(calibration_paths["tinykg"])
            tampered[0]["metrics"]["cost_usd"] = 0.5
            write_rollouts(calibration_paths["tinykg"], tampered)
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch("scripts.eval.paired_runner._run_once") as run_once:
                with self.assertRaisesRegex(
                    ValidationError, "does not match authoritative calibration"
                ):
                    run_multi_arm(
                        experiment,
                        self.confirmatory_suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        revision="confirmatory-revision",
                        output_dir=root / "tampered-checkpoint",
                        suite_path=CONFIRMATORY_SUITE_PATH,
                        allow_paid_rollouts=True,
                        promotion_receipt=receipt,
                        calibration_checkpoints=calibration_paths,
                    )
            run_once.assert_not_called()


if __name__ == "__main__":
    unittest.main()
