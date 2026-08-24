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
    main,
)


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"


class PluginReleaseGateTest(unittest.TestCase):
    def test_integer_median_does_not_depend_on_stdlib_module_resolution(self) -> None:
        self.assertEqual(3, _median_int([5, 1, 3]))
        self.assertEqual(2, _median_int([4, 1, 2, 3]))
        with self.assertRaises(PluginGateError):
            _median_int([])

    def test_checked_in_protocol_is_valid_and_zero_provider(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
        self.assertFalse(protocol["quality_evidence"])
        self.assertEqual(0, protocol["deterministic_gate"]["provider_requests"])
        self.assertEqual(
            "blocked_pending_explicit_paid_authority",
            protocol["coding_pair"]["status"],
        )
        self.assertEqual(
            implementation_fingerprint(ROOT, protocol),
            protocol["coding_pair"]["implementation_fingerprint"],
        )
        self.assertEqual(64, len(protocol["coding_pair"]["runtime_binary_sha256"]))

    def test_static_protocol_rejects_malformed_runtime_identity(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
        protocol["coding_pair"]["runtime_binary_sha256"] = "0" * 63
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.json"
            path.write_text(json.dumps(protocol), encoding="utf-8")
            with self.assertRaisesRegex(PluginGateError, "lowercase SHA-256"):
                load_protocol(ROOT, path)

    def test_runtime_attestation_uses_only_the_explicit_artifact(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
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
        with redirect_stdout(output):
            self.assertEqual(0, main(["--validate-only"]))
        value = json.loads(output.getvalue())
        self.assertEqual("metacodes.plugin-evaluation/v1", value["schema"])
        self.assertEqual(0, value["provider_requests"])

    def test_candidate_hash_drift_fails_closed(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
        tampered = copy.deepcopy(protocol)
        key = next(iter(tampered["candidate"]["files"]))
        tampered["candidate"]["files"][key] = "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocol.json"
            path.write_text(json.dumps(tampered), encoding="utf-8")
            with self.assertRaises(PluginGateError):
                load_protocol(ROOT, path)

    def test_unsafe_implementation_path_is_rejected(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
        protocol["implementation_paths"] = ["../outside"]
        with self.assertRaises(PluginGateError):
            implementation_fingerprint(ROOT, protocol)

    def test_benchmark_thresholds_are_bound_to_protocol(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
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
        protocol = load_protocol(ROOT, PROTOCOL)
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


if __name__ == "__main__":
    unittest.main()
