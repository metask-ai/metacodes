import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    _canonical_sha256,
    reopen_checkpoint_transaction,
    usd_to_microusd,
    usd_to_microusd_ceiling,
    validate_checkpoint_payload,
)
from scripts.eval.model import ValidationError


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


class MemoryBudgetJournalTest(unittest.TestCase):
    def authority(self, *, total_cost: int = 10_000_000) -> BudgetAuthority:
        return BudgetAuthority(
            manifest_sha256=digest("manifest"),
            model_fingerprint=digest("model"),
            provider_identity="metask-anthropic-compatible-v1",
            total_cost_microusd=total_cost,
            total_metered_tokens=1_000_000,
        )

    def transaction(
        self,
        run_id: str = "suite:0:case:0:no_memory",
        *,
        max_cost: int = 3_000_000,
        max_tokens: int = 100_000,
    ) -> BudgetTransaction:
        return BudgetTransaction(
            run_id=run_id,
            manifest_sha256=digest("manifest"),
            model_fingerprint=digest("model"),
            harness_fingerprint=digest(f"harness:{run_id}"),
            provider_identity="metask-anthropic-compatible-v1",
            max_cost_microusd=max_cost,
            max_metered_tokens=max_tokens,
        )

    def authorize(self, journal: BudgetJournal, transaction: BudgetTransaction):
        reserved = journal.reserve(transaction)
        return journal.authorize_request(
            reserved["transaction_id"],
            expected_revision=reserved["journal_revision"],
            expected_head_sha256=reserved["journal_head_sha256"],
        )

    def test_exact_money_and_authority_cap(self):
        self.assertEqual(usd_to_microusd(0.9), 900_000)
        self.assertEqual(usd_to_microusd("1000"), 1_000_000_000)
        self.assertEqual(usd_to_microusd_ceiling("0.0000003"), 1)
        with self.assertRaisesRegex(ValidationError, "precision"):
            usd_to_microusd("0.0000001")
        with self.assertRaisesRegex(ValidationError, "must not exceed"):
            BudgetAuthority(
                manifest_sha256=digest("manifest"),
                model_fingerprint=digest("model"),
                provider_identity="provider",
                total_cost_microusd=1_000_000_001,
                total_metered_tokens=1,
            ).validate()

    def test_state_machine_crash_exposure_and_commit_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pilot-budget.json"
            transaction = self.transaction()
            with BudgetJournal(path, self.authority()) as journal:
                authorized = self.authorize(journal, transaction)
                self.assertEqual(authorized["state"], "request_authorized")
                self.assertIsNotNone(authorized["authorization_revision"])
                self.assertIsNotNone(authorized["authorization_head_sha256"])

            with BudgetJournal(path, self.authority()) as recovered:
                snapshot = recovered.snapshot()
                self.assertEqual(snapshot["committed_cost_microusd"], 0)
                self.assertEqual(snapshot["unsettled_max_cost_microusd"], 3_000_000)
                self.assertEqual(snapshot["exposure_metered_tokens"], 100_000)
                with self.assertRaisesRegex(ValidationError, "retry is forbidden"):
                    recovered.reserve(transaction)
                committed = recovered.commit(
                    authorized["transaction_id"],
                    actual_cost_microusd=750_000,
                    actual_metered_tokens=12_345,
                )
                revision = committed["journal_revision"]
                replayed = recovered.commit(
                    authorized["transaction_id"],
                    actual_cost_microusd=750_000,
                    actual_metered_tokens=12_345,
                )
                self.assertEqual(replayed["journal_revision"], revision)
                with self.assertRaisesRegex(ValidationError, "identically"):
                    recovered.commit(
                        authorized["transaction_id"],
                        actual_cost_microusd=750_001,
                        actual_metered_tokens=12_345,
                    )
                final = recovered.snapshot()
                self.assertEqual(final["committed_cost_microusd"], 750_000)
                self.assertEqual(final["unsettled_max_cost_microusd"], 0)
                checkpoint = validate_checkpoint_payload(recovered.checkpoint_payload())
                self.assertEqual(checkpoint["head_sha256"], final["head_sha256"])
                reopened = reopen_checkpoint_transaction(
                    recovered.checkpoint_payload(),
                    committed["transaction_id"],
                )
                self.assertEqual(committed, reopened)
                tampered = json.loads(recovered.checkpoint_payload())
                tampered["events"][-1]["actual_metered_tokens"] += 1
                with self.assertRaisesRegex(ValidationError, "does not bind event"):
                    reopen_checkpoint_transaction(
                        json.dumps(tampered).encode("utf-8"),
                        committed["transaction_id"],
                    )

    def test_abort_is_only_legal_before_authorization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pilot-budget.json"
            with BudgetJournal(path, self.authority()) as journal:
                reserved = journal.reserve(self.transaction("pre-request"))
                aborted = journal.abort_pre_request(reserved["transaction_id"])
                self.assertEqual(aborted["state"], "aborted_pre_request")
                self.assertEqual(journal.snapshot()["exposure_cost_microusd"], 0)

                authorized = self.authorize(journal, self.transaction("authorized"))
                with self.assertRaisesRegex(ValidationError, "cannot be aborted"):
                    journal.abort_pre_request(authorized["transaction_id"])

    def test_authorized_run_id_cannot_be_reauthorized_by_harness_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pilot-budget.json"
            original = self.transaction("stable-run")
            drifted = BudgetTransaction(
                run_id=original.run_id,
                manifest_sha256=original.manifest_sha256,
                model_fingerprint=original.model_fingerprint,
                harness_fingerprint=digest("changed-harness"),
                provider_identity=original.provider_identity,
                max_cost_microusd=original.max_cost_microusd,
                max_metered_tokens=original.max_metered_tokens,
            )
            with BudgetJournal(path, self.authority()) as journal:
                self.authorize(journal, original)
                before = journal.snapshot()
                with self.assertRaisesRegex(
                    ValidationError,
                    "run id is already bound.*new explicit run identity",
                ):
                    journal.reserve(drifted)
                self.assertEqual(journal.snapshot(), before)

                identity = drifted.record()
                reservation_revision = before["revision"] + 1
                transaction_id = _canonical_sha256(
                    {
                        "journal_id": before["journal_id"],
                        "reservation_revision": reservation_revision,
                        "identity": identity,
                    }
                )
                with self.assertRaisesRegex(
                    ValidationError,
                    "run id already has a non-aborted transaction",
                ):
                    journal._append(
                        action="reserved",
                        transaction_id=transaction_id,
                        identity=identity,
                    )
                self.assertEqual(journal.snapshot(), before)

    def test_exposure_limit_is_checked_before_persist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pilot-budget.json"
            with BudgetJournal(path, self.authority(total_cost=5_000_000)) as journal:
                first = self.authorize(
                    journal,
                    self.transaction("first", max_cost=3_000_000),
                )
                with self.assertRaisesRegex(ValidationError, "exceeds authority"):
                    journal.reserve(self.transaction("second", max_cost=3_000_000))
                journal.commit(
                    first["transaction_id"],
                    actual_cost_microusd=1_000_000,
                    actual_metered_tokens=10_000,
                )
                second = journal.reserve(
                    self.transaction("second", max_cost=3_000_000)
                )
                self.assertEqual(second["state"], "reserved")
                self.assertEqual(journal.snapshot()["exposure_cost_microusd"], 4_000_000)

    def test_revision_cas_and_identity_drift_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pilot-budget.json"
            with BudgetJournal(path, self.authority()) as journal:
                reserved = journal.reserve(self.transaction())
                with self.assertRaisesRegex(ValidationError, "CAS"):
                    journal.authorize_request(
                        reserved["transaction_id"],
                        expected_revision=reserved["journal_revision"] + 1,
                        expected_head_sha256=reserved["journal_head_sha256"],
                    )
            drifted = BudgetAuthority(
                manifest_sha256=digest("manifest"),
                model_fingerprint=digest("other-model"),
                provider_identity="metask-anthropic-compatible-v1",
                total_cost_microusd=10_000_000,
                total_metered_tokens=1_000_000,
            )
            with self.assertRaisesRegex(ValidationError, "identity or limits drifted"):
                with BudgetJournal(path, drifted):
                    pass

    def test_lock_is_process_exclusive_and_loser_does_not_mutate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "pilot-budget.json"
            with BudgetJournal(path, self.authority()) as journal:
                before = journal.snapshot()
                code = """
from pathlib import Path
from scripts.eval.memory_budget_journal import BudgetAuthority, BudgetJournal
authority = BudgetAuthority(
    manifest_sha256=%r,
    model_fingerprint=%r,
    provider_identity='metask-anthropic-compatible-v1',
    total_cost_microusd=10000000,
    total_metered_tokens=1000000,
)
with BudgetJournal(Path(%r), authority):
    raise SystemExit(91)
""" % (digest("manifest"), digest("model"), str(path))
                completed = subprocess.run(
                    [sys.executable, "-c", code],
                    cwd=Path(__file__).resolve().parents[3],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(completed.returncode, 91)
                self.assertIn("another local runner holds it", completed.stderr)
                self.assertEqual(journal.snapshot(), before)

    def test_corrupt_truncated_symlink_hardlink_and_temp_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            authority = self.authority()

            corrupt = root / "corrupt.json"
            corrupt.write_bytes(b'{"schema_version":1')
            corrupt.chmod(0o600)
            with self.assertRaisesRegex(ValidationError, "invalid JSON"):
                with BudgetJournal(corrupt, authority):
                    pass

            target = root / "target.json"
            target.write_text("not-a-journal\n", encoding="utf-8")
            target.chmod(0o600)
            symlink = root / "symlink.json"
            symlink.symlink_to(target)
            with self.assertRaisesRegex(ValidationError, "cannot open"):
                with BudgetJournal(symlink, authority):
                    pass

            original = root / "hardlinked.json"
            with BudgetJournal(original, authority):
                pass
            alias = root / "hardlinked-alias.json"
            os.link(original, alias)
            with self.assertRaisesRegex(ValidationError, "hard links"):
                with BudgetJournal(original, authority):
                    pass

            incomplete = root / "incomplete.json"
            incomplete.with_name(incomplete.name + ".tmp").write_text(
                "partial\n", encoding="utf-8"
            )
            incomplete.with_name(incomplete.name + ".tmp").chmod(0o600)
            with self.assertRaisesRegex(ValidationError, "manual inspection"):
                with BudgetJournal(incomplete, authority):
                    pass

    def test_parent_directory_replacement_between_stat_and_open_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trusted = root / "trusted"
            replacement = root / "replacement"
            trusted.mkdir(mode=0o700)
            replacement.mkdir(mode=0o700)
            trusted_resolved = trusted.resolve()
            real_open = os.open

            def swapped_open(path, flags, *args, **kwargs):
                if Path(path) == trusted_resolved and kwargs.get("dir_fd") is None:
                    return real_open(replacement, flags, *args, **kwargs)
                return real_open(path, flags, *args, **kwargs)

            with mock.patch(
                "scripts.eval.memory_budget_journal.os.open",
                side_effect=swapped_open,
            ):
                with self.assertRaisesRegex(ValidationError, "changed while opening"):
                    with BudgetJournal(trusted / "pilot-budget.json", self.authority()):
                        pass
            self.assertFalse((trusted / "pilot-budget.json").exists())
            self.assertFalse((replacement / "pilot-budget.json").exists())

    def test_fault_before_rename_leaves_manual_stop_after_rename_recovers_new_head(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before_rename = root / "before-rename.json"
            with BudgetJournal(before_rename, self.authority()):
                pass

            def fail_before(stage: str) -> None:
                if stage == "after_temporary_fsync":
                    raise RuntimeError("injected pre-rename crash")

            with self.assertRaisesRegex(RuntimeError, "pre-rename"):
                with BudgetJournal(
                    before_rename,
                    self.authority(),
                    fault_hook=fail_before,
                ) as journal:
                    journal.reserve(self.transaction("before-rename"))
            with self.assertRaisesRegex(ValidationError, "manual inspection"):
                with BudgetJournal(before_rename, self.authority()):
                    pass

            after_rename = root / "after-rename.json"
            with BudgetJournal(after_rename, self.authority()):
                pass

            def fail_after(stage: str) -> None:
                if stage == "after_atomic_replace":
                    raise RuntimeError("injected post-rename crash")

            with self.assertRaisesRegex(RuntimeError, "post-rename"):
                with BudgetJournal(
                    after_rename,
                    self.authority(),
                    fault_hook=fail_after,
                ) as journal:
                    journal.reserve(self.transaction("after-rename"))
            with BudgetJournal(after_rename, self.authority()) as recovered:
                self.assertEqual(recovered.snapshot()["transaction_states"], {"reserved": 1})

    def test_on_disk_revision_drift_while_locked_is_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pilot-budget.json"
            with BudgetJournal(path, self.authority()) as journal:
                document = json.loads(path.read_text(encoding="utf-8"))
                document["revision"] = 1
                path.write_text(json.dumps(document), encoding="utf-8")
                path.chmod(0o600)
                with self.assertRaisesRegex(ValidationError, "event count"):
                    journal.reserve(self.transaction())


if __name__ == "__main__":
    unittest.main()
