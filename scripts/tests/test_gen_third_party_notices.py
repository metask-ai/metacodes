"""The third-party notices are rendered from the manifests, and `--check` is the
gate that keeps the committed file honest (#47)."""

from __future__ import annotations

import io
import json
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from scripts.gen_third_party_notices import INPUT_FILES, OUTPUT_FILE, TABLE_MARKER, NoticesError, generate, main

ROOT = Path(__file__).resolve().parents[2]


def _copy_inputs(destination: Path) -> None:
    for relative in INPUT_FILES + (OUTPUT_FILE,):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / relative, target)


def _write(path: Path, text: str) -> None:
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


class GeneratedNoticesTest(unittest.TestCase):
    def test_committed_file_is_what_the_manifests_render(self) -> None:
        rendered = generate(ROOT)
        self.assertEqual(rendered, generate(ROOT), "rendering must be deterministic")
        self.assertEqual(rendered, (ROOT / OUTPUT_FILE).read_text(encoding="utf-8"))
        self.assertEqual(0, main(["--root", str(ROOT), "--check"]))

    def test_a_bumped_manifest_changes_the_notices_and_fails_the_check(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _copy_inputs(root)
            manifest = root / INPUT_FILES[0]
            value = json.loads(manifest.read_text(encoding="utf-8"))
            value["upstream_release"] = "99.0.0"
            _write(manifest, json.dumps(value, indent=2) + "\n")
            rendered = generate(root)
            self.assertIn("| ripgrep 99.0.0 |", rendered)
            self.assertNotEqual(rendered, (root / OUTPUT_FILE).read_text(encoding="utf-8"))
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(1, main(["--root", str(root), "--check"]))
            self.assertIn("+| ripgrep 99.0.0 |", stderr.getvalue())
            # The default action rewrites the file, after which the check is green.
            self.assertEqual(0, main(["--root", str(root)]))
            self.assertEqual(0, main(["--root", str(root), "--check"]))
            self.assertNotIn(b"\r\n", (root / OUTPUT_FILE).read_bytes())

    def test_malformed_inputs_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _copy_inputs(root)
            _write(root / INPUT_FILES[4], "leanprover/lean4:nightly\n")
            with self.assertRaises(NoticesError):
                generate(root)
            _write(root / INPUT_FILES[4], "leanprover/lean4:v4.14.0\n")
            static = root / INPUT_FILES[5]
            _write(static, static.read_text(encoding="utf-8").replace(TABLE_MARKER + "\n", ""))
            with self.assertRaises(NoticesError):
                generate(root)
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                self.assertEqual(2, main(["--root", str(root), "--check"]))
            self.assertIn("table marker", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
