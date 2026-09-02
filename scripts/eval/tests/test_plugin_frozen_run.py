"""The frozen-run manifest: a paid run's pre-registration.

A user authority binds to the manifest's hash *before* any provider request;
`run_paid_pair` and `analyze` re-derive every field from the live tree and
refuse to proceed - before opening the authority, before reading rollouts -
if anything the user signed has moved. The path-set digest is what makes a
shrunk pin list a named mismatch rather than a silently narrower freeze.

Arm inventories are patched to constants throughout: they exercise the
wrapper fixtures against a real runtime, which is not what these tests are
about, and their values do not matter here - only that they are frozen.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import platform
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.e2e_adapter import comparison_fingerprints
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    usd_to_microusd,
    validate_checkpoint_payload,
)
from scripts.eval.model import ValidationError as JournalValidationError
from scripts.eval.model import ValidationError, load_rollouts
from scripts.eval.paired_runner import scenario_selector
from scripts.eval.plugin_pair_analysis import analyze
from scripts.eval.plugin_pair_analysis import verify_journal_authority
from scripts.eval.plugin_pair_runner import (
    AUTHORITY_SCHEMA,
    FROZEN_RUN_SCHEMA,
    _arm_identities,
    _authority_manifest,
    _canonical_sha256,
    _observe,
    build_plan,
    freeze_run,
    frozen_run_fields,
    load_user_authority,
    main,
    manifest_sha256_of,
    path_set_digest,
    rollout_evidence_sha256,
    run_paid_pair,
    verify_frozen_manifest,
    write_rollouts,
)
from scripts.eval.plugin_release_gate import (
    PluginGateError,
    load_protocol,
    refresh_implementation_fingerprint,
)

ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"
INVENTORIES = mock.patch(
    "scripts.eval.plugin_pair_runner._verify_arm_inventory",
    lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
)


def _frozen_fixture(directory: Path) -> tuple[Path, Path]:
    """A repinned protocol copy whose runtime pin names a fake executable."""
    runtime = directory / "metacodes-release-small"
    runtime.write_bytes(b"fake-release-small")
    os.chmod(runtime, 0o700)
    path = directory / "protocol.json"
    path.write_text(PROTOCOL.read_text(encoding="utf-8"), encoding="utf-8")
    refresh_implementation_fingerprint(ROOT, path)
    value = json.loads(path.read_text(encoding="utf-8"))
    value["coding_pair"]["runtime_binary_sha256"] = hashlib.sha256(runtime.read_bytes()).hexdigest()
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    return path, runtime


def _live_fields(protocol_path: Path, runtime: Path) -> dict:
    protocol = load_protocol(ROOT, protocol_path)
    _, wrapper_hashes, inventory_hashes = _arm_identities(ROOT, protocol, runtime)
    plan = build_plan(ROOT, protocol_path, runtime_binary=runtime)
    return frozen_run_fields(
        ROOT,
        protocol,
        protocol_sha256=hashlib.sha256(protocol_path.read_bytes()).hexdigest(),
        runtime_sha256=hashlib.sha256(runtime.read_bytes()).hexdigest(),
        wrapper_hashes=wrapper_hashes,
        inventory_hashes=inventory_hashes,
        schedule=plan["schedule"],
    )


def _write_private(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")
    os.chmod(path, 0o600)


@INVENTORIES
class FreezeAndVerifyTest(unittest.TestCase):
    def test_freeze_produces_a_manifest_that_verifies_against_the_same_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            manifest = freeze_run(ROOT, path, runtime)
            self.assertEqual(FROZEN_RUN_SCHEMA, manifest["schema"])
            self.assertEqual(manifest_sha256_of(manifest), manifest["manifest_sha256"])
            self.assertEqual(64, len(manifest["implementation_fingerprint"]))
            # The host is frozen too: rollouts record platform/python into
            # their environment fingerprint, so a run or analysis elsewhere
            # is refused by name before any money moves.
            environment = manifest["environment"]
            self.assertEqual(
                {"platform", "python", "implementation", "cache_tag", "executable", "executable_sha256", "prefix"},
                set(environment),
            )
            self.assertEqual(platform.platform(), environment["platform"])
            self.assertEqual(platform.python_version(), environment["python"])
            self.assertEqual(str(Path(sys.prefix).resolve()), environment["prefix"])
            self.assertEqual(hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest(), environment["executable_sha256"])
            self.assertEqual(manifest["manifest_sha256"], verify_frozen_manifest(manifest, _live_fields(path, runtime)))

    def test_every_field_is_load_bearing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            manifest = freeze_run(ROOT, path, runtime)
            live = _live_fields(path, runtime)
            for key in (k for k in manifest if k not in {"schema", "manifest_sha256"}):
                tampered = dict(manifest)
                tampered[key] = "0" * 64 if isinstance(manifest[key], str) else {"x": "0" * 64}
                tampered["manifest_sha256"] = manifest_sha256_of(tampered)
                with self.assertRaisesRegex(ValidationError, f"drifted: {key}$"):
                    verify_frozen_manifest(tampered, live)
            # A manifest whose hash does not match its own fields is refused
            # even when every field matches the tree.
            forged = dict(manifest, manifest_sha256="0" * 64)
            with self.assertRaisesRegex(ValidationError, "hash does not match"):
                verify_frozen_manifest(forged, live)
            # And an unknown schema, or extra fields, are not silently accepted.
            with self.assertRaisesRegex(ValidationError, "unsupported schema"):
                verify_frozen_manifest(dict(manifest, schema="x"), live)
            with self.assertRaisesRegex(ValidationError, "unsupported or missing fields"):
                verify_frozen_manifest(dict(manifest, extra=1), live)

    def test_a_shrunk_pin_list_is_a_named_mismatch(self) -> None:
        # This is the guard the content fingerprint cannot provide: after a
        # repin nothing in protocol.json remembers the list was longer.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            manifest = freeze_run(ROOT, path, runtime)
            value = json.loads(path.read_text(encoding="utf-8"))
            value["implementation_paths"].remove("src/tools/result_spool.zig")
            path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
            refresh_implementation_fingerprint(ROOT, path)  # the narrower list repins cleanly...
            load_protocol(ROOT, path)  # ...and the strict loader is satisfied by it.
            self.assertNotEqual(manifest["path_set_digest"], path_set_digest(load_protocol(ROOT, path)))
            # Shrinking the list necessarily rewrites protocol.json too, so the
            # protocol hash drifts as well; the digest's job is to *name* the
            # shrink alongside it rather than let it hide behind a generic
            # "protocol changed".
            with self.assertRaisesRegex(ValidationError, r"drifted: .*path_set_digest") as caught:
                verify_frozen_manifest(manifest, _live_fields(path, runtime))
            self.assertIn("protocol_sha256", str(caught.exception))


class ProductionEntryPointsVerifyTheManifestFirstTest(unittest.TestCase):
    def setUp(self) -> None:
        # Started here rather than as a class decorator: mock.patch on a class
        # wraps only test* methods, and setUp freezes a manifest - which
        # walks the arm inventories.
        patcher = mock.patch(
            "scripts.eval.plugin_pair_runner._verify_arm_inventory",
            lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.temporary = Path(self._tmp.name)
        self.protocol_path, self.runtime = _frozen_fixture(self.temporary)
        self.manifest = freeze_run(ROOT, self.protocol_path, self.runtime)
        self.manifest_path = self.temporary / "frozen.json"
        _write_private(self.manifest_path, self.manifest)

    def test_run_paid_pair_rejects_a_foreign_manifest_before_opening_the_authority(self) -> None:
        foreign = dict(self.manifest, implementation_fingerprint="f" * 64)
        foreign["manifest_sha256"] = manifest_sha256_of(foreign)
        _write_private(self.manifest_path, foreign)
        authority = self.temporary / "authority.json"
        opened = []
        real_open = os.open

        def spy_open(path, *args, **kwargs):
            if str(path) == str(authority):
                opened.append(path)
            return real_open(path, *args, **kwargs)

        with mock.patch("scripts.eval.plugin_pair_runner.os.open", spy_open):
            with self.assertRaisesRegex(ValidationError, "drifted: implementation_fingerprint"):
                run_paid_pair(
                    ROOT,
                    self.protocol_path,
                    runtime_binary=self.runtime,
                    output_dir=self.temporary / "output",
                    budget_journal_path=self.temporary / "budget.jsonl",
                    provider_auth_file=self.temporary / "missing-provider-auth",
                    user_authority_file=authority,
                    frozen_manifest_file=self.manifest_path,
                )
        self.assertEqual([], opened)
        self.assertFalse((self.temporary / "output").exists())

    def test_run_paid_pair_requires_the_authority_to_name_this_manifest(self) -> None:
        authority = self.temporary / "authority.json"
        _write_private(authority, {
            "schema": AUTHORITY_SCHEMA,
            "protocol_sha256": hashlib.sha256(self.protocol_path.read_bytes()).hexdigest(),
            "manifest_sha256": "b" * 64,
            "max_cost_usd": 72.0,
            "max_metered_tokens": 72_000_000,
            "authorized_by_user": True,
        })
        with self.assertRaisesRegex(ValidationError, "another frozen-run manifest"):
            run_paid_pair(
                ROOT,
                self.protocol_path,
                runtime_binary=self.runtime,
                output_dir=self.temporary / "output",
                budget_journal_path=self.temporary / "budget.jsonl",
                provider_auth_file=self.temporary / "missing-provider-auth",
                user_authority_file=authority,
                frozen_manifest_file=self.manifest_path,
            )
        self.assertFalse((self.temporary / "output").exists())

    def test_analyze_rejects_a_foreign_manifest_before_reading_any_evidence(self) -> None:
        foreign = dict(self.manifest, path_set_digest="0" * 64)
        foreign["manifest_sha256"] = manifest_sha256_of(foreign)
        _write_private(self.manifest_path, foreign)
        with self.assertRaisesRegex(ValidationError, "drifted: path_set_digest"):
            analyze(
                ROOT,
                self.protocol_path,
                self.runtime,
                self.temporary / "no-baseline",
                self.temporary / "no-candidate",
                self.temporary / "no-journal",
                frozen_manifest_file=self.manifest_path,
            )


@INVENTORIES
class FreezeCliTest(unittest.TestCase):
    def test_freeze_writes_a_private_manifest_and_refuses_to_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            out = Path(directory) / "frozen.json"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, main(["--freeze", "--protocol", str(path), "--runtime-binary", str(runtime), "--frozen-manifest", str(out)]))
            self.assertEqual(0o600, stat.S_IMODE(out.stat().st_mode))
            written = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(manifest_sha256_of(written), written["manifest_sha256"])
            with self.assertRaises(SystemExit):
                main(["--freeze", "--protocol", str(path), "--runtime-binary", str(runtime), "--frozen-manifest", str(out)])
            self.assertEqual(written, json.loads(out.read_text(encoding="utf-8")))


# --- a paid run, end to end, without a provider ---------------------------


class _PaidFixture:
    """A repinned protocol copy shrunk to one trial (six rollouts), a fake
    runtime, the frozen manifest for that tree, and a v2 authority naming
    the manifest. The provider key loader is patched by the tests; the auth
    file path never has to exist."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.runtime = directory / "metacodes-release-small"
        self.runtime.write_bytes(b"fake-release-small")
        os.chmod(self.runtime, 0o700)
        self.protocol = directory / "protocol.json"
        value = json.loads(PROTOCOL.read_text(encoding="utf-8"))
        pair = value["coding_pair"]
        pair["trials"] = 1
        pair["rollouts"] = 2 * len(pair["task_ids"])
        pair["runtime_binary_sha256"] = hashlib.sha256(self.runtime.read_bytes()).hexdigest()
        self.protocol.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        refresh_implementation_fingerprint(ROOT, self.protocol)
        self.manifest = freeze_run(ROOT, self.protocol, self.runtime)
        self.manifest_path = directory / "frozen.json"
        _write_private(self.manifest_path, self.manifest)
        self.authority = directory / "authority.json"
        _write_private(self.authority, {
            "schema": AUTHORITY_SCHEMA,
            "protocol_sha256": hashlib.sha256(self.protocol.read_bytes()).hexdigest(),
            "manifest_sha256": self.manifest["manifest_sha256"],
            "max_cost_usd": 2.0 * pair["rollouts"],
            "max_metered_tokens": 2_000_000 * pair["rollouts"],
            "authorized_by_user": True,
        })
        self.output = directory / "output"
        self.journal = directory / "budget.jsonl"

    def run(self, **overrides):
        arguments = dict(
            runtime_binary=self.runtime,
            output_dir=self.output,
            budget_journal_path=self.journal,
            provider_auth_file=self.directory / "never-opened-provider-auth",
            user_authority_file=self.authority,
            frozen_manifest_file=self.manifest_path,
        )
        arguments.update(overrides)
        return run_paid_pair(ROOT, self.protocol, **arguments)

    def analyze(self, **overrides):
        arguments = dict(
            baseline_path=self.output / "baseline.jsonl",
            candidate_path=self.output / "candidate.jsonl",
            budget_journal_path=self.journal,
            frozen_manifest_file=self.manifest_path,
        )
        arguments.update(overrides)
        return analyze(ROOT, self.protocol, self.runtime, **arguments)

    def rewrite_protocol(self) -> None:
        """A self-consistent edit after the freeze. The real shape of the
        attack swaps the candidate Skill and updates its pin - which this
        test cannot do without editing the repository tree - but the frozen
        mechanism refuses *any* change to the protocol bytes, so a field the
        strict loader accepts stands in exactly."""
        value = json.loads(self.protocol.read_text(encoding="utf-8"))
        value["coding_pair"]["max_output_tokens"] = 4096
        self.protocol.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


class _FakeProvider:
    """Stands in for the e2e harness: records each request, returns rows the
    real pipeline accepts (identities from `comparison_fingerprints`), and
    lets a test act at a chosen moment inside a request."""

    def __init__(self, fixture: _PaidFixture, *, during_request=None, mutate_row=None) -> None:
        self.fixture = fixture
        self.during_request = during_request
        self.mutate_row = mutate_row
        self.requests: list[tuple[str, int, str]] = []
        self.imports = 0
        self._state: dict[Path, tuple] = {}
        suite = json.loads((ROOT / "evals/plugin-v1/coding-suite.json").read_text(encoding="utf-8"))
        self.suite_id = suite["suite_id"]
        self.tasks = {task["id"]: task for task in suite["tasks"]}
        self.by_selector = {scenario_selector([task_id]): task_id for task_id in self.tasks}

    def run_once(self, repo_root, binary, variant, trial, selector, provider, model_id, suite_path, revision, *, harness_config_id=None, runtime_env=None, allow_invalid_run=False, timeout_seconds=None, max_metered_tokens=None, max_cost_usd=None, runtime_api_key=None):
        token = self.fixture.directory / f"run-{len(self.requests)}"
        self.requests.append((variant, trial, selector))
        self._state[token] = (binary, variant, trial, selector, provider, model_id, revision, harness_config_id, max_metered_tokens, max_cost_usd)
        if self.during_request is not None:
            self.during_request()
        return token

    def import_run(self, suite, repo_root, run_dir):
        self.imports += 1
        binary, variant, trial, selector, provider, model_id, revision, config_id, max_tokens, max_cost = self._state[run_dir]
        task_id = self.by_selector[selector]
        task = self.tasks[task_id]
        identity = comparison_fingerprints(
            task, ROOT, model_provider=provider, model_id=model_id, harness_config_id=config_id,
            harness_revision=revision, permission_mode=task["constraints"]["permission_mode"], binary_path=binary,
        )
        row = self._row(task, task_id, variant, trial, provider, model_id, revision, config_id, max_tokens, max_cost, identity)
        if self.mutate_row is not None:
            self.mutate_row(row)
        return [row]

    def _row(self, task, task_id, variant, trial, provider, model_id, revision, config_id, max_tokens, max_cost, identity):
        return {
            "schema_version": 1,
            "run_id": f"{variant}:{task_id}:{trial}",
            "suite_id": self.suite_id,
            "task_id": task_id,
            "task_fingerprint": identity["task_fingerprint"],
            "task_fingerprint_provenance": "recorded_at_execution",
            "trial": trial,
            "layers": task["layers"],
            "model": {"provider": provider, "id": model_id, "fingerprint": identity["model_fingerprint"]},
            "harness": {
                "config_id": config_id, "revision": revision, "fingerprint": identity["harness_fingerprint"],
                "permission_mode": identity["permission_mode"], "environment_fingerprint": identity["environment_fingerprint"],
                "runtime_budget": {"max_metered_tokens": max_tokens, "max_cost_usd": max_cost},
            },
            "readiness": {"status": "pass", "checks": []},
            "execution": {"status": "completed", "exit_code": 0, "invalid_reasons": []},
            "outcome": {"status": "pass", "checks": []},
            "trajectory": {"status": "pass", "checks": [], "tool_failures": []},
            "evaluator": {"status": "ready", "kind": "deterministic_workspace", "version": "plugin-v1", "fingerprint": identity["grader_fingerprint"], "errors": []},
            "judgement": {"valid_for_scoring": True, "trustworthy_success": True},
            "metrics": {
                "cost_usd": 0.01, "input_tokens": 10, "output_tokens": 5, "cache_read_tokens": 0, "cache_write_tokens": 0,
                "wall_time_ms": 1000, "model_request_time_ms": 600, "tool_stage_time_ms": 300, "harness_time_ms": 100,
                "policy_violations": 0, "model_tool_errors": 0, "tool_calls": 1,
            },
            "attribution": [],
            "artifacts": {},
        }

    @contextlib.contextmanager
    def installed(self):
        with mock.patch("scripts.eval.plugin_pair_runner._run_once", side_effect=self.run_once), mock.patch(
            "scripts.eval.plugin_pair_runner.import_run", side_effect=self.import_run
        ), mock.patch("scripts.eval.plugin_pair_runner._load_api_key", return_value="test-only-key"):
            yield


class PaidRunStaysFrozenTest(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch(
            "scripts.eval.plugin_pair_runner._verify_arm_inventory",
            lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.fixture = _PaidFixture(Path(self._tmp.name))

    def test_a_complete_pair_is_bound_to_the_manifest_end_to_end(self) -> None:
        fixture = self.fixture
        fake = _FakeProvider(fixture)
        with fake.installed():
            self.assertEqual({"baseline": 3, "candidate": 3}, fixture.run())
        self.assertEqual(6, len(fake.requests))
        self.assertEqual(6, fake.imports)
        journal_bytes = fixture.journal.read_bytes()
        journal = validate_checkpoint_payload(journal_bytes)
        self.assertEqual(6, len(journal["transactions"]))
        self.assertEqual({"committed"}, {t["state"] for t in journal["transactions"].values()})
        for arm in ("baseline", "candidate"):
            for row in load_rollouts(fixture.output / f"{arm}.jsonl"):
                self.assertEqual(fixture.manifest["manifest_sha256"], row["plugin_treatment"]["frozen_manifest_sha256"])
                # The committed event sealed this exact body (attestation
                # included, receipt excluded).
                sealed = journal["transactions"][row["budget_transaction"]["transaction_id"]]["evidence_sha256"]
                self.assertEqual(rollout_evidence_sha256(row), sealed)
        # A resume of the completed pair re-validates the persisted bodies
        # against the sealed digests and makes no further request.
        resumed = _FakeProvider(fixture)
        with resumed.installed():
            self.assertEqual({"baseline": 3, "candidate": 3}, fixture.run())
        self.assertEqual(0, len(resumed.requests))
        receipt = fixture.analyze()
        self.assertEqual("development_gate_passed", receipt["release_status"])
        self.assertEqual(fixture.manifest["manifest_sha256"], receipt["frozen_manifest_sha256"])
        self.assertEqual(fixture.manifest["implementation_fingerprint"], receipt["implementation_fingerprint"])
        self.assertEqual(fixture.manifest["path_set_digest"], receipt["path_set_digest"])
        self.assertEqual(hashlib.sha256(journal_bytes).hexdigest(), receipt["budget_journal_sha256"])
        self.assertEqual(3, receipt["pair_count"])
        self.assertEqual(6, receipt["provider_requests_upper_bound"])

    def test_a_protocol_rewritten_during_a_request_is_refused_before_its_evidence_is_imported(self) -> None:
        fixture = self.fixture
        fake = _FakeProvider(fixture, during_request=fixture.rewrite_protocol)
        with fake.installed():
            with self.assertRaisesRegex(ValidationError, r"drifted: protocol_sha256 \(after request\)"):
                fixture.run()
        self.assertEqual(1, len(fake.requests))
        self.assertEqual(0, fake.imports)
        journal = validate_checkpoint_payload(fixture.journal.read_bytes())
        self.assertEqual(["request_authorized"], [t["state"] for t in journal["transactions"].values()])
        self.assertFalse((fixture.output / "baseline.jsonl").exists())

    def test_a_protocol_rewritten_between_requests_is_refused_before_the_next_request(self) -> None:
        fixture = self.fixture
        fake = _FakeProvider(fixture)
        written = []

        def write_then_rewrite(path, rows):
            write_rollouts(path, rows)
            written.append(path)
            if len(written) == 1:
                fixture.rewrite_protocol()

        with fake.installed(), mock.patch(
            "scripts.eval.plugin_pair_runner.write_rollouts", side_effect=write_then_rewrite
        ):
            with self.assertRaisesRegex(ValidationError, r"drifted: protocol_sha256 \(before request\)"):
                fixture.run()
        self.assertEqual(1, len(fake.requests))
        journal = validate_checkpoint_payload(fixture.journal.read_bytes())
        self.assertEqual(["committed"], [t["state"] for t in journal["transactions"].values()])
        self.assertEqual(1, len(load_rollouts(fixture.output / "baseline.jsonl")))


class PreAuthorizationFailureTest(unittest.TestCase):
    """A failure between reservation and durable authorization spent nothing;
    the reservation is aborted so a resume is not blocked by it. A failure
    after the authorization became durable leaves it authorized: a request
    may have been admitted, and resume must stay refused."""

    def setUp(self) -> None:
        patcher = mock.patch(
            "scripts.eval.plugin_pair_runner._verify_arm_inventory",
            lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.fixture = _PaidFixture(Path(self._tmp.name))

    def test_a_failure_before_the_authorization_is_durable_aborts_the_reservation(self) -> None:
        fixture = self.fixture
        with mock.patch.object(BudgetJournal, "authorize_request", side_effect=RuntimeError("lost before the write")):
            with _FakeProvider(fixture).installed():
                with self.assertRaisesRegex(RuntimeError, "lost before the write"):
                    fixture.run()
        journal = validate_checkpoint_payload(fixture.journal.read_bytes())
        self.assertEqual(["aborted_pre_request"], [t["state"] for t in journal["transactions"].values()])
        # ...and the pair then completes on a plain retry.
        fake = _FakeProvider(fixture)
        with fake.installed():
            self.assertEqual({"baseline": 3, "candidate": 3}, fixture.run())
        self.assertEqual(6, len(fake.requests))

    def test_a_failure_after_the_authorization_is_durable_keeps_it_and_blocks_resume(self) -> None:
        fixture = self.fixture
        real = BudgetJournal.authorize_request

        def authorize_then_die(self, *args, **kwargs):
            real(self, *args, **kwargs)
            raise RuntimeError("lost after the write")

        with mock.patch.object(BudgetJournal, "authorize_request", authorize_then_die):
            with _FakeProvider(fixture).installed():
                with self.assertRaisesRegex(RuntimeError, "lost after the write"):
                    fixture.run()
        journal = validate_checkpoint_payload(fixture.journal.read_bytes())
        self.assertEqual(["request_authorized"], [t["state"] for t in journal["transactions"].values()])
        with _FakeProvider(fixture).installed():
            with self.assertRaisesRegex(ValidationError, "replay is forbidden"):
                fixture.run()

    def test_an_abort_that_cannot_be_recorded_is_reported_not_swallowed(self) -> None:
        # The authorization never became durable *and* the abort could not
        # be persisted (storage failure): the reservation is stranded on
        # disk. That is reported, with the original failure as the cause,
        # rather than hidden behind "aborted".
        fixture = self.fixture
        with mock.patch.object(
            BudgetJournal, "authorize_request", side_effect=RuntimeError("lost before the write")
        ), mock.patch.object(
            BudgetJournal,
            "abort_pre_request",
            side_effect=JournalValidationError("budget journal: cannot create temporary file: EACCES"),
        ):
            with _FakeProvider(fixture).installed():
                with self.assertRaisesRegex(ValidationError, "abort could not be recorded") as caught:
                    fixture.run()
        self.assertIsInstance(caught.exception.__cause__, RuntimeError)
        journal = validate_checkpoint_payload(fixture.journal.read_bytes())
        self.assertEqual(["reserved"], [t["state"] for t in journal["transactions"].values()])


class AnalysisBindsTheJournalTest(unittest.TestCase):
    """The receipt's `budget_journal_sha256` is the hash of a journal that
    replayed, whose authority names this frozen run, and whose transactions
    are exactly the rollouts' receipts - not of whatever file was passed."""

    def setUp(self) -> None:
        patcher = mock.patch(
            "scripts.eval.plugin_pair_runner._verify_arm_inventory",
            lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.fixture = _PaidFixture(Path(self._tmp.name))
        with _FakeProvider(self.fixture).installed():
            self.fixture.run()
        self.state = validate_checkpoint_payload(self.fixture.journal.read_bytes())

    def _rewrite_candidate(self, mutate) -> None:
        path = self.fixture.output / "candidate.jsonl"
        rows = load_rollouts(path)
        mutate(rows[0])
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def test_an_unrelated_readable_file_is_not_a_budget_journal(self) -> None:
        with self.assertRaisesRegex(ValidationError, "budget journal"):
            self.fixture.analyze(budget_journal_path=self.fixture.protocol)

    def test_a_journal_sealed_without_this_frozen_manifest_is_refused(self) -> None:
        foreign = self.fixture.directory / "foreign-budget.jsonl"
        authority = dict(self.state["authority"], manifest_sha256="c" * 64)
        with BudgetJournal(foreign, BudgetAuthority(**authority)):
            pass
        with self.assertRaisesRegex(ValidationError, "does not bind this frozen run"):
            self.fixture.analyze(budget_journal_path=foreign)

    def test_a_row_naming_an_unknown_transaction_is_refused(self) -> None:
        self._rewrite_candidate(lambda row: row["budget_transaction"].__setitem__("transaction_id", "0" * 64))
        with self.assertRaisesRegex(ValidationError, "the budget journal does not contain"):
            self.fixture.analyze()

    def test_a_receipt_that_drifted_from_the_journal_is_refused(self) -> None:
        self._rewrite_candidate(lambda row: row["budget_transaction"].__setitem__("identity_sha256", "0" * 64))
        with self.assertRaisesRegex(ValidationError, "drifted from the journal"):
            self.fixture.analyze()

    def test_an_authorized_transaction_without_a_rollout_is_refused(self) -> None:
        authority = self.state["authority"]
        extra = BudgetTransaction(
            run_id="plugin-v1:candidate:00_smoke:1",
            manifest_sha256=authority["manifest_sha256"],
            model_fingerprint=authority["model_fingerprint"],
            harness_fingerprint="f" * 64,
            provider_identity=authority["provider_identity"],
            max_cost_microusd=usd_to_microusd(2.0),
            max_metered_tokens=2_000_000,
        )
        with BudgetJournal(self.fixture.journal, BudgetAuthority(**authority)) as journal:
            reserved = journal.reserve(extra)
            journal.authorize_request(
                str(reserved["transaction_id"]),
                expected_revision=int(reserved["journal_revision"]),
                expected_head_sha256=str(reserved["journal_head_sha256"]),
            )
        with self.assertRaisesRegex(ValidationError, "without a matching rollout"):
            self.fixture.analyze()

    def test_the_journal_authority_is_a_function_of_the_frozen_manifest(self) -> None:
        observation = _observe(ROOT, self.fixture.protocol, self.fixture.runtime)
        hashes = {
            _canonical_sha256(
                _authority_manifest(
                    observation,
                    frozen_manifest_sha256=digest,
                    authorized_cost_microusd=1,
                    authorized_metered_tokens=1,
                )
            )
            for digest in ("a" * 64, "b" * 64)
        }
        self.assertEqual(2, len(hashes))
        # And the verifier consumes that binding: the real journal verifies
        # against the manifest it was sealed under and no other.
        sealed_under = self.fixture.manifest["manifest_sha256"]
        verify_journal_authority(self.state, observation, frozen_manifest_sha256=sealed_under)
        with self.assertRaisesRegex(ValidationError, "does not bind this frozen run"):
            verify_journal_authority(self.state, observation, frozen_manifest_sha256="b" * 64)

    def test_an_authority_too_small_for_the_schedule_is_not_a_paid_run(self) -> None:
        # The runner refuses an authority below rollouts x max_rollout; a
        # journal sealed under one (six rollouts of zero usage fit under $2)
        # therefore cannot have come from run_paid_pair.
        observation = _observe(ROOT, self.fixture.protocol, self.fixture.runtime)
        authority = dict(self.state["authority"], total_cost_microusd=usd_to_microusd(2.0))
        authority["manifest_sha256"] = _canonical_sha256(
            _authority_manifest(
                observation,
                frozen_manifest_sha256=self.fixture.manifest["manifest_sha256"],
                authorized_cost_microusd=authority["total_cost_microusd"],
                authorized_metered_tokens=authority["total_metered_tokens"],
            )
        )
        with self.assertRaisesRegex(ValidationError, "cannot cover the complete frozen schedule"):
            verify_journal_authority(dict(self.state, authority=authority), observation, frozen_manifest_sha256=self.fixture.manifest["manifest_sha256"])

    def test_resume_refuses_a_checkpoint_whose_body_was_edited(self) -> None:
        # Same sealed digest, checked on the runner's own resume path.
        def flip(row):
            row["outcome"]["status"] = "fail"
            row["judgement"]["trustworthy_success"] = False
        self._rewrite_candidate(flip)
        with _FakeProvider(self.fixture).installed():
            with self.assertRaisesRegex(ValidationError, "checkpoint rollout body does not match the evidence sealed"):
                self.fixture.run()

    def test_a_rollout_body_edited_after_the_run_is_refused(self) -> None:
        # Outcome and judgement flipped coherently: validate_rollout accepts
        # the row, usage and receipt are untouched, only the sealed digest
        # disagrees.
        def flip(row):
            row["outcome"]["status"] = "fail"
            row["judgement"]["trustworthy_success"] = False
        self._rewrite_candidate(flip)
        with self.assertRaisesRegex(ValidationError, "does not match the evidence sealed"):
            self.fixture.analyze()

    def test_a_receipt_transplanted_from_another_run_of_the_same_freeze_is_refused(self) -> None:
        # Run B of the same freeze, different usage, into a fresh journal.
        fixture = self.fixture
        rows_a = {arm: load_rollouts(fixture.output / f"{arm}.jsonl") for arm in ("baseline", "candidate")}
        fixture.journal.unlink()
        shutil.rmtree(fixture.output)

        def pricier(row):
            row["metrics"]["cost_usd"] = 0.02
        with _FakeProvider(fixture, mutate_row=pricier).installed():
            fixture.run()
        rows_b = {arm: load_rollouts(fixture.output / f"{arm}.jsonl") for arm in ("baseline", "candidate")}
        # Transplant: A's bodies (with outcomes flipped so they differ from
        # B's) carrying B's receipts and B's counters, judged against B's
        # journal. Every receipt matches a committed transaction; only the
        # sealed body digest tells the two runs apart.
        for arm in ("baseline", "candidate"):
            by_key = {(r["task_id"], r["trial"]): r for r in rows_b[arm]}
            spliced = []
            for row in rows_a[arm]:
                twin = by_key[(row["task_id"], row["trial"])]
                row["metrics"] = twin["metrics"]
                row["budget_transaction"] = twin["budget_transaction"]
                row["outcome"]["status"] = "fail"
                row["judgement"]["trustworthy_success"] = False
                spliced.append(row)
            (fixture.output / f"{arm}.jsonl").write_text(
                "".join(json.dumps(r) + "\n" for r in spliced), encoding="utf-8"
            )
        with self.assertRaisesRegex(ValidationError, "does not match the evidence sealed"):
            fixture.analyze()

    def test_a_receipt_with_foreign_fields_or_a_later_journal_position_is_refused(self) -> None:
        self._rewrite_candidate(lambda row: row["budget_transaction"].__setitem__("note", "x"))
        with self.assertRaisesRegex(ValidationError, "unexpected or missing fields"):
            self.fixture.analyze()
        self.setUp()
        self._rewrite_candidate(lambda row: row["budget_transaction"].__setitem__("journal_revision", row["budget_transaction"]["commit_revision"] + 1))
        with self.assertRaisesRegex(ValidationError, "not bound to its commit revision/head"):
            self.fixture.analyze()

    def test_resume_applies_the_same_receipt_binding_as_analysis(self) -> None:
        # A receipt with a foreign field, or one pointing at another journal
        # position, is refused on resume exactly as in analysis: the two
        # share one validator.
        self._rewrite_candidate(lambda row: row["budget_transaction"].__setitem__("note", "x"))
        with _FakeProvider(self.fixture).installed():
            with self.assertRaisesRegex(ValidationError, "unexpected or missing fields"):
                self.fixture.run()
        self.setUp()
        self._rewrite_candidate(lambda row: row["budget_transaction"].__setitem__("journal_revision", row["budget_transaction"]["commit_revision"] + 1))
        with _FakeProvider(self.fixture).installed():
            with self.assertRaisesRegex(ValidationError, "not bound to its commit revision/head"):
                self.fixture.run()

    def test_a_row_the_harness_recorded_with_the_wrong_identity_is_refused(self) -> None:
        # The body is authentic - the journal sealed it - but its task
        # fingerprint is not the one this suite produces. Resume would refuse
        # the checkpoint; analysis applies the same grounded validation.
        fixture = self.fixture
        fixture.journal.unlink()
        shutil.rmtree(fixture.output)

        def wrong_task(row):
            row["task_fingerprint"] = "0" * 64
        with _FakeProvider(fixture, mutate_row=wrong_task).installed():
            fixture.run()
        with self.assertRaisesRegex(ValidationError, "identity mismatch"):
            fixture.analyze()


if __name__ == "__main__":
    unittest.main()
