from __future__ import annotations

import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

from scripts.eval import tinykg_lean_factorial_executor as executor
from scripts.eval.attribution_protocol import balanced_factorial_schedule
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
)
from scripts.eval.memory_replay import PRODUCTION_PROVIDER_ID
from scripts.eval.model import stable_json


class TinyKgLeanFactorialBlockTest(unittest.TestCase):
    def _context(self, root: Path, *, resume: bool) -> executor.BlockContext:
        run_dir = root / "run"
        if resume:
            run_dir.mkdir(mode=0o700)
            (run_dir / "rollouts").mkdir(mode=0o700)
        authority = BudgetAuthority(
            manifest_sha256="a" * 64,
            model_fingerprint="b" * 64,
            provider_identity=PRODUCTION_PROVIDER_ID,
            total_cost_microusd=100_000,
            total_metered_tokens=100_000,
        )
        schedules = tuple(balanced_factorial_schedule(executor.BLOCK_CASE_IDS))
        identity = {
            "schema_version": executor.EXECUTOR_SCHEMA,
            "block_id": "c" * 64,
            "procedural_memory_sha256": "d" * 64,
        }
        return executor.BlockContext(
            repo=root,
            manifest={"execution": {"rollout_timeout_seconds": 1}},
            templates={},
            case_ids=executor.BLOCK_CASE_IDS,
            root=root,
            workspace=root / "workspace",
            run_dir=run_dir,
            budget_path=root / "budget.json",
            ripgrep=root / "rg",
            ripgrep_sha256="e" * 64,
            tinykg_binary=root / "tinykg",
            tinykg_sha256="f" * 64,
            seed_batch=b"seed\n",
            recall_query=executor.PROCEDURAL_MEMORY_QUERY,
            identity=identity,
            schedules=schedules,
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
        self, *, run_dir: Path, schedule: dict[str, object]
    ) -> dict[str, object]:
        sequence = int(schedule["sequence"])
        source_path = run_dir / "sources" / f"source-{sequence}.json"
        source_payload = (stable_json({"sequence": sequence}) + "\n").encode()
        executor._write_private(source_path, source_payload)
        projection = {
            "sequence": sequence,
            "case_id": schedule["case_id"],
            "cell": schedule["cell"],
            "quality_evidence": True,
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

    def _report(self) -> dict[str, object]:
        return {
            "quality_evidence": True,
            "claim_boundary": "internal complete 2x2 attribution",
        }

    def test_procedural_seed_is_fixed_and_does_not_leak_scored_cases(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-block-seed-") as temporary:
            payload, query = executor._block_seed(workspace=Path(temporary))
        self.assertEqual(executor.PROCEDURAL_MEMORY_QUERY, query)
        self.assertIn(b"source-CAS", payload)
        for forbidden in (
            *executor.BLOCK_CASE_IDS,
            ".archive.env",
            "nodes.json",
            "lifecycle.yaml",
            "proxy.conf",
        ):
            self.assertNotIn(forbidden.encode(), payload)

    def test_dry_run_observes_complete_schedule_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-block-preflight-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=False)
            with mock.patch.object(executor, "_prepare_block", return_value=context):
                result = executor.preflight_block(
                    repo=root,
                    manifest_path=root / "manifest.json",
                    tinykg_binary=root / "tinykg",
                    ripgrep=root / "rg",
                    run_dir=context.run_dir,
                    budget_path=context.budget_path,
                    resume=False,
                )
            self.assertFalse(context.run_dir.exists())
            self.assertFalse(context.budget_path.exists())
            self.assertEqual(0, result["provider_requests"])
            self.assertFalse(result["credential_read"])
            self.assertFalse(result["quality_evidence"])
            self.assertTrue(result["quality_eligible_after_paid_execution"])
            self.assertEqual(16, result["planned_rollouts"])

    def test_block_checkpoints_each_quality_eligible_rollout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-block-run-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=False)
            auth_file = root / "auth.json"
            auth_file.write_text("{}\n")
            auth_file.chmod(0o600)
            observed_prefixes: list[int] = []

            def fake_execute(**kwargs: object) -> dict[str, object]:
                schedule = kwargs["schedule"]
                budget = kwargs["budget"]
                self.assertIsInstance(schedule, dict)
                self.assertIsInstance(budget, BudgetJournal)
                self.assertTrue(kwargs["quality_evidence_eligible"])
                sequence = int(schedule["sequence"])  # type: ignore[index]
                if sequence > 0:
                    checkpoint = json.loads(
                        (context.run_dir / "factorial-block-checkpoint.json").read_text()
                    )
                    observed_prefixes.append(len(checkpoint["completed"]))
                self._commit(budget, sequence)
                return self._fake_result(run_dir=context.run_dir, schedule=schedule)

            report = self._report()
            with (
                mock.patch.object(executor, "_prepare_block", return_value=context),
                mock.patch.object(executor, "_load_api_key", return_value="secret"),
                mock.patch.object(executor, "execute_cell", side_effect=fake_execute),
                mock.patch.object(executor, "_validate_paid_block_sources"),
                mock.patch.object(executor, "build_report", return_value=report),
                mock.patch.object(
                    executor,
                    "load_receipts",
                    return_value=SimpleNamespace(projections=tuple()),
                ),
            ):
                summary = executor.run_block(
                    repo=root,
                    manifest_path=root / "manifest.json",
                    tinykg_binary=root / "tinykg",
                    ripgrep=root / "rg",
                    run_dir=context.run_dir,
                    budget_path=context.budget_path,
                    auth_file=auth_file,
                    resume=False,
                )
            self.assertEqual(list(range(1, 16)), observed_prefixes)
            checkpoint = json.loads(
                (context.run_dir / "factorial-block-checkpoint.json").read_text()
            )
            self.assertEqual(executor.BLOCK_CHECKPOINT_SCHEMA, checkpoint["schema_version"])
            self.assertEqual(16, len(checkpoint["completed"]))
            self.assertEqual(16, summary["rollouts"])
            self.assertTrue(summary["quality_evidence"])

    def test_completed_resume_reads_no_credential_and_replays_no_provider(self) -> None:
        with tempfile.TemporaryDirectory(prefix="factorial-block-resume-") as temporary:
            root = Path(temporary)
            context = self._context(root, resume=True)
            results = [
                self._fake_result(run_dir=context.run_dir, schedule=dict(schedule))
                for schedule in context.schedules
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
                for index in range(16):
                    self._commit(budget, index)
                executor._persist_checkpoint(
                    path=context.run_dir / "factorial-block-checkpoint.json",
                    identity=context.identity,
                    completed=[
                        executor._checkpoint_entry(result, context.run_dir)
                        for result in results
                    ],
                    budget=budget,
                    references=references,
                    schema_version=executor.BLOCK_CHECKPOINT_SCHEMA,
                )

            report = self._report()
            with (
                mock.patch.object(executor, "_prepare_block", return_value=context),
                mock.patch.object(executor, "_reopen_completed", side_effect=results),
                mock.patch.object(executor, "_validate_paid_block_sources"),
                mock.patch.object(executor, "build_report", return_value=report),
                mock.patch.object(
                    executor,
                    "load_receipts",
                    return_value=SimpleNamespace(projections=tuple()),
                ),
                mock.patch.object(executor, "_load_api_key") as load_key,
                mock.patch.object(executor, "execute_cell") as execute,
            ):
                summary = executor.run_block(
                    repo=root,
                    manifest_path=root / "manifest.json",
                    tinykg_binary=root / "tinykg",
                    ripgrep=root / "rg",
                    run_dir=context.run_dir,
                    budget_path=context.budget_path,
                    auth_file=root / "missing-auth.json",
                    resume=True,
                )
            load_key.assert_not_called()
            execute.assert_not_called()
            self.assertEqual(16, summary["rollouts"])


if __name__ == "__main__":
    unittest.main()
