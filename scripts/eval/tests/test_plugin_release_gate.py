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

from scripts.eval.plugin_release_gate import (
    PluginGateError,
    _benchmark_row,
    _median_int,
    attest_runtime_artifact,
    implementation_fingerprint,
    load_protocol,
    load_protocol_structure,
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
        # And the live tree is freezable: a repinned copy passes the strict
        # loader, with the pin equal to the fingerprint of this very tree.
        frozen = _fresh_protocol(self)
        self.assertEqual(
            implementation_fingerprint(ROOT, frozen),
            frozen["coding_pair"]["implementation_fingerprint"],
        )

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
        output = StringIO()
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(output):
            path = _repinned_copy(Path(directory))
            self.assertEqual(0, main(["--validate-only", "--protocol", str(path)]))
        value = json.loads(output.getvalue())
        self.assertEqual("metacodes.plugin-evaluation/v1", value["schema"])
        self.assertEqual(0, value["provider_requests"])

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

    def test_symlinked_protocol_file_is_rejected(self) -> None:
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


if __name__ == "__main__":
    unittest.main()
