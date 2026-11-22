from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from scripts.check_changelog_sections import main, misplaced, stale

PROJECT_ROOT = Path(__file__).resolve().parents[2]

BASE = """# Changelog

## Unreleased

### Fixed

- **Main's entry.**

## 0.13.0 — 2026-11-20

### Added

- **Released entry.**
  Continued.
"""


class ChangelogSectionsTest(unittest.TestCase):
    """Entries a branch adds belong under ## Unreleased."""

    def test_an_entry_under_unreleased_passes(self) -> None:
        candidate = BASE.replace("- **Main's entry.**", "- **Branch entry.**\n\n- **Main's entry.**")
        self.assertEqual(misplaced(BASE, candidate), [])

    def test_an_entry_under_a_released_section_fails(self) -> None:
        # What union produced at 52122b44: the branch's entry kept its old
        # position, which after the cut is the released section.
        candidate = BASE.replace("- **Released entry.**", "- **Branch entry.**\n\n- **Released entry.**")
        self.assertEqual(misplaced(BASE, candidate), [("## 0.13.0 — 2026-11-20", "- **Branch entry.**")])

    def test_rewording_a_released_entry_passes(self) -> None:
        candidate = BASE.replace("  Continued.", "  Continued, corrected.")
        self.assertEqual(misplaced(BASE, candidate), [])

    def test_rewording_a_released_entry_title_passes(self) -> None:
        candidate = BASE.replace("- **Released entry.**", "- **Released entry, reworded.**")
        self.assertEqual(misplaced(BASE, candidate), [])

    def test_a_release_cut_passes(self) -> None:
        candidate = BASE.replace("## Unreleased\n", "## Unreleased\n\n## 0.14.0 — 2026-11-27\n")
        self.assertEqual(misplaced(BASE, candidate), [])

    def test_an_entry_the_change_added_is_not_stale(self) -> None:
        candidate = BASE.replace("- **Main's entry.**", "- **Branch entry.**\n\n- **Main's entry.**")
        self.assertEqual(stale(BASE, candidate, Counter({"- **Branch entry.**": 1})), [])

    def test_an_entry_main_rewrote_is_stale(self) -> None:
        # #696 (1cc8665f) rewrote the first entry under ### Added; a branch
        # that had added one above it kept the old text through union.
        base = BASE.replace("- **Main's entry.**", "- **Main's entry, rewritten.**")
        candidate = BASE.replace("- **Main's entry.**",
                                 "- **Branch entry.**\n- **Main's entry.**\n- **Main's entry, rewritten.**")
        self.assertEqual(stale(base, candidate, Counter({"- **Branch entry.**": 1})), ["- **Main's entry.**"])

    def test_an_entry_main_moved_is_stale(self) -> None:
        candidate = BASE.replace("- **Main's entry.**", "- **Main's entry.**\n\n- **Main's entry.**")
        self.assertEqual(stale(BASE, candidate, Counter()), ["- **Main's entry.**"])

    def test_union_leftover_after_merging_main_fails(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            def git(*args: str) -> str:
                env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                       "GIT_COMMITTER_EMAIL": "t@t"}
                return subprocess.run(["git", *args], cwd=root, env=env, capture_output=True, text=True,
                                      check=True).stdout.strip()

            def commit(text: str) -> None:
                Path(root, "CHANGELOG.md").write_text(text, encoding="utf-8")
                git("commit", "-qam", "change")

            git("init", "-q", "-b", "main")
            Path(root, ".gitattributes").write_text("CHANGELOG.md merge=union\n", encoding="utf-8")
            Path(root, "CHANGELOG.md").write_text(BASE, encoding="utf-8")
            git("add", ".")
            git("commit", "-qm", "base")
            git("checkout", "-qb", "branch")
            commit(BASE.replace("- **Main's entry.**", "- **Branch entry.**\n\n- **Main's entry.**"))
            git("checkout", "-q", "main")
            commit(BASE.replace("- **Main's entry.**", "- **Main's entry, rewritten.**"))
            git("checkout", "-q", "branch")
            git("merge", "-q", "main", "-m", "merge main")
            # What CI checks on a pull_request run: main merged with the branch.
            git("checkout", "-q", "main")
            git("merge", "-q", "--no-ff", "branch", "-m", "pr")
            cwd = os.getcwd()
            os.chdir(root)
            try:
                self.assertEqual(main(["--base", "HEAD^1"]), 1)
                # Deleting the leftover on the branch clears it.
                git("reset", "-q", "--hard", "HEAD^1")
                git("checkout", "-q", "branch")
                text = Path(root, "CHANGELOG.md").read_text(encoding="utf-8")
                commit(text.replace("- **Main's entry.**\n", "", 1))
                git("checkout", "-q", "main")
                git("merge", "-q", "--no-ff", "branch", "-m", "pr")
                self.assertEqual(main(["--base", "HEAD^1"]), 0)
            finally:
                os.chdir(cwd)

    def test_union_merges_the_changelog(self) -> None:
        attribute = subprocess.run(["git", "check-attr", "merge", "--", "CHANGELOG.md"], cwd=PROJECT_ROOT,
                                   capture_output=True, text=True, check=True).stdout
        self.assertEqual(attribute.strip(), "CHANGELOG.md: merge: union")


if __name__ == "__main__":
    unittest.main()
