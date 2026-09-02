from __future__ import annotations

import copy
import hashlib
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

from scripts.eval.plugin_release_gate import (
    PluginGateError,
    _benchmark_row,
    _median_int,
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
             mock.patch("scripts.eval.plugin_release_gate._git_head", fake_git_head):
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
                 mock.patch("scripts.eval.plugin_release_gate._git_head", lambda p: expected_dsh):
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

if __name__ == "__main__":
    unittest.main()
