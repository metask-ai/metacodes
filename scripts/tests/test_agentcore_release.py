"""AgentCore's release rules (doc/RELEASE_AUTOMATION_DESIGN.md §2a): each refusal
here fails if its check is removed. Fixtures are throwaway repositories and
archives; no release is cut and nothing is pushed.
"""
from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import agentcore_contract as contract  # noqa: E402
import agentcore_release as release  # noqa: E402
import check_version_state  # noqa: E402
import release_archive  # noqa: E402
import release_common as common  # noqa: E402
import release_cut as rc  # noqa: E402
import release_notes  # noqa: E402
import release_sums  # noqa: E402

build_wheel = release.load_build_wheel()
DIGEST = "a" * 64
CHANGES = """# AgentCore changelog

## Unreleased

### Added

- a Host-visible feature.
"""
TARGET = "riscv64-linux-gnu"  # no host can load it, so nothing tries to
TAG = "manylinux_2_28_riscv64"


def git(cwd: Path, *argv: str) -> str:
    return subprocess.run(["git", *argv], cwd=str(cwd), capture_output=True, text=True, check=True).stdout.strip()


def write_tree(root: Path, version: str = "0.13.0-dev", revision: int = 26, main_version: str = "0.10.0-dev") -> None:
    files = {
        contract.SDK_VERSION: f"{version}\n",
        contract.PY_PROJECT: f'[project]\nname = "metacodes"\nversion = "{contract.python_version(version)}"\n',
        contract.PY_INIT: f'__version__ = "{contract.python_version(version)}"\n',
        contract.NODE_PACKAGE: json.dumps({"name": "metacodes", "version": contract.node_version(version)}, indent=2) + "\n",
        contract.SDK_CHANGELOG: CHANGES,
        contract.LEDGER: contract.dump_ledger(contract.Ledger()),
        contract.ABI_AUTHORITY: f"pub const ABI_VERSION_V1: u32 = 1;\npub const ABI_REVISION: u32 = {revision};\n",
        "sdk/metask/agentcore.h": f"#define METASK_AGENTCORE_ABI_REVISION {revision}u\n",
        "sdk/rust/src/raw.rs": f"pub const METASK_AGENTCORE_ABI_REVISION: u32 = {revision};\n",
        "sdk/python/src/metacodes/_native.py": f"ABI_REVISION = {revision}\n",
        "sdk/python/README.md": "# metacodes\n",
        "sdk/node/index.js": f"const ABI_REVISION = {revision};\n",
        "LICENSE": "MIT\n",
        "src/lib.zig": "pub const x = 1;\n",
        common.VERSION_ZIG: f'pub const semver = "{main_version}";\n',
        common.ZON: f'.{{\n    .version = "{main_version}",\n}}\n',
        "doc/note.md": "not an input\n",
    }
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))


def set_revision(root: Path, revision: int, only: str = "") -> None:
    """The ABI bump a change like #408 makes: every mirror, or just one."""
    for rel, pattern in contract.ABI_MIRRORS.items():
        if only and rel != only:
            continue
        path = root / rel
        text = path.read_text(encoding="utf-8")
        match = pattern.search(text)
        start, end = match.span(1)
        path.write_text(text[:start] + str(revision) + text[end:], encoding="utf-8")


class Tree(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "repo"
        self.root.mkdir()
        write_tree(self.root)
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.email", "test@metacodes.local")
        git(self.root, "config", "user.name", "metacodes-test")
        self.commit("chore: init")
        self.addCleanup(self._tmp.cleanup)

    def commit(self, message: str) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", message)
        return git(self.root, "rev-parse", "HEAD")

    def release_built(self, version: str = "0.13.0", main: str = "0.10.0") -> None:
        """A cut, its commit and tag, then the reopen: the state of `main` after
        a real release."""
        release.apply_cut(self.root, version, main, "2026-11-01")
        self.commit(f"release: {main}")
        git(self.root, "tag", main)
        release.apply_reopen(self.root, release.reopen_target(self.root))
        self.commit(f"chore: reopen after {main}")

    def change_input(self, text: str = "pub const x = 2;\n") -> None:
        (self.root / "src" / "lib.zig").write_text(text, encoding="utf-8")
        changes = (self.root / contract.SDK_CHANGELOG).read_text(encoding="utf-8")
        (self.root / contract.SDK_CHANGELOG).write_text(changes + "\n### Fixed\n\n- a fix.\n", encoding="utf-8")


class VersionMappingTest(unittest.TestCase):
    def test_a_release_is_itself_in_every_ecosystem(self) -> None:
        self.assertEqual(contract.python_version("0.13.0"), "0.13.0")
        self.assertEqual(contract.node_version("0.13.0"), "0.13.0")
        self.assertEqual(contract.python_version("0.13.0-dev"), "0.13.0.dev0")
        self.assertEqual(contract.node_version("0.13.0-dev"), "0.13.0-dev.0")

    def test_other_shapes_are_not_agentcore_versions(self) -> None:
        for bad in ("0.13", "0.13.0-rc.1", "0.13.0+abc", "v0.13.0", "00.1.0"):
            with self.subTest(bad), self.assertRaises(common.CutError):
                contract.parse(bad)
        for bad in ("0.13.0-rc.1", "0.13.0-dev", "0.13.0+0123456789ab", "0.13.0-dev+short"):
            with self.subTest(bad), self.assertRaises(common.CutError):
                contract.base_of_built(bad)
        self.assertEqual(contract.base_of_built("0.13.0"), ("0.13.0", False))
        self.assertEqual(contract.base_of_built("0.13.0-dev+0123456789ab.dirty"), ("0.13.0", True))


class LedgerTest(unittest.TestCase):
    def entry(self, version="0.13.0", revision=26, digest=DIGEST, mains=("0.10.0",)) -> contract.Release:
        return contract.Release(version, 1, revision, digest, mains)

    def test_a_round_trip(self) -> None:
        ledger = contract.Ledger((self.entry(), self.entry("0.14.0", 27, "b" * 64, ("0.11.0", "0.11.1"))))
        self.assertEqual(contract.parse_ledger(contract.dump_ledger(ledger)), ledger)
        self.assertEqual(ledger.by_main_release("0.11.1").version, "0.14.0")
        self.assertEqual(ledger.by_version("0.14.0").built_by, "0.11.0")

    def test_the_real_ledger_is_valid(self) -> None:
        contract.load_ledger(ROOT)

    def test_refusals(self) -> None:
        cases = (
            ((self.entry("0.13.0-dev"),), "not a final"),
            ((self.entry("0.13.0+abc"),), "not a final"),
            ((self.entry(digest="short"),), "input digest"),
            ((self.entry(revision=0),), "ABI version and revision"),
            ((self.entry(mains=()),), "names no main-project"),
            ((self.entry(mains=("0.10.0-dev",)),), "not a final"),
            ((self.entry(), self.entry("0.13.0", digest="b" * 64, mains=("0.11.0",))), "does not follow"),
            ((self.entry(), self.entry("0.13.1", digest=DIGEST, mains=("0.11.0",))), "unchanged AgentCore keeps its version"),
            ((self.entry(), self.entry("0.13.1", digest="b" * 64, mains=("0.10.0",))), "out of order"),
            ((self.entry(revision=27), self.entry("0.14.0", 26, "b" * 64, ("0.11.0",))), "lowers the ABI revision"),
            ((self.entry(), self.entry("0.13.1", 27, "b" * 64, ("0.11.0",))), "needs at least a minor"),
        )
        for releases, message in cases:
            with self.subTest(message), self.assertRaisesRegex(common.CutError, message):
                contract.validated(contract.Ledger(releases))

    def test_a_malformed_file_is_refused(self) -> None:
        for text in ("not json", "[]", '{"schema": "other", "releases": []}', json.dumps({"schema": contract.LEDGER_SCHEMA, "releases": [{"version": "0.13.0"}]})):
            with self.subTest(text), self.assertRaises(common.CutError):
                contract.parse_ledger(text)

    def test_released_entries_only_grow(self) -> None:
        older = contract.Ledger((self.entry(),))
        self.assertIsNone(contract.is_prefix_of(older, older))
        self.assertIsNone(contract.is_prefix_of(older, older.carrying(older.latest, "0.10.1")))
        self.assertIsNone(contract.is_prefix_of(older, older.appended(self.entry("0.14.0", 26, "b" * 64, ("0.11.0",)))))
        self.assertIn("dropped", contract.is_prefix_of(older, contract.Ledger()))
        self.assertIn("changed", contract.is_prefix_of(older, contract.Ledger((self.entry(revision=27),))))
        self.assertIn("changed", contract.is_prefix_of(older, contract.Ledger((self.entry(mains=("0.10.1",)),))))


class InputDigestTest(Tree):
    def test_version_churn_and_documents_are_not_inputs(self) -> None:
        before = release.input_digest(self.root)
        contract.set_sdk_version(self.root, "0.13.0")
        rc.apply_version(self.root, "0.10.0")
        (self.root / contract.SDK_CHANGELOG).write_text("# changed\n", encoding="utf-8")
        (self.root / contract.LEDGER).write_text(contract.dump_ledger(contract.Ledger()) + "\n", encoding="utf-8")
        (self.root / "doc" / "note.md").write_text("changed\n", encoding="utf-8")
        self.assertEqual(release.input_digest(self.root), before)

    def test_inputs_are(self) -> None:
        before = release.input_digest(self.root)
        for rel in ("src/lib.zig", contract.ABI_AUTHORITY, contract.PY_INIT, "LICENSE"):
            original = (self.root / rel).read_bytes()
            (self.root / rel).write_bytes(original + b"// changed\n")
            self.assertNotEqual(release.input_digest(self.root), before, rel)
            (self.root / rel).write_bytes(original)
        project = (self.root / contract.PY_PROJECT).read_bytes()
        (self.root / contract.PY_PROJECT).write_bytes(project.replace(b"metacodes", b"other"))
        self.assertNotEqual(release.input_digest(self.root), before, "the package apart from its version line")

    def test_only_tracked_files_count_and_line_endings_do_not(self) -> None:
        before = release.input_digest(self.root)
        (self.root / "sdk" / "node" / "prebuilds").mkdir()
        (self.root / "sdk" / "node" / "prebuilds" / "x.node").write_bytes(b"built")
        self.assertEqual(release.input_digest(self.root), before)
        path = self.root / "src" / "lib.zig"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(release.input_digest(self.root), before)

    def test_no_repository_is_a_refusal(self) -> None:
        with tempfile.TemporaryDirectory() as empty, self.assertRaisesRegex(common.CutError, "tracked files"):
            release.input_digest(Path(empty))

    def test_the_real_tree_has_a_digest(self) -> None:
        paths = release.input_paths(ROOT)
        for expected in ("src/agentcore/abi_v1.zig", "sdk/metask/agentcore.h", "sdk/zig/types.zig", "scripts/agentcore_manifest.zig", "build.zig"):
            self.assertIn(expected, paths)
        for version_record in (contract.SDK_VERSION, contract.LEDGER, contract.SDK_CHANGELOG, common.VERSION_ZIG):
            self.assertNotIn(version_record, paths)


class PlanTest(Tree):
    def test_the_first_release_is_the_floor(self) -> None:
        plan = release.plan_cut(self.root)
        self.assertEqual((plan.kind, plan.version, plan.abi_revision), ("built", "0.13.0", 26))

    def test_unchanged_keeps_the_version(self) -> None:
        self.release_built()
        plan = release.plan_cut(self.root)
        self.assertEqual((plan.kind, plan.version), ("reused", "0.13.0"))
        with self.assertRaisesRegex(common.CutError, "keeps that version"):
            release.plan_cut(self.root, "minor", True)

    def test_a_fix_is_a_patch_and_a_feature_or_break_a_minor(self) -> None:
        self.release_built()
        self.change_input()
        for messages, expected in (
            (["fix: x"], "0.13.1"),
            (["chore: no type explains it"], "0.13.1"),
            ([], "0.13.1"),
            (["feat: x"], "0.14.0"),
            (["fix!: x"], "0.14.0"),
            (["fix: x\n\nBREAKING CHANGE: y"], "0.14.0"),
        ):
            with self.subTest(messages):
                self.assertEqual(release.plan_cut(self.root, messages=lambda _: messages).version, expected)

    def test_the_commits_are_asked_for_since_the_release_that_built_it(self) -> None:
        self.release_built()
        self.change_input()
        asked = []
        release.plan_cut(self.root, messages=lambda tag: asked.append(tag) or [])
        self.assertEqual(asked, ["0.10.0"])

    def test_a_raised_floor_holds(self) -> None:
        self.release_built()
        self.change_input()
        contract.set_sdk_version(self.root, "0.20.0-dev")
        self.assertEqual(release.plan_cut(self.root).version, "0.20.0")

    def test_a_level_below_the_derived_one_needs_force(self) -> None:
        self.release_built()
        self.change_input()
        with self.assertRaisesRegex(common.CutError, "below the derived"):
            release.plan_cut(self.root, "patch", messages=lambda _: ["feat: x"])
        self.assertEqual(release.plan_cut(self.root, "patch", True, messages=lambda _: ["feat: x"]).version, "0.13.1")
        self.assertEqual(release.plan_cut(self.root, "minor").version, "0.14.0")

    def test_a_mid_flight_tree_is_refused(self) -> None:
        contract.set_sdk_version(self.root, "0.13.0")
        with self.assertRaisesRegex(common.CutError, "without -dev"):
            release.plan_cut(self.root)


class AbiBumpTest(Tree):
    """How a later ABI bump is handled: a change on `main` bumps the revision and
    nothing here needs editing. The state gate takes it, the cut raises the
    version and records the new mapping, and a partial bump is refused."""

    def bump(self) -> None:
        self.release_built()
        set_revision(self.root, 27)

    def test_the_state_gate_accepts_a_whole_bump_on_main(self) -> None:
        self.bump()
        self.assertEqual(release.state_findings(self.root, "0.10.1-dev", "0.10.0"), [])

    def test_a_partial_bump_is_a_finding_for_every_mirror(self) -> None:
        self.release_built()
        for rel in contract.ABI_MIRRORS:
            if rel == contract.ABI_AUTHORITY:
                continue
            with self.subTest(rel):
                set_revision(self.root, 27, only=rel)
                self.assertIn("ABI revision mismatch", " ".join(release.state_findings(self.root, "0.10.1-dev", "0.10.0")))
                set_revision(self.root, 26, only=rel)

    def test_a_reworded_declaration_cannot_drop_out(self) -> None:
        (self.root / "sdk" / "node" / "index.js").write_text("export const ABI_REVISION = 26;\n", encoding="utf-8")
        with self.assertRaisesRegex(common.CutError, "no longer declares"):
            contract.abi_revision(self.root)

    def test_the_cut_raises_the_version_even_for_a_fix(self) -> None:
        self.bump()
        plan = release.plan_cut(self.root, messages=lambda _: ["fix: x"])
        self.assertEqual((plan.version, plan.abi_revision), ("0.14.0", 27))
        with self.assertRaisesRegex(common.CutError, "below the derived"):
            release.plan_cut(self.root, "patch", messages=lambda _: ["fix: x"])

    def test_the_cut_records_the_new_mapping_and_needs_migration(self) -> None:
        self.bump()
        (self.root / contract.SDK_CHANGELOG).write_text(CHANGES, encoding="utf-8")
        with self.assertRaisesRegex(common.CutError, "### Migration"):
            release.apply_cut(self.root, "0.14.0", "0.11.0", "2026-11-02")
        (self.root / contract.SDK_CHANGELOG).write_text(CHANGES + "\n### Migration\n\n- rebuild against 27.\n", encoding="utf-8")
        with self.assertRaisesRegex(common.CutError, "needs at least a minor"):
            release.apply_cut(self.root, "0.13.1", "0.11.0", "2026-11-02")
        self.assertEqual(release.apply_cut(self.root, "0.14.0", "0.11.0", "2026-11-02"), "built")
        latest = contract.load_ledger(self.root).latest
        self.assertEqual((latest.version, latest.abi_revision), ("0.14.0", 27))
        self.assertEqual(contract.load_ledger(self.root).by_version("0.13.0").abi_revision, 26)

    def test_a_ledger_that_misses_the_bump_is_refused_at_release(self) -> None:
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        set_revision(self.root, 27)
        findings = " ".join(release.state_findings(self.root, "0.10.0", None))
        self.assertIn("maps AgentCore 0.13.0 to ABI revision 26", findings)


class ApplyCutTest(Tree):
    def test_finalizing_reaches_every_package(self) -> None:
        self.assertEqual(release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01"), "built")
        self.assertEqual(contract.sdk_version(self.root), "0.13.0")
        self.assertEqual(contract.package_version_findings(self.root), [])
        self.assertIn('version = "0.13.0"', common.read(self.root, contract.PY_PROJECT))
        self.assertIn('__version__ = "0.13.0"', common.read(self.root, contract.PY_INIT))
        self.assertEqual(json.loads(common.read(self.root, contract.NODE_PACKAGE))["version"], "0.13.0")
        self.assertIn("## 0.13.0 — 2026-11-01", common.read(self.root, contract.SDK_CHANGELOG))
        entry = contract.load_ledger(self.root).latest
        self.assertEqual((entry.version, entry.abi_version, entry.abi_revision, entry.main_releases), ("0.13.0", 1, 26, ("0.10.0",)))
        self.assertEqual(entry.input_digest, release.input_digest(self.root))

    def test_a_development_or_hashed_version_is_refused(self) -> None:
        for bad in ("0.13.0-dev", "0.13.0+0123456789ab", "0.13.0-dev+0123456789ab"):
            with self.subTest(bad), self.assertRaisesRegex(common.CutError, "final"):
                release.apply_cut(self.root, bad, "0.10.0", "2026-11-01")

    def test_a_version_below_the_floor_is_refused(self) -> None:
        with self.assertRaisesRegex(common.CutError, "below"):
            release.apply_cut(self.root, "0.12.0", "0.10.0", "2026-11-01")

    def test_an_empty_changelog_is_refused(self) -> None:
        (self.root / contract.SDK_CHANGELOG).write_text("# x\n\n## Unreleased\n", encoding="utf-8")
        with self.assertRaisesRegex(common.CutError, "a release needs release notes"):
            release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")

    def test_unchanged_inputs_may_not_take_a_new_version(self) -> None:
        self.release_built()
        with self.assertRaisesRegex(common.CutError, "keeps that version"):
            release.apply_cut(self.root, "0.13.1", "0.10.1", "2026-11-02")

    def test_changed_inputs_may_not_keep_the_version(self) -> None:
        self.release_built()
        self.change_input()
        with self.assertRaisesRegex(common.CutError, "already released"):
            release.apply_cut(self.root, "0.13.0", "0.10.1", "2026-11-02")

    def test_a_reuse_adds_the_main_release_and_leaves_the_notes(self) -> None:
        self.release_built()
        before = common.read(self.root, contract.SDK_CHANGELOG)
        self.assertEqual(release.apply_cut(self.root, "0.13.0", "0.10.1", "2026-11-02"), "reused")
        self.assertEqual(contract.load_ledger(self.root).latest.main_releases, ("0.10.0", "0.10.1"))
        self.assertEqual(contract.sdk_version(self.root), "0.13.0")
        self.assertEqual(common.read(self.root, contract.SDK_CHANGELOG), before)

    def test_a_mid_flight_tree_is_refused(self) -> None:
        contract.set_sdk_version(self.root, "0.13.0")
        with self.assertRaisesRegex(common.CutError, "without -dev"):
            release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")

    def test_the_reopen_is_the_next_dev_of_the_release(self) -> None:
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        self.assertEqual(release.reopen_target(self.root), "0.13.1-dev")
        self.assertEqual(release.reopen_target(self.root, "minor"), "0.14.0-dev")
        with self.assertRaisesRegex(common.CutError, "reopens at"):
            release.apply_reopen(self.root, "0.15.0-dev")
        release.apply_reopen(self.root, "0.13.1-dev")
        self.assertEqual(contract.sdk_version(self.root), "0.13.1-dev")
        self.assertEqual(contract.package_version_findings(self.root), [])
        with self.assertRaisesRegex(common.CutError, "nothing to reopen"):
            release.apply_reopen(self.root, "0.13.1-dev")


class StateGateTest(Tree):
    def test_the_real_tree_passes(self) -> None:
        self.assertEqual(check_version_state.check_agentcore(ROOT), [])

    def test_a_clean_development_tree_passes(self) -> None:
        self.assertEqual(release.state_findings(self.root, "0.10.0-dev", None), [])

    def test_package_metadata_must_follow_sdk_version(self) -> None:
        for rel, old, new in (
            (contract.PY_PROJECT, "0.13.0.dev0", "0.12.0"),
            (contract.PY_INIT, "0.13.0.dev0", "0.13.0"),
            (contract.NODE_PACKAGE, "0.13.0-dev.0", "0.13.0-dev"),
        ):
            with self.subTest(rel):
                text = common.read(self.root, rel)
                common.write(self.root, rel, text.replace(old, new))
                self.assertIn(rel, " ".join(release.state_findings(self.root, "0.10.0-dev", None)))
                common.write(self.root, rel, text)

    def test_agentcore_moves_with_the_main_project(self) -> None:
        self.assertIn("finalized and reopened", " ".join(release.state_findings(self.root, "0.10.0", None)))
        contract.set_sdk_version(self.root, "0.13.0")
        self.assertIn("finalized and reopened", " ".join(release.state_findings(self.root, "0.10.0-dev", None)))

    def test_the_floor_is_above_the_release(self) -> None:
        self.release_built()
        contract.set_sdk_version(self.root, "0.13.0-dev")
        self.assertIn("not above", " ".join(release.state_findings(self.root, "0.10.1-dev", "0.10.0")))

    def test_a_release_commit_must_be_in_the_ledger(self) -> None:
        contract.set_sdk_version(self.root, "0.13.0")
        self.assertIn("does not say which", " ".join(release.state_findings(self.root, "0.10.0", None)))

    def test_a_release_commit_must_match_its_entry(self) -> None:
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        self.assertEqual(release.state_findings(self.root, "0.10.0", None), [])
        (self.root / "src" / "lib.zig").write_text("// changed after the cut\n", encoding="utf-8")
        self.assertIn("inputs differ", " ".join(release.state_findings(self.root, "0.10.0", None)))

    def test_a_rewritten_ledger_is_caught_against_the_last_tag(self) -> None:
        self.release_built()
        ledger = contract.load_ledger(self.root)
        forged = contract.Ledger((contract.Release("0.13.0", 1, 26, "b" * 64, ("0.10.0",)),))
        self.assertNotEqual(ledger, forged)
        common.write(self.root, contract.LEDGER, contract.dump_ledger(forged))
        self.assertIn("immutable", " ".join(release.state_findings(self.root, "0.10.1-dev", "0.10.0")))

    def test_a_tag_older_than_the_ledger_is_not_a_finding(self) -> None:
        git(self.root, "tag", "0.9.0", "HEAD")
        (self.root / contract.LEDGER).unlink()
        self.commit("chore: at a tag without a ledger")
        git(self.root, "tag", "0.9.1")
        write_tree(self.root)
        self.commit("chore: ledger")
        self.assertEqual(release.state_findings(self.root, "0.10.0-dev", "0.9.1"), [])


class BundleContentsTest(unittest.TestCase):
    def bundle(self, **fixture) -> tuple:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = release_archive._sdk_fixture(Path(tmp.name), "linux", TARGET, **fixture)
        return path, json.loads((path / "manifest.json").read_text(encoding="utf-8"))

    def check(self, **fixture) -> None:
        path, manifest = self.bundle(**fixture)
        contract.check_bundle_contents(manifest, lambda rel: (path / rel).read_bytes())

    def test_a_consistent_bundle_passes(self) -> None:
        self.check()
        self.check(version="0.13.0")

    def test_each_member_that_disagrees_is_refused(self) -> None:
        cases = (
            ("include/metask/agentcore.h", "#define METASK_AGENTCORE_ABI_REVISION 25u\n", "ABI revision mismatch"),
            ("bindings/zig/src/types.zig", "pub const ABI_REVISION: u32 = 25;\n", "ABI revision mismatch"),
            ("bindings/rust/src/raw.rs", "pub const METASK_AGENTCORE_ABI_REVISION: u32 = 25;\n", "ABI revision mismatch"),
            ("bindings/zig/build.zig.zon", '.{\n    .version = "9.9.9",\n}\n', "version mismatch"),
            ("bindings/rust/Cargo.toml", '[package]\nversion = "9.9.9"\n', "version mismatch"),
            ("bindings/rust/Cargo.lock", 'version = "9.9.9"\n', "version mismatch"),
            ("README.md", "# metask-agentcore 9.9.9\n\nRevision 26 x.\n", "does not name version"),
            # The stale delivery document the issue names.
            ("README.md", "# metask-agentcore 0.1.0-dev+0123456789ab\n\nRevision 18 exposes one 64-byte root.\n", "describes ABI revision"),
            ("README.md", "# metask-agentcore 0.1.0-dev+0123456789ab\n\nNo revision stated.\n", "describes ABI revision"),
        )
        for rel, text, message in cases:
            with self.subTest(rel=rel, message=message), self.assertRaisesRegex(common.CutError, message):
                self.check(overrides={rel: text})

    def test_crlf_members_from_a_windows_checkout_pass(self) -> None:
        self.check(overrides={"include/metask/agentcore.h": "// header\r\n#define METASK_AGENTCORE_ABI_REVISION 26u\r\n"})

    def test_a_bad_version_shape_is_refused(self) -> None:
        with self.assertRaisesRegex(common.CutError, "neither a final"):
            self.check(version="0.13.0-rc.1")

    def test_a_development_version_must_name_its_commit(self) -> None:
        with self.assertRaisesRegex(common.CutError, "does not name its source commit"):
            self.check(commit="f" * 40)

    def test_an_unpinned_library_is_refused(self) -> None:
        path, manifest = self.bundle()
        manifest["files"] = [f for f in manifest["files"] if not f["path"].startswith("lib/")]
        with self.assertRaisesRegex(common.CutError, "not pinned"):
            contract.check_bundle_contents(manifest, lambda rel: (path / rel).read_bytes())

    def test_the_archive_refuses_an_inconsistent_bundle(self) -> None:
        path, _ = self.bundle(overrides={"bindings/zig/src/types.zig": "pub const ABI_REVISION: u32 = 25;\n"})
        with tempfile.TemporaryDirectory() as out, self.assertRaisesRegex(ValueError, "ABI revision mismatch"):
            release_archive.write_archive(path, Path(out), "agentcore", None)


class PackageInputsTest(Tree):
    """The issue's case: the wheel's version comes from the checkout and its
    library from a supplied bundle."""

    def setUp(self) -> None:
        super().setUp()
        self.out = Path(self._tmp.name) / "out"
        self.head = git(self.root, "rev-parse", "HEAD")
        self.bundles = Path(self._tmp.name) / "bundles"

    def dev_bundle(self, base: str = "0.13.0", commit: str = "", revision: int = 26, **fixture) -> Path:
        commit = commit or self.head
        self.bundles.mkdir(exist_ok=True)
        where = Path(tempfile.mkdtemp(dir=self.bundles))
        return release_archive._sdk_fixture(where, "linux", TARGET, version=f"{base}-dev+{commit[:12]}", commit=commit, revision=revision, architecture="riscv64", **fixture)

    def stable_bundle(self, version: str = "0.13.0", revision: int = 26) -> Path:
        self.bundles.mkdir(exist_ok=True)
        where = Path(tempfile.mkdtemp(dir=self.bundles))
        return release_archive._sdk_fixture(where, "linux", TARGET, version=version, commit=self.head, revision=revision, architecture="riscv64")

    def build(self, bundle: Path, formal: bool = False) -> Path:
        return build_wheel.build(bundle, self.out, "", formal=formal, root=self.root)

    def test_a_matching_bundle_builds_and_the_wheel_carries_its_version(self) -> None:
        wheel = self.build(self.dev_bundle())
        self.assertEqual(wheel.name, f"metacodes-0.13.0.dev0-py3-none-{TAG}.whl")
        members = release.read_archive(wheel)
        self.assertIn("\nVersion: 0.13.0.dev0\n", members["metacodes-0.13.0.dev0.dist-info/METADATA"].decode("utf-8"))

    def test_a_bundle_of_another_version_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "the bundle is AgentCore 0.12.0"):
            self.build(self.dev_bundle("0.12.0"))

    def test_a_release_bundle_in_a_development_checkout_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "this checkout is 0.13.0-dev"):
            self.build(self.stable_bundle())

    def test_a_bundle_of_another_abi_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "implements ABI revision 25"):
            self.build(self.dev_bundle(revision=25))

    def test_a_bundle_of_another_commit_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "was built from"):
            self.build(self.dev_bundle(commit="f" * 40))

    def test_a_tampered_library_is_refused(self) -> None:
        bundle = self.dev_bundle()
        (bundle / "lib" / "libmetask_agentcore.so").write_bytes(b"another library")
        with self.assertRaisesRegex(SystemExit, "SHA-256 mismatch"):
            self.build(bundle)

    def test_a_formal_package_refuses_a_development_bundle(self) -> None:
        with self.assertRaisesRegex(SystemExit, "cannot go into a formal release"):
            self.build(self.dev_bundle(), formal=True)

    def test_a_release_bundle_needs_its_ledger_entry_and_its_inputs(self) -> None:
        contract.set_sdk_version(self.root, "0.13.0")
        with self.assertRaisesRegex(SystemExit, "has no AgentCore 0.13.0"):
            self.build(self.stable_bundle(), formal=True)
        contract.set_sdk_version(self.root, "0.13.0-dev")
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        self.assertEqual(self.build(self.stable_bundle(), formal=True).name, f"metacodes-0.13.0-py3-none-{TAG}.whl")
        (self.root / "src" / "lib.zig").write_text("// another source\n", encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "not the source"):
            self.build(self.stable_bundle(), formal=True)

    def test_the_library_itself_must_report_the_revision(self) -> None:
        bundle = self.dev_bundle()
        with self.assertRaisesRegex(common.CutError, "reports ABI v1 revision 25"):
            release.verify_package_inputs(bundle, self.root, probe=lambda _: (1, 25))
        release.verify_package_inputs(bundle, self.root, probe=lambda _: (1, 26))

    def test_a_host_that_can_run_the_target_must_load_it(self) -> None:
        bundle = self.dev_bundle()
        with mock.patch.object(release, "host_runs", return_value=True), self.assertRaises(OSError):
            release.verify_package_inputs(bundle, self.root)  # the fixture is not a library

    def test_host_runs_compares_the_machine(self) -> None:
        self.assertFalse(release.host_runs({"architecture": "riscv64", "os": "linux"}))
        with mock.patch("platform.machine", return_value="arm64"), mock.patch("platform.system", return_value="Darwin"):
            self.assertTrue(release.host_runs({"architecture": "aarch64", "os": "macos"}))
            self.assertFalse(release.host_runs({"architecture": "x86_64", "os": "macos"}))


@unittest.skipIf(shutil.which("node") is None, "node is not installed")
class NodeBundleTest(unittest.TestCase):
    """sdk/node/scripts/verify_bundle.js, as build.js calls it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.package = Path(self._tmp.name) / "package"
        self.package.mkdir()
        self.declare("0.13.0-dev.0", 26)

    def declare(self, version: str, revision: int) -> None:
        (self.package / "package.json").write_text(json.dumps({"version": version}), encoding="utf-8")
        (self.package / "index.js").write_text(f"const ABI_REVISION = {revision};\n", encoding="utf-8")

    def verify(self, bundle: Path, release_flag: bool = False) -> subprocess.CompletedProcess:
        script = (
            "const { verifyBundle } = require(process.argv[1]);"
            "verifyBundle(process.argv[2], { release: process.argv[3] === 'release', packageRoot: process.argv[4] });"
        )
        return subprocess.run(
            ["node", "-e", script, str(ROOT / "sdk" / "node" / "scripts" / "verify_bundle.js"), str(bundle), "release" if release_flag else "dev", str(self.package)],
            capture_output=True,
            text=True,
        )

    def bundle(self, **fixture) -> Path:
        return release_archive._sdk_fixture(Path(tempfile.mkdtemp(dir=self._tmp.name)), "linux", TARGET, **fixture)

    def test_a_matching_bundle_passes(self) -> None:
        self.assertEqual(self.verify(self.bundle(version="0.13.0-dev+0123456789ab")).returncode, 0)
        self.declare("0.13.0", 26)
        proc = self.verify(self.bundle(version="0.13.0"), release_flag=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_refusals(self) -> None:
        proc = self.verify(self.bundle(version="0.12.0-dev+0123456789ab"))
        self.assertIn("package.json says 0.13.0-dev.0", proc.stderr)
        proc = self.verify(self.bundle(version="0.13.0-dev+0123456789ab", revision=25))
        self.assertIn("implements ABI revision 25", proc.stderr)
        proc = self.verify(self.bundle(version="0.13.0-dev+0123456789ab"), release_flag=True)
        self.assertIn("cannot go into a formal release", proc.stderr)
        tampered = self.bundle(version="0.13.0-dev+0123456789ab")
        (tampered / "lib" / "libmetask_agentcore.so").write_bytes(b"another")
        self.assertIn("not the file its manifest pins", self.verify(tampered).stderr)


def wheel_fixture(dist: Path, version: str, library: bytes, tag: str = TAG, revision: int = 26, metadata_version: str = "", init_version: str = "", wheel_tag: str = "") -> Path:
    py = contract.python_version(version)
    path = dist / f"metacodes-{py}-py3-none-{tag}.whl"
    import zipfile

    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("metacodes/__init__.py", f'__version__ = "{init_version or py}"\n')
        archive.writestr("metacodes/_native.py", f"ABI_REVISION = {revision}\n")
        archive.writestr("metacodes/_lib/libmetask_agentcore.so", library)
        archive.writestr(f"metacodes-{py}.dist-info/METADATA", f"Name: metacodes\nVersion: {metadata_version or py}\n\nreadme\n")
        archive.writestr(f"metacodes-{py}.dist-info/WHEEL", f"Wheel-Version: 1.0\nTag: py3-none-{wheel_tag or tag}\n")
    return path


def node_fixture(dist: Path, version: str, library: bytes, target: str = TARGET, revision: int = 26, declared: str = "") -> Path:
    path = dist / release.node_package_name(version, target)
    with tarfile.open(path, "w:gz") as archive:
        for name, data in (
            ("package/package.json", json.dumps({"version": declared or contract.node_version(version)}).encode()),
            ("package/index.js", f"const ABI_REVISION = {revision};\n".encode()),
            ("package/prebuilds/linux-riscv64/libmetask_agentcore.so", library),
        ):
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return path


class DoorTest(Tree):
    """verify_dist over a real release directory, then one defect at a time."""

    def setUp(self) -> None:
        super().setUp()
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        rc.apply_version(self.root, "0.10.0")
        self.head = self.commit("release: 0.10.0")
        git(self.root, "tag", "0.10.0")
        self.dist = Path(self._tmp.name) / "dist"
        self.dist.mkdir()
        self.library = self.make_sdk()
        wheel_fixture(self.dist, "0.13.0", self.library)
        node_fixture(self.dist, "0.13.0", self.library)
        self.make_unit()

    def make_sdk(self, version: str = "0.13.0", target: str = TARGET, **fixture) -> bytes:
        options = {"commit": self.head, "architecture": "riscv64"}
        options.update(fixture)
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        bundle = release_archive._sdk_fixture(where, "linux", target, version=version, **options)
        facts = release_archive.GitFacts(head_tag="0.10.0", head_commit=options["commit"], agentcore_built_by="0.10.0")
        release_archive.write_archive(bundle, self.dist, "agentcore", facts)
        return (bundle / "lib" / "libmetask_agentcore.so").read_bytes()

    def make_unit(self, revision: int = 26) -> None:
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        bundle = release_archive._cli_fixture(where, "linux", TARGET, "0.10.0", "stable")
        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        manifest["contract"] = {"binary_abi_revision": revision}
        (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        release_archive.write_archive(bundle, self.dist, "cli", release_archive.GitFacts(head_tag="0.10.0"))

    def replace_sdk(self, **fixture) -> None:
        for path in self.dist.glob("metask-agentcore-*"):
            path.unlink()
        self.make_sdk(**fixture)

    def findings(self, published=(), root=None) -> str:
        return "\n".join(
            release.verify_dist(
                root or self.root,
                self.dist,
                "0.10.0",
                lambda tag: self.head if tag == "0.10.0" else None,
                published,
                platform_tag=lambda target: TAG,
            )
        )

    def test_a_consistent_release_passes(self) -> None:
        self.assertEqual(self.findings(), "")

    def test_a_development_agentcore_archive_is_refused(self) -> None:
        for path in self.dist.glob("metask-agentcore-*"):
            path.unlink()
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        version = f"0.13.0-dev+{self.head[:12]}"
        bundle = release_archive._sdk_fixture(where, "linux", TARGET, version=version, commit=self.head, architecture="riscv64")
        release_archive.write_archive(bundle, self.dist, "agentcore", None)
        found = self.findings()
        self.assertIn("carries a development version or a commit hash", found)
        self.assertIn("the ledger says AgentCore 0.13.0", found)

    def test_a_development_wheel_is_refused(self) -> None:
        wheel_fixture(self.dist, "0.13.0-dev", self.library)
        self.assertIn(".dev0", self.findings())

    def test_a_development_main_version_is_refused(self) -> None:
        found = release.verify_dist(self.root, self.dist, "0.10.0-dev", lambda tag: self.head)
        self.assertIn("not a final", " ".join(found))

    def test_a_main_release_the_ledger_does_not_name_is_refused(self) -> None:
        found = release.verify_dist(self.root, self.dist, "0.10.1", lambda tag: self.head)
        self.assertIn("does not say which AgentCore", " ".join(found))

    def test_an_archive_of_another_abi_is_refused(self) -> None:
        self.replace_sdk(revision=25)
        self.assertIn("implements ABI v1 revision 25", self.findings())

    def test_an_archive_of_another_version_is_refused(self) -> None:
        self.replace_sdk(version="0.13.1")
        self.assertIn("the ledger says AgentCore 0.13.0", self.findings())

    def test_an_archive_from_another_commit_is_refused(self) -> None:
        self.replace_sdk(commit="f" * 40)
        self.assertIn("is built by 0.10.0", self.findings())

    def test_an_inconsistent_archive_is_refused(self) -> None:
        # The archive step refuses this too, so it reaches the door by hand.
        for path in self.dist.glob("metask-agentcore-*"):
            path.unlink()
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        bundle = release_archive._sdk_fixture(where, "linux", TARGET, version="0.13.0", commit=self.head, architecture="riscv64", overrides={"README.md": "# metask-agentcore 0.13.0\n\nRevision 18 is old.\n"})
        manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
        members = [(bundle / item["path"], item["path"]) for item in manifest["files"]] + [(bundle / "manifest.json", "manifest.json")]
        release_archive.write_immutable(self.dist, f"metask-agentcore-0.13.0-{TARGET}", members, as_zip=False)
        self.assertIn("describes ABI revision [18]", self.findings())

    def test_a_tampered_archive_member_is_refused(self) -> None:
        archive = next(self.dist.glob("metask-agentcore-*.tar.gz"))
        members = release.read_archive(archive)
        name = f"metask-agentcore-0.13.0-{TARGET}/lib/libmetask_agentcore.so"
        members[name] = b"another library"
        with tarfile.open(archive, "w:gz") as out:
            for key, data in members.items():
                info = tarfile.TarInfo(key)
                info.size = len(data)
                out.addfile(info, io.BytesIO(data))
        self.assertIn("is not the file its manifest pins", self.findings())

    def test_a_dirty_archive_is_refused(self) -> None:
        archive = next(self.dist.glob("metask-agentcore-*.tar.gz"))
        members = release.read_archive(archive)
        name = f"metask-agentcore-0.13.0-{TARGET}/manifest.json"
        manifest = json.loads(members[name])
        manifest["source"]["dirty"] = True
        members[name] = json.dumps(manifest).encode()
        with tarfile.open(archive, "w:gz") as out:
            for key, data in members.items():
                info = tarfile.TarInfo(key)
                info.size = len(data)
                out.addfile(info, io.BytesIO(data))
        self.assertIn("dirty tree", self.findings())

    def test_no_agentcore_archive_is_refused(self) -> None:
        for path in self.dist.glob("metask-agentcore-*"):
            path.unlink()
        found = self.findings()
        self.assertIn("has no AgentCore archive", found)
        self.assertIn("no AgentCore archive for riscv64-linux-gnu", found)

    def test_a_wheel_around_another_library_is_refused(self) -> None:
        wheel_fixture(self.dist, "0.13.0", b"another library")
        self.assertIn("not the one in the AgentCore archive", self.findings())

    def test_a_wheel_of_another_abi_is_refused(self) -> None:
        wheel_fixture(self.dist, "0.13.0", self.library, revision=25)
        self.assertIn("the binding speaks ABI revision", self.findings())

    def test_inconsistent_wheel_metadata_is_refused(self) -> None:
        wheel_fixture(self.dist, "0.13.0", self.library, metadata_version="0.12.0")
        self.assertIn("METADATA does not say", self.findings())
        wheel_fixture(self.dist, "0.13.0", self.library, init_version="0.12.0")
        self.assertIn("__version__ is not", self.findings())
        wheel_fixture(self.dist, "0.13.0", self.library, wheel_tag="other")
        self.assertIn("WHEEL does not carry", self.findings())

    def test_a_wheel_for_no_archive_is_refused(self) -> None:
        wheel_fixture(self.dist, "0.13.0", self.library, tag="win_amd64", wheel_tag="win_amd64")
        self.assertIn("no AgentCore archive in this release for platform tag win_amd64", self.findings())

    def test_a_missing_wheel_is_refused(self) -> None:
        next(self.dist.glob("*.whl")).unlink()
        self.assertIn(f"no Python wheel for {TAG}", self.findings())

    def test_a_node_package_that_disagrees_is_refused(self) -> None:
        node_fixture(self.dist, "0.13.0", self.library, declared="0.12.0")
        self.assertIn("package.json says 0.12.0", self.findings())
        node_fixture(self.dist, "0.13.0", self.library, revision=25)
        self.assertIn("the binding speaks ABI revision", self.findings())
        node_fixture(self.dist, "0.13.0", b"another library")
        self.assertIn("not the one in the AgentCore archive", self.findings())

    def test_a_missing_node_package_is_refused_except_on_windows(self) -> None:
        next(self.dist.glob("metacodes-node-*")).unlink()
        self.assertIn(f"no Node package for {TARGET}", self.findings())

    def test_a_unit_of_another_abi_is_refused(self) -> None:
        for path in self.dist.glob("metacodes-0.10.0-*"):
            path.unlink()
        self.make_unit(revision=25)
        self.assertIn("states ABI revision 25", self.findings())

    def test_a_tree_that_left_the_entry_is_refused(self) -> None:
        (self.root / "src" / "lib.zig").write_text("// changed\n", encoding="utf-8")
        self.assertIn("inputs differ", self.findings())
        (self.root / "src" / "lib.zig").write_text("pub const x = 1;\n", encoding="utf-8")
        contract.set_sdk_version(self.root, "0.13.1")
        self.assertIn(contract.SDK_VERSION, self.findings())

    def published(self, entries: dict) -> Path:
        path = Path(self._tmp.name) / "metacodes-0.9.0-SHA256SUMS"
        path.write_text("".join(f"{digest}  {name}\n" for name, digest in entries.items()), encoding="ascii")
        return path

    def test_a_conflict_with_a_published_artifact_is_refused(self) -> None:
        archive = next(self.dist.glob("metask-agentcore-*.tar.gz"))
        same = self.published({archive.name: release_archive.sha256_file(archive)})
        self.assertEqual(self.findings([same]), "")
        other = self.published({archive.name: "0" * 64})
        self.assertIn("never replaced", self.findings([other]))
        wheel = next(self.dist.glob("*.whl"))
        self.assertIn(wheel.name, self.findings([self.published({wheel.name: "0" * 64})]))

    def test_published_history_that_already_conflicts_stops_the_release(self) -> None:
        one = self.published({"x.tar.gz": "0" * 64})
        two = Path(self._tmp.name) / "metacodes-0.9.1-SHA256SUMS"
        two.write_text(f"{'1' * 64}  x.tar.gz\n", encoding="ascii")
        with self.assertRaisesRegex(common.CutError, "already differs"):
            self.findings([one, two])

    def test_malformed_sums_are_refused(self) -> None:
        for text in ("garbage\n", f"{'0' * 63}  x\n", f"{'0' * 64}  x\n{'1' * 64}  x\n"):
            with self.subTest(text), self.assertRaisesRegex(common.CutError, "malformed"):
                release.parse_sums(text)


class ReuseTest(Tree):
    def setUp(self) -> None:
        super().setUp()
        self.release_built()
        self.source = Path(self._tmp.name) / "published"
        self.source.mkdir()
        self.library = b"library"
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        bundle = release_archive._sdk_fixture(where, "linux", TARGET, version="0.13.0", commit="f" * 40, architecture="riscv64", overrides={"lib/libmetask_agentcore.so": "library"})
        facts = release_archive.GitFacts(head_tag="0.10.0", head_commit="f" * 40, agentcore_built_by="0.10.0")
        release_archive.write_archive(bundle, self.source, "agentcore", facts)
        wheel_fixture(self.source, "0.13.0", self.library, tag=build_wheel.platform_tag({"architecture": "riscv64", "os": "linux", "abi": "gnu", "zig_target": TARGET}))
        node_fixture(self.source, "0.13.0", self.library)
        for sidecar in self.source.glob("*.sha256"):
            sidecar.unlink()
        for path in list(self.source.iterdir()):
            release.write_sidecar(path)
        release_sums.write_sums(self.source, "0.10.0", self.source)
        release.apply_cut(self.root, "0.13.0", "0.10.1", "2026-11-02")
        self.dist = Path(self._tmp.name) / "dist"
        self.asked = []

    def download(self, tag: str, name: str, directory: Path) -> None:
        self.asked.append((tag, name))
        shutil.copyfile(self.source / name, Path(directory) / name)

    def test_the_mode_names_the_release_that_built_it(self) -> None:
        self.assertEqual(release.release_mode(self.root, "0.10.1"), "0.10.0")
        self.assertEqual(release.release_mode(self.root, "0.10.0"), "")
        self.assertEqual(release.release_mode(self.root, "0.11.0-dev"), "")
        with self.assertRaisesRegex(common.CutError, "does not say which"):
            release.release_mode(self.root, "0.11.0")

    def test_every_artifact_comes_from_that_release_with_its_digest(self) -> None:
        made = release.fetch_reused(self.root, "0.10.1", TARGET, self.dist, self.download)
        self.assertEqual({tag for tag, _ in self.asked}, {"0.10.0"})
        self.assertEqual(len(made), 3)
        for path in made:
            self.assertEqual(path.read_bytes(), (self.source / path.name).read_bytes())
            self.assertTrue((self.dist / (path.name + ".sha256")).is_file())

    def test_a_reused_release_passes_the_door_and_a_rebuild_does_not(self) -> None:
        release.fetch_reused(self.root, "0.10.1", TARGET, self.dist, self.download)
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        unit = release_archive._cli_fixture(where, "linux", TARGET, "0.10.1", "stable")
        manifest = json.loads((unit / "manifest.json").read_text(encoding="utf-8"))
        manifest["contract"] = {"binary_abi_revision": 26}
        (unit / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        release_archive.write_archive(unit, self.dist, "cli", release_archive.GitFacts(head_tag="0.10.1"))
        published = self.source / "metacodes-0.10.0-SHA256SUMS"
        commit_of = lambda tag: "f" * 40 if tag == "0.10.0" else None  # noqa: E731
        tag_of = lambda target: build_wheel.platform_tag(target)  # noqa: E731
        self.assertEqual(release.verify_dist(self.root, self.dist, "0.10.1", commit_of, [published], platform_tag=tag_of), [])
        # A rebuild under the same version: other bytes, whatever its manifest says.
        wheel = next(self.dist.glob("*.whl"))
        wheel.write_bytes(wheel.read_bytes() + b"\0")
        found = " ".join(release.verify_dist(self.root, self.dist, "0.10.1", commit_of, [published], platform_tag=tag_of))
        self.assertIn("never replaced", found)

    def test_a_build_on_the_reusing_release_is_refused_at_the_archive(self) -> None:
        where = Path(tempfile.mkdtemp(dir=self._tmp.name))
        bundle = release_archive._sdk_fixture(where, "linux", TARGET, version="0.13.0", commit="e" * 40, architecture="riscv64")
        facts = release_archive.GitFacts(head_tag="0.10.1", head_commit="e" * 40, agentcore_built_by="0.10.0")
        with self.assertRaisesRegex(ValueError, "reuse them"):
            release_archive.write_archive(bundle, self.dist, "agentcore", facts)

    def test_a_changed_download_is_refused_and_removed(self) -> None:
        def corrupt(tag, name, directory):
            self.download(tag, name, directory)
            if name.startswith("metask-agentcore-"):
                (Path(directory) / name).write_bytes(b"other")

        with self.assertRaisesRegex(common.CutError, "is not the file its SHA256SUMS names"):
            release.fetch_reused(self.root, "0.10.1", TARGET, self.dist, corrupt)
        self.assertFalse(list(self.dist.glob("metask-agentcore-*")))

    def test_a_missing_artifact_is_refused(self) -> None:
        with self.assertRaisesRegex(common.CutError, "has no metask-agentcore-0.13.0-x86_64-linux-gnu"):
            release.fetch_reused(self.root, "0.10.1", "x86_64-linux-gnu", self.dist, self.download)

    def test_a_missing_node_package_is_refused(self) -> None:
        sums = self.source / "metacodes-0.10.0-SHA256SUMS"
        lines = [line for line in sums.read_text(encoding="ascii").splitlines() if "metacodes-node" not in line]
        sums.write_text("\n".join(lines) + "\n", encoding="ascii")
        with self.assertRaisesRegex(common.CutError, "has no metacodes-node-"):
            release.fetch_reused(self.root, "0.10.1", TARGET, self.dist, self.download)

    def test_a_release_that_builds_has_nothing_to_fetch(self) -> None:
        with self.assertRaisesRegex(common.CutError, "does not reuse"):
            release.fetch_reused(self.root, "0.10.0", TARGET, self.dist, self.download)


class PublishedSumsTest(unittest.TestCase):
    def test_drafts_this_release_and_early_releases_are_skipped(self) -> None:
        listing = [
            {"tagName": "0.10.0", "isDraft": True},
            {"tagName": "0.9.0", "isDraft": False},
            {"tagName": "0.8.0", "isDraft": True},
            {"tagName": "0.1.0", "isDraft": False},
        ]
        assets = {"0.9.0": ["metacodes-0.9.0-SHA256SUMS", "x"], "0.1.0": ["other"]}

        def query(argv):
            return listing if argv[1] == "list" else {"assets": [{"name": name} for name in assets[argv[2]]]}

        downloaded = []
        with tempfile.TemporaryDirectory() as out:
            fetched = release.fetch_published_sums(Path(out), "0.10.0", query, lambda tag, name, _: downloaded.append((tag, name)))
        self.assertEqual(downloaded, [("0.9.0", "metacodes-0.9.0-SHA256SUMS")])
        self.assertEqual([path.name for path in fetched], ["metacodes-0.9.0-SHA256SUMS"])


class ChannelTest(Tree):
    def test_collecting_the_facts_reads_the_ledger_and_the_tag(self) -> None:
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        head = self.commit("release: 0.10.0")
        git(self.root, "tag", "0.10.0")
        facts = release_archive.collect_git_facts(self.root, "0.13.0")
        self.assertEqual((facts.head_tag, facts.head_commit, facts.agentcore_built_by), ("0.10.0", head, "0.10.0"))
        self.assertIsNone(release_archive.collect_git_facts(self.root, "0.99.0").agentcore_built_by)


class NotesTest(Tree):
    def setUp(self) -> None:
        super().setUp()
        (self.root / common.CHANGELOG).write_text("# Changelog\n\n## Unreleased\n\n## 0.10.0 — 2026-11-01\n\n### Fixed\n\n- main fix.\n\n## 0.10.1 — 2026-11-02\n\n### Fixed\n\n- main fix 2.\n", encoding="utf-8")

    def test_a_built_release_names_version_abi_changes_and_migration(self) -> None:
        common.write(self.root, contract.SDK_CHANGELOG, CHANGES + "\n### Migration\n\n- do this.\n")
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        notes = release_notes.release_notes(self.root, "0.10.0")
        self.assertTrue(notes.startswith("## AgentCore 0.13.0\n"))
        self.assertIn("binary ABI v1 revision 26", notes)
        self.assertIn("`metacodes` 0.13.0 on Python", notes)
        self.assertIn("#### Added", notes)
        self.assertIn("- a Host-visible feature.", notes)
        self.assertIn("#### Migration", notes)
        self.assertIn("- do this.", notes)
        self.assertIn("- main fix.", notes)
        self.assertLess(notes.index("do this"), notes.index("main fix"))

    def test_no_migration_says_so(self) -> None:
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        self.assertIn("- No migration steps.", release_notes.release_notes(self.root, "0.10.0"))

    def test_a_reuse_names_the_release_that_built_it(self) -> None:
        self.release_built()
        release.apply_cut(self.root, "0.13.0", "0.10.1", "2026-11-02")
        notes = release_notes.release_notes(self.root, "0.10.1")
        self.assertIn("includes AgentCore **0.13.0**", notes)
        self.assertIn("unchanged since metacodes 0.10.0", notes)
        self.assertIn("No migration is needed", notes)

    def test_a_main_release_without_an_agentcore_has_no_notes(self) -> None:
        with self.assertRaisesRegex(common.CutError, "does not say which AgentCore"):
            release_notes.release_notes(self.root, "0.10.0")

    def test_long_agentcore_notes_cannot_crowd_out_the_main_section(self) -> None:
        long = "## Unreleased\n\n### Added\n\n" + "".join(f"- entry {i} {'x' * 200}\n" for i in range(2000))
        common.write(self.root, contract.SDK_CHANGELOG, long)
        release.apply_cut(self.root, "0.13.0", "0.10.0", "2026-11-01")
        notes = release_notes.release_notes(self.root, "0.10.0")
        self.assertLessEqual(len(notes.encode("utf-8")), release_notes.RELEASE_BODY_LIMIT)
        self.assertIn("do not fit here", notes)
        self.assertIn("- main fix.", notes)


class CutCommandTest(Tree):
    """release_cut.cmd_cut on a repository, with the network stopped at the edge."""

    def setUp(self) -> None:
        super().setUp()
        common.write(self.root, common.CHANGELOG, "# Changelog\n\n## Unreleased\n\n### Added\n\n- main feature.\n")
        (self.root / rc.PROTOCOL).parent.mkdir(parents=True)
        common.write(self.root, rc.PROTOCOL, "{}\n")
        self.commit("feat: a feature")
        git(self.root, "tag", "0.9.0", "HEAD~1")
        self.opened = {}
        for name, value in (
            ("require_clean_main", None),
            ("repin_fingerprint", None),
        ):
            patcher = mock.patch.object(rc, name, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(rc, "open_pr", side_effect=lambda root, branch, title, body, label, dry_run: self.opened.update(branch=branch, body=body))
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_cut_finalizes_agentcore_and_tells_the_reviewer(self) -> None:
        self.assertEqual(rc.cmd_cut(self.root, "auto", False, False), 0)
        self.assertEqual(contract.sdk_version(self.root), "0.13.0")
        self.assertEqual(contract.load_ledger(self.root).latest.main_releases, ("0.10.0",))
        self.assertEqual(self.opened["branch"], "release/0.10.0")
        self.assertIn("AgentCore **0.13.0** is built by this release", self.opened["body"])
        self.assertEqual(release.state_findings(self.root, "0.10.0", None), [])

    def test_a_dry_run_writes_nothing(self) -> None:
        self.assertEqual(rc.cmd_cut(self.root, "auto", False, True), 0)
        self.assertEqual(contract.sdk_version(self.root), "0.13.0-dev")
        self.assertEqual(self.opened, {})

    def test_the_second_cut_of_an_unchanged_agentcore_reuses_it(self) -> None:
        rc.cmd_cut(self.root, "auto", False, False)
        self.commit("release: 0.10.0")
        git(self.root, "tag", "0.10.0")
        rc.apply_version(self.root, "0.10.1-dev")
        release.apply_reopen(self.root, "0.13.1-dev")
        common.write(self.root, common.CHANGELOG, common.read(self.root, common.CHANGELOG).replace("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- main fix.\n", 1))
        common.write(self.root, "doc/note.md", "a main-project change\n")
        self.commit("fix: main only")
        self.assertEqual(rc.cmd_cut(self.root, "auto", False, False), 0)
        self.assertEqual(contract.sdk_version(self.root), "0.13.0")
        self.assertEqual(contract.load_ledger(self.root).latest.main_releases, ("0.10.0", "0.10.1"))
        self.assertIn("AgentCore **0.13.0** is reused", self.opened["body"])
        self.assertEqual(release.release_mode(self.root, "0.10.1"), "0.10.0")


class OpenPrFilesTest(unittest.TestCase):
    def test_the_generated_files_are_committed(self) -> None:
        commands = []

        def run(argv, cwd, check=True):
            commands.append(list(argv))
            return ""

        with mock.patch.object(rc, "open_release_prs", return_value=[]), mock.patch.object(rc, "branch_was_merged", return_value=False), mock.patch.object(rc, "run", side_effect=run):
            rc.open_pr(ROOT, "release/9.9.9", "release: 9.9.9", "body", "release", dry_run=False)
        added = next(argv for argv in commands if argv[:2] == ["git", "add"])
        for rel in contract.GENERATED:
            self.assertIn(rel, added)


class SumsTest(unittest.TestCase):
    def test_language_packages_need_sidecars_and_enter_the_sums(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            dist = Path(tmp) / "dist"
            dist.mkdir()
            for name in ("metacodes-0.13.0-py3-none-x.whl", "metacodes-node-0.13.0-t.tgz"):
                (dist / name).write_bytes(b"x")
            with self.assertRaisesRegex(ValueError, "without a .sha256"):
                release_sums.write_sums(dist, "0.10.0", Path(tmp) / "out")
            for path in list(dist.iterdir()):
                release.write_sidecar(path)
            target = release_sums.write_sums(dist, "0.10.0", Path(tmp) / "out")
            self.assertEqual(sorted(release.parse_sums(target.read_text(encoding="ascii"))), ["metacodes-0.13.0-py3-none-x.whl", "metacodes-node-0.13.0-t.tgz"])


class WorkflowTest(unittest.TestCase):
    """The door is only a door if the release path goes through it."""

    def setUp(self) -> None:
        self.text = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")

    def test_nothing_is_drafted_before_the_door(self) -> None:
        door = self.text.index("agentcore_release.py verify-dist")
        self.assertLess(self.text.index("agentcore_release.py fetch-published-sums"), door)
        self.assertLess(door, self.text.index("scripts/release_sums.py \"$RUNNER_TEMP/dist\""))
        self.assertLess(door, self.text.index("gh release create"))
        self.assertLess(door, self.text.index("gh release upload"))

    def test_every_platform_builds_or_reuses(self) -> None:
        self.assertEqual(self.text.count("release-mode --github-env"), 2)
        self.assertEqual(self.text.count("if: env.AGENTCORE_REUSE_FROM != ''"), 2)
        self.assertEqual(self.text.count("if: env.AGENTCORE_REUSE_FROM == ''"), 4)
        self.assertEqual(self.text.count("agentcore_release.py package-languages"), 2)
        self.assertEqual(self.text.count("agentcore_release.py fetch-reused"), 2)

    def test_the_rehearsal_runs_in_ci(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("agentcore_release.py rehearse", ci)


if __name__ == "__main__":
    unittest.main()
