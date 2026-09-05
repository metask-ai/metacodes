from __future__ import annotations

import copy
import hashlib
import json
import os
import stat
import tempfile
import unittest
import subprocess
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock
from scripts.eval.tests.posix_only import POSIX, requires_symlinks
import scripts.eval.plugin_release_gate as gate_module

from scripts.eval.plugin_release_gate import (
    PluginGateError,
    _benchmark_row,
    _median_int,
    _require_exact_tree,
    _materialize_head,
    attest_runtime_artifact,
    implementation_fingerprint,
    load_protocol,
    load_protocol_structure,
    run_gate,
    main,
    refresh_implementation_fingerprint,
)


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"



def _repinned_copy(directory: Path) -> Path:
    """The checked-in protocol, copied and repinned against the live tree.

    Between freezes the committed implementation fingerprint is stale by
    design (see load_protocol_structure). A test that must exercise the
    *strict* loader - because it asserts some other fail-closed check that
    sits behind the fingerprint comparison - seeds from this copy, so the
    stale pin cannot pre-empt the error the test is actually about.
    """
    path = directory / "protocol.json"
    path.write_text(PROTOCOL.read_text(encoding="utf-8"), encoding="utf-8")
    refresh_implementation_fingerprint(ROOT, path)
    return path


def _fresh_protocol(case: unittest.TestCase) -> dict:
    """A strictly loaded protocol object whose pin matches the live tree.

    Owns its own temporary directory for the life of the test case, so the
    caller's control flow does not have to change shape.
    """
    directory = tempfile.TemporaryDirectory()
    case.addCleanup(directory.cleanup)
    return load_protocol(ROOT, _repinned_copy(Path(directory.name)))


def _fake_gate_run(protocol_path: Path, mutate_last: callable):
    """Fake every subprocess the gate shells out to.

    The outputs satisfy the gate's parsers, so a test built on this only
    exercises the discipline around the subprocesses. ``mutate_last`` runs
    inside the last one (the candidate inventory), where a change to an input
    is invisible to a gate that only observes its start and its end.
    """
    deterministic = json.loads(protocol_path.read_text(encoding="utf-8"))["deterministic_gate"]
    plugin_id = json.loads(protocol_path.read_text(encoding="utf-8"))["candidate"]["plugin_id"]
    benchmark = json.dumps({
        "schema": "metacodes.plugin-benchmark/v1",
        "quality_evidence": False,
        "passed": True,
        "thresholds": {
            "max_static_plugin_p95_overhead_ns": deterministic["max_static_plugin_p95_overhead_ns"],
            "max_inventory_avg_ns": deterministic["max_inventory_avg_ns"],
        },
        "static_plugin_p95_overhead_ns": 1,
        "inventory_avg_ns": 1,
    })
    empty = json.dumps({"schema": "metacodes.plugin-inventory/v1", "plugins": []})
    one = json.dumps({"schema": "metacodes.plugin-inventory/v1", "plugins": [{"id": plugin_id, "capabilities": ["skill_bundle"]}]})

    def fake(root, args, *, env, timeout=600):
        argv = list(args)
        if "plugin:bench" in argv:
            output = benchmark
        elif argv[0].endswith("plugin_baseline.py"):
            output = empty
        elif argv[0].endswith("plugin_candidate.py"):
            output = one
            mutate_last()  # the last subprocess of the gate
        else:
            output = "ok"
        return {"argv": argv, "elapsed_ms": 1, "output_sha256": hashlib.sha256(output.encode()).hexdigest(), "output": output}
    return fake


class PluginReleaseGateTest(unittest.TestCase):
    def test_integer_median_does_not_depend_on_stdlib_module_resolution(self) -> None:
        self.assertEqual(3, _median_int([5, 1, 3]))
        self.assertEqual(2, _median_int([4, 1, 2, 3]))
        with self.assertRaises(PluginGateError):
            _median_int([])

    def test_checked_in_protocol_is_valid_and_zero_provider(self) -> None:
        # Structural: every pin except the implementation fingerprint, which
        # is stale between freezes by design and must not fail this test.
        protocol = load_protocol_structure(ROOT, PROTOCOL)
        self.assertFalse(protocol["quality_evidence"])
        self.assertEqual(0, protocol["deterministic_gate"]["provider_requests"])
        self.assertEqual(
            "blocked_pending_explicit_paid_authority",
            protocol["coding_pair"]["status"],
        )
        self.assertEqual(64, len(protocol["coding_pair"]["runtime_binary_sha256"]))
        # And the live tree is freezable: a copy repinned against it passes
        # the strict loader. (Asserting the repinned value equals the tree's
        # fingerprint would be tautological - refresh just wrote that value;
        # what carries weight is that the strict load succeeds.)
        _fresh_protocol(self)

    def test_structural_load_tolerates_a_stale_implementation_pin_but_nothing_else(self) -> None:
        # The one thing the structural loader forgives, and proof that it
        # forgives only that.
        with tempfile.TemporaryDirectory() as directory:
            path = _repinned_copy(Path(directory))
            raw = path.read_text(encoding="utf-8")
            pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
            stale = "0f" * 32
            self.assertNotEqual(stale, pinned)
            path.write_text(raw.replace(pinned, stale), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
                load_protocol(ROOT, path)
            tolerated = load_protocol_structure(ROOT, path)
            self.assertEqual(stale, tolerated["coding_pair"]["implementation_fingerprint"])
            # Every other pin still fails closed under the structural loader.
            broken = json.loads(raw)
            first = next(iter(broken["candidate"]["files"]))
            broken["candidate"]["files"][first] = "00" * 32
            path.write_text(json.dumps(broken), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "candidate files drifted"):
                load_protocol_structure(ROOT, path)
            # And the evaluator pins - the daily protection this PR documents -
            # are not behind the implementation switch either.
            broken = json.loads(raw)
            broken["pinned_evaluator_files"]["scripts/eval/plugin_release_gate.py"] = "00" * 32
            path.write_text(json.dumps(broken), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "evaluator files drifted"):
                load_protocol_structure(ROOT, path)

    def test_static_protocol_rejects_malformed_runtime_identity(self) -> None:
        protocol = _fresh_protocol(self)
        protocol["coding_pair"]["runtime_binary_sha256"] = "0" * 63
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.json"
            path.write_text(json.dumps(protocol), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "lowercase SHA-256"):
                load_protocol(ROOT, path)

    def test_runtime_attestation_uses_only_the_explicit_artifact(self) -> None:
        protocol = load_protocol_structure(ROOT, PROTOCOL)
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "metacodes-release-small"
            runtime.write_bytes(b"portable-runtime-fixture")
            os.chmod(runtime, 0o700)
            with self.assertRaisesRegex(PluginGateError, "ReleaseSmall runtime drifted"):
                attest_runtime_artifact(protocol, runtime)

            expected = hashlib.sha256(runtime.read_bytes()).hexdigest()
            matching = copy.deepcopy(protocol)
            matching["coding_pair"]["runtime_binary_sha256"] = expected
            attestation = attest_runtime_artifact(matching, runtime)
            self.assertEqual(runtime.resolve(), attestation.path)
            self.assertEqual(expected, attestation.sha256)

    def test_validate_only_needs_no_runtime_artifact(self) -> None:
        # Inspection must work in the normal stale-by-design state: it loads
        # structurally and reports the pin's state rather than failing on it.
        output = StringIO()
        with redirect_stdout(output):
            self.assertEqual(0, main(["--validate-only"]))
        value = json.loads(output.getvalue())
        self.assertEqual("metacodes.plugin-evaluation/v1", value["schema"])
        self.assertEqual(0, value["provider_requests"])
        self.assertIn(value["implementation_pin"], {"current", "stale"})
        self.assertEqual(value["freeze_ready"], value["implementation_pin"] == "current")
        self.assertEqual(64, len(value["observed_implementation_fingerprint"]))

    def test_validate_only_reports_a_stale_pin_instead_of_failing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = _repinned_copy(Path(directory))
            raw = path.read_text(encoding="utf-8")
            pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
            path.write_text(raw.replace(pinned, "0f" * 32), encoding="utf-8")
            output = StringIO()
            with redirect_stdout(output):
                self.assertEqual(0, main(["--validate-only", "--protocol", str(path)]))
            value = json.loads(output.getvalue())
            self.assertEqual("stale", value["implementation_pin"])
            self.assertFalse(value["freeze_ready"])
            self.assertEqual("0f" * 32, value["pinned_implementation_fingerprint"])
            self.assertEqual(pinned, value["observed_implementation_fingerprint"])

    def test_candidate_hash_drift_fails_closed(self) -> None:
        protocol = _fresh_protocol(self)
        tampered = copy.deepcopy(protocol)
        key = next(iter(tampered["candidate"]["files"]))
        tampered["candidate"]["files"][key] = "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.json"
            path.write_text(json.dumps(tampered), encoding="utf-8")
            with self.assertRaises(PluginGateError):
                load_protocol(ROOT, path)

    def test_unsafe_implementation_path_is_rejected(self) -> None:
        protocol = load_protocol_structure(ROOT, PROTOCOL)
        protocol["implementation_paths"] = ["../outside"]
        with self.assertRaises(PluginGateError):
            implementation_fingerprint(ROOT, protocol)

    def test_benchmark_thresholds_are_bound_to_protocol(self) -> None:
        protocol = load_protocol_structure(ROOT, PROTOCOL)
        row = {
            "schema": "metacodes.plugin-benchmark/v1",
            "quality_evidence": False,
            "static_plugin_p95_overhead_ns": 1,
            "inventory_avg_ns": 1,
            "thresholds": {
                "max_static_plugin_p95_overhead_ns": 50001,
                "max_inventory_avg_ns": 100000,
            },
            "passed": True,
        }
        with self.assertRaises(PluginGateError):
            _benchmark_row(json.dumps(row), protocol["deterministic_gate"])

    @requires_symlinks
    def test_symlinked_pinned_file_is_rejected(self) -> None:
        # The symlink is a *candidate* file named by the protocol, not the
        # protocol path itself - that was never symlink-checked.
        protocol = _fresh_protocol(self)
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            temporary = Path(directory)
            link = temporary / "candidate.json"
            link.symlink_to(
                ROOT / "evals/plugin-v1/coding-plugin/.metacodes-plugin/plugin.json"
            )
            relative = link.relative_to(ROOT).as_posix()
            protocol["candidate"]["files"] = {
                relative: protocol["candidate"]["files"][
                    "evals/plugin-v1/coding-plugin/.metacodes-plugin/plugin.json"
                ]
            }
            path = temporary / "protocol.json"
            path.write_text(json.dumps(protocol), encoding="utf-8")
            with self.assertRaises(PluginGateError):
                load_protocol(ROOT, path)

    def test_refresh_mode_repins_stale_fingerprint_without_weakening_gate(self) -> None:
        raw = PROTOCOL.read_text(encoding="utf-8")
        pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
        fresh = implementation_fingerprint(ROOT, json.loads(raw))
        stale = "0f" * 32
        self.assertNotEqual(stale, pinned)
        self.assertEqual(1, raw.count(pinned))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.json"
            path.write_text(raw.replace(pinned, stale), encoding="utf-8")
            # Unrefreshed drift stays fail-closed on every validate path.
            with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
                load_protocol(ROOT, path)
            output = StringIO()
            with redirect_stdout(output):
                self.assertEqual(
                    0,
                    main(
                        ["--refresh-implementation-fingerprint", "--protocol", str(path)]
                    ),
                )
            row = json.loads(output.getvalue())
            self.assertEqual("refreshed", row["status"])
            self.assertEqual(stale, row["previous_implementation_fingerprint"])
            self.assertEqual(fresh, row["implementation_fingerprint"])
            # Text replacement preserved every other byte of the file.
            self.assertEqual(raw.replace(pinned, fresh), path.read_text(encoding="utf-8"))
            self.assertEqual(
                fresh,
                load_protocol(ROOT, path)["coding_pair"]["implementation_fingerprint"],
            )
            output = StringIO()
            with redirect_stdout(output):
                self.assertEqual(
                    0,
                    main(
                        ["--refresh-implementation-fingerprint", "--protocol", str(path)]
                    ),
                )
            self.assertEqual("already_current", json.loads(output.getvalue())["status"])

    def test_refresh_mode_refuses_other_modes(self) -> None:
        with self.assertRaises(SystemExit):
            main(["--refresh-implementation-fingerprint", "--validate-only"])

    def test_refresh_with_unrelated_drift_leaves_protocol_untouched(self) -> None:
        raw = PROTOCOL.read_text(encoding="utf-8")
        pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
        gate_hash = json.loads(raw)["pinned_evaluator_files"][
            "scripts/eval/plugin_release_gate.py"
        ]
        # Stale fingerprint AND a corrupted evaluator hash: refresh must fail
        # closed on the evaluator drift and leave the file byte-identical,
        # with no staging residue.
        tampered = raw.replace(pinned, "0f" * 32).replace(gate_hash, "0e" * 32)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.json"
            path.write_text(tampered, encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "drift"):
                refresh_implementation_fingerprint(ROOT, path)
            self.assertEqual(tampered, path.read_text(encoding="utf-8"))
            self.assertEqual(
                [], list(Path(directory).glob("*.refresh-staging"))
            )




class RunGateSnapshotTest(unittest.TestCase):
    """The gate's inputs must be the same at the end as at the start.

    Everything the real gate shells out to is faked with outputs that satisfy
    the parsers, so the only thing under test is the snapshot discipline.
    """

    def _protocol_with_fake_runtime(self, directory: Path) -> tuple[Path, Path]:
        runtime = directory / "metacodes-release-small"
        runtime.write_bytes(b"fake-release-small")
        os.chmod(runtime, 0o700)
        path = _repinned_copy(directory)
        value = json.loads(path.read_text(encoding="utf-8"))
        value["coding_pair"]["runtime_binary_sha256"] = hashlib.sha256(runtime.read_bytes()).hexdigest()
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        return path, runtime

    def _fake_run(self, protocol_path: Path, mutate_last: callable):
        return _fake_gate_run(protocol_path, mutate_last)

    def _run_gate(self, protocol_path: Path, runtime: Path, mutate_last: callable, root_heads: list | None = None, before_call: callable = lambda: None):
        expected_dsh = json.loads(protocol_path.read_text(encoding="utf-8"))["upstream"]["deepseek_harness_commit"]
        real_git_head = __import__("scripts.eval.plugin_release_gate", fromlist=["_git_head"])._git_head
        heads = list(root_heads) if root_heads is not None else None

        def fake_git_head(path):
            if path != ROOT:
                return expected_dsh
            if heads:
                return heads.pop(0)
            return real_git_head(ROOT)

        with mock.patch("scripts.eval.plugin_release_gate._run", self._fake_run(protocol_path, mutate_last)), \
             mock.patch("scripts.eval.plugin_release_gate._git_head", fake_git_head), \
             mock.patch("scripts.eval.plugin_release_gate._materialize_head", return_value=ROOT), \
             mock.patch("scripts.eval.plugin_release_gate._require_clean_pinned_inputs"):
            before_call()  # test setup above may have read the protocol itself
            return run_gate(ROOT, protocol_path, dsh=Path("/nonexistent-dsh"), runtime_binary=runtime)

    def test_gate_with_unchanged_inputs_produces_a_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            receipt = self._run_gate(path, runtime, mutate_last=lambda: None)
            self.assertEqual("metacodes.plugin-zero-provider-receipt/v1", receipt["schema"])
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), receipt["protocol_sha256"])

    def test_protocol_bytes_changed_by_the_last_subprocess_reject_the_receipt(self) -> None:
        # Same JSON, different bytes: the receipt would otherwise carry a
        # protocol_sha256 for a file its fields were not read from.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            def reformat():
                path.write_text(json.dumps(json.loads(path.read_text(encoding="utf-8")), indent=4), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "protocol changed while the gate was running"):
                self._run_gate(path, runtime, mutate_last=reformat)

    def test_pin_changed_by_the_last_subprocess_rejects_the_receipt(self) -> None:
        # A *semantic* change, not just formatting. It is caught by the same
        # byte-equality check as the formatting case - any change to the file
        # is - which is why the gate no longer carries a separate pin
        # comparison; this test keeps the semantic case from regressing if the
        # byte check were ever narrowed.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            def stale_pin():
                raw = path.read_text(encoding="utf-8")
                pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
                path.write_text(raw.replace(pinned, "0f" * 32), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "protocol changed while the gate was running"):
                self._run_gate(path, runtime, mutate_last=stale_pin)

    def test_git_head_moving_during_the_gate_rejects_the_receipt(self) -> None:
        # Deleting the HEAD comparison left every other snapshot test green:
        # they all see the same real HEAD twice. Feed a different one the
        # second time.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            with self.assertRaisesRegex(PluginGateError, "git HEAD moved"):
                self._run_gate(path, runtime, mutate_last=lambda: None, root_heads=["a" * 40, "b" * 40])

    def test_stale_pin_is_rejected_at_entry_before_any_subprocess(self) -> None:
        # The gate must not spend minutes of subprocesses on a protocol whose
        # pin is stale; every RunGateSnapshotTest input is repinned, so this
        # is the one test that proves entry is strict.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            raw = path.read_text(encoding="utf-8")
            pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
            path.write_text(raw.replace(pinned, "0f" * 32), encoding="utf-8")
            calls = []
            expected_dsh = json.loads(raw)["upstream"]["deepseek_harness_commit"]
            # `_git_head` is patched too: without it, an implementation that
            # let a stale pin past entry crashed on the nonexistent DSH path
            # with FileNotFoundError - a non-PluginGateError that escaped
            # assertRaises and reported as an ERROR, hiding the assertion
            # this test exists for.
            with mock.patch("scripts.eval.plugin_release_gate._run", lambda *a, **k: calls.append(a) or {"argv": [], "elapsed_ms": 0, "output_sha256": "", "output": ""}), \
                 mock.patch("scripts.eval.plugin_release_gate._git_head", lambda p: expected_dsh), \
                 mock.patch("scripts.eval.plugin_release_gate._materialize_head", return_value=ROOT), \
                 mock.patch("scripts.eval.plugin_release_gate._require_clean_pinned_inputs"):
                with self.assertRaises(PluginGateError) as caught:
                    run_gate(ROOT, path, dsh=Path("/nonexistent-dsh"), runtime_binary=runtime)
            # The key assertion first, so a gate that *did* run subprocesses
            # and then failed for some other reason is reported as exactly
            # that, not as a message mismatch.
            self.assertEqual([], calls)
            self.assertRegex(str(caught.exception), "fingerprint drifted")

    def test_pinned_source_drifting_during_the_gate_rejects_the_receipt(self) -> None:
        # Protocol bytes unchanged, but a pinned source changed while the
        # subprocesses ran: the final re-validation of the same bytes against
        # the tree is the only check that can see it. The live tree is not
        # touched; the fingerprint the tree *would* produce is what changes.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            gate = __import__("scripts.eval.plugin_release_gate", fromlist=["implementation_fingerprint"])
            real = gate.implementation_fingerprint
            drifted = {"now": False}

            def fingerprint_that_drifts(root, protocol):
                value = real(root, protocol)
                return ("f" * 64) if drifted["now"] else value

            with mock.patch("scripts.eval.plugin_release_gate.implementation_fingerprint", fingerprint_that_drifts):
                with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
                    self._run_gate(path, runtime, mutate_last=lambda: drifted.update(now=True))

    def test_gate_reads_the_protocol_file_exactly_twice_and_never_as_text(self) -> None:
        # The object the checks run with and the hash the receipt carries must
        # come from ONE read at the start; the final check is the second. A
        # third read - hashing the file separately, or reloading it - is the
        # window an atomic replacement slips through.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = self._protocol_with_fake_runtime(Path(directory))
            target = path.resolve()
            reads = {"bytes": 0, "text": 0}
            real_read_bytes, real_read_text = Path.read_bytes, Path.read_text

            def counting_read_bytes(self_path, *args, **kwargs):
                if self_path.resolve() == target:
                    reads["bytes"] += 1
                return real_read_bytes(self_path, *args, **kwargs)

            def counting_read_text(self_path, *args, **kwargs):
                if self_path.resolve() == target:
                    reads["text"] += 1
                return real_read_text(self_path, *args, **kwargs)

            with mock.patch.object(Path, "read_bytes", counting_read_bytes), \
                 mock.patch.object(Path, "read_text", counting_read_text):
                # Only reads performed by run_gate itself count: the helpers
                # read the protocol to build their fakes, which is not the
                # discipline under test.
                receipt = self._run_gate(
                    path, runtime, mutate_last=lambda: None,
                    before_call=lambda: reads.update(bytes=0, text=0),
                )
            self.assertEqual({"bytes": 2, "text": 0}, reads)
            self.assertEqual(hashlib.sha256(real_read_bytes(path)).hexdigest(), receipt["protocol_sha256"])

class CandidateTreeIsPinnedExactlyTest(unittest.TestCase):
    """`candidate.files` hashes prove the pinned files are unchanged; the
    tree check proves they are the only files. A file added beside a pinned
    Skill needs no protocol edit, so nothing else would notice it."""

    PINNED = {"plugin/plugin.json": "x", "plugin/skills/verify/SKILL.md": "y"}

    def _tree(self, root: Path) -> Path:
        skill = root / "plugin/skills/verify"
        skill.mkdir(parents=True)
        (root / "plugin/plugin.json").write_text("{}", encoding="utf-8")
        (skill / "SKILL.md").write_text("skill", encoding="utf-8")
        return skill

    def test_exactly_the_pinned_files_and_nothing_else(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            skill = self._tree(root)
            _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            extra = skill / "reference.md"
            extra.write_text("unpinned", encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, r"unpinned \['plugin/skills/verify/reference.md'\], missing \[\]"):
                _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            extra.unlink()
            (root / "plugin/plugin.json").unlink()
            with self.assertRaisesRegex(PluginGateError, r"unpinned \[\], missing \['plugin/plugin.json'\]"):
                _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            (root / "plugin/plugin.json").write_text("{}", encoding="utf-8")
            _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            # Directory names are part of the runtime's Skill identity: an
            # empty directory the pins do not imply is a different candidate.
            (skill / "resources").mkdir()
            with self.assertRaisesRegex(PluginGateError, r"directories its pins do not imply: unpinned \['plugin/skills/verify/resources'\]"):
                _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            (skill / "resources").rmdir()
            with self.assertRaisesRegex(PluginGateError, "not a directory"):
                _require_exact_tree(root, "plugin/plugin.json", self.PINNED, "candidate")
            with self.assertRaisesRegex(PluginGateError, "unsafe protocol path"):
                _require_exact_tree(root, "../plugin", self.PINNED, "candidate")

    @unittest.skipIf(os.name == "nt", "symlink and mode-bit fixtures require POSIX")
    def test_symlinks_and_executable_files_under_the_candidate_root_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            skill = self._tree(root)
            # A symlink is refused even when it points at a pinned file: what
            # the runtime would read is not what the pin describes.
            (skill / "alias.md").symlink_to(skill / "SKILL.md")
            with self.assertRaisesRegex(PluginGateError, "contains a symlink: plugin/skills/verify/alias.md"):
                _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            (skill / "alias.md").unlink()
            # The executable bit is hashed into the Skill content revision;
            # identical bytes with +x are a different candidate.
            os.chmod(skill / "SKILL.md", 0o755)
            with self.assertRaisesRegex(PluginGateError, "executable or special file: plugin/skills/verify/SKILL.md"):
                _require_exact_tree(root, "plugin", self.PINNED, "candidate")
            os.chmod(skill / "SKILL.md", 0o644)
            _require_exact_tree(root, "plugin", self.PINNED, "candidate")

    def test_every_loader_checks_the_candidate_tree(self) -> None:
        with mock.patch(
            "scripts.eval.plugin_release_gate._require_exact_tree",
            side_effect=PluginGateError("candidate tree probe"),
        ) as probe:
            with self.assertRaisesRegex(PluginGateError, "candidate tree probe"):
                load_protocol_structure(ROOT, PROTOCOL)
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(PluginGateError, "candidate tree probe"):
                    load_protocol(ROOT, _repinned_copy(Path(directory)))
        protocol = json.loads(PROTOCOL.read_text(encoding="utf-8"))
        for call in probe.call_args_list:
            self.assertEqual(
                (ROOT, protocol["candidate"]["root"], protocol["candidate"]["files"], "candidate"),
                call.args,
            )
        self.assertGreaterEqual(len(probe.call_args_list), 2)


class MaterializedCheckoutTest(unittest.TestCase):
    """The gate consumes a materialized ``git archive HEAD`` checkout, not the live tree.

    Every test builds its own git repository in a temporary directory and
    never touches the real repository's working tree, so the class stays
    green on a dirty developer checkout and cannot damage one.
    """

    DSH = Path("/nonexistent-dsh")

    def _git(self, repo: Path, *args: str) -> None:
        subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def _scratch(self) -> Path:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        return Path(holder.name)

    def _repo(self) -> Path:
        repo = self._scratch()
        self._git(repo, "init", "-q")
        self._git(repo, "config", "core.autocrlf", "false")
        return repo

    def _commit(self, repo: Path, message: str) -> str:
        self._git(repo, "add", ".")
        self._git(repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message)
        return gate_module._git_head(repo)

    def _dsh_aware_git_head(self, value: dict):
        """The real ``_git_head`` for every path but the fake DeepSeek Harness checkout."""
        expected_dsh = value["upstream"]["deepseek_harness_commit"]
        real = gate_module._git_head

        def fake(path: Path) -> str:
            if path == self.DSH:
                return expected_dsh
            return real(path)

        return fake

    def test_materialize_head_extracts_the_commit_not_the_working_tree(self) -> None:
        """Committed bytes only: no working-tree edit, no untracked file, no ``.git``; modes kept."""
        repo = self._repo()
        (repo / "a.txt").write_text("A\n", encoding="utf-8")
        (repo / "dir").mkdir()
        (repo / "dir/b.txt").write_text("B\n", encoding="utf-8")
        script = repo / "run.py"
        script.write_text("#!/bin/sh\n", encoding="utf-8")
        os.chmod(script, 0o755)
        self._commit(repo, "initial")
        if not POSIX:
            # Windows cannot express the mode bit on disk; record it in the index.
            self._git(repo, "update-index", "--chmod=+x", "run.py")
            self._commit(repo, "mode")
        head = gate_module._git_head(repo)
        (repo / "a.txt").write_text("B\n", encoding="utf-8")
        (repo / "untracked.txt").write_text("x", encoding="utf-8")

        tree = _materialize_head(repo, head, self._scratch() / "tree")

        self.assertEqual("A\n", (tree / "a.txt").read_text(encoding="utf-8"))
        self.assertTrue((tree / "dir/b.txt").exists())
        self.assertFalse((tree / "untracked.txt").exists())
        self.assertFalse((tree / ".git").exists())
        if POSIX:
            self.assertTrue((tree / "run.py").stat().st_mode & stat.S_IXUSR)

    @requires_symlinks
    def test_materialize_head_refuses_a_committed_symlink(self) -> None:
        """A symlink member fails the materialization closed instead of being followed."""
        repo = self._repo()
        (repo / "target").write_text("x", encoding="utf-8")
        (repo / "link").symlink_to("target")
        head = self._commit(repo, "link")
        with self.assertRaisesRegex(PluginGateError, "link"):
            _materialize_head(repo, head, self._scratch() / "tree")

    def _synthetic(self) -> tuple[Path, Path, Path, dict, str]:
        """A committed synthetic repository whose protocol pins point into it.

        Derived from the checked-in protocol so every invariant
        ``_validate_payload`` enforces still holds; only the pin sets are
        rewritten. Returns ``(repo, protocol_path, runtime_binary, protocol, head)``.
        """
        repo = self._repo()
        value = json.loads(PROTOCOL.read_text(encoding="utf-8"))

        def put(relative: str, data: bytes) -> str:
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            return hashlib.sha256(data).hexdigest()

        value["implementation_paths"] = ["src/impl_a.zig", "src/impl_b.zig"]
        put("src/impl_a.zig", b"A\n")
        put("src/impl_b.zig", b"B\n")
        value["pinned_evaluator_files"] = {"eval.py": put("eval.py", b"eval\n")}
        value["candidate"]["root"] = "candidate"
        value["candidate"]["files"] = {
            "candidate/a.txt": put("candidate/a.txt", b"a\n"),
            "candidate/b.txt": put("candidate/b.txt", b"b\n"),
        }
        pair = value["coding_pair"]
        pair["suite"] = "suite.py"
        pair["baseline_executable"] = "base.py"
        pair["treatment_executable"] = "treat.py"
        for key in ("suite", "baseline_executable", "treatment_executable"):
            pair[key + "_sha256"] = put(pair[key], (key + "\n").encode("utf-8"))
        task = "synthetic"
        pair["task_ids"] = [task]
        pair["rollouts"] = pair["trials"] * 2
        pair["scenario_sha256"] = {task: put(f"tests/e2e/scenarios/{task}.txt", b"task\n")}
        runtime = self._scratch() / "runtime"
        runtime.write_bytes(b"runtime")
        os.chmod(runtime, 0o700)
        pair["runtime_binary_sha256"] = hashlib.sha256(runtime.read_bytes()).hexdigest()
        pair["implementation_fingerprint"] = implementation_fingerprint(repo, value)
        protocol = repo / "evals/plugin-v1/protocol.json"
        protocol.parent.mkdir(parents=True)
        protocol.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        head = self._commit(repo, "protocol")
        return repo, protocol, runtime, value, head

    def test_gate_consumes_the_materialized_tree_and_ignores_change_and_restore_on_the_live_tree(self) -> None:
        """Subprocesses and pin hashes see the checkout only.

        A change-and-restore of a pinned file on the live tree during the last
        subprocess is invisible, and so is a live edit that is never restored:
        the receipt is still produced, which a gate hashing the live tree could
        not do.
        """
        repo, protocol, runtime, value, head = self._synthetic()
        fake = _fake_gate_run(protocol, lambda: None)
        calls: list[tuple[Path, list[str]]] = []

        def run(root, args, *, env, timeout=600):
            calls.append((root, list(args)))
            result = fake(root, args, env=env, timeout=timeout)
            if str(args[0]).endswith("plugin_candidate.py"):
                live = repo / "src/impl_a.zig"
                committed = live.read_bytes()
                live.write_bytes(b"ABA")
                # The tree handed to the subprocess is untouched by the live edit.
                self.assertEqual(b"A\n", (root / "src/impl_a.zig").read_bytes())
                live.write_bytes(committed)
                (repo / "src/impl_b.zig").write_bytes(b"LIVE-MODIFIED\n")
            return result

        with mock.patch("scripts.eval.plugin_release_gate._run", run), \
             mock.patch("scripts.eval.plugin_release_gate._git_head", self._dsh_aware_git_head(value)):
            receipt = run_gate(repo, protocol, self.DSH, runtime)

        self.assertEqual(head, receipt["metacodes_git_head"])
        self.assertTrue(calls)
        roots = {root for root, _ in calls}
        self.assertEqual(1, len(roots))
        tree_root = roots.pop()
        self.assertNotEqual(repo, tree_root)
        self.assertTrue(str(tree_root).startswith(tempfile.gettempdir()))
        inventory = [
            args[0]
            for _, args in calls
            if str(args[0]).endswith(("plugin_baseline.py", "plugin_candidate.py"))
        ]
        self.assertEqual(2, len(inventory))
        for path in inventory:
            self.assertTrue(str(path).startswith(str(tree_root)))
        # The live edit really was in place while the end re-validation ran.
        self.assertEqual(b"LIVE-MODIFIED\n", (repo / "src/impl_b.zig").read_bytes())

    def test_subprocess_mutating_the_checkout_is_caught_by_the_end_revalidation(self) -> None:
        """The end re-validation hashes the checkout: a subprocess editing a pinned
        file there fails the gate, and the live repository stays untouched."""
        repo, protocol, runtime, value, _ = self._synthetic()
        fake = _fake_gate_run(protocol, lambda: None)

        def run(root, args, *, env, timeout=600):
            result = fake(root, args, env=env, timeout=timeout)
            if str(args[0]).endswith("plugin_candidate.py"):
                (root / "src/impl_a.zig").write_bytes(b"CHECKOUT-MODIFIED\n")
            return result

        with mock.patch("scripts.eval.plugin_release_gate._run", run), \
             mock.patch("scripts.eval.plugin_release_gate._git_head", self._dsh_aware_git_head(value)):
            with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
                run_gate(repo, protocol, self.DSH, runtime)
        self.assertEqual(b"A\n", (repo / "src/impl_a.zig").read_bytes())

    def test_dirty_pinned_input_is_refused_before_any_subprocess(self) -> None:
        """An uncommitted edit to a pinned input is refused up front: the receipt names HEAD."""
        repo, protocol, runtime, _, _ = self._synthetic()
        (repo / "src/impl_a.zig").write_text("dirty", encoding="utf-8")
        calls: list = []
        with mock.patch("scripts.eval.plugin_release_gate._run", lambda *a, **k: calls.append(a)):
            with self.assertRaisesRegex(PluginGateError, "modified in the working tree.*src/impl_a.zig"):
                run_gate(repo, protocol, self.DSH, runtime)
        self.assertEqual([], calls)

    def test_in_repo_protocol_must_be_tracked_and_clean(self) -> None:
        """A protocol inside the repository is a pinned input too: modified or untracked, the gate refuses."""
        repo, protocol, runtime, _, _ = self._synthetic()
        protocol.write_bytes(protocol.read_bytes() + b"\n")
        with self.assertRaisesRegex(PluginGateError, "modified in the working tree"):
            run_gate(repo, protocol, self.DSH, runtime)
        self._git(repo, "rm", "--cached", "-q", "evals/plugin-v1/protocol.json")
        with self.assertRaisesRegex(PluginGateError, "is not tracked by Git"):
            run_gate(repo, protocol, self.DSH, runtime)
