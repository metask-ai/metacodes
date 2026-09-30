"""release_cut.py / check_version_state.py: the pure rules and the two git
probes, on fixtures and throwaway repositories (doc/RELEASE_AUTOMATION_DESIGN.md)."""
from __future__ import annotations

import contextlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import check_version_state  # noqa: E402
import release_cut as rc  # noqa: E402
import release_notes  # noqa: E402

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

    def test_real_changelog_has_the_shape_the_cut_parses(self):
        # Structural only: right after a cut the real Unreleased block is empty
        # by design, so cut eligibility is tested on the fixture, not here.
        lines = (ROOT / rc.CHANGELOG).read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines.count(rc.UNRELEASED), 1)
        releases = [l for l in lines if rc.RELEASE_HEADING_RE.match(l)]
        self.assertIn("## 0.1.0 — 2026-08-29", releases)
        self.assertLess(lines.index(rc.UNRELEASED), lines.index(releases[0]))
        start = lines.index(rc.UNRELEASED)
        end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("## "))
        for line in lines[start + 1:end]:
            if line.startswith("### "):
                self.assertIn(line[4:], rc.SUBSECTIONS, line)
        self.assertEqual(rc.release_section("\n".join(lines) + "\n", "0.1.0").splitlines()[0], "## 0.1.0 — 2026-08-29")

    def test_pr_body_lists_drivers_and_unknowns(self):
        body = rc.pr_body("0.2.0", "minor", "## 0.2.0 — d\n\n- x\n", {"minor": ["feat: a"], "patch": ["fix: b"]}, ["merge main"])
        for needle in ("Level: **minor**", "- feat: a", "- fix: b", "- merge main", "--reopen"):
            self.assertIn(needle, body)


def _section(entries: int, text: str = "fix number {i}, described at some length") -> str:
    return "## 0.2.0 — 2026-09-30\n\n### Fixed\n\n" + "".join(f"- {text.format(i=i)}.\n" for i in range(entries))


class BodyLimitTest(unittest.TestCase):
    """GitHub refuses a PR body over 65,536 characters and a release body over
    125,000; the 0.2.0 cut failed at `gh pr create` with a 90,841-character
    section. Bodies are fitted before anything is pushed."""

    DRIVERS = {"minor": ["feat: a"], "patch": ["fix: b"]}

    def test_a_body_under_the_limit_is_unchanged(self):
        # byte for byte what the cut produced before the limit existed
        body = rc.pr_body("0.2.0", "minor", "## 0.2.0 — d\n\n- x\n", self.DRIVERS, ["merge main"], ["fix: squashed"])
        self.assertEqual(
            body,
            "## 0.2.0 — d\n\n- x\n\n\n## Bump derivation\n\nLevel: **minor**\n\nminor:\n- feat: a\n\npatch:\n- fix: b\n\n"
            "Commits whose subject does not follow `type(scope): text` (contributed nothing to the level; raise it by hand if one of them is a feature or a breaking change):\n- merge main\n\n"
            "Squash/rebase-merged PRs (only the squash subject was classified; their inner commit types are not visible):\n- fix: squashed\n\n"
            "Merging this PR is the decision to release; `release-tag.yml` tags the merge commit and starts `release.yml`. Then run `python3 scripts/release_cut.py --reopen`.\n",
        )

    def test_an_oversized_section_gives_way_to_a_pointer(self):
        section = _section(2000)
        self.assertGreater(rc.body_size(section), rc.PR_BODY_LIMIT)
        body = rc.pr_body("0.2.0", "minor", section, self.DRIVERS, ["merge main"])
        self.assertLessEqual(rc.body_size(body), rc.PR_BODY_LIMIT)
        self.assertTrue(body.startswith("## 0.2.0 — 2026-09-30\n\nThis section is 2004 lines"))
        self.assertNotIn("fix number 0,", body)
        for needle in ("`CHANGELOG.md` diff", "`scripts/release_notes.py 0.2.0`", "Level: **minor**", "- feat: a", "- fix: b", "- merge main", "--reopen`."):
            self.assertIn(needle, body)
        self.assertNotIn("- … and", body)  # the derivation fits once the section is gone

    def test_oversized_derivation_lists_keep_their_first_entries_and_count_the_rest(self):
        patch = [f"fix(area): change number {i} with a subject of ordinary length" for i in range(3000)]
        unknown = [f"merge main {i}" for i in range(500)]
        body = rc.pr_body("0.2.0", "patch", _section(2000), {"patch": patch}, unknown, ["fix: squashed"])
        self.assertLessEqual(rc.body_size(body), rc.PR_BODY_LIMIT)
        self.assertIn("Level: **patch**", body)
        self.assertTrue(body.endswith("Then run `python3 scripts/release_cut.py --reopen`.\n"))
        shown = [line for line in body.splitlines() if line.startswith("- fix(area): ")]
        self.assertEqual(shown[0], "- " + patch[0])  # the first entries, in order
        self.assertEqual(shown, ["- " + s for s in patch[: len(shown)]])
        counts = [int(n) for n in re.findall(r"^- … and (\d+) more$", body, re.M)]
        self.assertIn(3000 - len(shown), counts)
        self.assertIn("- fix: squashed", body)  # a short list is not cut
        # the cap is the most that fits: one more entry per list would not
        pointer = rc.section_pointer("0.2.0", _section(2000))
        longer = rc._pr_body("patch", pointer, {"patch": patch}, unknown, ["fix: squashed"], len(shown) + 1)
        self.assertGreater(rc.body_size(longer), rc.PR_BODY_LIMIT)

    def test_the_limit_counts_utf8_bytes(self):
        # 30,000 characters but 90,000 bytes: under GitHub's character count,
        # yet never trusted to be, so the section still gives way
        section = "## 0.2.0 — 2026-09-30\n\n- " + "修" * 30000 + "\n"
        self.assertLess(len(section), rc.PR_BODY_LIMIT)
        body = rc.pr_body("0.2.0", "minor", section, self.DRIVERS, [])
        self.assertNotIn("修", body)
        self.assertLessEqual(rc.body_size(body), rc.PR_BODY_LIMIT)

    def test_release_notes_stop_after_the_last_whole_entry_that_fits(self):
        section = _section(40, "entry {i}\n  continued on a second line")
        self.assertEqual(release_notes.fit_notes(section, "0.2.0", limit=10_000), section)
        notes = release_notes.fit_notes(section, "0.2.0", limit=1_000)
        self.assertLessEqual(rc.body_size(notes), 1_000)
        kept, _, tail = notes.partition("\n_The notes stop here: ")
        self.assertTrue(kept.startswith("## 0.2.0 — 2026-09-30\n"))
        self.assertTrue(kept.rstrip("\n").endswith("  continued on a second line."), kept[-80:])  # a whole entry
        dropped = int(tail.split(" ", 1)[0])
        self.assertEqual(len(kept.splitlines()) + dropped, len(section.rstrip("\n").splitlines()))
        self.assertIn("`share/doc/CHANGELOG-0.2.0.md`", tail)
        # the real limit leaves a section of today's size alone
        self.assertEqual(release_notes.fit_notes(_section(2000), "0.2.0"), _section(2000))


LOCAL: dict = {}  # the maintainer's checkout: no GitHub Actions environment


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
        self.assertEqual(check_version_state.check(self.root, "main", LOCAL), "")  # -dev: no-op
        self._set_version("0.2.0", "release: 0.2.0")
        self.assertIn("mid-flight", check_version_state.check(self.root, "main", LOCAL))
        self.assertEqual(check_version_state.check(self.root, "release/0.2.0", LOCAL), "")
        self.assertIn("mid-flight", check_version_state.check(self.root, "release/0.2.1", LOCAL))
        # the release PR's own merge commit on main is accepted before the tag exists
        _git("checkout", "-q", "-b", "release/0.2.0", cwd=self.root)
        _commit(self.root, "release: 0.2.0")
        _git("checkout", "-q", "main", cwd=self.root)
        _git("merge", "-q", "--no-ff", "-m", "Merge pull request #7 from metask-ai/release/0.2.0", "release/0.2.0", cwd=self.root)
        self.assertEqual(check_version_state.check(self.root, "main", LOCAL), "")
        _git("tag", "0.2.0", cwd=self.root)
        self.assertEqual(check_version_state.check(self.root, "main", LOCAL), "")
        _commit(self.root, "fix: landed in the window")  # bare version, HEAD no longer the tagged commit
        self.assertIn("mid-flight", check_version_state.check(self.root, "main", LOCAL))

    def test_ci_release_pr_exception_needs_title_and_label(self):
        _git("checkout", "-q", "-b", "release/0.2.0", cwd=self.root)
        self._set_version("0.2.0", "release: 0.2.0")
        ci = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request"}
        self.assertFalse(check_version_state.rehearsable(self.root, "0.2.0", "release/0.2.0", ci))
        self.assertFalse(check_version_state.rehearsable(self.root, "0.2.0", "release/0.2.0", dict(ci, RELEASE_PR_TITLE="release: 0.2.0")))
        self.assertFalse(check_version_state.rehearsable(self.root, "0.2.0", "release/0.2.0", dict(ci, RELEASE_PR_TITLE="release: 0.2.0", RELEASE_PR_LABELS="bug")))
        self.assertTrue(check_version_state.rehearsable(self.root, "0.2.0", "release/0.2.0", dict(ci, RELEASE_PR_TITLE="release: 0.2.0", RELEASE_PR_LABELS="bug,release")))
        self.assertTrue(check_version_state.rehearsable(self.root, "0.2.0", "release/0.2.0", {}))  # maintainer checkout
        # the merge-subject exception only on push runs
        _git("checkout", "-q", "main", cwd=self.root)
        _git("merge", "-q", "--no-ff", "-m", "Merge pull request #7 from metask-ai/release/0.2.0", "release/0.2.0", cwd=self.root)
        self.assertTrue(check_version_state.rehearsable(self.root, "0.2.0", "main", {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "push"}))
        self.assertFalse(check_version_state.rehearsable(self.root, "0.2.0", "feature/x", {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request"}))
        self.assertFalse(check_version_state.rehearsable(self.root, "0.2.0", "main", {"GITHUB_ACTIONS": "true"}))  # no event name: not a push
        # end to end through check(): the CI environment must not leak into a fixture
        ci_ok = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request", "RELEASE_PR_TITLE": "release: 0.2.0", "RELEASE_PR_LABELS": "release"}
        _git("checkout", "-q", "release/0.2.0", cwd=self.root)
        self.assertEqual(check_version_state.check(self.root, "release/0.2.0", ci_ok), "")
        self.assertIn("mid-flight", check_version_state.check(self.root, "release/0.2.0", {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "pull_request"}))

    def test_rehearsal_tags_only_the_legitimate_states_locally(self):
        self.assertIn("no rehearsal needed", check_version_state.rehearse(self.root, "main", LOCAL))
        _git("checkout", "-q", "-b", "release/0.2.0", cwd=self.root)
        self._set_version("0.2.0", "release: 0.2.0")
        self.assertIn("tagged HEAD as 0.2.0 locally", check_version_state.rehearse(self.root, "release/0.2.0", LOCAL))
        self.assertEqual(_git("describe", "--tags", "--exact-match", "HEAD", cwd=self.root), "0.2.0")
        self.assertIn("already carries", check_version_state.rehearse(self.root, "release/0.2.0", LOCAL))
        _git("tag", "-d", "0.2.0", cwd=self.root)
        _commit(self.root, "fix: unrelated on a bare version")
        self.assertEqual(check_version_state.rehearse(self.root, "some/other-branch", LOCAL), "")

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


class OpenPrFailureTest(unittest.TestCase):
    """open_pr against a local bare `origin`, with `gh` replaced: whatever
    fails, the checkout ends on main, and the error says whether the branch
    was already pushed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.origin = base / "origin.git"
        self.root = base / "clone"
        _git("init", "-q", "--bare", "-b", "main", str(self.origin), cwd=base)
        _git("init", "-q", "-b", "main", str(self.root), cwd=base)
        _git("config", "user.name", "t", cwd=self.root)
        _git("config", "user.email", "t@x", cwd=self.root)
        for rel in (rc.ZON, rc.VERSION_ZIG, rc.CHANGELOG, rc.PROTOCOL):
            (self.root / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.root / rel).write_text("0.2.0-dev\n", encoding="utf-8")
        _git("add", "-A", cwd=self.root)
        _git("commit", "-q", "-m", "chore: init", cwd=self.root)
        _git("remote", "add", "origin", str(self.origin), cwd=self.root)
        _git("push", "-q", "origin", "main", cwd=self.root)
        (self.root / rc.ZON).write_text("0.2.0\n", encoding="utf-8")  # what the cut generated

    def tearDown(self):
        self.tmp.cleanup()

    @contextlib.contextmanager
    def gh_refuses_the_body(self):
        real_run = rc.run

        def run(argv, cwd, check=True):
            if argv[0] == "gh":
                raise rc.CutError(f"{' '.join(argv[:3])} failed (1): GraphQL: Body is too long (maximum is 65536 characters)")
            return real_run(argv, cwd, check)

        with mock.patch.object(rc, "open_release_prs", return_value=[]), mock.patch.object(rc, "branch_was_merged", return_value=False), mock.patch.object(rc, "run", side_effect=run):
            yield

    def test_a_failure_after_the_push_says_so_and_ends_on_main(self):
        with self.gh_refuses_the_body(), self.assertRaises(rc.CutError) as caught:
            rc.open_pr(self.root, "release/0.2.0", "release: 0.2.0", "body\n", "release", dry_run=False)
        self.assertIn("Body is too long", str(caught.exception))
        self.assertIn("release/0.2.0 is already pushed", str(caught.exception))
        self.assertEqual(_git("rev-parse", "--abbrev-ref", "HEAD", cwd=self.root), "main")
        self.assertEqual(_git("status", "--porcelain", "--untracked-files=no", cwd=self.root), "")
        self.assertEqual(_git("rev-parse", "release/0.2.0", cwd=self.origin), _git("rev-parse", "release/0.2.0", cwd=self.root))

    def test_a_failure_before_the_push_ends_on_main_and_claims_no_push(self):
        _git("remote", "set-url", "origin", str(self.origin) + "-missing", cwd=self.root)
        with self.gh_refuses_the_body(), self.assertRaises(rc.CutError) as caught:
            rc.open_pr(self.root, "release/0.2.0", "release: 0.2.0", "body\n", "release", dry_run=False)
        self.assertIn("git push", str(caught.exception))
        self.assertNotIn("already pushed", str(caught.exception))
        self.assertEqual(_git("rev-parse", "--abbrev-ref", "HEAD", cwd=self.root), "main")

    def test_an_oversized_body_is_refused_before_any_command(self):
        with mock.patch.object(rc, "run", side_effect=AssertionError("no command may run")), self.assertRaisesRegex(rc.CutError, "nothing was pushed"):
            rc.open_pr(self.root, "release/0.2.0", "release: 0.2.0", "x" * (rc.PR_BODY_LIMIT + 1), "release", dry_run=False)
        self.assertEqual(_git("rev-parse", "--abbrev-ref", "HEAD", cwd=self.root), "main")


# A stand-in for `gh api` with GitHub's answers for one repository and gh's
# error behaviour: the error body on stdout, the status on stderr, exit 1.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_GH_STATE"], encoding="utf-8"))
argv = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(argv) + "\n")
assert argv[0] == "api", argv
path, rest, fields, jq = argv[1], argv[2:], {}, None
while rest:
    flag, value, rest = rest[0], rest[1], rest[2:]
    if flag == "-f":
        key, _, val = value.partition("=")
        fields[key] = val
    elif flag == "--jq":
        jq = value
    else:
        sys.exit("unexpected flag " + flag)
assert path.startswith("repos/o/r/"), path
path = path[len("repos/o/r/"):]
tag = state["tag"]  # None or {"name", "type": "tag"|"commit", "sha", "peeled"}

def not_found():
    print(json.dumps({"message": "Not Found", "status": "404"}))
    print("gh: Not Found (HTTP 404)", file=sys.stderr)
    sys.exit(1)

if path.startswith("git/matching-refs/tags/"):
    name = path[len("git/matching-refs/tags/"):]
    assert jq == '.[] | select(.ref == "refs/tags/%s") | "\\(.object.type) \\(.object.sha)"' % name, jq
    if tag and tag["name"] == name:
        print(tag["type"] + " " + tag["sha"])
elif path.startswith("git/ref/tags/"):
    if not tag or path != "git/ref/tags/" + tag["name"]:
        not_found()
    print(tag["sha"] if jq == ".object.sha" else tag["type"])
elif path.startswith("git/tags/"):
    if not tag or path != "git/tags/" + tag["sha"]:
        not_found()
    print(tag["peeled"])
elif path == "git/tags":
    print("f" * 40)
elif path != "git/refs":
    sys.exit("unexpected path " + path)
'''


@unittest.skipIf(os.name == "nt", "POSIX executable fixture")
class ReleaseTagStepTest(unittest.TestCase):
    """release-tag.yml's tag step, run by bash against the fake gh. The 0.2.0
    run read the 404 body of a single-ref lookup as an existing tag and
    failed before creating any."""

    MERGE = "a" * 40
    STEP = "Create the annotated tag at the merge commit (fail on a mismatched existing tag)"

    def run_step(self, tag):
        try:
            import yaml
        except ImportError:  # requirements-dev.txt
            self.skipTest("PyYAML is not installed")
        workflow = yaml.safe_load((ROOT / ".github/workflows/release-tag.yml").read_text(encoding="utf-8"))
        script = next(s["run"] for s in workflow["jobs"]["tag"]["steps"] if s.get("name") == self.STEP)
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            (bindir / "gh").write_text(FAKE_GH, encoding="utf-8")
            (bindir / "gh").chmod(0o755)
            (Path(tmp) / "state.json").write_text(json.dumps({"tag": tag}), encoding="utf-8")
            env = dict(os.environ, PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}", FAKE_GH_STATE=str(Path(tmp) / "state.json"),
                       FAKE_GH_LOG=str(Path(tmp) / "calls.jsonl"), GITHUB_REPOSITORY="o/r", VERSION="0.2.0", MERGE_SHA=self.MERGE)
            proc = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
            log = Path(tmp) / "calls.jsonl"
            calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []
        writes = [c[1] for c in calls if "-f" in c]
        return proc, writes

    def test_an_absent_tag_is_created_at_the_merge_commit(self):
        proc, writes = self.run_step(None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(f"created tag 0.2.0 -> {self.MERGE}", proc.stdout)
        self.assertEqual(writes, ["repos/o/r/git/tags", "repos/o/r/git/refs"])

    def test_a_tag_already_at_the_merge_commit_is_accepted(self):
        proc, writes = self.run_step({"name": "0.2.0", "type": "tag", "sha": "b" * 40, "peeled": self.MERGE})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("already points at", proc.stdout)
        self.assertEqual(writes, [])

    def test_a_tag_elsewhere_is_refused(self):
        proc, writes = self.run_step({"name": "0.2.0", "type": "commit", "sha": "c" * 40, "peeled": None})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("refusing", proc.stderr)
        self.assertEqual(writes, [])


if __name__ == "__main__":
    unittest.main()
