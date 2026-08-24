from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from scripts.stage_tinykg_binary import StageError, stage


CONTRACT = {
    "contract_schema": "metacodes.tinykg-binary/v1",
    "license": "Apache-2.0",
    "source_repository": "https://example.invalid/tinykg",
    "storage_format_version": "3",
    "store_schema_version": "3",
    "tinykg_version": "0.2.0",
}


@unittest.skipIf(os.name == "nt", "POSIX executable fixture")
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
            self.assertEqual("metacodes.tinykg-binary-receipt/v1", value["receipt_schema"])
            self.assertEqual(digest, value["binary_sha256"])
            self.assertEqual("tinykg 0.2.0", value["binary_version"])
            self.assertEqual("aarch64-macos", value["target"])
            self.assertNotIn(str(binary), receipt.read_text(encoding="utf-8"))

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


if __name__ == "__main__":
    unittest.main()
