import json
import hashlib
import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.workbuddy.cohort_manifest import (
    CohortError,
    SUBSETS,
    build_manifest,
)
from scripts.eval.workbuddy.stage_artifacts import StageError, stage
from scripts.eval.workbuddy.install_overlay import _digest
from scripts.eval.workbuddy.key_fd import (
    CredentialFdError,
    _SECRET_CACHE,
    resolve_secret_env,
)
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


class WorkBuddyCredentialFdTest(unittest.TestCase):
    def setUp(self):
        _SECRET_CACHE.clear()

    def tearDown(self):
        _SECRET_CACHE.clear()

    def test_fd_reference_consumes_once_clears_environment_and_supports_shared_routes(self):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"private-test-key")
        os.close(write_fd)
        with mock.patch.dict(os.environ, {"WB_TEST_KEY": f"fd://{read_fd}"}, clear=False):
            first = resolve_secret_env("", "WB_TEST_KEY")
            second = resolve_secret_env("", "WB_TEST_KEY")
            self.assertEqual(first, "private-test-key")
            self.assertEqual(second, first)
            self.assertNotIn("WB_TEST_KEY", os.environ)
            with self.assertRaises(OSError):
                os.fstat(read_fd)

    def test_normal_workbuddy_environment_key_remains_compatible(self):
        with mock.patch.dict(os.environ, {"WB_TEST_PLAIN": "ordinary-test-key"}):
            self.assertEqual(resolve_secret_env("", "WB_TEST_PLAIN"), "ordinary-test-key")
        with mock.patch.dict(
            os.environ,
            {"METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF": "raw-key-is-forbidden"},
        ):
            with self.assertRaisesRegex(CredentialFdError, "requires an anonymous"):
                resolve_secret_env("", "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF")

    def test_invalid_or_oversized_descriptor_fails_closed(self):
        with mock.patch.dict(os.environ, {"WB_TEST_BAD": "fd://not-a-number"}):
            with self.assertRaisesRegex(CredentialFdError, "invalid"):
                resolve_secret_env("", "WB_TEST_BAD")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "oversized-key"
            source.write_bytes(b"x" * (16 * 1024 + 1))
            read_fd = os.open(source, os.O_RDONLY)
            with mock.patch.dict(os.environ, {"WB_TEST_LARGE": f"fd://{read_fd}"}):
                with self.assertRaisesRegex(CredentialFdError, "exceeds"):
                    resolve_secret_env("", "WB_TEST_LARGE")


class WorkBuddyCohortManifestTest(unittest.TestCase):
    @staticmethod
    def _archive(path: Path, dataset_id: str, slugs: list[str], *, reverse: bool = False):
        ordered = list(reversed(slugs)) if reverse else slugs
        with tarfile.open(path, "w:gz") as archive:
            for slug in ordered:
                payload = b"\xff\x00body-must-not-be-parsed"
                member = tarfile.TarInfo(f"{dataset_id}/tasks/{slug}/task.toml")
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
                instruction = tarfile.TarInfo(
                    f"{dataset_id}/tasks/{slug}/instruction.md"
                )
                instruction.size = 7
                archive.addfile(instruction, io.BytesIO(b"private"))

    def _fixtures(self, root: Path, *, reverse: bool = False):
        archives = {}
        sums = {}
        for subset in SUBSETS:
            path = root / subset.archive
            slugs = [f"{subset.name}-task-{index:03}" for index in range(subset.task_count)]
            self._archive(path, subset.dataset_id, slugs, reverse=reverse)
            archives[subset.name] = path
            sums[subset.archive] = hashlib.sha256(path.read_bytes()).hexdigest()
        return archives, sums

    def test_fixed_split_is_exhaustive_disjoint_and_workbuddy_consumable(self):
        with tempfile.TemporaryDirectory() as directory:
            archives, sums = self._fixtures(Path(directory))
            manifest = build_manifest(archives=archives, expected_sums=sums)
        self.assertFalse(manifest["quality_evidence"])
        self.assertFalse(
            manifest["contamination_boundary"]["task_payload_exposed_to_generator"]
        )
        self.assertEqual(
            manifest["cohort_totals"],
            {"dev": 52, "promotion_a": 26, "promotion_b": 26, "sealed": 156},
        )
        for subset in SUBSETS:
            rows = manifest["subsets"][subset.name]
            assigned = []
            for cohort, expected_count in subset.cohort_counts:
                selection = rows["cohorts"][cohort]["task_selection"]
                self.assertEqual(selection["mode"], "name")
                self.assertEqual(len(selection["names"]), expected_count)
                assigned.extend(selection["names"])
            self.assertEqual(len(assigned), len(set(assigned)))
            self.assertEqual(len(assigned), subset.task_count)

    def test_member_order_cannot_change_partition(self):
        with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
            first, first_sums = self._fixtures(Path(first_dir))
            second, second_sums = self._fixtures(Path(second_dir), reverse=True)
            a = build_manifest(archives=first, expected_sums=first_sums)
            b = build_manifest(archives=second, expected_sums=second_sums)
        for subset in SUBSETS:
            self.assertEqual(
                a["subsets"][subset.name]["cohorts"],
                b["subsets"][subset.name]["cohorts"],
            )

    def test_checksum_mismatch_and_linked_task_metadata_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archives, sums = self._fixtures(root)
            sums[SUBSETS[0].archive] = "0" * 64
            with self.assertRaisesRegex(CohortError, "checksum mismatch"):
                build_manifest(archives=archives, expected_sums=sums)

            subset = SUBSETS[0]
            linked = root / "linked.tar.gz"
            with tarfile.open(linked, "w:gz") as archive:
                for index in range(subset.task_count):
                    member = tarfile.TarInfo(
                        f"{subset.dataset_id}/tasks/code-task-{index:03}/task.toml"
                    )
                    member.type = tarfile.SYMTYPE
                    member.linkname = "elsewhere"
                    archive.addfile(member)
            archives[subset.name] = linked
            sums[subset.archive] = hashlib.sha256(linked.read_bytes()).hexdigest()
            with self.assertRaisesRegex(CohortError, "not a regular file"):
                build_manifest(archives=archives, expected_sums=sums)

if __name__ == "__main__":
    unittest.main()
