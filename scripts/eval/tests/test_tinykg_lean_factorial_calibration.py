from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.eval import tinykg_lean_factorial_executor as executor
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
)
from scripts.eval.memory_replay import PRODUCTION_PROVIDER_ID
from scripts.eval.model import ValidationError, stable_json
from scripts.eval.tests.posix_only import requires_posix_budget_journal


class TinyKgLeanFactorialCalibrationTest(unittest.TestCase):
    def _context(self, root: Path, *, resume: bool) -> executor.CalibrationContext:
        run_dir = root / "run"
        if resume:
            run_dir.mkdir(mode=0o700)
            (run_dir / "rollouts").mkdir(mode=0o700)
        authority = BudgetAuthority(
            manifest_sha256="a" * 64,
            model_fingerprint="b" * 64,
            provider_identity=PRODUCTION_PROVIDER_ID,
            total_cost_microusd=10_000,
            total_metered_tokens=10_000,
        )
        identity = {
            "schema_version": executor.EXECUTOR_SCHEMA,
            "calibration_id": "c" * 64,
        }
        return executor.CalibrationContext(
            repo=root,
            manifest={"execution": {"rollout_timeout_seconds": 1}},
            templates={},
            case={"id": "case"},
            root=root,
            workspace=root / "workspace",
            run_dir=run_dir,
            budget_path=root / "budget.json",
            ripgrep=root / "rg",
            ripgrep_sha256="d" * 64,
            tinykg_binary=root / "tinykg",
            tinykg_sha256="e" * 64,
            seed_batch=b"seed\n",
            recall_query="calibration marker",
            identity=identity,
            schedules=executor._calibration_schedules("case"),
            authority=authority,
        )

    def _commit(self, budget: BudgetJournal, sequence: int) -> None:
        transaction = BudgetTransaction(
            run_id=f"run-{sequence}",
            manifest_sha256="a" * 64,
            model_fingerprint="b" * 64,
            harness_fingerprint=f"{sequence:064x}",
            provider_identity=PRODUCTION_PROVIDER_ID,
            max_cost_microusd=1_000,
            max_metered_tokens=1_000,
        )
        reserved = budget.reserve(transaction)
        authorized = budget.authorize_request(
            str(reserved["transaction_id"]),
            expected_revision=int(reserved["journal_revision"]),
            expected_head_sha256=str(reserved["journal_head_sha256"]),
        )
        budget.commit(
            str(authorized["transaction_id"]),
            actual_cost_microusd=100,
            actual_metered_tokens=100,
        )

    def _fake_result(
        self,
        *,
        run_dir: Path,
        sequence: int,
        cell: str,
    ) -> dict[str, object]:
        source_path = run_dir / "sources" / f"source-{sequence}.json"
        source_payload = (stable_json({"sequence": sequence}) + "\n").encode()
        executor._write_private(source_path, source_payload)
        projection = {
            "sequence": sequence,
            "cell": cell,
            "quality_evidence": False,
        }
        persisted = executor.persist_projection(
            projection=projection,
            run_dir=run_dir,
        )
        return {
            **persisted,
            "source": {
                "receipt_path": str(source_path),
                "receipt_sha256": hashlib.sha256(source_payload).hexdigest(),
            },
        }

    def test_dry_run_does_not_create_run_or_budget_state(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-preflight-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=False)
            with mock.patch.object(executor, "_prepare_calibration", return_value=context):
                result = executor.preflight_calibration(
                    repo=root,
                    manifest_path=root / "manifest.json",
                    case_id="case",
                    tinykg_binary=root / "tinykg",
                    ripgrep=root / "rg",
                    run_dir=context.run_dir,
                    budget_path=context.budget_path,
                    resume=False,
                )
            self.assertFalse(context.run_dir.exists())
            self.assertFalse(context.budget_path.exists())
            self.assertFalse(context.budget_path.with_name("budget.json.lock").exists())
            self.assertEqual(0, result["provider_requests"])
            self.assertFalse(result["credential_read"])
            self.assertFalse(result["quality_evidence"])

    def test_execute_cell_forwards_calibration_evidence_boundary(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-eligibility-") as temporary:
            run_dir = Path(temporary)
            source = {"receipt_path": str(run_dir / "source.json"), "receipt_sha256": "f" * 64}
            projection = {
                "sequence": 0,
                "cell": "control",
                "quality_evidence": True,
            }
            with (
                mock.patch.object(executor, "_run_one", return_value=source) as run_one,
                mock.patch.object(executor, "build_projection", return_value=projection),
            ):
                result = executor.execute_cell(
                    repo=run_dir,
                    manifest={},
                    templates={},
                    schedule={
                        "sequence": 0,
                        "case_id": "case",
                        "position": 0,
                        "cell": "control",
                    },
                    run_dir=run_dir,
                    ripgrep=run_dir / "rg",
                    ripgrep_sha256="a" * 64,
                    api_key="secret",
                    budget=mock.Mock(),
                    timeout_seconds=1,
                    tinykg_binary=run_dir / "tinykg",
                    tinykg_binary_sha256="b" * 64,
                    seed_batch=b"",
                    recall_query="",
                    quality_evidence_eligible=False,
                )
            self.assertFalse(result["projection"]["quality_evidence"])
            self.assertFalse(run_one.call_args.kwargs["quality_evidence_eligible"])

    @requires_posix_budget_journal
    def test_checkpoint_advances_after_every_completed_cell(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-checkpoint-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=False)
            observed_prefixes: list[int] = []
            auth_file = root / "auth.json"
            auth_file.write_text("{}\n")
            auth_file.chmod(0o600)

            def fake_execute(**kwargs: object) -> dict[str, object]:
                schedule = kwargs["schedule"]
                self.assertIsInstance(schedule, dict)
                sequence = int(schedule["sequence"])  # type: ignore[index]
                budget = kwargs["budget"]
                self.assertIsInstance(budget, BudgetJournal)
                if sequence > 0:
                    checkpoint = json.loads(
                        (context.run_dir / "calibration-checkpoint.json").read_text()
                    )
                    snapshot = budget.snapshot()
                    observed_prefixes.append(len(checkpoint["completed"]))
                    self.assertEqual(snapshot["revision"], checkpoint["budget_revision"])
                    self.assertEqual(
                        snapshot["head_sha256"], checkpoint["budget_head_sha256"]
                    )
                self.assertFalse(kwargs["quality_evidence_eligible"])
                self._commit(budget, sequence)
                return self._fake_result(
                    run_dir=context.run_dir,
                    sequence=sequence,
                    cell=str(schedule["cell"]),  # type: ignore[index]
                )

            with (
                mock.patch.object(executor, "_prepare_calibration", return_value=context),
                mock.patch.object(executor, "_load_api_key", return_value="private-test-secret"),
                mock.patch.object(executor, "execute_cell", side_effect=fake_execute),
                mock.patch.object(executor, "_validate_calibration_projections"),
                mock.patch.object(executor, "_validate_paid_calibration_sources"),
            ):
                summary = executor.run_calibration(
                    repo=root,
                    manifest_path=root / "manifest.json",
                    case_id="case",
                    tinykg_binary=root / "tinykg",
                    ripgrep=root / "rg",
                    run_dir=context.run_dir,
                    budget_path=context.budget_path,
                    auth_file=auth_file,
                    resume=False,
                )
            checkpoint = json.loads(
                (context.run_dir / "calibration-checkpoint.json").read_text()
            )
            self.assertEqual([1, 2, 3], observed_prefixes)
            self.assertEqual(4, len(checkpoint["completed"]))
            self.assertIsNotNone(checkpoint["references"])
            self.assertEqual(4, summary["rollouts"])
            self.assertFalse(summary["quality_evidence"])

    @requires_posix_budget_journal
    def test_historical_receipt_survives_later_commits_but_not_transaction_drift(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-history-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=False)
            with BudgetJournal(context.budget_path, context.authority) as budget:
                self._commit(budget, 0)
                first = budget.transaction_receipts()[0]
                self._commit(budget, 1)
                executor._assert_historical_budget_receipt(budget, first)
                tampered = {**first, "actual_metered_tokens": 101}
                with self.assertRaisesRegex(
                    ValidationError, "durable journal transaction drift"
                ):
                    executor._assert_historical_budget_receipt(budget, tampered)

    @requires_posix_budget_journal
    def test_completed_resume_does_not_read_credential_or_reexecute(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-resume-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=True)
            results = [
                self._fake_result(run_dir=context.run_dir, sequence=index, cell=cell)
                for index, cell in enumerate(executor.CALIBRATION_CELLS)
            ]
            references_path = executor.persist_references(
                receipts=results,
                run_dir=context.run_dir,
            )
            references = {
                "path": references_path.relative_to(context.run_dir).as_posix(),
                "sha256": executor._sha256_file(references_path),
            }
            with BudgetJournal(context.budget_path, context.authority) as budget:
                for index in range(4):
                    self._commit(budget, index)
                executor._persist_checkpoint(
                    path=context.run_dir / "calibration-checkpoint.json",
                    identity=context.identity,
                    completed=[
                        executor._checkpoint_entry(result, context.run_dir)
                        for result in results
                    ],
                    budget=budget,
                    references=references,
                )

            with (
                mock.patch.object(executor, "_prepare_calibration", return_value=context),
                mock.patch.object(
                    executor,
                    "_reopen_completed",
                    side_effect=results,
                ),
                mock.patch.object(executor, "_validate_calibration_projections"),
                mock.patch.object(executor, "_validate_paid_calibration_sources"),
                mock.patch.object(executor, "_load_api_key") as load_key,
                mock.patch.object(executor, "execute_cell") as execute,
            ):
                summary = executor.run_calibration(
                    repo=root,
                    manifest_path=root / "manifest.json",
                    case_id="case",
                    tinykg_binary=root / "tinykg",
                    ripgrep=root / "rg",
                    run_dir=context.run_dir,
                    budget_path=context.budget_path,
                    auth_file=root / "missing-auth.json",
                    resume=True,
                )
            load_key.assert_not_called()
            execute.assert_not_called()
            self.assertEqual(4, summary["rollouts"])

    @requires_posix_budget_journal
    def test_resume_rejects_uncheckpointed_budget_state_before_credential(self) -> None:
        for authorize in (False, True):
            with self.subTest(authorize=authorize), tempfile.TemporaryDirectory(
                prefix="factorial-unsettled-"
            ) as temporary:
                root = Path(temporary)
                context = self._context(root, resume=True)
                with BudgetJournal(context.budget_path, context.authority) as budget:
                    executor._persist_checkpoint(
                        path=context.run_dir / "calibration-checkpoint.json",
                        identity=context.identity,
                        completed=[],
                        budget=budget,
                        references=None,
                    )
                    transaction = BudgetTransaction(
                        run_id="uncheckpointed",
                        manifest_sha256="a" * 64,
                        model_fingerprint="b" * 64,
                        harness_fingerprint="f" * 64,
                        provider_identity=PRODUCTION_PROVIDER_ID,
                        max_cost_microusd=1_000,
                        max_metered_tokens=1_000,
                    )
                    reserved = budget.reserve(transaction)
                    if authorize:
                        budget.authorize_request(
                            str(reserved["transaction_id"]),
                            expected_revision=int(reserved["journal_revision"]),
                            expected_head_sha256=str(reserved["journal_head_sha256"]),
                        )
                with (
                    mock.patch.object(
                        executor, "_prepare_calibration", return_value=context
                    ),
                    mock.patch.object(executor, "_load_api_key") as load_key,
                    self.assertRaisesRegex(ValidationError, "budget or prefix drift"),
                ):
                    executor.run_calibration(
                        repo=root,
                        manifest_path=root / "manifest.json",
                        case_id="case",
                        tinykg_binary=root / "tinykg",
                        ripgrep=root / "rg",
                        run_dir=context.run_dir,
                        budget_path=context.budget_path,
                        auth_file=root / "auth.json",
                        resume=True,
                    )
                load_key.assert_not_called()

    def test_references_and_projection_are_replayed_not_only_hashed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-references-") as temporary:
            run_dir = Path(temporary)
            result = self._fake_result(run_dir=run_dir, sequence=0, cell="control")
            references_path = executor.persist_references(
                receipts=[result],
                run_dir=run_dir,
            )
            info = {
                "path": references_path.relative_to(run_dir).as_posix(),
                "sha256": executor._sha256_file(references_path),
            }
            self.assertEqual(
                references_path,
                executor._reopen_references(
                    info=info,
                    results=[result],
                    run_dir=run_dir,
                ),
            )
            references = json.loads(references_path.read_text())
            references["receipts"][0]["sequence"] = 1
            references_path.write_text(stable_json(references) + "\n")
            tampered_info = {
                **info,
                "sha256": executor._sha256_file(references_path),
            }
            with self.assertRaisesRegex(ValidationError, "binding drift"):
                executor._reopen_references(
                    info=tampered_info,
                    results=[result],
                    run_dir=run_dir,
                )

            expected = result["projection"]
            entry = executor._checkpoint_entry(result, run_dir)
            receipt_path = Path(str(result["path"]))
            receipt = json.loads(receipt_path.read_text())
            receipt["projection"] = {**expected, "cell": "memory_only"}
            receipt["projection_sha256"] = hashlib.sha256(
                stable_json(receipt["projection"]).encode()
            ).hexdigest()
            receipt_path.write_text(stable_json(receipt) + "\n")
            entry = {**entry, "receipt_sha256": executor._sha256_file(receipt_path)}
            with (
                mock.patch.object(executor, "build_projection", return_value=expected),
                self.assertRaisesRegex(ValidationError, "projection replay drift"),
            ):
                executor._reopen_completed(
                    entry=entry,
                    schedule={"sequence": 0, "cell": "control"},
                    run_dir=run_dir,
                    manifest={},
                    budget=mock.Mock(),
                )


if __name__ == "__main__":
    unittest.main()
