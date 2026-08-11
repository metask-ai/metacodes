import json
import hashlib
import io
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT
from scripts.eval.workbuddy.cohort_manifest import (
    CohortError,
    SUBSETS,
    build_manifest,
)
from scripts.eval.workbuddy.stage_artifacts import StageError, stage
from scripts.eval.workbuddy.environment_preflight import (
    EnvironmentPreflightError,
    prebuild,
    validate_receipt,
)
from scripts.eval.workbuddy.install_overlay import _digest
from scripts.eval.workbuddy import install_overlay as overlay_installer
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
    @staticmethod
    def _elf(machine: int) -> bytes:
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        header[18:20] = machine.to_bytes(2, "little")
        return bytes(header)

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
            self.assertEqual(manifest["target_platform"], "test-fixture")
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

    def test_production_stage_requires_x86_64_and_records_elf_machine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            x86 = root / "x86"
            x86.write_bytes(self._elf(62))
            arm = root / "arm"
            arm.write_bytes(self._elf(183))
            license_file = root / "LICENSE"
            license_file.write_text("license\n", encoding="utf-8")
            licenses = (
                ("metacodes", "NOASSERTION", license_file),
                ("tinykg", "Apache-2.0", license_file),
                ("lean4", "Apache-2.0", license_file),
            )
            manifest = stage(
                output=root / "x86-stage",
                metacodes=x86,
                tinykg=x86,
                formal_kernel=x86,
                metacodes_commit=ZERO_COMMIT,
                tinykg_commit=ONE_COMMIT,
                licenses=licenses,
            )
            self.assertEqual(manifest["target_platform"], "linux/amd64")
            self.assertEqual(
                {row["elf_machine"] for row in manifest["executables"].values()},
                {62},
            )
            with self.assertRaisesRegex(StageError, "does not match linux/amd64"):
                stage(
                    output=root / "arm-stage",
                    metacodes=arm,
                    tinykg=arm,
                    formal_kernel=arm,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=licenses,
                )
            self.assertFalse((root / "arm-stage").exists())


class WorkBuddyEnvironmentPreflightTest(unittest.TestCase):
    @staticmethod
    def _fake_run(architecture: str = "amd64"):
        def run(argv, **_kwargs):
            args = [str(item) for item in argv]
            if args[0] == "git" and args[-2:] == ["rev-parse", "HEAD"]:
                return subprocess.CompletedProcess(
                    args, 0, WORKBUDDY_PINNED_COMMIT + "\n", ""
                )
            if "buildx" in args and "build" in args:
                return subprocess.CompletedProcess(args, 0, "built\n", "")
            if args[1:3] == ["image", "inspect"]:
                row = {
                    "Id": "sha256:" + "a" * 64,
                    "Architecture": architecture,
                    "Os": "linux",
                }
                return subprocess.CompletedProcess(args, 0, json.dumps(row), "")
            if args[1:3] == ["version", "--format"]:
                return subprocess.CompletedProcess(
                    args, 0, '{"Version":"test"}\n', ""
                )
            raise AssertionError(f"unexpected preflight command: {args}")

        return run

    def test_preflight_binds_environment_hash_image_and_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            environment = workbuddy / "datasets/code/tasks/task-a/environment"
            environment.mkdir(parents=True)
            (environment / "Dockerfile").write_text(
                "FROM scratch\n", encoding="utf-8"
            )
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            receipt = root / "preflight.json"
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run(),
            ):
                built = prebuild(
                    workbuddy=workbuddy,
                    dataset="datasets/code/tasks",
                    selected_tasks=["task-a"],
                    output=receipt,
                    docker=docker,
                )
                observed = validate_receipt(
                    receipt,
                    workbuddy=workbuddy,
                    dataset="datasets/code/tasks",
                    selected_tasks=["task-a"],
                    inspect_images=True,
                )
            self.assertEqual(built, observed)
            self.assertEqual(built["target_platform"], "linux/amd64")
            self.assertEqual(built["tasks"]["task-a"]["architecture"], "amd64")
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

            (environment / "Dockerfile").write_text(
                "FROM busybox\n", encoding="utf-8"
            )
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run(),
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError, "changed after preflight"
                ):
                    validate_receipt(
                        receipt,
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-a"],
                        inspect_images=True,
                    )

    def test_preflight_rejects_non_amd64_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            environment = workbuddy / "datasets/code/tasks/task-a/environment"
            environment.mkdir(parents=True)
            (environment / "Dockerfile").write_text(
                "FROM scratch\n", encoding="utf-8"
            )
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run("arm64"),
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError, "expected linux/amd64"
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-a"],
                        output=root / "preflight.json",
                        docker=docker,
                    )


class WorkBuddyOverlayUpgradeTest(unittest.TestCase):
    def test_overlay_patches_resolve_and_prepare_with_one_mount_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            fixtures = {
                overlay_installer._ADAPTER_PATH:
                    overlay_installer._ADAPTER_ANCHOR,
                overlay_installer._RESOLVER_PATH: (
                    overlay_installer._DISPATCH_OLD
                    + overlay_installer._GENERIC_ANCHOR
                    + overlay_installer._MODEL_ROUTE_OLD
                    + overlay_installer._RESOLVER_MOUNT_OLD
                ),
                overlay_installer._PREPARE_JOB_PATH:
                    overlay_installer._PREPARE_MOUNT_OLD,
                overlay_installer._PROXY_CONFIG_PATH: (
                    overlay_installer._PROXY_IMPORT_ANCHOR
                    + overlay_installer._PROXY_KEY_OLD
                ),
            }
            for relative, content in fixtures.items():
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            for args in (
                ("init", "-q"),
                ("add", "."),
                (
                    "-c", "user.name=metacodes-test",
                    "-c", "user.email=metacodes-test@example.invalid",
                    "commit", "-qm", "fixture",
                ),
            ):
                subprocess.run(
                    ["git", "-C", str(repo), *args],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            patched = overlay_installer._patched_upstream(repo)
            resolver = patched[overlay_installer._RESOLVER_PATH].decode("utf-8")
            prepare = patched[overlay_installer._PREPARE_JOB_PATH].decode("utf-8")
            self.assertIn(overlay_installer._RESOLVER_MOUNT_NEW, resolver)
            self.assertIn(overlay_installer._MODEL_ROUTE_NEW, resolver)
            self.assertIn(overlay_installer._PREPARE_MOUNT_NEW, prepare)
            self.assertNotIn(overlay_installer._RESOLVER_MOUNT_OLD, resolver)
            self.assertNotIn(overlay_installer._MODEL_ROUTE_OLD, resolver)
            self.assertNotIn(overlay_installer._PREPARE_MOUNT_OLD, prepare)

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

    def test_paid_code_canary_is_frozen_to_first_three_code_dev_tasks(self):
        root = Path(__file__).parents[1] / "workbuddy"
        overlay = root / "overlay"
        job = yaml.safe_load(
            (overlay / "configs/jobs/metacodes-glm52-code-3-canary.yaml").read_text(
                encoding="utf-8"
            )
        )
        model = yaml.safe_load(
            (overlay / "configs/models/metacodes-glm52.yaml").read_text(
                encoding="utf-8"
            )
        )["model"]
        cohort = json.loads(
            (root / "manifests/workbuddy-v1-cohorts.json").read_text(encoding="utf-8")
        )
        expected = cohort["subsets"]["code"]["cohorts"]["dev"][
            "task_selection"
        ]["names"][:3]
        self.assertEqual(job["task_selection"], {"mode": "name", "names": expected})
        self.assertEqual(job["dataset"], cohort["subsets"]["code"]["dataset"])
        self.assertEqual(job["n_attempts"], 1)
        self.assertTrue(job["record_full_io"])
        self.assertEqual(job["orchestrator_override"]["n_concurrent_trials"], 1)
        self.assertEqual(model["name"], "glm-5.2")
        self.assertEqual(model["protocols"], ["anthropic"])
        self.assertEqual(
            model["backend_key_env"],
            "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF",
        )
        self.assertEqual(model["max_concurrent"], 1)
        self.assertEqual(model["context_window"], job["context_window"])


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
