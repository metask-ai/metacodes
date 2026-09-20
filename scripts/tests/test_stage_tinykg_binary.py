from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.stage_tinykg_binary import (
    BinaryIdentity,
    BundleArtifact,
    StageError,
    TinyKgBundle,
    TinyKgContract,
    _publish,
    _validate_mach_o_universal,
    _validate_pe,
    stage,
    stage_bundled,
    validate_bundle_bytes,
)


CONTRACT = {
    "contract_schema": "metacodes.tinykg-binary/v1",
    "license": "Apache-2.0",
    "source_repository": "https://example.invalid/tinykg",
    "storage_format_version": "3",
    "store_schema_version": "3",
    "tinykg_version": "0.2.0",
}
PROJECT_ROOT = Path(__file__).resolve().parents[2]


class TinyKgBinaryStageTest(unittest.TestCase):
    def fixture(self, root: Path, *, version: str = "0.2.0") -> Path:
        binary = root / "tinykg"
        binary.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            'if [ "$1" = version ]; then echo "tinykg '
            + version
            + '"; exit 0; fi\n'
            'if [ "$1" = init ]; then mkdir -p "$2"; echo ready; exit 0; fi\n'
            'if [ "$1" = store-info ]; then\n'
            '  printf "storage_format_version=3\\nschema_version=3\\n"\n'
            "  exit 0\n"
            "fi\n"
            "exit 9\n",
            encoding="utf-8",
        )
        binary.chmod(0o700)
        return binary

    def contract(self, root: Path, value: object = CONTRACT) -> Path:
        path = root / "tinykg.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def bundled_elf(
        self,
        root: Path,
        *,
        machine: int = 62,
        program_type: int = 1,
    ) -> Path:
        binary = root / "bin/tinykg-linux-x86_64"
        binary.parent.mkdir(parents=True)
        data = bytearray(256)
        data[:7] = b"\x7fELF\x02\x01\x01"
        data[16:18] = struct.pack("<H", 2)
        data[18:20] = struct.pack("<H", machine)
        data[20:24] = struct.pack("<I", 1)
        data[32:40] = struct.pack("<Q", 64)
        data[52:54] = struct.pack("<H", 64)
        data[54:56] = struct.pack("<H", 56)
        data[56:58] = struct.pack("<H", 1)
        data[64:68] = struct.pack("<I", program_type)
        data[160 : 160 + len(b"tinykg 0.2.0")] = b"tinykg 0.2.0"
        binary.write_bytes(data)
        binary.chmod(0o700)
        return binary

    def manifest(self, root: Path, binary: Path, **overrides: object) -> Path:
        artifact = {
            "architectures": ["x86_64"],
            "format": "elf-static",
            "key": "linux-x86_64",
            "path": binary.relative_to(root).as_posix(),
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "targets": ["x86_64-linux"],
        }
        artifact.update(overrides)
        schema = "metacodes.tinykg-bundle/v2" if "role" in artifact else "metacodes.tinykg-bundle/v1"
        value = {
            "artifacts": [artifact],
            "build": {
                "optimize": "ReleaseSafe",
                "strip": True,
                "zig_version": "0.16.0",
            },
            "bundle_schema": schema,
            "source_commit": "a" * 40,
        }
        path = root / "manifest.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_explicit_binary_is_attested_copied_and_receipted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.fixture(root)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            output = root / "out/tinykg"
            receipt = root / "out/tinykg.provenance.json"

            stage(
                binary,
                digest,
                self.contract(root),
                "aarch64-macos",
                output,
                receipt,
            )

            self.assertEqual(binary.read_bytes(), output.read_bytes())
            self.assertTrue(os.access(output, os.X_OK))
            value = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual("metacodes.tinykg-binary-receipt/v2", value["receipt_schema"])
            self.assertEqual(digest, value["binary_sha256"])
            self.assertEqual("tinykg 0.2.0", value["binary_version"])
            self.assertEqual("explicit", value["distribution"])
            self.assertEqual("aarch64-macos", value["target"])
            self.assertNotIn(str(binary), receipt.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_hash_mismatch_fails_before_any_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.fixture(root)
            output = root / "out/tinykg"
            receipt = root / "out/receipt.json"
            with self.assertRaisesRegex(StageError, "SHA-256 mismatch"):
                stage(binary, "0" * 64, self.contract(root), "native", output, receipt)
            self.assertFalse(output.exists())
            self.assertFalse(receipt.exists())

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_version_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.fixture(root, version="9.9.9")
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            with self.assertRaisesRegex(StageError, "version mismatch"):
                stage(
                    binary,
                    digest,
                    self.contract(root),
                    "native",
                    root / "out/tinykg",
                    root / "out/receipt.json",
                )

    @unittest.skipIf(os.name == "nt", "POSIX symbolic-link fixture")
    def test_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.fixture(root)
            link = root / "tinykg-link"
            link.symlink_to(binary)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            with self.assertRaisesRegex(StageError, "non-symlink"):
                stage(
                    link,
                    digest,
                    self.contract(root),
                    "native",
                    root / "out/tinykg",
                    root / "out/receipt.json",
                )

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_contract_unknown_field_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.fixture(root)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            invalid = dict(CONTRACT)
            invalid["surprise"] = True
            with self.assertRaisesRegex(StageError, "missing or unknown"):
                stage(
                    binary,
                    digest,
                    self.contract(root, invalid),
                    "native",
                    root / "out/tinykg",
                    root / "out/receipt.json",
                )

    def test_bundled_binary_is_target_selected_and_receipted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            manifest = self.manifest(root, binary)
            output = root / "out/tinykg"
            receipt = root / "out/tinykg.provenance.json"

            stage_bundled(
                binary=binary.resolve(),
                manifest_path=manifest,
                bundle_key="linux-x86_64",
                expected_sha256=digest,
                target_family="x86_64-linux",
                runtime_probe=False,
                contract_path=self.contract(root),
                target="x86_64-linux-musl",
                output=output,
                receipt=receipt,
            )

            self.assertEqual(binary.read_bytes(), output.read_bytes())
            value = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual("bundled", value["distribution"])
            self.assertEqual("linux-x86_64", value["bundle_key"])
            self.assertEqual("a" * 40, value["source_commit"])
            self.assertEqual(digest, value["binary_sha256"])

    def test_bundled_target_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            with self.assertRaisesRegex(StageError, "does not support target"):
                stage_bundled(
                    binary=binary.resolve(),
                    manifest_path=self.manifest(root, binary),
                    bundle_key="linux-x86_64",
                    expected_sha256=digest,
                    target_family="aarch64-linux",
                    runtime_probe=False,
                    contract_path=self.contract(root),
                    target="aarch64-linux-musl",
                    output=root / "out/tinykg",
                    receipt=root / "out/receipt.json",
                )

    def test_bundled_build_digest_must_match_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            with self.assertRaisesRegex(StageError, "selection digest"):
                stage_bundled(
                    binary=binary.resolve(),
                    manifest_path=self.manifest(root, binary),
                    bundle_key="linux-x86_64",
                    expected_sha256="0" * 64,
                    target_family="x86_64-linux",
                    runtime_probe=False,
                    contract_path=self.contract(root),
                    target="x86_64-linux-musl",
                    output=root / "out/tinykg",
                    receipt=root / "out/receipt.json",
                )

    def test_bundled_format_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root, machine=183)
            digest = hashlib.sha256(binary.read_bytes()).hexdigest()
            with self.assertRaisesRegex(StageError, "architecture"):
                stage_bundled(
                    binary=binary.resolve(),
                    manifest_path=self.manifest(root, binary),
                    bundle_key="linux-x86_64",
                    expected_sha256=digest,
                    target_family="x86_64-linux",
                    runtime_probe=False,
                    contract_path=self.contract(root),
                    target="x86_64-linux-musl",
                    output=root / "out/tinykg",
                    receipt=root / "out/receipt.json",
                )

    def test_bundled_elf_rejects_dynamic_program_header(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root, program_type=2)
            artifact = BundleArtifact(
                key="linux-x86_64",
                path="bin/tinykg-linux-x86_64",
                sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                binary_format="elf-static",
                architectures=("x86_64",),
                targets=("x86_64-linux",),
            )
            with self.assertRaisesRegex(StageError, "PT_DYNAMIC"):
                validate_bundle_bytes(
                    binary.resolve(),
                    artifact,
                    TinyKgContract.load(self.contract(root)),
                )

    def test_v2_daemon_role_is_staged_with_daemon_marker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            data = bytearray(binary.read_bytes())
            data[160 : 160 + len(b"tinykg 0.2.0")] = b"tinykgd 0.2.0"
            daemon = root / "bin/tinykgd-linux-x86_64"
            daemon.write_bytes(data)
            daemon.chmod(0o700)
            manifest = self.manifest(root, daemon, key="linux-x86_64-daemon", path="bin/tinykgd-linux-x86_64", role="daemon")
            digest = hashlib.sha256(daemon.read_bytes()).hexdigest()
            output = root / "out/tinykgd"
            receipt = root / "out/tinykgd.provenance.json"
            stage_bundled(daemon.resolve(), manifest, "linux-x86_64-daemon", digest, "x86_64-linux", False, self.contract(root), "x86_64-linux-musl", output, receipt, role="daemon")
            self.assertEqual("tinykgd 0.2.0", json.loads(receipt.read_text(encoding="utf-8"))["binary_version"])

    def test_daemon_marker_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            daemon = self.bundled_elf(root)
            manifest = self.manifest(root, daemon, key="linux-x86_64-daemon", path="bin/tinykg-linux-x86_64", role="daemon")
            with self.assertRaisesRegex(StageError, "version marker"):
                stage_bundled(daemon.resolve(), manifest, "linux-x86_64-daemon", hashlib.sha256(daemon.read_bytes()).hexdigest(), "x86_64-linux", False, self.contract(root), "x86_64-linux-musl", root / "out/tinykgd", root / "out/receipt.json", role="daemon")

    def test_mach_o_fat_table_cannot_impersonate_slice_cpu(self) -> None:
        data = bytearray(512)
        data[:8] = b"\xca\xfe\xba\xbe" + struct.pack(">I", 1)
        data[8:28] = struct.pack(">IIIII", 0x01000007, 3, 256, 64, 8)
        data[256:260] = b"\xcf\xfa\xed\xfe"
        data[260:264] = struct.pack("<I", 0x0100000C)
        data[268:272] = struct.pack("<I", 2)
        with self.assertRaisesRegex(StageError, "CPU disagrees"):
            _validate_mach_o_universal(bytes(data), ("x86_64",))

    def test_mach_o_overlapping_slices_are_rejected(self) -> None:
        data = bytearray(1024)
        data[:8] = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
        data[8:28] = struct.pack(">IIIII", 0x01000007, 3, 256, 512, 8)
        data[28:48] = struct.pack(">IIIII", 0x0100000C, 0, 512, 256, 8)
        for offset, cpu in ((256, 0x01000007), (512, 0x0100000C)):
            data[offset : offset + 4] = b"\xcf\xfa\xed\xfe"
            data[offset + 4 : offset + 8] = struct.pack("<I", cpu)
            data[offset + 12 : offset + 16] = struct.pack("<I", 2)
            data[offset + 16 : offset + 20] = struct.pack("<I", 1)
            data[offset + 20 : offset + 24] = struct.pack("<I", 24)
            data[offset + 32 : offset + 56] = struct.pack(
                "<IIIIII", 0x32, 24, 1, 0x000B0000, 0, 0
            )
        with self.assertRaisesRegex(StageError, "overlap"):
            _validate_mach_o_universal(bytes(data), ("x86_64", "aarch64"))

    def test_windows_gui_subsystem_is_rejected(self) -> None:
        data = bytearray(512)
        data[:2] = b"MZ"
        data[0x3C:0x40] = struct.pack("<I", 128)
        data[128:132] = b"PE\0\0"
        data[132:134] = struct.pack("<H", 0x8664)
        data[134:136] = struct.pack("<H", 1)
        data[148:150] = struct.pack("<H", 112)
        data[150:152] = struct.pack("<H", 0x0002)
        data[152:154] = struct.pack("<H", 0x20B)
        data[220:222] = struct.pack("<H", 2)
        with self.assertRaisesRegex(StageError, "console"):
            _validate_pe(bytes(data), ("x86_64",))

    def test_publish_rejects_source_drift_without_replacing_last_good_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "tinykg"
            source.write_bytes(b"changed-after-inspection")
            source.chmod(0o700)
            output = root / "out/tinykg"
            output.parent.mkdir(parents=True)
            output.write_bytes(b"last-good")
            receipt = root / "out/receipt.json"
            identity = BinaryIdentity(source, "0" * 64, "tinykg 0.2.0")
            with self.assertRaisesRegex(StageError, "changed while staging"):
                _publish(
                    identity,
                    TinyKgContract.load(self.contract(root)),
                    "native",
                    output,
                    receipt,
                    "explicit",
                )
            self.assertEqual(b"last-good", output.read_bytes())
            self.assertFalse(receipt.exists())

    def test_bundle_manifest_rejects_duplicate_target_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            manifest = self.manifest(root, binary)
            value = json.loads(manifest.read_text(encoding="utf-8"))
            duplicate = dict(value["artifacts"][0])
            duplicate["key"] = "duplicate"
            duplicate["path"] = "bin/duplicate"
            value["artifacts"].append(duplicate)
            manifest.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "targets"):
                TinyKgBundle.load(manifest)

    def test_bundle_manifest_rejects_impossible_target_format_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            manifest = self.manifest(root, binary)
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["artifacts"][0]["targets"] = ["x86_64-windows"]
            manifest.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "target and executable format"):
                TinyKgBundle.load(manifest)

    def test_bundle_manifest_rejects_target_architecture_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            manifest = self.manifest(root, binary)
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["artifacts"][0]["architectures"] = ["aarch64"]
            manifest.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "target and architecture"):
                TinyKgBundle.load(manifest)

    def test_bundle_manifest_rejects_nonportable_artifact_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            manifest = self.manifest(root, binary)
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["artifacts"][0]["path"] = "bin\\tinykg"
            manifest.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "portable POSIX"):
                TinyKgBundle.load(manifest)

    def test_bundle_manifest_rejects_windows_drive_path_on_every_host(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = self.bundled_elf(root)
            manifest = self.manifest(root, binary)
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["artifacts"][0]["path"] = "C:/tinykg.exe"
            manifest.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "portable POSIX"):
                TinyKgBundle.load(manifest)

    def test_checked_in_universal_contains_version_marker_in_every_slice(self) -> None:
        manifest_path = PROJECT_ROOT / "vendor/tinykg/manifest.json"
        bundle = TinyKgBundle.load(manifest_path)
        for key, marker in (
            ("macos-universal", b"tinykg 0.3.0"),
            ("macos-universal-daemon", b"tinykgd 0.3.0"),
        ):
            artifact = bundle.artifact(key)
            binary = (manifest_path.parent / artifact.path).read_bytes()
            slices = _validate_mach_o_universal(binary, artifact.architectures)
            self.assertTrue(
                all(marker in binary[start:end] for start, end in slices),
                f"{key} is missing {marker!r} in a slice",
            )


class CheckedInTinyKgBundleTest(unittest.TestCase):
    def test_every_declared_cross_platform_asset_matches_its_manifest(self) -> None:
        manifest_path = PROJECT_ROOT / "vendor/tinykg/manifest.json"
        bundle = TinyKgBundle.load(manifest_path)
        contract = TinyKgContract.load(PROJECT_ROOT / "deps/tinykg.json")
        self.assertEqual("0b04014ba8d0bcb1f9f73c63c12e49f3c2ee1ece", bundle.source_commit)
        self.assertEqual("0.16.0", bundle.zig_version)
        self.assertEqual("ReleaseSafe", bundle.optimize)
        self.assertTrue(bundle.strip)
        self.assertEqual(
            {
                "linux-aarch64",
                "linux-aarch64-daemon",
                "linux-x86_64",
                "linux-x86_64-daemon",
                "macos-universal",
                "macos-universal-daemon",
                "windows-x86_64",
                "windows-x86_64-daemon",
            },
            {artifact.key for artifact in bundle.artifacts},
        )
        for artifact in bundle.artifacts:
            binary = (manifest_path.parent / artifact.path).resolve()
            identity = validate_bundle_bytes(binary, artifact, contract)
            self.assertEqual(artifact.sha256, identity.sha256)
            expected = "tinykg 0.3.0" if artifact.role == "cli" else "tinykgd 0.3.0"
            self.assertEqual(expected, identity.version_line)

    def test_bundle_inventory_rejects_undeclared_and_missing_binaries(self) -> None:
        from scripts.verify_tinykg_binary import validate_bundle_inventory

        real_manifest = PROJECT_ROOT / "vendor/tinykg/manifest.json"
        bundle = TinyKgBundle.load(real_manifest)
        # The checked-in bundle itself must be inventory-clean.
        validate_bundle_inventory(real_manifest, bundle)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(
                real_manifest.read_text(encoding="utf-8"), encoding="utf-8"
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            for artifact in bundle.artifacts:
                (root / artifact.path).write_bytes(b"placeholder")
            validate_bundle_inventory(manifest_path, bundle)
            extra = bin_dir / "tinykg-helper"
            extra.write_bytes(b"unattested")
            with self.assertRaisesRegex(StageError, "undeclared=\\['tinykg-helper'\\]"):
                validate_bundle_inventory(manifest_path, bundle)
            extra.unlink()
            (root / bundle.artifacts[0].path).unlink()
            with self.assertRaisesRegex(StageError, "missing="):
                validate_bundle_inventory(manifest_path, bundle)


if __name__ == "__main__":
    unittest.main()
