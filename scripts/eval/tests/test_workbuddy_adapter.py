import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.workbuddy.stage_artifacts import StageError, stage
from scripts.eval.workbuddy.install_overlay import _digest
from scripts.eval.workbuddy.trace import (
    TraceError,
    final_result,
    read_json_lines,
    transcript_ir,
)


ZERO_COMMIT = "0" * 40
ONE_COMMIT = "1" * 40


class WorkBuddyTraceTest(unittest.TestCase):
    def test_transcript_maps_calls_results_and_cache_metrics_without_dropping_provenance(self):
        result = final_result(
            [
                {
                    "type": "result",
                    "stop_reason": "end_turn",
                    "turns": 2,
                    "tool_calls": 1,
                    "input_tokens": 120,
                    "output_tokens": 30,
                    "cache_read_input_tokens": 80,
                    "cache_creation_input_tokens": 10,
                    "cost_usd": 0.01,
                    "text": "done",
                }
            ]
        )
        steps = transcript_ir(
            [
                {"role": "user", "blocks": [{"type": "text", "text": "fix it"}]},
                {
                    "role": "assistant",
                    "blocks": [
                        {"type": "thinking", "thinking": "inspect"},
                        {
                            "type": "tool_use",
                            "id": "call-1",
                            "name": "Read",
                            "input": '{"file_path":"a.txt"}',
                        },
                    ],
                },
                {
                    "role": "user",
                    "blocks": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "call-1",
                            "content": "old",
                            "is_error": False,
                        }
                    ],
                },
                {
                    "role": "assistant",
                    "blocks": [{"type": "text", "text": "done"}],
                },
            ],
            result=result,
        )
        self.assertEqual([row["source"] for row in steps], ["user", "agent", "agent"])
        self.assertEqual(steps[1]["tool_calls"][0]["arguments"], {"file_path": "a.txt"})
        self.assertEqual(
            steps[1]["observations"][0],
            {
                "source_call_id": "call-1",
                "content": "old",
                "extra": {"is_error": False},
            },
        )
        self.assertEqual(result["cache_read_input_tokens"], 80)
        self.assertEqual(result["cache_creation_input_tokens"], 10)

    def test_result_is_exactly_once_and_fail_closed(self):
        row = {
            "type": "result",
            "stop_reason": "end_turn",
            "turns": 1,
            "tool_calls": 0,
            "input_tokens": 1,
            "output_tokens": 1,
            "cost_usd": 0,
            "text": "ok",
        }
        with self.assertRaises(TraceError):
            final_result([])
        with self.assertRaises(TraceError):
            final_result([row, row])

    def test_trace_rejects_non_utf8_instead_of_replacing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            path.write_bytes(b'{"type":"result","text":"\xff"}\n')
            with self.assertRaises(TraceError):
                read_json_lines(path)


class WorkBuddyArtifactStageTest(unittest.TestCase):
    def test_synthetic_stage_binds_all_hashes_and_licenses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture-bin"
            executable.write_bytes(b"#!/bin/sh\nexit 0\n")
            license_file = root / "LICENSE"
            license_file.write_text("fixture license\n", encoding="utf-8")
            output = root / "stage"
            manifest = stage(
                output=output,
                metacodes=executable,
                tinykg=executable,
                formal_kernel=executable,
                metacodes_commit=ZERO_COMMIT,
                tinykg_commit=ONE_COMMIT,
                licenses=(
                    ("metacodes", "NOASSERTION", license_file),
                    ("tinykg", "Apache-2.0", license_file),
                    ("lean4", "Apache-2.0", license_file),
                ),
                allow_synthetic_fixtures=True,
            )
            self.assertFalse(manifest["quality_evidence"])
            self.assertTrue(manifest["synthetic_fixture"])
            self.assertEqual(
                set(manifest["executables"]),
                {"metacodes", "tinykg", "metacodes-formal-kernel"},
            )
            sums = (output / "share/metacodes/SHA256SUMS").read_text(encoding="ascii")
            self.assertIn("bin/metacodes", sums)
            self.assertIn("share/licenses/tinykg/LICENSE", sums)
            on_disk = json.loads(
                (output / "share/metacodes/artifact-manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(on_disk, manifest)
            with self.assertRaises(StageError):
                stage(
                    output=output,
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                    allow_synthetic_fixtures=True,
                )

    def test_stage_rejects_non_hex_commit_and_duplicate_license_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture-bin"
            executable.write_bytes(b"fixture")
            license_file = root / "LICENSE"
            license_file.write_text("license\n", encoding="utf-8")
            with self.assertRaisesRegex(StageError, "40-hex"):
                stage(
                    output=root / "bad-commit",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit="z" * 40,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(("metacodes", "NOASSERTION", license_file),),
                    allow_synthetic_fixtures=True,
                )

    def test_production_stage_rejects_non_elf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "not-elf"
            executable.write_text("not an ELF\n", encoding="utf-8")
            license_file = root / "LICENSE"
            license_file.write_text("license\n", encoding="utf-8")
            with self.assertRaisesRegex(StageError, "not a Linux ELF"):
                stage(
                    output=root / "stage",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                )
            with self.assertRaisesRegex(StageError, "exactly"):
                stage(
                    output=root / "duplicate-license",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                    allow_synthetic_fixtures=True,
                )


class WorkBuddyOverlayUpgradeTest(unittest.TestCase):
    def test_digest_detects_changes_before_owned_overlay_replacement(self):
        rows = [(Path("a"), b"one"), (Path("b"), b"two")]
        before = _digest(rows, {})
        self.assertEqual(before, _digest(list(reversed(rows)), {}))
        self.assertNotEqual(before, _digest([(Path("a"), b"changed"), rows[1]], {}))

    def test_w0_uses_native_no_network_compose(self):
        root = Path(__file__).parents[1] / "workbuddy/overlay/datasets"
        task = root / "metacodes-w0-synthetic/tasks/metacodes-w0-artifact"
        compose = (task / "environment/docker-compose.yaml").read_text(encoding="utf-8")
        config = (task / "task.toml").read_text(encoding="utf-8")
        self.assertIn("network_mode: none", compose)
        self.assertEqual(config.count('network_mode = "public"'), 3)

if __name__ == "__main__":
    unittest.main()
