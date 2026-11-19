"""The vendored QuickJS stays upstream bytes plus reviewable patches.

The checked-in tree must verify and stage. A synthetic vendor directory then
proves each fail-closed path: a drifted upstream file, an undeclared file, a
patch that no longer applies exactly, a patched-digest drift, and an archive
that does not match the manifest.
"""

from __future__ import annotations

import hashlib
import io
import json
import shutil
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from scripts import stage_quickjs_sources as stage_mod
from scripts import verify_quickjs_sources as verify_mod
from scripts.stage_quickjs_sources import QuickJsSources, StageError, apply_hunks, build_tree, parse_patch, stage

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "vendor" / "quickjs"

UPSTREAM_C = "int one(void)\n{\n    return 1;\n}\n\nint two(void)\n{\n    return 2;\n}\n"
PATCHED_C = "int one(void)\n{\n    return 1;\n}\n\nint two(void)\n{\n    return 2 + 0;\n}\n"
PATCH = (
    "Describe the change.\n"
    "\n"
    "--- a/engine.c\n"
    "+++ b/engine.c\n"
    "@@ -6,4 +6,4 @@\n"
    " int two(void)\n"
    " {\n"
    "-    return 2;\n"
    "+    return 2 + 0;\n"
    " }\n"
)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _write(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(data)


def _fixture(root: Path, *, patch: str = PATCH, patched: str = PATCHED_C, archive_sha: str = "0" * 64) -> Path:
    vendor = root / "vendor"
    _write(vendor / "engine.c", UPSTREAM_C)
    _write(vendor / "LICENSE", "MIT\n")
    _write(vendor / "README.md", "fixture\n")
    _write(vendor / "patches" / "0001-two.patch", patch)
    manifest = {
        "bundle_schema": "metacodes.quickjs-source/v1",
        "license": "MIT",
        "upstream_release": "test",
        "upstream_archive": {"url": "https://example.invalid/q.tar.xz", "sha256": archive_sha, "root": "q"},
        "files": [
            {"path": "LICENSE", "sha256": _sha(b"MIT\n")},
            {"path": "engine.c", "sha256": _sha(UPSTREAM_C.encode())},
        ],
        "patches": [{"path": "patches/0001-two.patch", "sha256": _sha(patch.encode())}],
        "patched": [{"path": "engine.c", "sha256": _sha(patched.encode())}],
    }
    _write(vendor / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    return vendor


def _archive(path: Path, members: dict) -> str:
    with tarfile.open(path, "w:xz") as bundle:
        for name, text in members.items():
            data = text.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            bundle.addfile(info, io.BytesIO(data))
    return _sha(path.read_bytes())


def _run(main, argv):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = main(argv)
    return code, out.getvalue(), err.getvalue()


class CheckedInTreeTest(unittest.TestCase):
    def test_the_vendored_tree_verifies(self) -> None:
        code, out, err = _run(verify_mod.main, [])
        self.assertEqual(0, code, err)
        self.assertIn("verify_quickjs_sources: ok release=2025-09-13", out)

    def test_upstream_files_are_never_edited_in_place(self) -> None:
        sources = QuickJsSources.load(VENDOR / "manifest.json")
        tree = build_tree(VENDOR, sources)
        upstream = (VENDOR / "quickjs.c").read_bytes()
        self.assertNotIn(b"METACODES_NO_ATOMICS", upstream)
        self.assertIn(b"(DynBufReallocFunc *)js_realloc_rt", upstream)
        self.assertIn(b"#if !defined(EMSCRIPTEN) && !defined(METACODES_NO_ATOMICS)", tree["quickjs.c"])
        self.assertNotIn(b"(DynBufReallocFunc *)js_realloc_rt", tree["quickjs.c"])
        for item in sources.files:
            if item.path != "quickjs.c":
                self.assertEqual((VENDOR / item.path).read_bytes(), tree[item.path], item.path)

    def test_stage_writes_exactly_the_engine_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "quickjs"
            code, _, err = _run(stage_mod.main, ["--out", str(out)])
            self.assertEqual(0, code, err)
            sources = QuickJsSources.load(VENDOR / "manifest.json")
            self.assertEqual(sorted(item.path for item in sources.files), sorted(p.name for p in out.iterdir()))
            patched = {item.path: item.sha256 for item in sources.patched}
            self.assertEqual(patched["quickjs.c"], _sha((out / "quickjs.c").read_bytes()))

    def test_gitattributes_keep_upstream_bytes(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn("vendor/quickjs/** -whitespace linguist-vendored", attributes)
        self.assertIn("vendor/quickjs/*.c linguist-generated", attributes)


class FailClosedTest(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)

    def tearDown(self) -> None:
        self._dir.cleanup()

    def test_fixture_stages_the_patched_file(self) -> None:
        vendor = _fixture(self.root)
        out = self.root / "out"
        stage(vendor, out)
        self.assertEqual(PATCHED_C, (out / "engine.c").read_text(encoding="utf-8"))
        self.assertEqual(["LICENSE", "engine.c"], sorted(p.name for p in out.iterdir()))

    def test_an_edited_upstream_file_fails(self) -> None:
        vendor = _fixture(self.root)
        _write(vendor / "engine.c", UPSTREAM_C.replace("return 1;", "return 1; "))
        with self.assertRaisesRegex(StageError, "engine.c sha256 drift"):
            stage(vendor, self.root / "out")

    def test_an_undeclared_file_fails(self) -> None:
        vendor = _fixture(self.root)
        _write(vendor / "patches" / "0002-extra.patch", PATCH)
        with self.assertRaisesRegex(StageError, r"undeclared=\['patches/0002-extra.patch'\]"):
            stage(vendor, self.root / "out")

    def test_a_patch_that_no_longer_applies_exactly_fails(self) -> None:
        vendor = _fixture(self.root, patch=PATCH.replace("@@ -6,4 +6,4 @@", "@@ -5,4 +5,4 @@"))
        with self.assertRaisesRegex(StageError, "does not apply exactly"):
            stage(vendor, self.root / "out")

    def test_a_patched_digest_drift_fails(self) -> None:
        vendor = _fixture(self.root, patched=UPSTREAM_C)
        with self.assertRaisesRegex(StageError, "patched engine.c sha256 drift"):
            stage(vendor, self.root / "out")

    def test_a_failed_stage_writes_nothing(self) -> None:
        vendor = _fixture(self.root, patched=UPSTREAM_C)
        code, _, err = _run(stage_mod.main, ["--out", str(self.root / "out"), "--vendor-dir", str(vendor)])
        self.assertEqual(1, code)
        self.assertIn("sha256 drift", err)
        self.assertFalse((self.root / "out").exists())

    def test_the_archive_must_match_the_manifest_and_the_files(self) -> None:
        archive = self.root / "q.tar.xz"
        digest = _archive(archive, {"q/engine.c": UPSTREAM_C, "q/LICENSE": "MIT\n"})
        vendor = _fixture(self.root, archive_sha=digest)
        code, out, err = _run(verify_mod.main, ["--vendor-dir", str(vendor), "--archive", str(archive)])
        self.assertEqual(0, code, err)
        self.assertIn("archive=match", out)

        other = self.root / "other.tar.xz"
        _archive(other, {"q/engine.c": UPSTREAM_C, "q/LICENSE": "MIT\n", "q/extra": "x"})
        code, _, err = _run(verify_mod.main, ["--vendor-dir", str(vendor), "--archive", str(other)])
        self.assertEqual(1, code)
        self.assertIn("archive sha256", err)

        changed = self.root / "changed.tar.xz"
        digest = _archive(changed, {"q/engine.c": PATCHED_C, "q/LICENSE": "MIT\n"})
        shutil.rmtree(vendor)
        vendor = _fixture(self.root, archive_sha=digest)
        code, _, err = _run(verify_mod.main, ["--vendor-dir", str(vendor), "--archive", str(changed)])
        self.assertEqual(1, code)
        self.assertIn("engine.c differs from the archive", err)


class PatchFormatTest(unittest.TestCase):
    def test_hunks_apply_at_their_stated_lines_only(self) -> None:
        [(name, hunks)] = parse_patch(PATCH)
        self.assertEqual("engine.c", name)
        self.assertEqual(PATCHED_C.encode(), apply_hunks(name, UPSTREAM_C.encode(), hunks))
        shifted = "\n" + UPSTREAM_C
        with self.assertRaisesRegex(StageError, "does not apply exactly"):
            apply_hunks(name, shifted.encode(), hunks)

    def test_a_renaming_patch_is_rejected(self) -> None:
        with self.assertRaisesRegex(StageError, "in place"):
            parse_patch(PATCH.replace("+++ b/engine.c", "+++ b/other.c"))

    def test_a_hunk_with_wrong_counts_is_rejected(self) -> None:
        with self.assertRaises(StageError):
            parse_patch(PATCH.replace("@@ -6,4 +6,4 @@", "@@ -6,5 +6,5 @@"))


if __name__ == "__main__":
    unittest.main()
