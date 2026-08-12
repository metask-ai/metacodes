from __future__ import annotations

import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.eval.memory_agent_runtime import PRODUCTION_MODEL_FINGERPRINT
from scripts.eval.memory_replay import PRODUCTION_PROVIDER_ID
from scripts.eval.model import stable_json
from scripts.eval.project_harness_e3_experiment import E3_ROLLOUT_TIMEOUT_SECONDS
from scripts.eval.project_harness_rule_impact_cases import (
    CALIBRATION_CASES,
    FRESHNESS,
    HELDOUT_CASES,
)
from scripts.eval import project_harness_rule_impact_prospective as prospective


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(stable_json(value) + "\n", encoding="utf-8")


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class _FakeBudget:
    def __init__(self, *_args: object, **_kwargs: object) -> None:
        pass

    def __enter__(self) -> "_FakeBudget":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def snapshot(self) -> dict[str, object]:
        return {
            "journal_id": "1" * 64,
            "revision": 12,
            "head_sha256": "2" * 64,
            "transaction_states": {
                "reserved": 0,
                "request_authorized": 0,
                "committed": prospective.CALIBRATION_COUNT,
            },
        }

    def checkpoint_payload(self) -> bytes:
        return b"{}\n"


class ProjectHarnessRuleImpactProspectiveTest(unittest.TestCase):
    def test_local_median_is_stable_for_direct_script_execution(self) -> None:
        self.assertEqual(3, prospective._median([5, 1, 3]))
        self.assertEqual(2.5, prospective._median([4, 1, 3, 2]))
        with self.assertRaises(ValueError):
            prospective._median([])

    def test_freshness_and_frozen_balanced_schedule(self) -> None:
        self.assertEqual(4, len(CALIBRATION_CASES))
        self.assertEqual(8, len(HELDOUT_CASES))
        self.assertEqual(28, len(prospective.SCHEDULE))
        self.assertEqual(4, FRESHNESS["calibration_cases"])
        self.assertEqual(8, FRESHNESS["heldout_cases"])
        self.assertEqual("initial-and-expected", FRESHNESS["filename_scope"])
        self.assertTrue(
            {case["id"] for case in CALIBRATION_CASES}.isdisjoint(
                {case["id"] for case in HELDOUT_CASES}
            )
        )
        self.assertTrue(
            all(row["phase"] == "calibration" for row in prospective.SCHEDULE[:4])
        )
        self.assertTrue(
            all(row["phase"] == "heldout" for row in prospective.SCHEDULE[4:])
        )
        self.assertEqual(
            list(range(28)), [row["sequence"] for row in prospective.SCHEDULE]
        )
        for case in HELDOUT_CASES:
            rows = [row for row in prospective.SCHEDULE if row["case_id"] == case["id"]]
            self.assertEqual(set(prospective.HELDOUT_ARMS), {row["arm"] for row in rows})
            self.assertEqual([0, 1, 2], sorted(row["position"] for row in rows))
        for arm in prospective.HELDOUT_ARMS:
            counts = [
                sum(
                    row["phase"] == "heldout"
                    and row["arm"] == arm
                    and row["position"] == position
                    for row in prospective.SCHEDULE
                )
                for position in range(3)
            ]
            self.assertLessEqual(max(counts) - min(counts), 1)

    def test_budget_journal_cannot_equal_or_enter_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = root / "run"
            run.mkdir()
            outside = root / "budget" / "journal.json"
            outside.parent.mkdir()
            self.assertEqual(
                outside.parent.resolve(strict=True) / outside.name,
                prospective._budget_location(run, outside),
            )
            for invalid in (run, run / "journal.json", run / "nested" / "journal.json"):
                with self.subTest(invalid=invalid):
                    with self.assertRaises(prospective.E3Error):
                        prospective._budget_location(run, invalid)

    def test_heldout_request_requires_reverified_promotion(self) -> None:
        heldout = prospective.SCHEDULE[prospective.CALIBRATION_COUNT]
        promotion = {"receipt_id": "1" * 64}
        authorization = {
            "schema_version": prospective.RUN_AUTHORIZATION_SCHEMA,
            "promotion_receipt_id": "1" * 64,
        }
        with self.assertRaises(prospective.E3Error):
            prospective._assert_rollout_authorized(heldout, None, None)
        with self.assertRaises(prospective.E3Error):
            prospective._assert_rollout_authorized(heldout, promotion, None)
        prospective._assert_rollout_authorized(heldout, promotion, authorization)
        prospective._assert_rollout_authorized(prospective.SCHEDULE[0], None, None)
        with self.assertRaises(prospective.E3Error):
            prospective._assert_rollout_authorized(
                prospective.SCHEDULE[0], promotion, authorization
            )

    def test_dry_run_loads_no_credential_budget_or_network(self) -> None:
        manifest = {"manifest_id": "1" * 64}
        stdout = io.StringIO()
        with mock.patch.object(prospective, "validate_manifest", return_value=manifest), mock.patch.object(
            prospective, "_load_api_key"
        ) as load_key, mock.patch.object(prospective, "BudgetJournal") as budget, mock.patch.object(
            prospective.subprocess, "run"
        ) as network, contextlib.redirect_stdout(stdout):
            self.assertEqual(
                0,
                prospective.main(
                    [
                        "dry-run",
                        "--repo",
                        "/nonexistent/repo",
                        "--manifest",
                        "/nonexistent/manifest.json",
                    ]
                ),
            )
        load_key.assert_not_called()
        budget.assert_not_called()
        network.assert_not_called()
        result = json.loads(stdout.getvalue())
        self.assertFalse(result["credential_loaded"])
        self.assertFalse(result["budget_journal_mutated"])
        self.assertEqual(0, result["provider_requests"])
        self.assertFalse(result["quality_evidence"])

    def test_cache_contract_compares_full_first_request_and_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows: list[dict[str, object]] = []
            files: dict[tuple[str, str], Path] = {}
            for case in HELDOUT_CASES:
                for arm in prospective.HELDOUT_ARMS:
                    path = root / str(case["id"]) / f"{arm}.json"
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'{"same":"provider-visible-request"}\n')
                    files[(str(case["id"]), arm)] = path
                    rows.append(
                        {
                            "case_id": case["id"],
                            "arm": arm,
                            "artifacts": {"first_request": str(path)},
                            "context_cache": {"cacheable_prefix_sha256": "3" * 64},
                        }
                    )
            requests, prefixes = prospective._cache_equivalence(rows)
            self.assertTrue(all(requests.values()))
            self.assertTrue(all(prefixes.values()))
            drift_case = str(HELDOUT_CASES[0]["id"])
            files[(drift_case, "evolved_enforced")].write_bytes(b'{"drift":true}\n')
            requests, _ = prospective._cache_equivalence(rows)
            self.assertFalse(requests[drift_case])

    def test_resume_reverifies_promotion_and_binds_runner_before_provider(self) -> None:
        class StopAtRunner(RuntimeError):
            pass

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            run = root / "run"
            run.mkdir()
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}\n", encoding="utf-8")
            auth_file = root / "auth.json"
            auth_file.write_text("{}\n", encoding="utf-8")
            ripgrep = root / "rg"
            ripgrep.write_bytes(b"rg")
            manifest = {
                "manifest_id": "4" * 64,
                "root": str(root),
                "templates_manifest": {"path": str(root / "templates.json")},
                "artifacts": {
                    "ripgrep": {
                        "path": str(ripgrep.resolve(strict=True)),
                        "sha256": _sha(ripgrep),
                    }
                },
                "execution": {
                    "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
                    "max_total_cost_usd": 50.0,
                    "max_total_metered_tokens": 15_000_000,
                    "rollout_timeout_seconds": E3_ROLLOUT_TIMEOUT_SECONDS,
                },
            }
            completed = [
                {"sequence": index, "receipt_path": f"r{index}", "receipt_sha256": "5" * 64}
                for index in range(prospective.CALIBRATION_COUNT)
            ]
            promotion = {
                "receipt_path": str(run / prospective.PROMOTION_NAME),
                "receipt_sha256": "6" * 64,
                "receipt_id": "7" * 64,
            }
            events: list[str] = []

            def load_resume(**_kwargs: object) -> tuple[list[dict[str, object]], dict[str, str]]:
                events.append("resume_reopened")
                return completed, promotion

            def verify(*_args: object, **_kwargs: object) -> dict[str, object]:
                events.append("promotion_reverified")
                return {
                    "receipt_id": "7" * 64,
                    "body": {
                        "manifest_id": "4" * 64,
                        "policy_epoch": 1,
                        "aggregate_receipt_id": "8" * 64,
                        "verdict_sha256": "9" * 64,
                        "kernel_sha256": "a" * 64,
                        "driver_sha256": "b" * 64,
                    },
                }

            def load_key(_path: Path) -> str:
                events.append("credential_loaded")
                return "test-secret"

            def run_one(**kwargs: object) -> dict[str, object]:
                events.append("runner_entered")
                authorization = kwargs.get("run_authorization")
                self.assertIsInstance(authorization, dict)
                assert isinstance(authorization, dict)
                self.assertEqual("7" * 64, authorization["promotion_receipt_id"])
                raise StopAtRunner

            with mock.patch.object(prospective, "validate_manifest", return_value=manifest), mock.patch.object(
                prospective, "verify_templates", return_value={"templates": {}}
            ), mock.patch.object(prospective, "BudgetJournal", _FakeBudget), mock.patch.object(
                prospective, "_load_resume", side_effect=load_resume
            ), mock.patch.object(prospective, "verify_promotion", side_effect=verify), mock.patch.object(
                prospective, "_load_api_key", side_effect=load_key
            ), mock.patch.object(
                prospective, "_run_one", side_effect=run_one
            ):
                with self.assertRaises(StopAtRunner):
                    prospective.run_paid(
                        repo=repo,
                        manifest_path=manifest_path,
                        ripgrep=ripgrep,
                        run_dir=run,
                        budget_path=root / "budget.json",
                        auth_file=auth_file,
                        resume=True,
                        max_rollouts=None,
                    )
            self.assertEqual(
                [
                    "resume_reopened",
                    "promotion_reverified",
                    "credential_loaded",
                    "promotion_reverified",
                    "runner_entered",
                ],
                events,
            )

    def test_paid_calibration_is_checkpointed_before_promotion_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            run = root / "run"
            run.mkdir()
            manifest_path = root / "manifest.json"
            manifest_path.write_text("{}\n", encoding="utf-8")
            auth_file = root / "auth.json"
            auth_file.write_text("{}\n", encoding="utf-8")
            ripgrep = root / "rg"
            ripgrep.write_bytes(b"rg")
            manifest = {
                "manifest_id": "4" * 64,
                "root": str(root.resolve(strict=True)),
                "templates_manifest": {"path": str(root / "templates.json")},
                "artifacts": {
                    "ripgrep": {
                        "path": str(ripgrep.resolve(strict=True)),
                        "sha256": _sha(ripgrep),
                    }
                },
                "execution": {
                    "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
                    "max_total_cost_usd": 50.0,
                    "max_total_metered_tokens": 15_000_000,
                    "rollout_timeout_seconds": E3_ROLLOUT_TIMEOUT_SECONDS,
                },
            }
            completed = [
                {
                    "sequence": index,
                    "receipt_path": f"r{index}",
                    "receipt_sha256": "5" * 64,
                }
                for index in range(prospective.CALIBRATION_COUNT - 1)
            ]
            checkpoints: list[dict[str, object]] = []

            def replace(path: Path, payload: bytes) -> None:
                if path.name == prospective.CHECKPOINT_NAME:
                    checkpoints.append(json.loads(payload))

            with mock.patch.object(
                prospective, "validate_manifest", return_value=manifest
            ), mock.patch.object(
                prospective, "verify_templates", return_value={"templates": {}}
            ), mock.patch.object(
                prospective, "BudgetJournal", _FakeBudget
            ), mock.patch.object(
                prospective, "_load_resume", return_value=(completed, None)
            ), mock.patch.object(
                prospective, "_load_api_key", return_value="test-secret"
            ), mock.patch.object(
                prospective,
                "_run_one",
                return_value={
                    "sequence": prospective.CALIBRATION_COUNT - 1,
                    "receipt_path": "r3",
                    "receipt_sha256": "6" * 64,
                },
            ), mock.patch.object(
                prospective, "_replace_private_file", side_effect=replace
            ), mock.patch.object(
                prospective, "promote", side_effect=prospective.E3Error("rejected")
            ):
                with self.assertRaisesRegex(prospective.E3Error, "rejected"):
                    prospective.run_paid(
                        repo=repo,
                        manifest_path=manifest_path,
                        ripgrep=ripgrep,
                        run_dir=run,
                        budget_path=root / "budget.json",
                        auth_file=auth_file,
                        resume=True,
                        max_rollouts=1,
                    )
            self.assertEqual([3, 4], [len(item["completed"]) for item in checkpoints])
            self.assertIsNone(checkpoints[-1]["promotion"])

    def _promotion_fixture(
        self, root: Path
    ) -> tuple[
        dict[str, object],
        Path,
        list[dict[str, object]],
        dict[str, object],
        dict[str, object],
        list[dict[str, object]],
    ]:
        run = root / "run"
        control = run / "rule-impact-control"
        aggregate_dir = control / "aggregate"
        aggregate_dir.mkdir(parents=True)
        run = run.resolve(strict=True)
        control = run / "rule-impact-control"
        aggregate_dir = control / "aggregate"
        repo = root / "repo"
        repo.mkdir()
        template = {
            "candidate_id": "8" * 64,
            "bundle_sha256": "9" * 64,
            "bundle_revision": 3,
        }
        templates = {"templates": {"evolved": template}}
        manifest: dict[str, object] = {
            "manifest_id": "a" * 64,
            "project_sha256": "b" * 64,
            "issuer_sha256": "c" * 64,
            "policy_epoch": 1,
            "calibration_case_ids": [case["id"] for case in CALIBRATION_CASES],
            "templates_manifest": {"path": str(root / "templates.json")},
            "artifacts": {
                "kernel": {"path": str(root / "kernel"), "sha256": "d" * 64},
                "rule_impact_driver": {"path": str(root / "driver"), "sha256": "e" * 64},
            },
            "promotion_policy": {"min_exposures": 4},
        }
        completed: list[dict[str, object]] = []
        rows: list[dict[str, object]] = []
        issue_refs: list[dict[str, object]] = []
        issue_results: list[dict[str, object]] = []
        members: list[dict[str, object]] = []
        for index, expected in enumerate(prospective.SCHEDULE[: prospective.CALIBRATION_COUNT]):
            session = run / "sessions" / f"s{index}"
            session.mkdir(parents=True)
            journal = session / "tool-observations.jsonl"
            session_id = f"{index + 1:024x}"
            run_id = f"{index + 101:024x}"
            records = [
                {"sequence": 0, "session_id": session_id, "run_id": run_id, "event": {"run_started": {}}},
                {"sequence": 1, "session_id": session_id, "run_id": run_id, "event": {"run_finished": {}}},
            ]
            journal.write_text("".join(stable_json(record) + "\n" for record in records), encoding="utf-8")
            row = {
                **expected,
                "oracle_class": "hazard_recurrence",
                "grader": {"passed": True},
                "provider_requests": 2,
                "elapsed_ms_host": 10,
                "usage": {
                    "input_tokens": 11,
                    "output_tokens": 12,
                    "cache_read_tokens": 13,
                    "cache_write_tokens": 14,
                    "cost_usd": 0.01,
                },
                "governance": {
                    "formal_block": True,
                    "existing_file_write_dispatch": True,
                    "realized_existing_file_write_effect": True,
                    "trustworthy_task_success": False,
                    "safe_action_false_intervention": False,
                    "safe_case_intervention": False,
                },
                "artifacts": {"journal": str(journal)},
            }
            rows.append(row)
            completed.append({"sequence": index, "receipt_path": str(run / f"rollout-{index}.json")})
            request = prospective._issue_request(manifest, row)
            request_path = control / f"issue-{index:05d}-request.json"
            result_path = control / f"issue-{index:05d}-result.json"
            _write_json(request_path, request)
            outcome = session / f"rule-impact-outcome-{'1' * 64}.json"
            usage = session / f"rule-impact-usage-{'2' * 64}.json"
            outcome.write_bytes(f"outcome-{index}\n".encode())
            usage.write_bytes(f"usage-{index}\n".encode())
            receipt_id = f"{index + 20:064x}"
            (session / f"rule-impact-label-receipt-{receipt_id}.json").write_text("{}\n", encoding="utf-8")
            result = {
                "schema_version": prospective.ISSUE_RESULT_SCHEMA,
                "provider_requests_made_by_driver": 0,
                "session_dir": str(session),
                "project_sha256": manifest["project_sha256"],
                "issuer_sha256": manifest["issuer_sha256"],
                "observation": request["issue"]["observation"],
                "source_interval_sha256": "3" * 64,
                "outcome_evidence_name": outcome.name,
                "outcome_evidence_sha256": _sha(outcome),
                "usage_evidence_name": usage.name,
                "usage_evidence_sha256": _sha(usage),
                "receipt_id": receipt_id,
                "receipt_created": True,
            }
            _write_json(result_path, result)
            issue_results.append(result)
            issue_refs.append(
                {
                    "sequence": index,
                    "request_path": str(request_path),
                    "request_sha256": _sha(request_path),
                    "result_path": str(result_path),
                    "result_sha256": _sha(result_path),
                    "receipt_id": receipt_id,
                }
            )
            members.append({"session_dir": str(session), "receipt_id": receipt_id})

        aggregate_request = prospective._aggregate_request(
            manifest=manifest,
            template=template,
            aggregate_dir=aggregate_dir,
            members=members,
        )
        aggregate_request_path = control / "aggregate-request.json"
        aggregate_result_path = control / "aggregate-result.json"
        _write_json(aggregate_request_path, aggregate_request)
        checks = {
            "bindings_valid": True,
            "evidence_valid": True,
            "members_valid": True,
            "aggregate_exact": True,
            "counts_consistent": True,
            "usage_consistent": True,
            "lifecycle_valid": True,
            "policy_satisfied": True,
        }
        aggregate_result = {
            "schema_version": prospective.AGGREGATE_RESULT_SCHEMA,
            "provider_requests_made_by_driver": 0,
            "aggregate_dir": str(aggregate_dir),
            "aggregate_receipt_id": "4" * 64,
            "aggregate_created": True,
            "member_count": 4,
            "request_sha256": "5" * 64,
            "verdict_sha256": "6" * 64,
            "actual_checker_sha256": "d" * 64,
            "request_bytes": 1024,
            "observer_elapsed_ns": 10,
            "checker_elapsed_ns": 20,
            "failure": "none",
            "checker_stdout": "admitted",
            "checker_stderr": "",
            "admitted": True,
            "checks": checks,
        }
        _write_json(aggregate_result_path, aggregate_result)
        (aggregate_dir / f"rule-impact-aggregate-receipt-{'4' * 64}.json").write_text(
            "{}\n", encoding="utf-8"
        )
        body = {
            "schema_version": prospective.PROMOTION_SCHEMA,
            "manifest_id": manifest["manifest_id"],
            "policy_epoch": 1,
            "issuer_sha256": manifest["issuer_sha256"],
            "candidate_id": template["candidate_id"],
            "project_sha256": manifest["project_sha256"],
            "bundle_sha256": template["bundle_sha256"],
            "bundle_revision": template["bundle_revision"],
            "source_state": "shadowed",
            "authorized_target_state": "promoted",
            "canonical_lifecycle_cas_committed": False,
            "calibration_case_ids": manifest["calibration_case_ids"],
            "issue_results": issue_refs,
            "aggregate_request_path": str(aggregate_request_path),
            "aggregate_request_sha256": _sha(aggregate_request_path),
            "aggregate_result_path": str(aggregate_result_path),
            "aggregate_result_sha256": _sha(aggregate_result_path),
            "aggregate_receipt_id": aggregate_result["aggregate_receipt_id"],
            "request_sha256": aggregate_result["request_sha256"],
            "verdict_sha256": aggregate_result["verdict_sha256"],
            "kernel_sha256": "d" * 64,
            "driver_sha256": "e" * 64,
            "provider_requests_made_by_control_plane": 0,
        }
        record = prospective._promotion_record(body)
        promotion_path = run / prospective.PROMOTION_NAME
        _write_json(promotion_path, record)
        promotion_ref = {
            "receipt_path": str(promotion_path),
            "receipt_sha256": _sha(promotion_path),
            "receipt_id": record["receipt_id"],
        }
        return manifest, repo, completed, templates, promotion_ref, rows + issue_results + [aggregate_result]

    def test_promotion_replays_every_issue_and_aggregate_and_rejects_tamper(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest, repo, completed, templates, promotion_ref, fixture = self._promotion_fixture(root)
            rows = fixture[: prospective.CALIBRATION_COUNT]
            issue_results = fixture[
                prospective.CALIBRATION_COUNT : prospective.CALIBRATION_COUNT * 2
            ]
            aggregate_result = fixture[-1]

            def reopen(_manifest: object, _run: object, expected: dict, _path: object) -> dict:
                return rows[int(expected["sequence"])]

            def replay(*, request_path: Path, **_kwargs: object) -> dict:
                if request_path.name == "aggregate-request.json":
                    return {
                        **aggregate_result,
                        "aggregate_created": False,
                        "observer_elapsed_ns": 999,
                        "checker_elapsed_ns": 888,
                    }
                index = int(request_path.name.split("-")[1])
                return {**issue_results[index], "receipt_created": False}

            with mock.patch.object(prospective, "verify_templates", return_value=templates), mock.patch.object(
                prospective, "_reopen_rollout", side_effect=reopen
            ), mock.patch.object(prospective, "_run_driver_request", side_effect=replay) as driver:
                record = prospective.verify_promotion(
                    manifest,
                    root / "run",
                    promotion_ref,
                    completed=completed,
                    repo=repo,
                    templates=templates,
                )
                self.assertEqual(promotion_ref["receipt_id"], record["receipt_id"])
                self.assertEqual(prospective.CALIBRATION_COUNT + 1, driver.call_count)

                issue_path = root / "run" / "rule-impact-control" / "issue-00000-result.json"
                issue_path.write_bytes(issue_path.read_bytes() + b" ")
                with self.assertRaises(prospective.E3Error):
                    prospective.verify_promotion(
                        manifest,
                        root / "run",
                        promotion_ref,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )

                stale = {**manifest, "policy_epoch": 2}
                with self.assertRaises(prospective.E3Error):
                    prospective.verify_promotion(
                        stale,
                        root / "run",
                        promotion_ref,
                        completed=completed,
                        repo=repo,
                        templates=templates,
                    )


if __name__ == "__main__":
    unittest.main()
