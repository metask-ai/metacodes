from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.stage_ripgrep_binary import (
    RipgrepBundle,
    StageError,
    stage,
    validate_artifact_bytes,
)
from scripts.verify_ripgrep_binary import validate_bundle_inventory

PROJECT_ROOT = Path(__file__).resolve().parents[2]

MACHO_ARM64 = struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"\x00" * 24
MACHO_X86_64 = struct.pack("<II", 0xFEEDFACF, 0x01000007) + b"\x00" * 24
ELF_X86_64 = b"\x7fELF" + b"\x02\x01\x01" + b"\x00" * 9 + struct.pack("<HH", 3, 62) + b"\x00" * 44
PE_STUB = b"MZ" + b"\x00" * 62


def _artifact_entry(key: str, path: str, payload: bytes, *, fmt: str, arch: str, target: str) -> dict:
    return {
        "architectures": [arch],
        "format": fmt,
        "key": key,
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "targets": [target],
    }


class RipgrepBundleStageTest(unittest.TestCase):
    def bundle_fixture(self, root: Path) -> Path:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "rg-macos-aarch64").write_bytes(MACHO_ARM64)
        (bin_dir / "rg-linux-x86_64").write_bytes(ELF_X86_64)
        manifest = {
            "artifacts": [
                _artifact_entry(
                    "macos-aarch64",
                    "bin/rg-macos-aarch64",
                    MACHO_ARM64,
                    fmt="mach-o",
                    arch="aarch64",
                    target="aarch64-macos",
                ),
                _artifact_entry(
                    "linux-x86_64",
                    "bin/rg-linux-x86_64",
                    ELF_X86_64,
                    fmt="elf-static",
                    arch="x86_64",
                    target="x86_64-linux",
                ),
            ],
            "bundle_schema": "metacodes.ripgrep-bundle/v1",
            "license": "MIT OR Unlicense",
            "source_repository": "https://example.invalid/ripgrep",
            "upstream_release": "15.2.0",
            "upstream_revision": "deadbeef00",
        }
        (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return root

    def test_stage_verifies_hash_and_installs_canonical_name(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            dest = Path(raw) / "out"
            staged = stage("aarch64", "macos", dest, bundle_dir=root)
            self.assertEqual(staged, dest / "rg")
            self.assertEqual(staged.read_bytes(), MACHO_ARM64)
            self.assertTrue(staged.stat().st_mode & 0o111)

    def test_stage_rejects_tampered_binary(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            (root / "bin" / "rg-macos-aarch64").write_bytes(MACHO_ARM64 + b"tamper")
            with self.assertRaisesRegex(StageError, "hash mismatch"):
                stage("aarch64", "macos", Path(raw) / "out", bundle_dir=root)

    def test_stage_rejects_format_and_architecture_drift(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            # 同一字节换个身份声明:mach-o 声明配 ELF 字节必须被拒。
            manifest["artifacts"][0]["sha256"] = hashlib.sha256(ELF_X86_64).hexdigest()
            (root / "bin" / "rg-macos-aarch64").write_bytes(ELF_X86_64)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "Mach-O"):
                stage("aarch64", "macos", Path(raw) / "out", bundle_dir=root)

        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["artifacts"][0]["sha256"] = hashlib.sha256(MACHO_X86_64).hexdigest()
            (root / "bin" / "rg-macos-aarch64").write_bytes(MACHO_X86_64)
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "cputype"):
                stage("aarch64", "macos", Path(raw) / "out", bundle_dir=root)

    def test_missing_target_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            with self.assertRaisesRegex(StageError, "no artifact for target"):
                stage("x86_64", "windows", Path(raw) / "out", bundle_dir=root)

    def test_manifest_schema_is_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["extra"] = 1
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "missing or unknown fields"):
                RipgrepBundle.load(root / "manifest.json")

        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            manifest["artifacts"][0]["path"] = "bin/../rg-escape"
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(StageError, "directly under bin/"):
                RipgrepBundle.load(root / "manifest.json")

    def test_inventory_rejects_undeclared_executables(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = self.bundle_fixture(Path(raw))
            bundle = RipgrepBundle.load(root / "manifest.json")
            validate_bundle_inventory(root, bundle)
            (root / "bin" / "rg-smuggled").write_bytes(PE_STUB)
            with self.assertRaisesRegex(StageError, "inventory drift"):
                validate_bundle_inventory(root, bundle)

    def test_checked_in_bundle_is_attested(self) -> None:
        # 仓库真实 vendored 集必须始终通过与 CI 相同的校验路径。
        bundle_dir = PROJECT_ROOT / "vendor" / "ripgrep"
        bundle = RipgrepBundle.load(bundle_dir / "manifest.json")
        for artifact in bundle.artifacts:
            validate_artifact_bytes(bundle_dir, artifact)
        validate_bundle_inventory(bundle_dir, bundle)


if __name__ == "__main__":
    unittest.main()
