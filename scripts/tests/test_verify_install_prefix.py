"""The default install prefix is exactly the release executable and the TinyKG
bundle (#77, B1); `verify_install_prefix.py` is the gate that says so in CI."""
import tempfile
import unittest
from pathlib import Path

from scripts.verify_install_prefix import check


class VerifyInstallPrefixTest(unittest.TestCase):
    def _make(self, names):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        for name in names:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        return root

    def test_matching_prefix(self):
        root = self._make(("bin/metacodes", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])

    def test_extra_and_missing_are_named(self):
        root = self._make(("bin/metacodes", "vendor/tinykg/tinykg", "extra.txt"))
        findings = check(root)
        self.assertIn("missing: vendor/tinykg/tinykg.provenance.json", findings)
        self.assertIn("unexpected: extra.txt", findings)

    def test_windows_names(self):
        root = self._make(("bin/metacodes.exe", "vendor/tinykg/tinykg.exe", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])
