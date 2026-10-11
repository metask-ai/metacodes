"""Unit tests for scripts/release_fast_path.py (CI release fast path)."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release_cut as rc  # noqa: E402
import release_fast_path as fp  # noqa: E402

CHANGELOG = """# Changelog

## Unreleased

### Added

- a feature.

## 0.4.0 — 2026-10-10

### Added

- an older feature.
"""


def fake_repin(tree: Path) -> None:
    """Stand-in for the fingerprint repin: a digest of every non-protocol file,
    so any content the candidate smuggles in changes it."""
    digest = hashlib.sha256()
    for path in sorted(p for p in tree.rglob("*") if p.is_file() and ".git" not in p.parts):
        rel = path.relative_to(tree).as_posix()
        if rel != rc.PROTOCOL:
            digest.update(rel.encode() + b"\0" + path.read_bytes())
    protocol = tree / rc.PROTOCOL
    protocol.write_text(json.dumps({"implementation_fingerprint": digest.hexdigest()}) + "\n", encoding="utf-8")


def git(cwd: Path, *argv: str) -> str:
    proc = subprocess.run(["git", *argv], cwd=str(cwd), capture_output=True, text=True, check=True)
    return proc.stdout.strip()


class Repo:
    """A repository whose HEAD is a `-dev` (or released) base; candidates are
    commits on top of it, built the way release_cut would or tampered."""

    def __init__(self, tmp: Path, version: str = "0.4.1-dev", changelog: str = CHANGELOG):
        self.root = tmp
        git(tmp, "init", "-q", "-b", "main")
        git(tmp, "config", "user.email", "test@metacodes.local")
        git(tmp, "config", "user.name", "metacodes-test")
        (tmp / "src").mkdir()
        (tmp / "evals" / "plugin-v1").mkdir(parents=True)
        (tmp / rc.ZON).write_text(f'.{{\n    .name = .metacodes,\n    .version = "{version}",\n}}\n', encoding="utf-8")
        (tmp / rc.VERSION_ZIG).write_text(f'pub const semver = "{version}";\n', encoding="utf-8")
        (tmp / rc.CHANGELOG).write_text(changelog, encoding="utf-8")
        (tmp / "src" / "main.zig").write_text("pub fn main() void {}\n", encoding="utf-8")
        fake_repin(tmp)
        self.commit("base")
        self.base = git(tmp, "rev-parse", "HEAD")

    def commit(self, message: str) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", message)
        return git(self.root, "rev-parse", "HEAD")

    def cut(self, version: str = "0.5.0", date: str = "2026-10-11") -> None:
        rc.apply_version(self.root, version)
        text = rc.read(self.root, rc.CHANGELOG)
        rc.write(self.root, rc.CHANGELOG, rc.rewrite_changelog(text, version, date)[0])
        fake_repin(self.root)


class VerifyBumpTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def verify(self, candidate: str):
        return fp.verify_bump(self.repo.root, self.repo.base, candidate, fake_repin)

    def test_a_generated_cut_is_a_bump(self) -> None:
        self.repo.cut()
        candidate = self.repo.commit("release: 0.5.0")
        self.assertEqual(("cut", "0.5.0"), self.verify(candidate))
        # The scratch worktree is gone again.
        self.assertNotIn("base", git(self.repo.root, "worktree", "list"))

    def test_a_generated_reopen_is_a_bump(self) -> None:
        self.repo.cut()
        released = self.repo.commit("release: 0.5.0")
        rc.apply_version(self.repo.root, "0.5.1-dev")
        rc.write(self.repo.root, rc.CHANGELOG, rc.ensure_unreleased(rc.read(self.repo.root, rc.CHANGELOG)))
        fake_repin(self.repo.root)
        reopen = self.repo.commit("chore: reopen 0.5.1-dev")
        self.assertEqual(("reopen", "0.5.1-dev"), fp.verify_bump(self.repo.root, released, reopen, fake_repin))

    def test_any_other_file_takes_the_full_path(self) -> None:
        self.repo.cut()
        (self.repo.root / "src" / "main.zig").write_text("pub fn main() void { unreachable; }\n", encoding="utf-8")
        candidate = self.repo.commit("release: 0.5.0 plus code")
        with self.assertRaisesRegex(fp.NotABump, "src/main.zig"):
            self.verify(candidate)

    def test_an_edited_changelog_takes_the_full_path(self) -> None:
        self.repo.cut()
        text = rc.read(self.repo.root, rc.CHANGELOG).replace("- a feature.", "- a feature, reworded.")
        rc.write(self.repo.root, rc.CHANGELOG, text)
        candidate = self.repo.commit("release: 0.5.0 with an edited section")
        with self.assertRaisesRegex(fp.NotABump, "CHANGELOG.md differs"):
            self.verify(candidate)

    def test_a_hand_edited_fingerprint_takes_the_full_path(self) -> None:
        self.repo.cut()
        (self.repo.root / rc.PROTOCOL).write_text(json.dumps({"implementation_fingerprint": "0" * 64}) + "\n", encoding="utf-8")
        candidate = self.repo.commit("release: 0.5.0 with a forged pin")
        with self.assertRaisesRegex(fp.NotABump, "protocol.json differs"):
            self.verify(candidate)

    def test_a_version_change_that_is_neither_cut_nor_reopen_takes_the_full_path(self) -> None:
        rc.apply_version(self.repo.root, "0.6.0-dev")
        candidate = self.repo.commit("chore: jump the floor")
        with self.assertRaisesRegex(fp.NotABump, "neither a cut nor a reopen"):
            self.verify(candidate)

    def test_an_ordinary_change_takes_the_full_path(self) -> None:
        (self.repo.root / "src" / "main.zig").write_text("// changed\n", encoding="utf-8")
        candidate = self.repo.commit("fix: something")
        with self.assertRaisesRegex(fp.NotABump, "does not generate"):
            self.verify(candidate)

    def test_an_empty_candidate_takes_the_full_path(self) -> None:
        with self.assertRaisesRegex(fp.NotABump, "changes nothing"):
            self.verify(self.repo.base)


class DecideTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))
        self.repo.cut()
        self.candidate = self.repo.commit("release: 0.5.0")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def decide(self, states, wait_seconds: float = 60):
        queried = []
        clock = [0.0]

        def query(sha: str) -> str:
            queried.append(sha)
            return states[min(len(queried), len(states)) - 1]

        def sleep(seconds: float) -> None:
            clock[0] += seconds

        result = fp.decide(self.repo.root, self.repo.base, self.candidate, query, wait_seconds, sleep, lambda: clock[0], fake_repin)
        return result, queried

    def test_a_bump_over_a_green_base_is_fast(self) -> None:
        (fast, reason), queried = self.decide(["success"])
        self.assertTrue(fast, reason)
        self.assertEqual([self.repo.base], queried)
        self.assertIn("cut to 0.5.0", reason)

    def test_a_running_base_is_waited_for(self) -> None:
        (fast, reason), queried = self.decide(["pending", "pending", "success"])
        self.assertTrue(fast, reason)
        self.assertEqual(3, len(queried))

    def test_a_base_that_stays_pending_takes_the_full_path(self) -> None:
        (fast, reason), queried = self.decide(["pending"], wait_seconds=60)
        self.assertFalse(fast)
        self.assertIn("is pending", reason)
        self.assertEqual(3, len(queried))  # t=0, t=30, t=60

    def test_a_red_base_takes_the_full_path(self) -> None:
        (fast, reason), _ = self.decide(["failure"])
        self.assertFalse(fast)
        self.assertIn("is failure", reason)

    def test_a_non_bump_never_asks_for_the_base(self) -> None:
        (self.repo.root / "src" / "main.zig").write_text("// changed\n", encoding="utf-8")
        self.candidate = self.repo.commit("fix: something")
        (fast, reason), queried = self.decide(["success"])
        self.assertFalse(fast)
        self.assertEqual([], queried)


class MainTest(unittest.TestCase):
    def test_an_error_is_reported_as_the_full_path_and_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            code = fp.main(["--base", "nope", "--candidate", "nope", "--repository", "o/r", "--repo-root", tmp, "--github-output", str(output)])
            self.assertEqual(0, code)
            text = output.read_text(encoding="utf-8")
            self.assertIn("fast=false\n", text)
            self.assertIn("reason=full path:", text)


if __name__ == "__main__":
    unittest.main()
