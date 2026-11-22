from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

from scripts.check_changelog_sections import misplaced

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

    def test_a_release_cut_passes(self) -> None:
        candidate = BASE.replace("## Unreleased\n", "## Unreleased\n\n## 0.14.0 — 2026-11-27\n")
        self.assertEqual(misplaced(BASE, candidate), [])

    def test_union_merges_the_changelog(self) -> None:
        attribute = subprocess.run(["git", "check-attr", "merge", "--", "CHANGELOG.md"], cwd=PROJECT_ROOT,
                                   capture_output=True, text=True, check=True).stdout
        self.assertEqual(attribute.strip(), "CHANGELOG.md: merge: union")


if __name__ == "__main__":
    unittest.main()
