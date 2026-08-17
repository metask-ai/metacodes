import copy
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.model import stable_json
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
)
from scripts.eval.workbuddy.launch_gate import (
    COMPARISON_SCHEMA_VERSION,
    RECEIPT_SCHEMA_VERSION,
    SCHEMA_VERSION,
    HOST_CONTROL_PLANE_MODULES,
    LaunchError,
)
from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT
from scripts.eval.workbuddy.paired_analysis import (
    VERIFICATION_CHECKPOINT,
    build_report,
)
from scripts.eval.workbuddy import paired_analysis


def digest(label: str) -> str:
    return hashlib.sha256(label.encode()).hexdigest()


class WorkBuddyPairedAnalysisTest(unittest.TestCase):
    def _write(self, path: Path, value: dict) -> Path:
        path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(path, 0o600)
        return path

    def _manifest(
        self, root: Path, arm: str, *, study: str = "project_control"
    ) -> tuple[Path, dict]:
        mode = (
            {"baseline": "disabled", "treatment": "enforced"}[arm]
            if study == "project_control"
            else "disabled"
        )
        covariates = {
            "cohort": ["task-a", "task-b"],
            "artifact_sha256": digest("same-artifact"),
            "model_sha256": digest("same-model"),
            "context_window": 200_000,
            "context_compact_pct": 92,
            "cache_prefix_contract": "equal",
        }
        value = {
            "schema_version": SCHEMA_VERSION,
            "quality_evidence": False,
            "quality_evidence_on_commit": True,
            "evaluation_treatment": {
                "project_control": mode,
                "actor_prompt_changed": False,
                "tool_schema_changed": False,
                "provider_cache_prefix_changed_by_control_plane": False,
                "verification_checkpoint": (
                    arm == "treatment" if study == VERIFICATION_CHECKPOINT else False
                ),
            },
            "comparison": {
                "schema_version": COMPARISON_SCHEMA_VERSION,
                "comparison_id": "code-2-project-control-pair",
                "covariates_sha256": hashlib.sha256(
                    stable_json(covariates).encode()
                ).hexdigest(),
                "covariates": covariates,
            },
            "run_id": f"code-2-{arm}",
            "workbuddy": {
                "commit": WORKBUDDY_PINNED_COMMIT,
                "overlay_content_sha256": digest("overlay"),
                "checkout": str(root / "checkout"),
            },
            "cohort": {
                "selected_tasks": ["task-a", "task-b"],
                "selected_tasks_sha256": digest("tasks"),
            },
            "artifacts": {"project_control": {"same": True}},
            "environment_preflight": {
                "target_platform": "linux/amd64",
                "content_sha256": digest("preflight"),
                "receipt": {"path": "/fixture/preflight", "bytes": 1, "sha256": digest("p")},
            },
            "job": {"slug": f"job-{arm}", "config": {"sha256": digest(arm)}},
            "model": {
                "slug": "model",
                "config": {"sha256": digest("model-config")},
                "provider_identity": "provider",
                "fingerprint": digest("model"),
                "backend_model_name": "glm-5.2",
            },
            "harness_fingerprint": digest(f"harness-{arm}"),
            "host_control_plane": {
                name: {
                    "path": f"/fixture/{name}.py",
                    "bytes": 1,
                    "sha256": digest(name),
                }
                for name in HOST_CONTROL_PLANE_MODULES
            },
            "budget": {
                "total_cost_microusd": 1_000_000,
                "total_metered_tokens": 1_000_000,
                "max_cost_microusd": 500_000,
                "max_metered_tokens": 500_000,
                "prior_exposure_microusd": 0,
                "user_authority_microusd": 2_000_000_000,
            },
            "execution": {
                "n_attempts": 1,
                "n_concurrent_trials": 1,
                "shards": 1,
                "proxy_max_retries": 0,
                "shared_proxy": False,
                "credential_delivery": "anonymous-fd",
                "provider_key_env": "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF",
                "remote_tinykg_env_cleared": True,
                "local_tinykg": "fresh-home-per-trial",
                "cacheable_first_request_hash_required": True,
                "target_platform": "linux/amd64",
                "docker_default_platform": "linux/amd64",
                "environment_preflight_required": True,
                "harbor_force_build": False,
                "runner_tools": {
                    "bash": {"path": "/fixture/bash", "sha256": digest("bash"), "version_sha256": digest("bv")},
                    "uv": {"path": "/fixture/uv", "sha256": digest("uv"), "version_sha256": digest("uvv")},
                },
                "runner": ["/fixture/uv", "run", "--frozen", "/fixture/bash", "scripts/run.sh", "--job", f"job-{arm}"],
            },
            "dry_run": {
                "network_requests": 0,
                "credential_loaded": False,
                "journal_mutations": 0,
                "paid_rollouts_authorized": False,
            },
        }
        value["content_sha256"] = hashlib.sha256(stable_json(value).encode()).hexdigest()
        return self._write(root / f"{arm}-manifest.json", value), value

    @staticmethod
    def _control(*, used: bool) -> dict:
        return {
            "lean": {
                "used": used,
                "checker_calls": int(used),
                "checker_elapsed_ns": 100 if used else 0,
                "rule_filter_events": int(used),
                "active_rule_phases": int(used),
                "checker_rule_phases": int(used),
                "statically_pruned_rule_phases": 0,
                "block": 0,
                "fault": 0,
                "enforced_blocks": 0,
            }
        }

    def _receipt(
        self,
        root: Path,
        arm: str,
        manifest: dict,
        *,
        study: str = "project_control",
    ) -> tuple[Path, dict, Path]:
        rewards = {"baseline": (0.0, 1.0), "treatment": (1.0, 1.0)}[arm]
        tasks = {}
        for index, (task, reward) in enumerate(zip(("task-a", "task-b"), rewards)):
            control = self._control(
                used=study == "project_control" and arm == "treatment"
            )
            control["source"] = {
                "transcript_sha256": digest(f"{arm}-{task}-transcript"),
                "observation_journal_sha256": digest(f"{arm}-{task}-observation"),
            }
            artifact_dir = root / "checkout" / "results" / f"job-{arm}" / task
            artifact_dir.mkdir(parents=True, exist_ok=True)
            artifact_bytes = (
                json.dumps({"verifier_result": {"rewards": {"reward": reward}}})
                + "\n"
            ).encode("utf-8")
            (artifact_dir / "result.json").write_bytes(artifact_bytes)
            tasks[task] = {
                "task_checksum": digest(task),
                "cacheable_first_request_sha256": digest(f"prefix-{task}"),
                "trial_result_sha256": hashlib.sha256(artifact_bytes).hexdigest(),
                "verifier_reward": reward,
                "full_pass": reward == 1.0,
                "cost_usd": 0.01 + index / 100,
                "metered_tokens": 100 + index,
                "provider_requests": 2 + index,
                "cache_read_input_tokens": 50 + index,
                "cache_creation_input_tokens": 10 + index,
                "control_metrics": control,
            }
            if study == VERIFICATION_CHECKPOINT:
                checkpoint = int(arm == "treatment")
                tasks[task]["progress_metrics"] = {
                    "schema_version": "metacodes-workbuddy-progress-analysis-v1",
                    "source": control["source"],
                    "progress": {
                        "tool_calls": 8 if arm == "baseline" else 4,
                        "first_mutation_call": 1,
                        "first_successful_verification_call": 2,
                        "calls_after_first_successful_verification": (
                            6 if arm == "baseline" else 2
                        ),
                        "mutation_calls": 2 if arm == "baseline" else 1,
                        "mutations_after_first_successful_verification": (
                            1 if arm == "baseline" else 0
                        ),
                        "verification_calls": 2,
                        "successful_verifications": 1,
                        "exact_repeated_tool_input_result_calls": 0,
                        "checkpoint_messages": checkpoint,
                        "checkpoint_messages_after_successful_verification": checkpoint,
                        "time_to_first_mutation_ms": 1000.0,
                        "time_to_first_successful_verification_ms": 2000.0,
                        "time_after_first_successful_verification_ms": (
                            6000.0 if arm == "baseline" else 2000.0
                        ),
                        "time_to_final_dispatch_ms": (
                            8000.0 if arm == "baseline" else 4000.0
                        ),
                    },
                    "privacy": {
                        "tool_arguments_retained": False,
                        "tool_results_retained": False,
                        "paths_retained": False,
                        "memory_text_retained": False,
                    },
                }
        journal_path = root / f"{arm}-budget.json"
        authority = BudgetAuthority(
            manifest_sha256=manifest["content_sha256"],
            model_fingerprint=manifest["model"]["fingerprint"],
            provider_identity=manifest["model"]["provider_identity"],
            total_cost_microusd=manifest["budget"]["total_cost_microusd"],
            total_metered_tokens=manifest["budget"]["total_metered_tokens"],
        )
        transaction = BudgetTransaction(
            run_id=manifest["run_id"],
            manifest_sha256=manifest["content_sha256"],
            model_fingerprint=manifest["model"]["fingerprint"],
            harness_fingerprint=manifest["harness_fingerprint"],
            provider_identity=manifest["model"]["provider_identity"],
            max_cost_microusd=manifest["budget"]["max_cost_microusd"],
            max_metered_tokens=manifest["budget"]["max_metered_tokens"],
        )
        with BudgetJournal(journal_path, authority) as budget:
            reserved = budget.reserve(transaction)
            authorized = budget.authorize_request(
                str(reserved["transaction_id"]),
                expected_revision=int(reserved["journal_revision"]),
                expected_head_sha256=str(reserved["journal_head_sha256"]),
            )
            committed = budget.commit(
                str(authorized["transaction_id"]),
                actual_cost_microusd=30_000,
                actual_metered_tokens=201,
            )
            snapshot = budget.snapshot()
        value = {
            "schema_version": RECEIPT_SCHEMA_VERSION,
            "quality_evidence": True,
            "launch_manifest_content_sha256": manifest["content_sha256"],
            "run_id": manifest["run_id"],
            "cohort": manifest["cohort"],
            "usage": {
                "tasks": tasks,
                "provider_requests": 5,
                "cost_microusd": 30_000,
                "metered_tokens": 201,
                "cache_read_input_tokens": 101,
                "cache_creation_input_tokens": 21,
                "control_metrics": {},
                "quality": {
                    "mean_verifier_reward": sum(rewards) / 2,
                    "full_passes": sum(reward == 1.0 for reward in rewards),
                    "task_count": 2,
                    "pass_rate": sum(reward == 1.0 for reward in rewards) / 2,
                },
                "runtime_contract": {},
            },
            "budget_transaction": committed,
            "journal": {
                "journal_id": snapshot["journal_id"],
                "revision": snapshot["revision"],
                "head_sha256": snapshot["head_sha256"],
                "transaction_states": snapshot["transaction_states"],
            },
            "elapsed_seconds": 10.0 if arm == "baseline" else 11.0,
            "evaluation_treatment": manifest["evaluation_treatment"],
            "comparison": manifest["comparison"],
        }
        return self._write(root / f"{arm}-receipt.json", value), value, journal_path

    def _pair(self, root: Path, *, study: str = "project_control"):
        bm, bmv = self._manifest(root, "baseline", study=study)
        tm, tmv = self._manifest(root, "treatment", study=study)
        br, brv, bj = self._receipt(root, "baseline", bmv, study=study)
        tr, trv, tj = self._receipt(root, "treatment", tmv, study=study)
        return bm, br, bj, tm, tr, tj, bmv, brv, tmv, trv

    def test_replaced_trial_result_artifact_fails_closed(self):
        # The committed reward is bound to the trial artifact by content
        # hash; replacing (or deleting) the artifact after commit orphans
        # the binding and the analysis must refuse, not report the
        # receipt's number as if it were still evidence-backed.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, *_ = self._pair(root)
            # baseline task-a (reward 0.0) is the only artifact with these
            # bytes; the 1.0-reward artifacts alias each other by content,
            # which is semantically fine for a content-addressed equality
            # witness but would mask this tamper.
            artifact = (
                root / "checkout" / "results" / "job-baseline"
                / "task-a" / "result.json"
            )
            artifact.write_text(
                json.dumps({"verifier_result": {"rewards": {"reward": 0.25}}})
                + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                LaunchError, "trial result artifact is missing"
            ):
                build_report(
                    baseline_manifest_path=bm,
                    baseline_receipt_path=br,
                    baseline_journal_path=bj,
                    treatment_manifest_path=tm,
                    treatment_receipt_path=tr,
                    treatment_journal_path=tj,
                )

    def test_results_root_override_survives_checkout_relocation(self):
        # The manifest pins the checkout's absolute path; after archival the
        # same receipts must stay analyzable via --results-root (global
        # review roadmap #1 — without this, cleaning the tmp checkout makes
        # historical pairs permanently un-analyzable).
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, *_ = self._pair(root)
            moved = root / "archived-results"
            (root / "checkout" / "results").rename(moved)
            with self.assertRaisesRegex(
                LaunchError, "trial result artifact is missing"
            ):
                build_report(
                    baseline_manifest_path=bm,
                    baseline_receipt_path=br,
                    baseline_journal_path=bj,
                    treatment_manifest_path=tm,
                    treatment_receipt_path=tr,
                    treatment_journal_path=tj,
                )
            report = build_report(
                baseline_manifest_path=bm,
                baseline_receipt_path=br,
                baseline_journal_path=bj,
                treatment_manifest_path=tm,
                treatment_receipt_path=tr,
                treatment_journal_path=tj,
                results_root=moved,
            )
            self.assertEqual(report["mean_reward_delta"], 0.5)

    def test_report_binds_equal_cache_prefix_and_quality_cost_time_deltas(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, *_ = self._pair(root)
            report = build_report(
                baseline_manifest_path=bm,
                baseline_receipt_path=br,
                baseline_journal_path=bj,
                treatment_manifest_path=tm,
                treatment_receipt_path=tr,
                treatment_journal_path=tj,
            )
            self.assertTrue(report["quality_evidence"])
            self.assertEqual(report["mean_reward_delta"], 0.5)
            self.assertEqual(report["pass_rate_delta"], 0.5)
            self.assertEqual(report["improved_tasks"], 1)
            self.assertEqual(report["regressed_tasks"], 0)
            self.assertEqual(report["elapsed_seconds_delta"], 1.0)
            self.assertTrue(report["cache_prefix_equal_for_every_task"])
            self.assertEqual(report["tasks"]["task-a"]["lean_delta"]["checker_calls"], 1)
            self.assertIn("observed paired difference", report["claim_boundary"])
            self.assertNotIn("assignment effect", report["claim_boundary"])

    def test_checkpoint_report_requires_single_actuation_and_reports_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, *_ = self._pair(
                root, study=VERIFICATION_CHECKPOINT
            )
            report = build_report(
                study=VERIFICATION_CHECKPOINT,
                baseline_manifest_path=bm,
                baseline_receipt_path=br,
                baseline_journal_path=bj,
                treatment_manifest_path=tm,
                treatment_receipt_path=tr,
                treatment_journal_path=tj,
            )
            self.assertEqual(VERIFICATION_CHECKPOINT, report["study"])
            self.assertFalse(report["arms"]["baseline"]["verification_checkpoint"])
            self.assertTrue(report["arms"]["treatment"]["verification_checkpoint"])
            progress = report["tasks"]["task-a"]["progress"]
            self.assertEqual(
                -4, progress["calls_after_first_successful_verification_delta"]
            )
            self.assertEqual(
                -1, progress["mutations_after_first_successful_verification_delta"]
            )
            self.assertEqual(
                -4000.0,
                progress["time_after_first_successful_verification_ms_delta"],
            )

    def test_checkpoint_report_fails_closed_on_treatment_lean_cache_or_progress_drift(self):
        mutations = (
            (
                "false-treatment",
                lambda tm, tr: tm["evaluation_treatment"].update(
                    {"verification_checkpoint": False}
                ),
            ),
            (
                "lean-actuation",
                lambda tm, tr: tr["usage"]["tasks"]["task-a"][
                    "control_metrics"
                ]["lean"].update({"used": True, "checker_calls": 1}),
            ),
            (
                "cache-prefix",
                lambda tm, tr: tr["usage"]["tasks"]["task-a"].update(
                    {"cacheable_first_request_sha256": digest("drift")}
                ),
            ),
            (
                "missing-progress",
                lambda tm, tr: tr["usage"]["tasks"]["task-a"].pop(
                    "progress_metrics"
                ),
            ),
            (
                "forged-checkpoint",
                lambda tm, tr: tr["usage"]["tasks"]["task-a"][
                    "progress_metrics"
                ]["progress"].update({"checkpoint_messages": 0}),
            ),
        )
        for name, mutate in mutations:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bm, br, bj, tm, tr, tj, _bmv, _brv, tmv, trv = self._pair(
                    root, study=VERIFICATION_CHECKPOINT
                )
                mutate(tmv, trv)
                if name == "false-treatment":
                    tmv["content_sha256"] = hashlib.sha256(
                        stable_json(
                            {
                                key: value
                                for key, value in tmv.items()
                                if key != "content_sha256"
                            }
                        ).encode()
                    ).hexdigest()
                    trv["launch_manifest_content_sha256"] = tmv["content_sha256"]
                    trv["evaluation_treatment"] = tmv["evaluation_treatment"]
                self._write(tm, tmv)
                self._write(tr, trv)
                with self.assertRaises(LaunchError):
                    build_report(
                        study=VERIFICATION_CHECKPOINT,
                        baseline_manifest_path=bm,
                        baseline_receipt_path=br,
                        baseline_journal_path=bj,
                        treatment_manifest_path=tm,
                        treatment_receipt_path=tr,
                        treatment_journal_path=tj,
                    )

    def test_covariate_cache_reward_and_budget_drift_fail_closed(self):
        mutations = (
            ("covariate", lambda tm, tr: tm["comparison"].update({"covariates_sha256": digest("other")})),
            ("cache-prefix", lambda tm, tr: tr["usage"]["tasks"]["task-a"].update({"cacheable_first_request_sha256": digest("other")})),
            ("reward", lambda tm, tr: tr["usage"]["tasks"]["task-a"].update({"verifier_reward": 0.5})),
            ("budget", lambda tm, tr: tr["budget_transaction"].update({"manifest_sha256": digest("other")})),
            ("budget-identity", lambda tm, tr: tr["budget_transaction"].update({"identity_sha256": digest("other")})),
            ("budget-revision", lambda tm, tr: tr["budget_transaction"].update({"commit_revision": 4})),
        )
        for name, mutate in mutations:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bm, br, bj, tm, tr, tj, _bmv, _brv, tmv, trv = self._pair(root)
                mutate(tmv, trv)
                if name == "covariate":
                    tmv["content_sha256"] = hashlib.sha256(
                        stable_json({k: v for k, v in tmv.items() if k != "content_sha256"}).encode()
                    ).hexdigest()
                    trv["launch_manifest_content_sha256"] = tmv["content_sha256"]
                    trv["budget_transaction"]["manifest_sha256"] = tmv["content_sha256"]
                self._write(tm, tmv)
                self._write(tr, trv)
                with self.assertRaises(LaunchError):
                    build_report(
                        baseline_manifest_path=bm,
                        baseline_receipt_path=br,
                        baseline_journal_path=bj,
                        treatment_manifest_path=tm,
                        treatment_receipt_path=tr,
                        treatment_journal_path=tj,
                    )

    def test_run_transaction_and_journal_reuse_fail_closed(self):
        for name, mutate in (
            (
                "run",
                lambda bmv, brv, tmv, trv: (
                    tmv.update({"run_id": bmv["run_id"]}),
                    trv.update({"run_id": bmv["run_id"]}),
                    trv["budget_transaction"].update({"run_id": bmv["run_id"]}),
                ),
            ),
            (
                "transaction",
                lambda bmv, brv, tmv, trv: trv["budget_transaction"].update(
                    {"transaction_id": brv["budget_transaction"]["transaction_id"]}
                ),
            ),
            (
                "journal",
                lambda bmv, brv, tmv, trv: (
                    trv["budget_transaction"].update(
                        {"journal_id": brv["budget_transaction"]["journal_id"]}
                    ),
                    trv["journal"].update(
                        {"journal_id": brv["budget_transaction"]["journal_id"]}
                    ),
                ),
            ),
        ):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bm, br, bj, tm, tr, tj, bmv, brv, tmv, trv = self._pair(root)
                mutate(bmv, brv, tmv, trv)
                if name == "run":
                    tmv["content_sha256"] = hashlib.sha256(
                        stable_json(
                            {key: value for key, value in tmv.items() if key != "content_sha256"}
                        ).encode()
                    ).hexdigest()
                    trv["launch_manifest_content_sha256"] = tmv["content_sha256"]
                    trv["budget_transaction"]["manifest_sha256"] = tmv["content_sha256"]
                self._write(tm, tmv)
                self._write(tr, trv)
                with self.assertRaises(LaunchError):
                    build_report(
                        baseline_manifest_path=bm,
                        baseline_receipt_path=br,
                        baseline_journal_path=bj,
                        treatment_manifest_path=tm,
                        treatment_receipt_path=tr,
                        treatment_journal_path=tj,
                    )

    def test_per_task_cost_delta_is_already_in_microusd(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, _bmv, _brv, _tmv, trv = self._pair(root)
            trv["usage"]["tasks"]["task-a"]["cost_usd"] = 0.011
            trv["usage"]["tasks"]["task-b"]["cost_usd"] = 0.019
            self._write(tr, trv)
            report = build_report(
                baseline_manifest_path=bm,
                baseline_receipt_path=br,
                baseline_journal_path=bj,
                treatment_manifest_path=tm,
                treatment_receipt_path=tr,
                treatment_journal_path=tj,
            )
            self.assertEqual(1_000, report["tasks"]["task-a"]["cost_microusd_delta"])

    def test_tampered_budget_journal_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, *_ = self._pair(root)
            document = json.loads(tj.read_text(encoding="utf-8"))
            document["events"][1]["event_sha256"] = digest("tampered")
            tj.write_text(json.dumps(document, sort_keys=True) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(LaunchError, "journal cannot be replayed"):
                build_report(
                    baseline_manifest_path=bm,
                    baseline_receipt_path=br,
                    baseline_journal_path=bj,
                    treatment_manifest_path=tm,
                    treatment_receipt_path=tr,
                    treatment_journal_path=tj,
                )

    def test_receipt_cannot_elevate_unregistered_quality_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, bmv, brv, *_ = self._pair(root)
            bmv["quality_evidence_on_commit"] = False
            bmv["content_sha256"] = hashlib.sha256(
                stable_json(
                    {key: value for key, value in bmv.items() if key != "content_sha256"}
                ).encode()
            ).hexdigest()
            brv["launch_manifest_content_sha256"] = bmv["content_sha256"]
            self._write(bm, bmv)
            self._write(br, brv)
            with self.assertRaisesRegex(LaunchError, "unregistered quality evidence"):
                build_report(
                    baseline_manifest_path=bm,
                    baseline_receipt_path=br,
                    baseline_journal_path=bj,
                    treatment_manifest_path=tm,
                    treatment_receipt_path=tr,
                    treatment_journal_path=tj,
                )

    def test_report_identities_use_the_same_bytes_that_were_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bm, br, bj, tm, tr, tj, *_ = self._pair(root)
            expected_receipt_sha = hashlib.sha256(br.read_bytes()).hexdigest()
            expected_journal_sha = hashlib.sha256(bj.read_bytes()).hexdigest()
            real_observed_json = paired_analysis._observed_json
            real_read_regular = paired_analysis._read_regular

            def observed_json(path, **kwargs):
                result = real_observed_json(path, **kwargs)
                if path == br:
                    self._write(br, {"replaced_after_observation": True})
                return result

            def read_regular(path, **kwargs):
                payload = real_read_regular(path, **kwargs)
                if path == bj:
                    self._write(bj, {"replaced_after_observation": True})
                return payload

            with mock.patch.object(
                paired_analysis, "_observed_json", side_effect=observed_json
            ), mock.patch.object(
                paired_analysis, "_read_regular", side_effect=read_regular
            ):
                report = build_report(
                    baseline_manifest_path=bm,
                    baseline_receipt_path=br,
                    baseline_journal_path=bj,
                    treatment_manifest_path=tm,
                    treatment_receipt_path=tr,
                    treatment_journal_path=tj,
                )

            self.assertEqual(
                expected_receipt_sha, report["arms"]["baseline"]["receipt"]["sha256"]
            )
            self.assertEqual(
                expected_journal_sha,
                report["arms"]["baseline"]["budget_journal"]["sha256"],
            )
            self.assertNotEqual(
                expected_receipt_sha, hashlib.sha256(br.read_bytes()).hexdigest()
            )
            self.assertNotEqual(
                expected_journal_sha, hashlib.sha256(bj.read_bytes()).hexdigest()
            )


if __name__ == "__main__":
    unittest.main()

class ProgressAnalyzerSuccessionTest(unittest.TestCase):
    """The succession verifier is fail-closed on every branch that is not the
    exact earned case: only the analyzer differs, the current analyzer is the
    treatment's, and baseline metrics reproduce byte-identically."""

    @staticmethod
    def _comparison(analyzer_sha):
        return {
            "comparison_id": "pair",
            "covariates_sha256": "x" * 64,
            "covariates": {
                "budget": {"total_cost_microusd": 1},
                "host_control_plane": {
                    "launch_gate": {"bytes": 1, "sha256": "a" * 64},
                    "progress_analysis": {"bytes": 2, "sha256": analyzer_sha},
                },
            },
        }

    def test_rejects_any_second_covariate_difference(self):
        from scripts.eval.workbuddy.paired_analysis import (
            LaunchError,
            _verify_instrument_succession,
        )

        base = self._comparison("b" * 64)
        treatment = self._comparison("c" * 64)
        treatment["covariates"]["budget"] = {"total_cost_microusd": 2}
        with self.assertRaises(LaunchError):
            _verify_instrument_succession(
                base, treatment, {}, Path("/nonexistent")
            )

    def test_rejects_analyzer_that_did_not_measure_the_treatment(self):
        from scripts.eval.workbuddy.paired_analysis import (
            LaunchError,
            _verify_instrument_succession,
        )

        base = self._comparison("b" * 64)
        treatment = self._comparison("c" * 64)
        with self.assertRaisesRegex(LaunchError, "measured the treatment"):
            _verify_instrument_succession(
                base, treatment, {}, Path("/nonexistent")
            )

    def test_accepts_only_after_byte_identical_baseline_reverification(self):
        import hashlib
        import json as json_mod
        import tempfile

        from scripts.eval.workbuddy import paired_analysis as pa
        from scripts.eval.workbuddy.progress_analysis import analyze_progress

        current_sha = hashlib.sha256(
            (Path(pa.__file__).resolve().parent / "progress_analysis.py").read_bytes()
        ).hexdigest()
        base = self._comparison("b" * 64)
        treatment = self._comparison(current_sha)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trial = root / "checkout" / "results" / "job" / "run" / "trial" / "agent"
            trial.mkdir(parents=True)
            transcript = trial / "metacodes-transcript.jsonl"
            observation = trial / "metacodes-tool-observations.jsonl"
            transcript.write_text(
                json_mod.dumps({"role": "assistant", "blocks": [{
                    "type": "tool_use", "id": "call", "name": "Bash",
                    "input": {"command": "true"},
                }]}) + "\n" + json_mod.dumps({"role": "user", "blocks": [{
                    "type": "tool_result", "tool_use_id": "call",
                    "content": "{\"exit_code\":0}", "is_error": False,
                }]}) + "\n"
            )
            observation.write_text(json_mod.dumps({
                "monotonic_elapsed_ns": 0,
                "event": {"tool_observation": {"dispatch_finished": {
                    "id": "call", "requested_name": "Bash",
                    "dispatched_name": "Bash", "origin": "authoritative",
                    "agent_depth": 0, "outcome": "succeeded",
                    "effect": None, "effect_valid": True,
                }}},
            }) + "\n")
            committed = analyze_progress(transcript, observation)
            receipt = root / "receipt.json"
            receipt.write_text(json_mod.dumps({
                "usage": {"tasks": {"task-a": {"progress_metrics": committed}}}
            }))
            manifests = {"baseline": {
                "workbuddy": {"checkout": str(root / "checkout")},
                "job": {"slug": "job"},
            }}
            record = pa._verify_instrument_succession(
                base, treatment, manifests, receipt
            )
            self.assertEqual(
                record["modules"]["progress_analysis"]["proof"],
                "reproduced_byte_identical:1",
            )
            # Any drift in the committed metrics must reject.
            drifted = dict(committed)
            drifted["progress"] = dict(committed["progress"])
            drifted["progress"]["tool_calls"] = 99
            receipt.write_text(json_mod.dumps({
                "usage": {"tasks": {"task-a": {"progress_metrics": drifted}}}
            }))
            with self.assertRaisesRegex(paired_analysis.LaunchError, "changed baseline progress_metrics"):
                pa._verify_instrument_succession(
                    base, treatment, manifests, receipt
                )



class MemoryStudyValidationTest(unittest.TestCase):
    """memory_accumulation arm validation + memory leakage into other
    studies is rejected."""

    @staticmethod
    def _manifests(**treatments):
        base = {
            "project_control": "disabled",
            "verification_checkpoint": False,
            "verification_final_gate": False,
            "verification_final_observe": False,
            "memory_accumulation": False,
        }
        out = {}
        for arm in ("baseline", "treatment"):
            merged = dict(base)
            merged.update(treatments.get(arm, {}))
            out[arm] = {"evaluation_treatment": merged}
        return out

    def test_correct_memory_arms_pass(self):
        paired_analysis._validate_study_treatment(
            self._manifests(treatment={"memory_accumulation": True}),
            paired_analysis.MEMORY_ACCUMULATION,
        )

    def test_memory_study_rejects_an_unaccumulating_treatment_arm(self):
        with self.assertRaisesRegex(paired_analysis.LaunchError, "memory-accumulation"):
            paired_analysis._validate_study_treatment(
                self._manifests(), paired_analysis.MEMORY_ACCUMULATION
            )

    def test_memory_study_rejects_gate_confounding(self):
        with self.assertRaisesRegex(paired_analysis.LaunchError, "memory-accumulation"):
            paired_analysis._validate_study_treatment(
                self._manifests(
                    treatment={
                        "memory_accumulation": True,
                        "verification_final_gate": True,
                    }
                ),
                paired_analysis.MEMORY_ACCUMULATION,
            )

    def test_memory_leaking_into_the_gate_study_is_rejected(self):
        with self.assertRaisesRegex(paired_analysis.LaunchError, "final-gate"):
            paired_analysis._validate_study_treatment(
                self._manifests(
                    baseline={"verification_final_observe": True},
                    treatment={
                        "verification_final_gate": True,
                        "memory_accumulation": True,
                    },
                ),
                paired_analysis.VERIFICATION_FINAL_GATE,
            )


class FullStackStudyValidationTest(unittest.TestCase):
    """full_stack merges project rules + final gate + requirement ledger into
    one treatment arm; the baseline observes the gate and the ledger so both
    arms carry obligation outcomes."""

    @staticmethod
    def _manifests(**treatments):
        base = {
            "project_control": "disabled",
            "verification_checkpoint": False,
            "verification_final_gate": False,
            "verification_final_observe": False,
            "requirement_ledger": False,
            "requirement_ledger_observe": False,
            "memory_accumulation": False,
        }
        out = {}
        for arm in ("baseline", "treatment"):
            merged = dict(base)
            merged.update(treatments.get(arm, {}))
            out[arm] = {"evaluation_treatment": merged}
        return out

    def _full_stack_arms(self):
        return self._manifests(
            baseline={
                "verification_final_observe": True,
                "requirement_ledger_observe": True,
            },
            treatment={
                "project_control": "enforced",
                "verification_final_gate": True,
                "requirement_ledger": True,
            },
        )

    def test_correct_full_stack_arms_pass(self):
        paired_analysis._validate_study_treatment(
            self._full_stack_arms(), paired_analysis.FULL_STACK
        )

    def test_full_stack_rejects_a_disabled_project_treatment_arm(self):
        manifests = self._full_stack_arms()
        manifests["treatment"]["evaluation_treatment"]["project_control"] = "disabled"
        with self.assertRaisesRegex(paired_analysis.LaunchError, "full-stack"):
            paired_analysis._validate_study_treatment(
                manifests, paired_analysis.FULL_STACK
            )

    def test_full_stack_rejects_a_silent_baseline_ledger(self):
        manifests = self._full_stack_arms()
        manifests["baseline"]["evaluation_treatment"][
            "requirement_ledger_observe"
        ] = False
        with self.assertRaisesRegex(paired_analysis.LaunchError, "full-stack"):
            paired_analysis._validate_study_treatment(
                manifests, paired_analysis.FULL_STACK
            )

    def test_full_stack_rejects_memory_confounding(self):
        manifests = self._full_stack_arms()
        manifests["treatment"]["evaluation_treatment"]["memory_accumulation"] = True
        with self.assertRaisesRegex(paired_analysis.LaunchError, "full-stack"):
            paired_analysis._validate_study_treatment(
                manifests, paired_analysis.FULL_STACK
            )

    def test_full_stack_rejects_legacy_manifests_without_ledger_fields(self):
        manifests = self._full_stack_arms()
        for arm in manifests:
            del manifests[arm]["evaluation_treatment"]["requirement_ledger"]
            del manifests[arm]["evaluation_treatment"]["requirement_ledger_observe"]
        with self.assertRaisesRegex(paired_analysis.LaunchError, "full-stack"):
            paired_analysis._validate_study_treatment(
                manifests, paired_analysis.FULL_STACK
            )

    def test_ledger_leaking_into_the_gate_study_is_rejected(self):
        with self.assertRaisesRegex(paired_analysis.LaunchError, "final-gate"):
            paired_analysis._validate_study_treatment(
                self._manifests(
                    baseline={"verification_final_observe": True},
                    treatment={
                        "verification_final_gate": True,
                        "requirement_ledger": True,
                    },
                ),
                paired_analysis.VERIFICATION_FINAL_GATE,
            )

    def test_ledger_leaking_into_the_project_study_is_rejected(self):
        with self.assertRaisesRegex(paired_analysis.LaunchError, "project-control"):
            paired_analysis._validate_study_treatment(
                self._manifests(
                    treatment={
                        "project_control": "enforced",
                        "requirement_ledger": True,
                    },
                ),
                paired_analysis.PROJECT_CONTROL,
            )
