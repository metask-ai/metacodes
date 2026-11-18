"""Release document sources and the actual installed bytes, without a CLI binary."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts import check_release_docs as checker

ROOT = Path(__file__).resolve().parents[2]


class ReleaseDocumentsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "release").mkdir()
        (self.root / "build.zig.zon").write_text('.{ .version = "1.2.3-dev" }\n', encoding="utf-8")
        (self.root / "README.md").write_bytes(b"readme\n")
        (self.root / "CHANGELOG.md").write_bytes(b"changelog\n")
        self.manifest = {"schema": checker.SCHEMA, "files": [
            {"source": "README.md", "destination": "share/doc/README.md"},
            {"source": "CHANGELOG.md", "destination": "share/doc/CHANGELOG-{version}.md"},
        ]}
        self.write_manifest()
        self.prefix = self.root / "prefix"
        docs = self.prefix / "share/doc"
        docs.mkdir(parents=True)
        (docs / "README.md").write_bytes(b"readme\n")
        (docs / "CHANGELOG-1.2.3-dev.md").write_bytes(b"changelog\n")

    def write_manifest(self):
        (self.root / checker.MANIFEST).write_text(json.dumps(self.manifest), encoding="utf-8")

    def test_sources_and_versioned_installation_are_valid(self):
        self.assertEqual(checker.check(self.root), [])
        self.assertEqual(checker.check(self.root, self.prefix), [])

    def test_the_checked_in_release_sources_exist(self):
        self.assertEqual(checker.check(ROOT), [])

    def test_missing_empty_and_stale_documents_fail(self):
        installed = self.prefix / "share/doc/README.md"
        installed.write_bytes(b"old readme\n")
        self.assertTrue(any("differs" in finding for finding in checker.check(self.root, self.prefix)))
        installed.unlink()
        self.assertTrue(any("missing documents entry" in finding for finding in checker.check(self.root, self.prefix)))
        (self.root / "README.md").write_bytes(b" \n")
        self.assertIn("empty release document: README.md", checker.check(self.root))
        (self.root / "README.md").unlink()
        with self.assertRaisesRegex(ValueError, "not a regular file"):
            checker.check(self.root)

    def test_a_product_binary_in_the_documents_prefix_is_rejected(self):
        (self.prefix / "bin").mkdir()
        (self.prefix / "bin/metacodes").write_bytes(b"unexpected executable")
        self.assertIn("unexpected documents entry: bin/metacodes", checker.check(self.root, self.prefix))

    def test_a_version_bump_requires_the_new_changelog_name(self):
        (self.root / "build.zig.zon").write_text('.{ .version = "1.2.4-dev" }\n', encoding="utf-8")
        findings = checker.check(self.root, self.prefix)
        self.assertIn("missing documents entry: share/doc/CHANGELOG-1.2.4-dev.md", findings)
        self.assertIn("unexpected documents entry: share/doc/CHANGELOG-1.2.3-dev.md", findings)

    def test_unsafe_or_colliding_destinations_are_rejected(self):
        for destination in ("../outside", "/outside", "share/doc/../outside", "bin/metacodes", "share/doc/{unknown}", "share/doc/readme.MD"):
            with self.subTest(destination=destination):
                self.manifest["files"][1]["destination"] = destination
                self.write_manifest()
                with self.assertRaises(ValueError):
                    checker.check(self.root)

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_symlinked_source_and_installed_document_are_rejected(self):
        for path, target in ((self.root / "README.md", "CHANGELOG.md"),
                             (self.prefix / "share/doc/README.md", "CHANGELOG-1.2.3-dev.md")):
            original = path.read_bytes()
            path.unlink()
            path.symlink_to(target)
            if path == self.root / "README.md":
                with self.assertRaisesRegex(ValueError, "symlink"):
                    checker.check(self.root)
            else:
                self.assertTrue(any("symlink" in finding for finding in checker.check(self.root, self.prefix)))
            path.unlink()
            path.write_bytes(original)

    def test_the_command_checks_installed_bytes_and_returns_nonzero_on_drift(self):
        argv = [sys.executable, str(ROOT / "scripts/check_release_docs.py"),
                "--root", str(self.root), "--prefix", str(self.prefix)]
        self.assertEqual(subprocess.run(argv, capture_output=True).returncode, 0)
        (self.prefix / "share/doc/README.md").write_bytes(b"drift")
        proc = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("differs from README.md", proc.stderr)

    def test_protocol_validation_alone_detects_a_removed_document_reference(self):
        protocol = json.loads((ROOT / "evals/plugin-v1/protocol.json").read_text(encoding="utf-8"))
        protocol_path = self.root / "protocol.json"
        protocol_path.write_text(json.dumps(protocol), encoding="utf-8")
        argv = [sys.executable, str(ROOT / "scripts/eval/plugin_release_gate.py"),
                "--protocol", str(protocol_path), "--validate-only"]
        valid = subprocess.run(argv, capture_output=True, text=True)
        self.assertEqual(valid.returncode, 0, valid.stderr)
        self.assertEqual(json.loads(valid.stdout)["provider_requests"], 0)
        protocol["implementation_paths"].append("doc/ci-scope-missing-document-reference.md")
        protocol_path.write_text(json.dumps(protocol), encoding="utf-8")
        broken = subprocess.run(argv, capture_output=True, text=True)
        self.assertNotEqual(broken.returncode, 0)
        self.assertIn("ci-scope-missing-document-reference.md", broken.stderr)
