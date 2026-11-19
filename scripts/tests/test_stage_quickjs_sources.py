"""The vendored QuickJS stays upstream bytes plus reviewable patches.

The checked-in tree must verify and stage. A synthetic vendor directory then
proves each fail-closed path: a drifted upstream file, an undeclared file, a
required file dropped from both manifest and directory, a patch that no longer
applies exactly or whose header lies, a patched-digest drift, an archive that
does not match the manifest, and an output that is not a missing or empty
directory. Staging never deletes anything outside its private temporary
directory, whatever happens to the output while it runs.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from scripts import stage_quickjs_sources as stage_mod
from scripts import verify_quickjs_sources as verify_mod
from scripts.stage_quickjs_sources import (
    QuickJsSources,
    StageError,
    apply_hunks,
    build_tree,
    parse_patch,
    stage,
)

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
            self.assertEqual(
                sorted(item.path for item in sources.files),
                sorted(p.name for p in out.iterdir()),
            )
            patched = {item.path: item.sha256 for item in sources.patched}
            self.assertEqual(patched["quickjs.c"], _sha((out / "quickjs.c").read_bytes()))

    def test_a_header_dropped_from_manifest_and_directory_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            vendor = Path(directory) / "quickjs"
            shutil.copytree(VENDOR, vendor)
            (vendor / "cutils.h").unlink()
            manifest = json.loads((vendor / "manifest.json").read_text(encoding="utf-8"))
            manifest["files"] = [item for item in manifest["files"] if item["path"] != "cutils.h"]
            _write(vendor / "manifest.json", json.dumps(manifest, indent=2) + "\n")
            with self.assertRaisesRegex(StageError, "includes cutils.h, which the manifest does not pin"):
                build_tree(vendor, QuickJsSources.load(vendor / "manifest.json"))

    def test_gitattributes_keep_upstream_bytes(self) -> None:
        attributes = (ROOT / ".gitattributes").read_text(encoding="utf-8")
        self.assertIn("vendor/quickjs/** -whitespace linguist-vendored", attributes)
        self.assertIn("vendor/quickjs/*.c linguist-generated", attributes)


class FailClosedTest(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        self._required = stage_mod.REQUIRED_FILES
        stage_mod.REQUIRED_FILES = ("LICENSE", "engine.c")

    def tearDown(self) -> None:
        stage_mod.REQUIRED_FILES = self._required
        self._dir.cleanup()

    def test_a_required_file_dropped_from_manifest_and_directory_fails(self) -> None:
        stage_mod.REQUIRED_FILES = ("LICENSE", "engine.c", "other.c")
        vendor = _fixture(self.root)
        with self.assertRaisesRegex(StageError, r"lacks required engine files: \['other.c'\]"):
            stage(vendor, self.root / "out")

    def test_output_overlapping_the_vendor_tree_is_refused_and_nothing_is_deleted(self) -> None:
        vendor = _fixture(self.root)
        before = sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*"))
        for out in (vendor, vendor / "patches", self.root, vendor / "new"):
            with self.subTest(out=out):
                with self.assertRaisesRegex(StageError, "overlaps the vendor tree"):
                    stage(vendor, out)
        self.assertEqual(before, sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob("*")))

    def test_a_foreign_non_empty_directory_is_refused_and_kept(self) -> None:
        vendor = _fixture(self.root)
        shared = self.root / "build"
        _write(shared / "other-artifact.o", "keep me\n")
        _write(shared / "engine.c", "someone else's file\n")
        with self.assertRaisesRegex(StageError, "it is not empty"):
            stage(vendor, shared)
        self.assertEqual("keep me\n", (shared / "other-artifact.o").read_text(encoding="utf-8"))
        self.assertEqual("someone else's file\n", (shared / "engine.c").read_text(encoding="utf-8"))

    def _snapshot(self, directory: Path) -> dict:
        return {
            p.relative_to(directory).as_posix(): (p.read_bytes() if p.is_file() else None)
            for p in sorted(directory.rglob("*"))
        }

    def test_a_staged_output_is_never_restaged_in_place(self) -> None:
        vendor = _fixture(self.root)
        out = self.root / "out"
        stage(vendor, out)
        _write(out / "engine.c", "a local edit to keep\n")
        before = self._snapshot(self.root)
        with self.assertRaisesRegex(StageError, "it is not empty"):
            stage(vendor, out)
        self.assertEqual(before, self._snapshot(self.root))

    def test_a_file_saved_into_the_output_while_staging_is_kept(self) -> None:
        """The reviewer's race: another process writes into the output after
        the emptiness check, while the tree is being generated."""
        vendor = _fixture(self.root)
        out = self.root / "out"
        out.mkdir()
        real = stage_mod._write_tree

        def concurrent_writer(directory: Path, tree: dict) -> None:
            real(directory, tree)
            _write(out / "quickjs.h", "saved by someone else\n")

        stage_mod._write_tree = concurrent_writer
        try:
            with self.assertRaisesRegex(StageError, "it is not empty"):
                stage(vendor, out)
        finally:
            stage_mod._write_tree = real
        self.assertEqual({"quickjs.h": b"saved by someone else\n"}, self._snapshot(out))
        self.assertEqual(["out", "vendor"], sorted(p.name for p in self.root.iterdir()), "no staging leftovers")

    def test_an_interrupted_write_leaves_the_output_as_it_was_and_a_retry_succeeds(self) -> None:
        vendor = _fixture(self.root)
        out = self.root / "out"
        out.mkdir()
        real = stage_mod._write_tree

        def disk_full(directory: Path, tree: dict) -> None:
            (directory / "LICENSE").write_bytes(tree["LICENSE"])
            raise OSError(28, "No space left on device")

        stage_mod._write_tree = disk_full
        try:
            with self.assertRaisesRegex(StageError, "No space left on device"):
                stage(vendor, out)
        finally:
            stage_mod._write_tree = real
        self.assertEqual({}, self._snapshot(out))
        self.assertEqual(["out", "vendor"], sorted(p.name for p in self.root.iterdir()), "no staging leftovers")
        stage(vendor, out)
        self.assertEqual(PATCHED_C, (out / "engine.c").read_text(encoding="utf-8"))

    def test_a_failed_publish_restores_the_empty_output_and_a_retry_succeeds(self) -> None:
        vendor = _fixture(self.root)
        for existed in (True, False):
            with self.subTest(existed=existed):
                out = self.root / ("empty" if existed else "missing")
                if existed:
                    out.mkdir()
                real = stage_mod.os.rename

                def failing_rename(src, dst):
                    raise OSError(5, "Input/output error")

                stage_mod.os.rename = failing_rename
                try:
                    with self.assertRaisesRegex(StageError, "cannot publish"):
                        stage(vendor, out)
                finally:
                    stage_mod.os.rename = real
                self.assertEqual(existed, out.is_dir())
                if existed:
                    self.assertEqual({}, self._snapshot(out))
                leftovers = [p.name for p in self.root.iterdir() if "staging" in p.name]
                self.assertEqual([], leftovers)
                stage(vendor, out)
                self.assertEqual(PATCHED_C, (out / "engine.c").read_text(encoding="utf-8"))

    def test_the_working_directory_is_refused_and_left_empty(self) -> None:
        vendor = _fixture(self.root)
        build = self.root / "build"
        build.mkdir()
        previous = os.getcwd()
        os.chdir(build)
        try:
            for out in (Path("."), Path(".."), build):
                with self.subTest(out=out):
                    code, _, err = _run(stage_mod.main, ["--out", str(out), "--vendor-dir", str(vendor)])
                    self.assertEqual(1, code)
                    # `..` is also a parent of the vendor tree, refused for that first.
                    self.assertIn("refusing output directory", err)
                    if out != Path(".."):
                        self.assertIn("working directory", err)
        finally:
            os.chdir(previous)
        self.assertEqual([], list(build.iterdir()))
        self.assertEqual(["build", "vendor"], sorted(p.name for p in self.root.iterdir()))

    def test_a_case_alias_inside_the_vendor_tree_is_refused(self) -> None:
        vendor = _fixture(self.root)
        alias = vendor.parent / vendor.name.upper()
        if not alias.exists():
            self.skipTest("case-sensitive file system")
        before = self._snapshot(self.root)
        for out in (alias / "new", alias, alias / "patches"):
            with self.subTest(out=out):
                with self.assertRaisesRegex(StageError, "overlaps the vendor tree"):
                    stage(vendor, out)
        self.assertEqual(before, self._snapshot(self.root))

    def test_an_empty_existing_directory_is_accepted(self) -> None:
        vendor = _fixture(self.root)
        out = self.root / "empty"
        out.mkdir()
        stage(vendor, out)
        self.assertEqual(PATCHED_C, (out / "engine.c").read_text(encoding="utf-8"))

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

    def test_a_new_start_that_disagrees_with_the_old_start_is_rejected(self) -> None:
        [(name, hunks)] = parse_patch(PATCH.replace("@@ -6,4 +6,4 @@", "@@ -6,4 +7,4 @@"))
        with self.assertRaisesRegex(StageError, "new start 7"):
            apply_hunks(name, UPSTREAM_C.encode(), hunks)

    def test_an_insertion_past_the_end_of_the_file_is_rejected(self) -> None:
        patch = "--- a/engine.c\n+++ b/engine.c\n@@ -20,0 +21,1 @@\n+int three(void);\n"
        [(name, hunks)] = parse_patch(patch)
        with self.assertRaisesRegex(StageError, "past the end of the file"):
            apply_hunks(name, UPSTREAM_C.encode(), hunks)
        # The same insertion right after the last line is fine.
        last = len(UPSTREAM_C.splitlines())
        [(name, hunks)] = parse_patch(patch.replace("-20,0 +21,1", "-%d,0 +%d,1" % (last, last + 1)))
        self.assertTrue(apply_hunks(name, UPSTREAM_C.encode(), hunks).endswith(b"int three(void);\n"))

    def test_a_hunk_with_wrong_counts_is_rejected(self) -> None:
        with self.assertRaises(StageError):
            parse_patch(PATCH.replace("@@ -6,4 +6,4 @@", "@@ -6,5 +6,5 @@"))


if __name__ == "__main__":
    unittest.main()
