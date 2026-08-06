import copy
import hashlib
import json
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
    formal_kernel_identity,
    tinykg_binary_identity,
    validate_experiment,
)
from scripts.eval.model import ValidationError, load_json, load_rollouts, write_rollouts
from scripts.eval.paired_runner import InfrastructureRunError, run_multi_arm
from scripts.eval.promotion import build_promotion_receipt
from scripts.eval.treatment_activation import (
    attach_treatment_activation as real_attach_treatment_activation,
    reverify_treatment_activation as real_reverify_treatment_activation,
)
from scripts.eval.tests.multi_arm_fixture import write_multi_arm_checkpoints
from scripts.eval.tests.test_treatment_activation import (
    TINYKG as REAL_TINYKG,
    write_activation_artifacts,
    write_baseline_artifacts,
)


ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_PATH = ROOT / "evals/experiments/long-horizon-three-arm-calibration-v2.json"
SUITE_PATH = ROOT / "evals/suites/long-horizon-calibration.json"
CONFIRMATORY_EXPERIMENT_PATH = (
    ROOT / "evals/experiments/long-horizon-three-arm-confirmatory-v2.json"
)
CONFIRMATORY_SUITE_PATH = ROOT / "evals/suites/long-horizon-repository-pk.json"


def fake_formal_artifact(root: Path) -> tuple[Path, dict]:
    binary = root / "metacodes-formal-kernel"
    binary.write_bytes(b"formal-kernel-test-artifact")
    binary.chmod(0o755)
    binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
    provenance_path = Path(f"{binary}.provenance.json")
    provenance = {
        "schema_version": "metacodes-formal-artifact-v3",
        "checker_version": "metacodes-formal-kernel-v2",
        "request_schema": "metacodes-formal-request-v1",
        "memory_request_schema": "metacodes-memory-migration-request-v1",
        "verdict_schema": "metacodes-formal-verdict-v2",
        "binary_sha256": binary_sha,
        "binary_bytes": binary.stat().st_size,
        "kernel_source_sha256": "1" * 64,
        "memory_kernel_source_sha256": "2" * 64,
        "main_source_sha256": "3" * 64,
        "axiom_audit_source_sha256": "4" * 64,
        "axiom_policy": "propext,Quot.sound",
        "axiom_audit": "passed",
        "host_os": "test",
        "host_arch": "test",
        "linker": "test",
        "lean_version": "Lean test",
        "native_smoke": "passed",
    }
    provenance_path.write_text(
        json.dumps(provenance, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    provenance_sha = hashlib.sha256(provenance_path.read_bytes()).hexdigest()
    build_receipt_path = Path(f"{binary}.build-receipt.json")
    build_receipt = {
        "schema_version": "metacodes-formal-build-receipt-v1",
        "artifact_manifest_sha256": provenance_sha,
        "binary_sha256": binary_sha,
        "built_at_utc": "2026-08-06T00:00:00Z",
    }
    build_receipt_path.write_text(
        json.dumps(build_receipt, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    build_receipt_sha = hashlib.sha256(build_receipt_path.read_bytes()).hexdigest()
    fingerprint_payload = {
        "binary_sha256": binary_sha,
        "provenance_sha256": provenance_sha,
        "checker_version": provenance["checker_version"],
        "request_schema": provenance["request_schema"],
        "memory_request_schema": provenance["memory_request_schema"],
        "verdict_schema": provenance["verdict_schema"],
    }
    identity = {
        "path": str(binary.resolve()),
        "sha256": binary_sha,
        "bytes": binary.stat().st_size,
        "provenance_path": str(provenance_path.resolve()),
        "provenance_sha256": provenance_sha,
        "build_receipt_path": str(build_receipt_path.resolve()),
        "build_receipt_sha256": build_receipt_sha,
        "checker_version": "metacodes-formal-kernel-v2",
        "artifact_fingerprint": hashlib.sha256(
            json.dumps(
                fingerprint_payload, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        ).hexdigest(),
    }
    return binary, identity


class LongHorizonExperimentTest(unittest.TestCase):
    def setUp(self):
        self.experiment = load_json(EXPERIMENT_PATH)
        self.suite = load_json(SUITE_PATH)
        self.confirmatory_experiment = load_json(CONFIRMATORY_EXPERIMENT_PATH)
        self.confirmatory_suite = load_json(CONFIRMATORY_SUITE_PATH)
        # Most runner tests use normalized synthetic rollouts.  Keep that test
        # seam explicit instead of weakening the production verifier; dedicated
        # treatment tests exercise real events/transcripts/TinyKG stores.
        attach_patcher = mock.patch(
            "scripts.eval.paired_runner.attach_treatment_activation"
        )
        resume_patcher = mock.patch(
            "scripts.eval.paired_runner.reverify_treatment_activation"
        )
        promotion_patcher = mock.patch(
            "scripts.eval.promotion.reverify_treatment_activation"
        )
        self.attach_activation = attach_patcher.start()
        self.resume_activation = resume_patcher.start()
        self.promotion_activation = promotion_patcher.start()
        self.addCleanup(attach_patcher.stop)
        self.addCleanup(resume_patcher.stop)
        self.addCleanup(promotion_patcher.stop)

    def test_checked_in_contract_is_valid_and_zero_cost(self):
        validate_experiment(self.experiment, ROOT, self.suite)
        validate_experiment(
            self.confirmatory_experiment, ROOT, self.confirmatory_suite
        )
        self.assertTrue(self.experiment["budget"]["paid_rollouts_enabled"])
        self.assertFalse(
            self.confirmatory_experiment["budget"]["paid_rollouts_enabled"]
        )
        self.assertEqual(self.experiment["stage"]["id"], "calibration")
        self.assertEqual(
            self.confirmatory_experiment["stage"]["id"], "confirmatory"
        )
        self.assertEqual(
            self.experiment["budget"]["max_rollout_tokens"], 1_200_000
        )
        self.assertEqual(
            self.confirmatory_experiment["budget"]["max_rollout_tokens"],
            1_200_000,
        )
        self.assertEqual(
            self.experiment["budget"]["max_rollout_cost_usd"], 2.0
        )
        self.assertEqual([arm["id"] for arm in self.experiment["arms"]], list(ARM_IDS))

    def test_budget_contract_rejects_partial_or_infeasible_fixed_rollout_caps(self):
        partial = copy.deepcopy(self.experiment)
        partial["budget"].pop("max_rollout_tokens")
        with self.assertRaisesRegex(ValidationError, "missing or unknown"):
            validate_experiment(partial, ROOT, self.suite)

        infeasible = copy.deepcopy(self.experiment)
        infeasible["budget"]["max_stage_tokens"] = 18 * 1_200_000
        with self.assertRaisesRegex(ValidationError, "strictly cover"):
            validate_experiment(infeasible, ROOT, self.suite)

        # Frozen schema-v2 failure evidence predates fixed caps and remains
        # readable, but current dry-run/live entry points reject it.
        legacy = copy.deepcopy(self.experiment)
        legacy["budget"].pop("max_rollout_tokens")
        legacy["budget"].pop("max_rollout_cost_usd")
        validate_experiment(legacy, ROOT, self.suite)

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

    def test_formal_kernel_probe_binds_binary_provenance_and_native_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            binary, expected = fake_formal_artifact(Path(directory))
            verdict = {
                "schema_version": "metacodes-formal-verdict-v2",
                "checker_version": "metacodes-formal-kernel-v2",
                "request_id": "a" * 64,
                "operation": "task_audit",
                "proposal_sha256": "b" * 64,
                "snapshot_sha256": "c" * 64,
                "snapshot_revision": "d" * 64,
                "decision": "admit",
                "admitted": True,
                "reason_codes": [],
            }
            with mock.patch.dict(
                os.environ,
                {
                    "METACODES_FORMAL_KERNEL_PATH": "/host/leak",
                    "TINYKG_STORE": "/host/store",
                },
            ), mock.patch(
                "scripts.eval.experiment.subprocess.run",
                return_value=mock.Mock(
                    returncode=0,
                    stdout=json.dumps(verdict),
                    stderr="",
                ),
            ) as run:
                observed = formal_kernel_identity(binary)
            self.assertEqual(observed, expected)
            self.assertNotIn("METACODES_FORMAL_KERNEL_PATH", run.call_args.kwargs["env"])
            self.assertNotIn("TINYKG_STORE", run.call_args.kwargs["env"])
            self.assertTrue(
                run.call_args.kwargs["input"].startswith(
                    '{"schema_version":"metacodes-formal-request-v1","request_id":'
                )
            )

            provenance_path = Path(expected["provenance_path"])
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["binary_sha256"] = "0" * 64
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "does not bind"):
                formal_kernel_identity(binary)

    def test_formal_kernel_identity_separates_stable_manifest_from_build_time(self):
        with tempfile.TemporaryDirectory() as directory:
            binary, _ = fake_formal_artifact(Path(directory))
            verdict = {
                "schema_version": "metacodes-formal-verdict-v2",
                "checker_version": "metacodes-formal-kernel-v2",
                "request_id": "a" * 64,
                "operation": "task_audit",
                "proposal_sha256": "b" * 64,
                "snapshot_sha256": "c" * 64,
                "snapshot_revision": "d" * 64,
                "decision": "admit",
                "admitted": True,
                "reason_codes": [],
            }
            with mock.patch(
                "scripts.eval.experiment.subprocess.run",
                return_value=mock.Mock(returncode=0, stdout=json.dumps(verdict), stderr=""),
            ):
                first = formal_kernel_identity(binary)
                receipt_path = Path(first["build_receipt_path"])
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                receipt["built_at_utc"] = "2026-08-06T00:00:01Z"
                receipt_path.write_text(
                    json.dumps(receipt, sort_keys=True, separators=(",", ":")),
                    encoding="utf-8",
                )
                second = formal_kernel_identity(binary)

            self.assertEqual(first["artifact_fingerprint"], second["artifact_fingerprint"])
            self.assertEqual(first["provenance_sha256"], second["provenance_sha256"])
            self.assertNotEqual(
                first["build_receipt_sha256"], second["build_receipt_sha256"]
            )

            receipt["artifact_manifest_sha256"] = "0" * 64
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            with mock.patch(
                "scripts.eval.experiment.subprocess.run",
                return_value=mock.Mock(returncode=0, stdout=json.dumps(verdict), stderr=""),
            ), self.assertRaisesRegex(ValidationError, "does not bind"):
                formal_kernel_identity(binary)

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
            formal, formal_identity = fake_formal_artifact(Path(directory))
            with mock.patch(
                "scripts.eval.experiment.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.experiment.formal_kernel_identity",
                return_value=formal_identity,
            ):
                first = build_dry_run_plan(
                    self.experiment,
                    self.suite,
                    binary=binary,
                    tinykg_binary=tinykg,
                    formal_kernel=formal,
                    revision="abc123",
                    budget_used_cost_usd=1.25,
                    budget_used_tokens=1234,
                )
                second = build_dry_run_plan(
                    self.experiment,
                    self.suite,
                    binary=binary,
                    tinykg_binary=tinykg,
                    formal_kernel=formal,
                    revision="abc123",
                    budget_used_cost_usd=1.25,
                    budget_used_tokens=1234,
                )
        self.assertEqual(first, second)
        self.assertEqual(first["rollout_count"], 18)
        self.assertEqual(first["execution_identity"]["revision"], "abc123")
        self.assertEqual(first["execution_identity"]["tinykg"], tinykg_identity)
        self.assertEqual(first["execution_identity"]["formal_kernel"], formal_identity)
        self.assertEqual(first["budget_carryover"]["stage_used_cost_usd"], 1.25)
        self.assertEqual(first["budget_carryover"]["stage_used_tokens"], 1234)
        self.assertEqual(first["budget_carryover"]["stage_remaining_cost_usd"], 98.75)
        self.assertEqual(first["budget_carryover"]["stage_remaining_tokens"], 23_998_766)
        self.assertEqual(
            first["schedule_capacity"],
            {
                "fixed_rollout_cost_usd": 2.0,
                "fixed_rollout_tokens": 1_200_000,
                "required_cost_reserve_usd": 36.0,
                "required_token_reserve": 21_600_000,
                "available_cost_usd": 98.75,
                "available_tokens": 23_998_766,
                "strictly_feasible": True,
            },
        )
        self.assertEqual(len({row["harness_config_id"] for row in first["rows"]}), 3)
        for row in first["rows"]:
            self.assertEqual(
                row["runtime_budget"],
                {"max_cost_usd": 2.0, "max_metered_tokens": 1_200_000},
            )
            self.assertEqual(
                row["runtime_env"]["METACODES_LONG_HORIZON_ARM"], row["arm_id"]
            )
            self.assertEqual(row["timeout_seconds"], 900)
            if row["arm_id"] == "tinykg":
                self.assertEqual(
                    row["runtime_env"]["METACODES_KG_BIN"], str(tinykg.resolve())
                )
                self.assertEqual(
                    row["runtime_env"]["METACODES_FORMAL_KERNEL_PATH"],
                    str(formal.resolve()),
                )
                self.assertEqual(
                    row["runtime_env"]["METACODES_FORMAL_KERNEL_SHA256"],
                    formal_identity["sha256"],
                )
            else:
                self.assertNotIn("METACODES_KG_BIN", row["runtime_env"])
                self.assertNotIn("METACODES_FORMAL_KERNEL_PATH", row["runtime_env"])
                self.assertNotIn("METACODES_FORMAL_KERNEL_SHA256", row["runtime_env"])

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
            formal, formal_identity = fake_formal_artifact(root)
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
                max_metered_tokens=None,
                max_cost_usd=None,
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
                    max_metered_tokens,
                    max_cost_usd,
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
                    max_metered_tokens,
                    max_cost_usd,
                ) = run_state[run_dir]
                self.assertEqual(runtime_env["METACODES_LONG_HORIZON_ARM"], arm_id)
                if arm_id == "tinykg":
                    self.assertEqual(runtime_env["METACODES_KG_BIN"], str(tinykg.resolve()))
                    self.assertEqual(
                        runtime_env["METACODES_FORMAL_KERNEL_PATH"],
                        str(formal.resolve()),
                    )
                    self.assertEqual(
                        runtime_env["METACODES_FORMAL_KERNEL_SHA256"],
                        formal_identity["sha256"],
                    )
                else:
                    self.assertNotIn("METACODES_KG_BIN", runtime_env)
                    self.assertNotIn("METACODES_FORMAL_KERNEL_PATH", runtime_env)
                    self.assertNotIn("METACODES_FORMAL_KERNEL_SHA256", runtime_env)
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
                        "harness": {"config_id": harness_config_id, "revision": revision, "fingerprint": identity["harness_fingerprint"], "permission_mode": identity["permission_mode"], "environment_fingerprint": identity["environment_fingerprint"], "runtime_budget": {"max_metered_tokens": max_metered_tokens, "max_cost_usd": max_cost_usd}},
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
                mock.patch(
                    "scripts.eval.paired_runner.formal_kernel_identity",
                    return_value=formal_identity,
                ),
            )
            with patches[0], patches[1], patches[2], patches[3]:
                with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="abc123",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
                self.assertEqual(len(invocations), 2)
                checkpoint_path = sorted(output_dir.glob("*.jsonl"))[0]
                checkpoint_bytes = checkpoint_path.read_bytes()
                tampered = load_rollouts(checkpoint_path)
                tampered[0]["harness"].pop("runtime_budget")
                write_rollouts(checkpoint_path, tampered)
                with self.assertRaisesRegex(
                    ValidationError, "missing runtime budget provenance"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="abc123",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
                checkpoint_path.write_bytes(checkpoint_bytes)
                fail_after[0] = None
                invocations.clear()
                result = run_multi_arm(
                    experiment,
                    self.suite,
                    ROOT,
                    binary,
                    tinykg_binary=tinykg,
                    formal_kernel=formal,
                    revision="abc123",
                    output_dir=output_dir,
                    suite_path=SUITE_PATH,
                    allow_paid_rollouts=True,
                )
            self.assertEqual(len(invocations), 16)
            self.assertEqual(sum(len(rows) for rows in result.values()), 18)
            self.assertTrue(
                all(
                    row["harness"].get("runtime_budget")
                    for rows in result.values()
                    for row in rows
                )
            )

    def test_multi_arm_rejects_infeasible_remaining_schedule_before_rollout(self):
        experiment = copy.deepcopy(self.experiment)
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
            formal, formal_identity = fake_formal_artifact(root)
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ), mock.patch("scripts.eval.paired_runner._run_once") as run_once:
                # 24M stage cap - 2.4M carryover leaves exactly 18 × 1.2M.
                # Equality is not enough because reaching the hard cap denies
                # promotion; the runner must spend zero model calls.
                with self.assertRaisesRegex(
                    ValidationError, "not budget-feasible before network"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="abc123",
                        output_dir=root / "checkpoints",
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                        budget_used_tokens=2_400_000,
                    )
            run_once.assert_not_called()

    def test_multi_arm_checkpoints_runtime_budget_overrun_before_abort(self):
        experiment = copy.deepcopy(self.experiment)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"fixed-budget-metacodes")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"fixed-budget-tinykg")
            tinykg.chmod(0o755)
            metacodes_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": tinykg_sha,
                "version": "tinykg test",
            }
            formal, formal_identity = fake_formal_artifact(root)
            seed_paths = write_multi_arm_checkpoints(
                root / "seed",
                experiment,
                self.suite,
                ROOT,
                metacodes_sha256=metacodes_sha,
                tinykg_sha256=tinykg_sha,
                formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
                revision="budget-revision",
            )
            over_budget = load_rollouts(seed_paths["codex_style"])[0]
            sealed_tokens = over_budget["harness"]["runtime_budget"][
                "max_metered_tokens"
            ]
            over_budget["metrics"].update(
                {
                    "input_tokens": sealed_tokens + 1,
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                }
            )
            run_dir = root / "over-budget-run"
            run_dir.mkdir()
            output_dir = root / "checkpoints"

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ), mock.patch(
                "scripts.eval.paired_runner._run_once", return_value=run_dir
            ), mock.patch(
                "scripts.eval.paired_runner.import_run",
                return_value=[copy.deepcopy(over_budget)],
            ):
                with self.assertRaisesRegex(
                    ValidationError, "exceeded its sealed fixed budget"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="budget-revision",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )

            checkpoint = load_rollouts(output_dir / "codex_style.jsonl")
            self.assertEqual(len(checkpoint), 1)
            self.assertEqual(
                checkpoint[0]["metrics"]["input_tokens"], sealed_tokens + 1
            )
            self.assertEqual(checkpoint[0]["execution"]["status"], "invalid")
            self.assertIn(
                "runtime_budget_contract_violation",
                checkpoint[0]["execution"]["invalid_reasons"],
            )
            self.assertFalse(checkpoint[0]["judgement"]["valid_for_scoring"])
            self.assertIn(
                "runtime_budget_contract_violation",
                [item["code"] for item in checkpoint[0]["attribution"]],
            )

    def test_multi_arm_checkpoints_treatment_failure_before_abort(self):
        experiment = copy.deepcopy(self.experiment)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"activation-metacodes")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"activation-tinykg")
            tinykg.chmod(0o755)
            metacodes_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": tinykg_sha,
                "version": "tinykg test",
            }
            formal, formal_identity = fake_formal_artifact(root)
            seed_paths = write_multi_arm_checkpoints(
                root / "seed",
                experiment,
                self.suite,
                ROOT,
                metacodes_sha256=metacodes_sha,
                tinykg_sha256=tinykg_sha,
                formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
                revision="activation-revision",
            )
            rollout = load_rollouts(seed_paths["codex_style"])[0]
            run_dir = root / "activation-run"
            run_dir.mkdir()
            output_dir = root / "checkpoints"

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ), mock.patch(
                "scripts.eval.paired_runner._run_once", return_value=run_dir
            ), mock.patch(
                "scripts.eval.paired_runner.import_run",
                return_value=[copy.deepcopy(rollout)],
            ), mock.patch(
                "scripts.eval.paired_runner.attach_treatment_activation",
                side_effect=ValidationError("persistent lifecycle was not activated"),
            ) as attester:
                with self.assertRaisesRegex(
                    ValidationError, "persistent lifecycle was not activated"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="activation-revision",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )

            attester.assert_called_once()
            checkpoint = load_rollouts(output_dir / "codex_style.jsonl")
            self.assertEqual(len(checkpoint), 1)
            self.assertEqual(checkpoint[0]["execution"]["status"], "invalid")
            self.assertIn(
                "treatment_activation_failed",
                checkpoint[0]["execution"]["invalid_reasons"],
            )
            self.assertFalse(checkpoint[0]["judgement"]["valid_for_scoring"])
            self.assertIn(
                "treatment_activation_failed",
                [item["code"] for item in checkpoint[0]["attribution"]],
            )

    def test_multi_arm_does_not_abort_past_failed_treatment_checkpoint(self):
        experiment = copy.deepcopy(self.experiment)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"checkpoint-failure-metacodes")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"checkpoint-failure-tinykg")
            tinykg.chmod(0o755)
            metacodes_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": tinykg_sha,
                "version": "tinykg test",
            }
            formal, formal_identity = fake_formal_artifact(root)
            seed_paths = write_multi_arm_checkpoints(
                root / "seed",
                experiment,
                self.suite,
                ROOT,
                metacodes_sha256=metacodes_sha,
                tinykg_sha256=tinykg_sha,
                formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
                revision="checkpoint-failure-revision",
            )
            rollout = load_rollouts(seed_paths["codex_style"])[0]
            run_dir = root / "activation-run"
            run_dir.mkdir()
            output_dir = root / "checkpoints"

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ), mock.patch(
                "scripts.eval.paired_runner._run_once", return_value=run_dir
            ), mock.patch(
                "scripts.eval.paired_runner.import_run",
                return_value=[copy.deepcopy(rollout)],
            ), mock.patch(
                "scripts.eval.paired_runner.attach_treatment_activation",
                side_effect=ValidationError("persistent lifecycle was not activated"),
            ) as attester, mock.patch(
                "scripts.eval.paired_runner.write_rollouts",
                side_effect=OSError("checkpoint commit failed"),
            ) as checkpoint_writer:
                with self.assertRaisesRegex(OSError, "checkpoint commit failed"):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="checkpoint-failure-revision",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )

            attester.assert_called_once()
            checkpoint_writer.assert_called_once()
            written_rows = list(checkpoint_writer.call_args.args[1])
            self.assertEqual(written_rows[0]["execution"]["status"], "invalid")
            self.assertIn(
                "treatment_activation_failed",
                written_rows[0]["execution"]["invalid_reasons"],
            )
            self.assertFalse((output_dir / "codex_style.jsonl").exists())

    def test_multi_arm_resume_reverifies_treatment_before_network(self):
        experiment = copy.deepcopy(self.experiment)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"resume-metacodes")
            binary.chmod(0o755)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"resume-tinykg")
            tinykg.chmod(0o755)
            metacodes_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            tinykg_identity = {
                "path": str(tinykg.resolve()),
                "sha256": tinykg_sha,
                "version": "tinykg test",
            }
            formal, formal_identity = fake_formal_artifact(root)
            seed_paths = write_multi_arm_checkpoints(
                root / "seed",
                experiment,
                self.suite,
                ROOT,
                metacodes_sha256=metacodes_sha,
                tinykg_sha256=tinykg_sha,
                formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
                revision="resume-revision",
            )
            resumed = load_rollouts(seed_paths["codex_style"])[0]
            task = next(
                item for item in self.suite["tasks"] if item["id"] == resumed["task_id"]
            )
            identity = comparison_fingerprints(
                task,
                ROOT,
                model_provider=experiment["model"]["provider"],
                model_id=experiment["model"]["id"],
                harness_config_id=resumed["harness"]["config_id"],
                harness_revision="resume-revision",
                permission_mode=task["constraints"]["permission_mode"],
                binary_path=binary,
            )
            resumed["model"]["fingerprint"] = identity["model_fingerprint"]
            resumed["harness"]["fingerprint"] = identity["harness_fingerprint"]
            resumed["harness"]["environment_fingerprint"] = identity[
                "environment_fingerprint"
            ]
            resumed["evaluator"]["fingerprint"] = identity["grader_fingerprint"]
            output_dir = root / "checkpoints"
            write_rollouts(output_dir / "codex_style.jsonl", [resumed])

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.reverify_treatment_activation",
                side_effect=ValidationError("activation artifacts changed"),
            ) as verifier, mock.patch(
                "scripts.eval.paired_runner._run_once"
            ) as run_once:
                with self.assertRaisesRegex(
                    ValidationError, "activation artifacts changed"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="resume-revision",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
            verifier.assert_called_once()
            run_once.assert_not_called()

    @unittest.skipUnless(
        REAL_TINYKG.is_file(), "build the vendored TinyKG binary first"
    )
    def test_multi_arm_attaches_real_tinykg_receipt_before_checkpoint(self):
        experiment = copy.deepcopy(self.experiment)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "metacodes"
            binary.write_bytes(b"real-activation-metacodes")
            binary.chmod(0o755)
            tinykg = REAL_TINYKG.resolve()
            metacodes_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            tinykg_identity = {
                "path": str(tinykg),
                "sha256": tinykg_sha,
                "version": "tinykg test",
            }
            formal, formal_identity = fake_formal_artifact(root)
            seed_paths = write_multi_arm_checkpoints(
                root / "seed",
                experiment,
                self.suite,
                ROOT,
                metacodes_sha256=metacodes_sha,
                tinykg_sha256=tinykg_sha,
                formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
                revision="real-activation-revision",
            )

            def normalize(arm_id):
                item = load_rollouts(seed_paths[arm_id])[0]
                task = next(
                    task
                    for task in self.suite["tasks"]
                    if task["id"] == item["task_id"]
                )
                identity = comparison_fingerprints(
                    task,
                    ROOT,
                    model_provider=experiment["model"]["provider"],
                    model_id=experiment["model"]["id"],
                    harness_config_id=item["harness"]["config_id"],
                    harness_revision="real-activation-revision",
                    permission_mode=task["constraints"]["permission_mode"],
                    binary_path=binary,
                )
                item["model"]["fingerprint"] = identity["model_fingerprint"]
                item["harness"]["fingerprint"] = identity["harness_fingerprint"]
                item["harness"]["environment_fingerprint"] = identity[
                    "environment_fingerprint"
                ]
                item["evaluator"]["fingerprint"] = identity["grader_fingerprint"]
                return item

            output_dir = root / "checkpoints"
            for arm_id in ("codex_style", "claude_style"):
                write_rollouts(output_dir / f"{arm_id}.jsonl", [normalize(arm_id)])

            tinykg_rollout = normalize("tinykg")
            workspace = root / "tinykg-workspace"
            workspace.mkdir()
            write_activation_artifacts(
                workspace,
                tinykg,
                metadata={
                    "run_id": tinykg_rollout["run_id"],
                    "trial": tinykg_rollout["trial"],
                    "suite_id": tinykg_rollout["suite_id"],
                    "task_id": tinykg_rollout["task_id"],
                    "harness_config_id": tinykg_rollout["harness"]["config_id"],
                },
            )
            tinykg_rollout["artifacts"] = {"workspace": str(workspace)}
            run_dir = root / "run"
            run_dir.mkdir()

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ), mock.patch(
                "scripts.eval.paired_runner._run_once",
                side_effect=[run_dir, RuntimeError("stop after real activation")],
            ), mock.patch(
                "scripts.eval.paired_runner.import_run",
                return_value=[tinykg_rollout],
            ), mock.patch(
                "scripts.eval.paired_runner.attach_treatment_activation",
                new=real_attach_treatment_activation,
            ):
                with self.assertRaisesRegex(RuntimeError, "stop after real activation"):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
                        revision="real-activation-revision",
                        output_dir=output_dir,
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )

            persisted = load_rollouts(output_dir / "tinykg.jsonl")
            self.assertEqual(len(persisted), 1)
            self.assertEqual(
                [row["phase"] for row in persisted[0]["treatment_activation"]["trace"]],
                ["created", "claimed", "completed"],
            )
            real_reverify_treatment_activation(
                persisted[0], "tinykg", tinykg, tinykg_sha
            )

    def test_promotion_rechecks_fixed_runtime_budget_and_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tinykg = root / "tinykg"
            tinykg.write_bytes(b"test-only-tinykg")
            tinykg.chmod(0o755)
            paths = write_multi_arm_checkpoints(
                root,
                self.experiment,
                self.suite,
                ROOT,
                metacodes_sha256="a" * 64,
                tinykg_sha256="b" * 64,
                formal_kernel_fingerprint="c" * 64,
                revision="budget-revision",
            )
            original = paths["tinykg"].read_bytes()
            rows = load_rollouts(paths["tinykg"])
            rows[0]["harness"]["runtime_budget"]["max_metered_tokens"] += 1
            write_rollouts(paths["tinykg"], rows)
            with self.assertRaisesRegex(
                ValidationError, "runtime budget is not the frozen"
            ):
                build_promotion_receipt(
                    self.experiment,
                    self.suite,
                    ROOT,
                    paths,
                    tinykg_binary=tinykg,
                )

            paths["tinykg"].write_bytes(original)
            rows = load_rollouts(paths["tinykg"])
            sealed_tokens = rows[0]["harness"]["runtime_budget"][
                "max_metered_tokens"
            ]
            rows[0]["metrics"].update(
                {
                    "input_tokens": sealed_tokens + 1,
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                }
            )
            write_rollouts(paths["tinykg"], rows)
            with self.assertRaisesRegex(
                ValidationError, "exceeded its frozen per-rollout budget"
            ):
                build_promotion_receipt(
                    self.experiment,
                    self.suite,
                    ROOT,
                    paths,
                    tinykg_binary=tinykg,
                )

    @unittest.skipUnless(
        REAL_TINYKG.is_file(), "build the vendored TinyKG binary first"
    )
    def test_promotion_reverifies_all_raw_treatment_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tinykg = REAL_TINYKG.resolve()
            tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()
            paths = write_multi_arm_checkpoints(
                root / "checkpoints",
                self.experiment,
                self.suite,
                ROOT,
                metacodes_sha256="a" * 64,
                tinykg_sha256=tinykg_sha,
                formal_kernel_fingerprint="c" * 64,
                revision="raw-promotion-revision",
            )
            baseline_transcript = None
            for arm_id, path in paths.items():
                rows = load_rollouts(path)
                for row in rows:
                    workspace = (
                        root
                        / "artifacts"
                        / arm_id
                        / f"{row['task_id']}-{row['trial']}"
                    )
                    workspace.mkdir(parents=True)
                    metadata = {
                        "run_id": row["run_id"],
                        "trial": row["trial"],
                        "suite_id": row["suite_id"],
                        "task_id": row["task_id"],
                        "harness_config_id": row["harness"]["config_id"],
                    }
                    if arm_id == "tinykg":
                        write_activation_artifacts(
                            workspace, tinykg, metadata=metadata
                        )
                    else:
                        write_baseline_artifacts(
                            workspace, arm_id, metadata=metadata
                        )
                        baseline_transcript = workspace / "transcript.jsonl"
                    row["artifacts"] = {"workspace": str(workspace)}
                    real_attach_treatment_activation(
                        row, arm_id, tinykg, tinykg_sha
                    )
                write_rollouts(path, rows)

            with mock.patch(
                "scripts.eval.promotion.reverify_treatment_activation",
                new=real_reverify_treatment_activation,
            ):
                receipt = build_promotion_receipt(
                    self.experiment,
                    self.suite,
                    ROOT,
                    paths,
                    tinykg_binary=tinykg,
                )
                self.assertTrue(receipt["eligible"])
                self.assertEqual(receipt["gate"]["valid_rollouts"], 18)

                assert baseline_transcript is not None
                baseline_transcript.write_text(
                    baseline_transcript.read_text(encoding="utf-8").replace(
                        '"text": "done"', '"text": "tampered"'
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    ValidationError, "artifacts changed after attestation"
                ):
                    build_promotion_receipt(
                        self.experiment,
                        self.suite,
                        ROOT,
                        paths,
                        tinykg_binary=tinykg,
                    )

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
            formal, formal_identity = fake_formal_artifact(root)

            def replace_binary(*_args, **_kwargs):
                binary.write_bytes(b"replaced-during-rollout")
                run_dir = root / "run"
                run_dir.mkdir()
                return run_dir

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
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
                        formal_kernel=formal,
                        revision="abc123",
                        output_dir=root / "checkpoints",
                        suite_path=SUITE_PATH,
                        allow_paid_rollouts=True,
                    )
            imported.assert_not_called()

    def test_multi_arm_rechecks_formal_artifact_after_each_rollout(self):
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
            formal, formal_identity = fake_formal_artifact(root)
            replaced = dict(formal_identity)
            replaced["provenance_sha256"] = "0" * 64

            def finish_one_rollout(*_args, **_kwargs):
                run_dir = root / "run"
                run_dir.mkdir()
                return run_dir

            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                side_effect=[formal_identity, formal_identity, replaced],
            ), mock.patch(
                "scripts.eval.paired_runner._run_once", side_effect=finish_one_rollout
            ), mock.patch("scripts.eval.paired_runner.import_run") as imported:
                with self.assertRaisesRegex(
                    ValidationError, "formal kernel artifact changed"
                ):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
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
            formal, formal_identity = fake_formal_artifact(root)
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
                max_metered_tokens=None,
                max_cost_usd=None,
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
                self.assertGreater(max_metered_tokens, 0)
                self.assertGreater(max_cost_usd, 0)
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
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
            ):
                with self.assertRaisesRegex(InfrastructureRunError, "invalid evidence retained"):
                    run_multi_arm(
                        experiment,
                        self.suite,
                        ROOT,
                        binary,
                        tinykg_binary=tinykg,
                        formal_kernel=formal,
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
            self.assertGreater(
                checkpoint[0]["harness"]["runtime_budget"]["max_metered_tokens"], 0
            )
            self.assertGreater(
                checkpoint[0]["harness"]["runtime_budget"]["max_cost_usd"], 0
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
            formal, formal_identity = fake_formal_artifact(root)
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
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
                        formal_kernel=formal,
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
                formal_kernel_fingerprint=formal_identity["artifact_fingerprint"],
                revision="confirmatory-revision",
            )
            receipt = build_promotion_receipt(
                self.experiment,
                self.suite,
                ROOT,
                calibration_paths,
                tinykg_binary=tinykg,
            )
            self.assertEqual(self.promotion_activation.call_count, 18)
            with mock.patch(
                "scripts.eval.paired_runner.tinykg_binary_identity",
                return_value=tinykg_identity,
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
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
                        formal_kernel=formal,
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
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
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
                        formal_kernel=formal,
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
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
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
                        formal_kernel=formal,
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
            ), mock.patch(
                "scripts.eval.paired_runner.formal_kernel_identity",
                return_value=formal_identity,
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
                        formal_kernel=formal,
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
