"""release_cut.py / check_version_state.py: the pure rules and the two git
probes, on fixtures and throwaway repositories (doc/RELEASE_AUTOMATION_DESIGN.md)."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check_version_state  # noqa: E402
import release_cut as rc  # noqa: E402

CHANGELOG_FIXTURE = """# Changelog

Intro paragraph.

## Unreleased

### Fixed

- one fix.

### Changed

- one change.

### Fixed

- a second Fixed block is legal (the real file has several).

## 0.1.0 — 2026-08-29

### Added

- first release.
"""


class LevelTableTest(unittest.TestCase):
    def test_types_map_to_levels(self):
        self.assertEqual(rc.classify_subject("feat(core): x"), ("feat", "minor"))
        self.assertEqual(rc.classify_subject("fix: x"), ("fix", "patch"))
        self.assertEqual(rc.classify_subject("perf(io): x"), ("perf", "patch"))
        self.assertEqual(rc.classify_subject("feat!: drop flag"), ("feat", "major"))
        self.assertEqual(rc.classify_subject("FIX: uppercase type"), ("fix", "patch"))
        for subject in ("ci: x", "test: x", "docs: x", "chore: x", "eval(x): y", "review: z", "core: w", "build: v"):
            self.assertEqual(rc.classify_subject(subject)[1], "none", subject)

    def test_unknown_shapes_contribute_nothing_and_are_reported(self):
        level, unknown = rc.derive_level(["merge main", "修复一个问题", "fix: real", "Merge pull request #1"])
        self.assertEqual(level, "patch")
        self.assertEqual(unknown, ["merge main", "修复一个问题", "Merge pull request #1"])

    def test_highest_level_wins_and_breaking_footer_counts(self):
        self.assertEqual(rc.derive_level(["fix: a", "feat: b", "ci: c"])[0], "minor")
        self.assertEqual(rc.derive_level(["fix: a\n\nBREAKING CHANGE: api"])[0], "major")
        self.assertEqual(rc.derive_level(["ci: a", "docs: b"])[0], "none")
        self.assertEqual(rc.derive_level([])[0], "none")


class VersionArithmeticTest(unittest.TestCase):
    def test_bump_pre_1_breaking_is_minor(self):
        self.assertEqual(rc.bump((0, 2, 0), "major"), (0, 3, 0))
        self.assertEqual(rc.bump((1, 2, 3), "major"), (2, 0, 0))
        self.assertEqual(rc.bump((0, 2, 3), "minor"), (0, 3, 0))
        self.assertEqual(rc.bump((0, 2, 3), "patch"), (0, 2, 4))

    def test_floor_wins_over_a_smaller_bump(self):
        self.assertEqual(rc.compute_version("0.1.0", "0.2.0-dev", "patch"), "0.2.0")
        self.assertEqual(rc.compute_version("0.1.0", "0.2.0-dev", "minor"), "0.2.0")
        self.assertEqual(rc.compute_version("0.2.0", "0.2.1-dev", "minor"), "0.3.0")
        self.assertEqual(rc.compute_version("0.2.0", "0.2.1-dev", "patch"), "0.2.1")

    def test_candidate_always_exceeds_the_last_tag(self):
        # bump(tag) is greater than the tag for every level, so the floor can
        # never drag the candidate down to an existing tag: a stale -dev floor
        # (0.2.0-dev after 0.2.0 was tagged) still yields 0.2.1, and a floor
        # below the tag never wins. The mid-flight state (bare version on main)
        # is caught by the -dev check, see test_mid_flight_and_no_change_refuse.
        self.assertEqual(rc.compute_version("0.2.0", "0.2.0-dev", "patch"), "0.2.1")
        self.assertEqual(rc.compute_version("0.2.0", "0.1.5-dev", "patch"), "0.2.1")
        for level in ("patch", "minor", "major"):
            self.assertGreater(rc.parse_version(rc.compute_version("0.2.0", "0.0.1-dev", level))[:3], (0, 2, 0))

    def test_mid_flight_and_no_change_refuse(self):
        with self.assertRaisesRegex(rc.CutError, "without -dev"):
            rc.compute_version("0.1.0", "0.2.0", "patch")
        with self.assertRaisesRegex(rc.CutError, "--force-level"):
            rc.compute_version("0.1.0", "0.2.0-dev", "none")

    def test_next_dev(self):
        self.assertEqual(rc.next_dev("0.2.0", "patch"), "0.2.1-dev")
        self.assertEqual(rc.next_dev("0.2.0", "minor"), "0.3.0-dev")
        with self.assertRaises(rc.CutError):
            rc.next_dev("0.2.0", "major")


class VersionFilesTest(unittest.TestCase):
    def test_exactly_one_declaration_is_rewritten(self):
        zon = '.{\n    .name = .metacodes,\n    .version = "0.2.0-dev",\n}\n'
        self.assertIn('.version = "0.2.0"', rc.set_version_text(zon, rc.ZON_VERSION_RE, "0.2.0", "zon"))
        zig = 'pub const semver = "0.2.0-dev";\n'
        self.assertEqual(rc.set_version_text(zig, rc.ZIG_VERSION_RE, "0.2.0", "zig"), 'pub const semver = "0.2.0";\n')
        with self.assertRaisesRegex(rc.CutError, "exactly one"):
            rc.set_version_text(zig + zig, rc.ZIG_VERSION_RE, "0.2.0", "zig")

    def test_real_tree_declarations_agree_and_parse(self):
        zon = rc.ZON_VERSION_RE.search((ROOT / rc.ZON).read_text(encoding="utf-8"))
        zig = rc.ZIG_VERSION_RE.search((ROOT / rc.VERSION_ZIG).read_text(encoding="utf-8"))
        self.assertIsNotNone(zon)
        self.assertIsNotNone(zig)
        self.assertEqual(zon.group(2), zig.group(2))
        rc.parse_version(zon.group(2))


class ChangelogTest(unittest.TestCase):
    def test_unreleased_becomes_the_release_and_an_empty_block_is_reinserted(self):
        new, section = rc.rewrite_changelog(CHANGELOG_FIXTURE, "0.2.0", "2026-09-22")
        self.assertTrue(section.startswith("## 0.2.0 — 2026-09-22\n"))
        self.assertIn("- one fix.", section)
        self.assertIn("- a second Fixed block is legal", section)
        self.assertNotIn("first release", section)
        lines = new.splitlines()
        self.assertEqual(lines.count("## Unreleased"), 1)
        self.assertLess(lines.index("## Unreleased"), lines.index("## 0.2.0 — 2026-09-22"))
        self.assertLess(lines.index("## 0.2.0 — 2026-09-22"), lines.index("## 0.1.0 — 2026-08-29"))
        # the new Unreleased block is empty: nothing between it and the release heading
        between = lines[lines.index("## Unreleased") + 1: lines.index("## 0.2.0 — 2026-09-22")]
        self.assertEqual([l for l in between if l.strip()], [])
        # the released section is retrievable and identical
        self.assertEqual(rc.release_section(new, "0.2.0"), section)

    def test_second_cut_of_the_same_version_is_refused(self):
        new, _ = rc.rewrite_changelog(CHANGELOG_FIXTURE, "0.2.0", "2026-09-22")
        with self.assertRaisesRegex(rc.CutError, "already exists"):
            rc.rewrite_changelog(new, "0.2.0", "2026-09-23")
        with self.assertRaisesRegex(rc.CutError, "no '- ' entry"):
            rc.rewrite_changelog(new, "0.2.1", "2026-09-23")

    def test_malformed_blocks_fail_closed(self):
        with self.assertRaisesRegex(rc.CutError, "exactly one"):
            rc.rewrite_changelog(CHANGELOG_FIXTURE.replace("## 0.1.0 — 2026-08-29", "## Unreleased"), "0.2.0", "d")
        with self.assertRaisesRegex(rc.CutError, "exactly one"):
            rc.rewrite_changelog(CHANGELOG_FIXTURE.replace("## Unreleased", "## unreleased"), "0.2.0", "d")
        with self.assertRaisesRegex(rc.CutError, "not one of"):
            rc.rewrite_changelog(CHANGELOG_FIXTURE.replace("### Changed", "### Misc"), "0.2.0", "d")
        with self.assertRaisesRegex(rc.CutError, "already exists"):
            rc.rewrite_changelog(CHANGELOG_FIXTURE, "0.1.0", "d")

    def test_reopen_restores_an_unreleased_block_once(self):
        released, _ = rc.rewrite_changelog(CHANGELOG_FIXTURE, "0.2.0", "2026-09-22")
        without = released.replace("## Unreleased\n\n", "", 1)
        self.assertNotIn("## Unreleased", without)
        restored = rc.ensure_unreleased(without)
        self.assertEqual(restored.splitlines().count("## Unreleased"), 1)
        self.assertEqual(rc.ensure_unreleased(restored), restored)

    def test_real_changelog_is_cuttable(self):
        text = (ROOT / rc.CHANGELOG).read_text(encoding="utf-8")
        new, section = rc.rewrite_changelog(text, "9.9.9", "2026-01-01")
        self.assertIn("## 9.9.9 — 2026-01-01", new)
        self.assertGreater(len(section.splitlines()), 3)

    def test_pr_body_lists_drivers_and_unknowns(self):
        body = rc.pr_body("0.2.0", "minor", "## 0.2.0 — d\n\n- x\n", {"minor": ["feat: a"], "patch": ["fix: b"]}, ["merge main"])
        for needle in ("Level: **minor**", "- feat: a", "- fix: b", "- merge main", "--reopen"):
            self.assertIn(needle, body)


def _git(*argv: str, cwd: Path) -> str:
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@x", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@x")
    return subprocess.run(["git", *argv], cwd=str(cwd), capture_output=True, text=True, check=True, env=env).stdout.strip()


def _commit(cwd: Path, subject: str) -> None:
    (cwd / "f.txt").write_text(subject + "\n", encoding="utf-8")
    _git("add", "f.txt", cwd=cwd)
    _git("commit", "-q", "-m", subject, cwd=cwd)


class ThrowawayRepoTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        _git("init", "-q", "-b", "main", cwd=self.root)
        (self.root / "build.zig.zon").write_text('.{ .version = "0.2.0-dev" }\n', encoding="utf-8")
        _git("add", "build.zig.zon", cwd=self.root)
        _git("commit", "-q", "-m", "chore: init", cwd=self.root)
        _git("tag", "0.1.0", cwd=self.root)

    def tearDown(self):
        self.tmp.cleanup()

    def _set_version(self, version: str, subject: str) -> None:
        (self.root / "build.zig.zon").write_text('.{ .version = "%s" }\n' % version, encoding="utf-8")
        _git("add", "build.zig.zon", cwd=self.root)
        _git("commit", "-q", "-m", subject, cwd=self.root)

    def test_version_state_gate(self):
        self.assertEqual(check_version_state.check(self.root, "main"), "")  # -dev: no-op
        self._set_version("0.2.0", "release: 0.2.0")
        self.assertIn("mid-flight", check_version_state.check(self.root, "main"))
        self.assertEqual(check_version_state.check(self.root, "release/0.2.0"), "")
        self.assertIn("mid-flight", check_version_state.check(self.root, "release/0.2.1"))
        _git("tag", "0.2.0", cwd=self.root)
        self.assertEqual(check_version_state.check(self.root, "main"), "")
        _commit(self.root, "fix: landed in the window")  # bare version, HEAD no longer the tagged commit
        self.assertIn("mid-flight", check_version_state.check(self.root, "main"))

    def test_commit_messages_and_merge_discipline(self):
        _git("checkout", "-q", "-b", "topic", cwd=self.root)
        _commit(self.root, "feat: topic work")
        _git("checkout", "-q", "main", cwd=self.root)
        _git("merge", "-q", "--no-ff", "-m", "Merge pull request #1", "topic", cwd=self.root)
        self.assertEqual(rc.last_tag(self.root), "0.1.0")
        messages = rc.commit_messages_since(self.root, "0.1.0")
        self.assertEqual([m.splitlines()[0] for m in messages], ["feat: topic work"])
        self.assertEqual(rc.first_parent_is_conventional(self.root, "0.1.0"), [])
        # a squash-style commit directly on the first-parent line is flagged
        _commit(self.root, "fix: squashed onto main")
        self.assertEqual(rc.first_parent_is_conventional(self.root, "0.1.0"), ["fix: squashed onto main"])


if __name__ == "__main__":
    unittest.main()
