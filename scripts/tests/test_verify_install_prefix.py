"""The default install prefix is exactly the release executable and the TinyKG
bundle (#77, B1); `verify_install_prefix.py` is the gate that says so in CI."""
import tempfile
import unittest
from pathlib import Path

from scripts.verify_install_prefix import check, evaluate_doctor


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
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])

    def test_prefix_without_vendored_ripgrep_is_accepted_only_when_asked(self):
        root = self._make(("bin/metacodes", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertIn("missing: bin/rg", check(root))
        self.assertIn("missing: share/licenses/ripgrep-LICENSE-MIT", check(root))
        self.assertEqual(check(root, ripgrep=False), [])

    def test_extra_and_missing_are_named(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "extra.txt"))
        findings = check(root)
        self.assertIn("missing: vendor/tinykg/tinykg.provenance.json", findings)
        self.assertIn("unexpected: extra.txt", findings)

    def test_windows_names(self):
        root = self._make(("bin/metacodes.exe", "bin/rg.exe", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg.exe", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])

    def test_a_missing_ripgrep_is_named(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        self.assertEqual(check(root), [])
        (root / "bin/rg").unlink()
        self.assertIn("missing: bin/rg", check(root))

    def test_doctor_report_accepts_the_adjacent_matching_tinykg(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        report = {
            "checks": [
                {"name": "ripgrep", "resolved_path": "/usr/bin/rg", "sha256": "ab", "expected_sha256": None, "match": None, "source": "path"},
                {"name": "tinykg", "resolved_path": str(root / "vendor" / "tinykg" / "tinykg"), "sha256": "cd", "expected_sha256": "cd", "match": True, "source": "adjacent"},
            ]
        }
        self.assertEqual(evaluate_doctor(report, root), [])

    def test_release_doctor_requires_adjacent_ripgrep(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        base = {"name": "tinykg", "resolved_path": str(root / "vendor/tinykg/tinykg"), "match": True, "source": "adjacent"}
        report = {"checks": [{"name": "ripgrep", "resolved_path": str(root / "bin/rg"), "match": True, "source": "adjacent"}, base]}
        self.assertEqual(evaluate_doctor(report, root, release=True), [])
        report["checks"][0]["source"] = "path"
        findings = evaluate_doctor(report, root, release=True)
        self.assertEqual(len(findings), 1)
        self.assertIn("expected 'adjacent'", findings[0])
        # Without --release the same report passes: a development install
        # resolves rg from PATH first.
        self.assertEqual(evaluate_doctor(report, root), [])

    def test_doctor_report_names_every_deviation(self):
        root = self._make(("bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json"))
        report = {
            "checks": [
                {"name": "tinykg", "resolved_path": "/elsewhere/tinykg", "sha256": "cd", "expected_sha256": "ef", "match": False, "source": "env"},
            ]
        }
        findings = evaluate_doctor(report, root)
        self.assertEqual(len(findings), 4)
        self.assertTrue(any("no ripgrep check" in finding for finding in findings))
        self.assertTrue(any("not under" in finding for finding in findings))
        self.assertTrue(any("expected 'adjacent'" in finding for finding in findings))
        self.assertTrue(any("expected true" in finding for finding in findings))
        self.assertEqual(evaluate_doctor({"nope": 1}, root), ["doctor: report has no checks array"])

    def test_release_prefix_carries_licences_docs_and_manifest(self):
        release_files = (
            "bin/metacodes", "bin/rg", "share/licenses/ripgrep-LICENSE-MIT", "share/licenses/metacodes-LICENSE",
            "share/licenses/tinykg-LICENSE", "share/licenses/THIRD_PARTY_NOTICES.md", "share/doc/README.md",
            "share/doc/CHANGELOG-0.2.0-dev.md", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.provenance.json",
        )
        root = self._make(release_files)
        self.assertEqual(check(root, release=True), [])
        self.assertIn("unexpected: share/licenses/metacodes-LICENSE", check(root))
        (root / "manifest.json").write_text("{}", encoding="utf-8")
        self.assertEqual(check(root, release=True), [])
        (root / "share/doc/CHANGELOG-0.2.0-dev.md").unlink()
        self.assertIn("missing: share/doc/CHANGELOG-<version>.md", check(root, release=True))
