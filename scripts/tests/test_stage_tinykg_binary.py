from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.stage_tinykg_binary import (
    StageError,
    TinyKgBundle,
    TinyKgContract,
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

    def bundled_elf(self, root: Path, *, machine: int = 62) -> Path:
        binary = root / "bin/tinykg-linux-x86_64"
        binary.parent.mkdir(parents=True)
        data = bytearray(256)
        data[:6] = b"\x7fELF\x02\x01"
        data[18:20] = struct.pack("<H", machine)
        data[32:40] = struct.pack("<Q", 64)
        data[54:56] = struct.pack("<H", 56)
        data[56:58] = struct.pack("<H", 1)
        data[64:68] = struct.pack("<I", 1)
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
        value = {
            "artifacts": [artifact],
            "build": {
                "optimize": "ReleaseSafe",
                "strip": True,
                "zig_version": "0.16.0",
            },
            "bundle_schema": "metacodes.tinykg-bundle/v1",
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


class CheckedInTinyKgBundleTest(unittest.TestCase):
    def test_every_declared_cross_platform_asset_matches_its_manifest(self) -> None:
        manifest_path = PROJECT_ROOT / "vendor/tinykg/manifest.json"
        bundle = TinyKgBundle.load(manifest_path)
        contract = TinyKgContract.load(PROJECT_ROOT / "deps/tinykg.json")
        self.assertEqual("a0544788aeadb3b92c69e539834be54850792285", bundle.source_commit)
        self.assertEqual("0.16.0", bundle.zig_version)
        self.assertEqual("ReleaseSafe", bundle.optimize)
        self.assertTrue(bundle.strip)
        self.assertEqual(
            {
                "linux-aarch64",
                "linux-x86_64",
                "macos-universal",
                "windows-x86_64",
            },
            {artifact.key for artifact in bundle.artifacts},
        )
        for artifact in bundle.artifacts:
            binary = (manifest_path.parent / artifact.path).resolve()
            identity = validate_bundle_bytes(binary, artifact, contract)
            self.assertEqual(artifact.sha256, identity.sha256)
            self.assertEqual("tinykg 0.2.0", identity.version_line)


if __name__ == "__main__":
    unittest.main()
