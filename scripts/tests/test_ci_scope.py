"""scripts/ci_scope.py and how ci.yml uses it (doc/CI_DESIGN.md §2-§4).

The classification is a pure function of the changed paths. The workflow
tests pin the wiring: which gate steps still run on a documentation-only
change, that every other step of a leg or shard reads its scope, that the
scope fails open, that each required check is a result job that passes only
when all of its legs did, and that the decision steps pick the right base for
a pull request and a legacy merge queue group."""
from __future__ import annotations

import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_scope  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
AGENTCORE_WORKFLOW = ROOT / ".github" / "workflows" / "agentcore-windows.yml"
# The runner's own bash invocation for `run:` steps.
BASH = ["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c"]
CHECKOUT = "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"
# The `gates` steps that also run on a documentation-only change. A new step
# must either read SUITES or be added here on purpose.
DOC_STEPS = {
    "Release fast path",
    "Change scope",
    CHECKOUT,
    "Install Python development dependencies",
    "Version state gate and release rehearsal",
    "Documentation link check",
    "Documentation fact check",
    "Documentation fact-check unit tests",
    "Changelog entries are unreleased",
    "Changelog section check unit tests",
    "Gate manifest unit tests",
    "Diff whitespace check",
    "Protocol document references",
    "Release document package check",
    "Release document check unit tests",
    "Third-party notices check",
    "Third-party notices unit tests",
    # The macOS pool job's own switch: it decides FAST_PATH for that job and
    # does nothing elsewhere (doc/CI_DESIGN.md §6).
    "Stand down if the hosted legs took over",
}
ECHO_STEPS = {"Release fast path", "Change scope"}
HOST_CACHE_STEP = "Keep the caches on the pool host"
# The jobs that do the work, one runner per leg or shard (doc/CI_DESIGN.md §4),
# and the switch each one's steps read.
LEG_JOBS = (("gates-linux", "SUITES"), ("gates-macos", "SUITES"), ("gates-macos-vm", "SUITES"),
            ("windows-gates", "SUITES"), ("windows-gates-vm", "SUITES"), ("tty-linux", "TTY"), ("tty-windows", "TTY"))
# The checks the `Protect main` ruleset requires, plus TTY (Windows), and the
# job whose legs or shards each one reports. Gates (macOS) and Gates (Windows)
# report where the gates ran, a pool or the hosted legs: test_ci_pool_plan.py.
RESULT_JOBS = {
    "Gates (Linux)": ["gates-linux", "test-ids", "scope"],
    "Gates (macOS)": ["runner-plan", "gates-macos-watch", "gates-macos"],
    "Gates (Windows)": ["runner-plan", "windows-gates-watch", "windows-gates"],
    "TTY (Linux)": "tty-linux",
    "TTY (Windows)": "tty-windows",
}
# The leg flags a gate step may be gated on; a step without one runs on every leg.
LEG_FLAGS = {"units", "integration", "product", "release", "cross", "checks"}
# Each gate job, its runner OS and the flags its steps read there.
GATE_JOBS = (("gates-linux", "Linux", {"units", "product", "release", "checks"}),
             ("gates-macos", "macOS", {"units", "product", "release", "checks"}),
             ("gates-macos-vm", "macOS", {"units", "product", "release", "checks"}),
             ("windows-gates", "Windows", {"units", "integration", "product", "release"}),
             ("windows-gates-vm", "Windows", {"units", "integration", "product", "release"}))
TEST_PARTS = {"test:units", "test:integration", "test:product"}
# The gate steps without a leg flag: environment setup, which runs on every
# leg. A new step names the leg it belongs to; added here instead, it runs on
# all twelve gate runners.
SETUP_STEPS = {
    "gates-linux": {
        "Release fast path", "Change scope", CHECKOUT,
        "Restore Lean toolchain and build products", "Install pinned elan", "Build pinned Lean kernel",
        "Install ripgrep", "Install bubblewrap", "Install Python development dependencies",
        "Stand down if the hosted legs took over", "Keep the caches on the pool host",
    },
    "windows-gates": {
        "Release fast path", "Change scope", CHECKOUT,
        "mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29",
        "Restore the Zig cache main saved", "Save the Zig cache for pull requests",
        "Normalize line endings of the checkout", "Install Python development dependencies",
        "Stand down if the hosted legs took over",
        "Restore Lean toolchain and build products", "Install pinned elan",
    },
}
# Caches (doc/CI_DESIGN.md §5): what main's warm run saves carries its run ID
# after the prefix every other run restores.
RUN_SUFFIX = "${{ github.run_id }}-${{ github.run_attempt }}"


def runs_on(step: dict, os_name: str) -> bool:
    """Whether a step's `runner.os` conditions let it run on this OS."""
    condition = step.get("if", "")
    pinned = re.findall(r"runner\.os == '(\w+)'", condition)
    excluded = re.findall(r"runner\.os != '(\w+)'", condition)
    return all(name == os_name for name in pinned) and os_name not in excluded


def leg_flags(step: dict) -> set:
    return set(re.findall(r"\bmatrix\.(\w+)", step.get("if", "")))


class ClassifyTest(unittest.TestCase):
    def test_documentation_alone_is_the_docs_scope(self) -> None:
        for paths in (["doc/API.md"], ["ROADMAP.md", "doc/README.md"], ["AGENTS.md"], ["doc/history/X.md"]):
            with self.subTest(paths=paths):
                self.assertEqual(ci_scope.classify(paths)[0], "docs")

    def test_release_documents_use_the_docs_scope(self) -> None:
        for path in ("README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "docs")
                self.assertEqual(ci_scope.classify(["doc/API.md", path])[0], "docs")

    def test_the_release_manifest_is_shared_with_the_build(self) -> None:
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn('"release/documents.json"', build)
        inputs = ci_scope.document_inputs(ROOT)
        self.assertIn("THIRD_PARTY_NOTICES.md", inputs.release_sources)
        self.assertIn("vendor/tinykg/LICENSE", inputs.release_sources)
        for path in inputs.release_sources:
            self.assertEqual(ci_scope.classify([path], release_sources=inputs.release_sources)[0], "docs")

    def test_a_removed_documentation_file_keeps_the_docs_scope(self) -> None:
        # evals/plugin-v1/protocol.json pins doc paths that zig build test resolves.
        scope, reason = ci_scope.classify(["doc/CORE_REFERENCE.md", "doc/history/CORE_REFERENCE.md"],
                                          deleted=["doc/CORE_REFERENCE.md"])
        self.assertEqual(scope, "docs")
        self.assertIn("checked independently", reason)
        # Removing harness files keeps the eval scope; only doc removals widen it.
        self.assertEqual(ci_scope.classify(["scripts/eval/old.py"], deleted=["scripts/eval/old.py"])[0], "eval")

    def test_document_checks_follow_the_actual_input_paths(self) -> None:
        inputs = ci_scope.DocumentInputs(frozenset(ci_scope.RELEASE_DOCS), frozenset(["doc/PINNED.md"]))
        for changes, expected in (([("D", "doc/unreferenced.md")], (False, False)),
                                  ([("D", "doc/PINNED.md")], (True, False)),
                                  ([("M", "README.md")], (False, True)),
                                  ([("M", ci_scope.PROTOCOL)], (True, False)),
                                  ([("D", "doc/PINNED.md"), ("M", "README.md")], (True, True))):
            with self.subTest(changes=changes):
                self.assertEqual(ci_scope.document_checks("docs", changes, inputs), expected)
        self.assertEqual(ci_scope.document_checks("full", [], inputs), (True, True))

    def test_protocol_document_relocation_cannot_change_other_inputs(self) -> None:
        before = {"implementation_paths": ["apps/cli/src/main.zig", "doc/A.md"], "budget": 0}
        moved = {"implementation_paths": ["apps/cli/src/main.zig", "doc/B.md"], "budget": 0}
        self.assertTrue(ci_scope.protocol_documents_only(before, moved))
        for after in ({**moved, "budget": 1}, {**moved, "budget": False},
                      {**moved, "implementation_paths": ["src/other.zig", "doc/B.md"]}):
            self.assertFalse(ci_scope.protocol_documents_only(before, after))

    def test_markdown_outside_doc_and_the_top_level_is_an_input(self) -> None:
        # Prompt templates are @embedFile'd; agent and Skill fixtures are read by tests.
        for path in ("packages/coding/src/core/templates/compact/prompt.md", "tests/e2e/fixtures/agents/release-mcp.md", "sdk/README.md"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")

    def test_the_evaluation_harness_is_the_eval_scope(self) -> None:
        for paths in (["scripts/eval/chained_runner.py"], ["evals/experiments/learning-turn-v1.md"],
                      ["evals/validators/d1_check_gate_v3_cron.py", "doc/README.md"]):
            with self.subTest(paths=paths):
                self.assertEqual(ci_scope.classify(paths)[0], "eval")

    def test_anything_else_is_the_full_scope_and_is_named(self) -> None:
        scope, reason = ci_scope.classify(["scripts/eval/cli.py", "apps/cli/src/main.zig"])
        self.assertEqual(scope, "full")
        self.assertIn("apps/cli/src/main.zig", reason)
        self.assertNotIn("scripts/eval/cli.py", reason)
        for path in ("build.zig", "scripts/release_cut.py", ".github/workflows/ci.yml", "tests/tty/tty_driver.py", "scripts/evaluate.py"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")

    def test_no_paths_is_the_full_scope(self) -> None:
        self.assertEqual(ci_scope.classify([])[0], "full")

    def test_outputs_fail_open(self) -> None:
        def flags(scope):
            chosen = ci_scope.select(scope)
            return chosen.suites, chosen.tty, chosen.units, chosen.product, chosen.complete

        self.assertEqual(flags("docs"), (False, False, False, False, False))
        self.assertEqual(flags("eval"), (True, False, True, True, True))
        self.assertEqual(flags("full"), (True, True, True, True, True))
        # Without the layout a narrow scope cannot be planned: everything runs.
        self.assertEqual(flags("packages"), (True, True, True, True, True))


class DecideTest(unittest.TestCase):
    def test_manual_and_unknown_runs_are_full_without_a_diff(self) -> None:
        def no_diff(base: str, candidate: str):
            raise AssertionError("a manual run must not diff")

        for event in ("workflow_dispatch", "push", ""):
            with self.subTest(event=event):
                self.assertEqual(ci_scope.decide(event, "abc", "HEAD", no_diff)[0], "full")

    def test_pull_requests_and_merge_groups_diff_against_their_base(self) -> None:
        seen = []

        def diff(base: str, candidate: str):
            seen.append((base, candidate))
            return [("M", "doc/API.md")]

        self.assertEqual(ci_scope.decide("pull_request", "HEAD^1", "HEAD", diff)[0], "docs")
        self.assertEqual(ci_scope.decide("merge_group", "a" * 40, "HEAD", diff)[0], "docs")
        self.assertEqual(seen, [("HEAD^1", "HEAD"), ("a" * 40, "HEAD")])

    def test_a_missing_base_or_a_failing_diff_is_the_full_scope(self) -> None:
        def broken(base: str, candidate: str):
            raise RuntimeError("bad object")

        self.assertEqual(ci_scope.decide("merge_group", "", "HEAD", broken)[0], "full")
        scope, reason = ci_scope.decide("merge_group", "a" * 40, "HEAD", broken)
        self.assertEqual(scope, "full")
        self.assertIn("bad object", reason)


class MainTest(unittest.TestCase):
    """The real `git diff` of a fixture repository, through main()."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "ci")
        (self.repo / ".gitignore").write_text("github-output\nsummary.md\n", encoding="utf-8")
        (self.repo / "doc").mkdir()
        (self.repo / "doc" / "A.md").write_text("a\n", encoding="utf-8")
        (self.repo / "main.zig").write_text("x\n", encoding="utf-8")
        (self.repo / "README.md").write_text("readme\n", encoding="utf-8")
        (self.repo / "build.zig.zon").write_text('.{ .version = "1.2.3-dev" }\n', encoding="utf-8")
        (self.repo / "release").mkdir()
        (self.repo / "release/documents.json").write_text(json.dumps({
            "schema": "metacodes.release-documents/v1", "files": [
                {"source": "README.md", "destination": "share/doc/README.md"}]}), encoding="utf-8")
        (self.repo / "evals/plugin-v1").mkdir(parents=True)
        self.protocol = {"implementation_paths": ["main.zig", "doc/A.md"], "budget": 0}
        self.write_protocol()
        self.commit("base")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *argv: str) -> str:
        return subprocess.run(["git", *argv], cwd=str(self.repo), check=True, capture_output=True, text=True).stdout

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def write_protocol(self):
        (self.repo / ci_scope.PROTOCOL).write_text(json.dumps(self.protocol), encoding="utf-8")

    def run_main(self, event: str, base: str) -> dict:
        out = self.repo / "github-output"
        out.write_text("", encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            code = ci_scope.main(["--event", event, "--base", base, "--candidate", "HEAD",
                                  "--github-output", str(out), "--repo-root", str(self.repo),
                                  "--github-summary", str(self.repo / "summary.md")])
        self.assertEqual(code, 0)
        return dict(line.split("=", 1) for line in out.read_text(encoding="utf-8").splitlines())

    def test_a_documentation_change_skips_the_suites(self) -> None:
        (self.repo / "doc" / "A.md").write_text("b\n", encoding="utf-8")
        self.commit("docs")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("docs", "false", "false"))
        summary = (self.repo / "summary.md").read_text(encoding="utf-8")
        self.assertIn("| M | doc/A.md | docs |", summary)
        self.assertIn("| Build, unit, integration, product, release | Skip |", summary)

    def test_diff_uses_the_whole_change_instead_of_just_the_last_commit(self) -> None:
        base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "main.zig").write_text("code change\n", encoding="utf-8")
        self.commit("code")
        (self.repo / "doc" / "A.md").write_text("docs\n", encoding="utf-8")
        self.commit("docs")
        self.assertEqual(self.run_main("pull_request", base)["scope"], "full")
        self.assertEqual(self.run_main("pull_request", "HEAD^1")["scope"], "docs")

    def test_summary_escapes_paths_and_does_not_truncate_the_decision(self) -> None:
        name = "doc/a|`<img>.md"
        destination = self.repo / "report.md"
        changes = [("M", name)] + [("M", f"doc/{i}.md") for i in range(200)] + [("M", "apps/cli/src/main.zig")]
        scope, reason = ci_scope.classify([path for _, path in changes])
        ci_scope.write_summary(str(destination), "pull_request", "base", "HEAD", scope, reason, changes)
        summary = destination.read_text(encoding="utf-8")
        self.assertIn("Scope: **full**", summary)
        self.assertIn("doc/a&#124;&#96;&lt;img&gt;.md", summary)
        self.assertIn("Showing 200 of 202 changed paths", summary)

    def test_a_rename_out_of_doc_is_the_full_scope(self) -> None:
        self.git("mv", "doc/A.md", "notes.zig")
        self.commit("rename")
        got = self.run_main("merge_group", self.git("rev-parse", "HEAD^1").strip())
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("full", "true", "true"))

    def test_a_move_within_doc_only_runs_reference_checks(self) -> None:
        (self.repo / "doc" / "history").mkdir()
        self.git("mv", "doc/A.md", "doc/history/A.md")
        self.commit("retire")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("docs", "false", "false"))
        self.assertEqual((got["doc_references"], got["release_docs"]), ("true", "false"))

    def test_a_move_and_its_protocol_path_update_remain_document_only(self) -> None:
        self.git("mv", "doc/A.md", "doc/B.md")
        self.protocol["implementation_paths"][-1] = "doc/B.md"
        self.write_protocol()
        self.commit("move documentation and update its protocol path")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["doc_references"]), ("docs", "false", "true"))
        self.protocol["budget"] = 1
        self.write_protocol()
        self.commit("change protocol budget")
        self.assertEqual(self.run_main("pull_request", "HEAD^1")["scope"], "eval")

    def test_readme_runs_release_document_checks_without_build_suites(self) -> None:
        (self.repo / "README.md").write_text("updated readme\n", encoding="utf-8")
        self.commit("readme")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["release_docs"]), ("docs", "false", "true"))

    def test_unreadable_attribution_inputs_default_to_full(self) -> None:
        (self.repo / "release/documents.json").write_text("invalid", encoding="utf-8")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["doc_references"], got["release_docs"]), ("full", "true", "true"))

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_a_documentation_file_turned_into_a_symlink_is_the_full_scope(self) -> None:
        # plugin_release_gate refuses a pinned path that is a symlink.
        (self.repo / "doc" / "A.md").unlink()
        os.symlink("../main.zig", self.repo / "doc" / "A.md")
        self.commit("symlink")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual(got["scope"], "full")
        self.assertIn("changed type", got["reason"])

    def test_an_added_documentation_file_keeps_the_docs_scope(self) -> None:
        (self.repo / "doc" / "B.md").write_text("b\n", encoding="utf-8")
        self.commit("add")
        self.assertEqual(self.run_main("pull_request", "HEAD^1")["scope"], "docs")

    def test_an_unknown_base_is_the_full_scope_and_exits_zero(self) -> None:
        got = self.run_main("merge_group", "0" * 40)
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("full", "true", "true"))
        self.assertIn("scope check failed", got["reason"])


FIXTURE_LAYERS = """.{
    .packages = .{
        .{ .name = "low", .paths = .{ "src/low/", "src/low.zig" }, .allowed_dependencies = .{} },
        .{ .name = "mid", .paths = .{"src/mid/"}, .allowed_dependencies = .{"low"} },
        .{ .name = "side", .paths = .{"src/side/"}, .allowed_dependencies = .{"low"} },
        .{ .name = "top", .paths = .{"src/top/"}, .allowed_dependencies = .{ "low", "mid" } },
        .{ .name = "testing", .paths = .{"tests/helpers/"}, .allowed_dependencies = .{ "low", "mid", "side", "top" } },
        .{ .name = "tests", .paths = .{"tests/"}, .allowed_dependencies = .{ "low", "mid", "side", "top", "testing" } },
    },
    .kernel_budget = .{ .package = "low", .max_lines = 10, .max_dependencies = .{} },
}
"""
# One deep import charged to both side and low: low, and side, are not yet
# trusted; mid and top are.
FIXTURE_BASELINE = """.{
    .upward = .{},
    .deep = .{
        .{ "src/side/a.zig", "src/low/inner.zig" },
    },
    .cycles = .{},
    .wiring = .{},
    .wide_roots = .{},
}
"""
FIXTURE_BUILD = """const s = &.{ "python3", "-m", "unittest", "scripts.tests.test_everywhere" };
const x = b.step("test:low", "");
const y = b.step(
    "test:mid",
    "",
);
const z = b.step("test:top", "");
"""


def fixture_layout(baseline: str = FIXTURE_BASELINE, build: str = FIXTURE_BUILD) -> "ci_scope.Layout":
    files = {ci_scope.LAYERS: FIXTURE_LAYERS, ci_scope.LAYER_BASELINE: baseline, ci_scope.BUILD: build}
    return ci_scope.load_layout(files.__getitem__)


class LayoutTest(unittest.TestCase):
    """The packages scope: layers.zon's dependency closure, narrowed only
    where layer_baseline.zon has nothing left for every affected package."""

    def test_zon_subset(self) -> None:
        self.assertEqual(ci_scope.parse_zon('.{ .a = .{ "x", "y\\"z" }, .b = 3, .c = .{}, // note\n }'),
                         {"a": ["x", 'y"z'], "b": 3, "c": []})
        for broken in ('.{ .a = 1 ', '.{ "x", .a = 1 }', '.{ @import("x") }', '.{} .{}'):
            with self.subTest(text=broken), self.assertRaises((ValueError, IndexError)):
                ci_scope.parse_zon(broken)

    def test_the_real_layers_parse_and_every_product_package_is_a_dependent_of_base(self) -> None:
        layout = ci_scope.load_layout(ci_scope.tree_reader(ROOT, None))
        self.assertNotIn("tests", layout.products)
        self.assertNotIn("testing", layout.products)
        self.assertEqual(layout.affected(["base"]), layout.products)
        # A change confined to the cli package, sources or tests, runs test:cli.
        for path in ("apps/cli/src/repl/tui/widget/status_bar.zig", "apps/cli/tests/component/ui_render_test.zig"):
            with self.subTest(path=path):
                changes = [("M", path)]
                scope, reason = ci_scope.classify([path], layout=layout)
                self.assertEqual(scope, "packages", reason)
                chosen = ci_scope.select(scope, changes, layout)
                self.assertEqual((chosen.packages, chosen.package_tests), (("cli",), ("test:cli",)))
                self.assertTrue(chosen.product and chosen.tty)
        self.assertEqual(layout.owner("packages/kernel/src/conversation.zig"), "kernel")
        self.assertEqual(layout.owner("packages/coding/src/core/agent_loop.zig"), "coding")
        self.assertEqual(layout.owner("packages/coding/src/core/tools_extra.zig"), "coding")
        self.assertEqual(layout.owner("tests/helpers/x.zig"), "testing")

    def test_a_package_is_charged_for_each_baseline_entry_it_is_part_of(self) -> None:
        layout = fixture_layout()
        self.assertEqual(layout.violations, {"side": 1, "low": 1})
        crowded = fixture_layout(FIXTURE_BASELINE.replace(".cycles = .{}", '.cycles = .{ .{ "mid", "top" } }')
                                 .replace(".wide_roots = .{}", '.wide_roots = .{ "src/top/root.zig" }')
                                 .replace(".wiring = .{}", '.wiring = .{ .{ "src/mid/root.zig", "top" } }'))
        self.assertEqual(crowded.violations, {"side": 1, "low": 1, "mid": 2, "top": 2})
        self.assertEqual(fixture_layout(".{}").violations, {})

    def test_the_closure_is_the_changed_packages_and_their_dependents(self) -> None:
        layout = fixture_layout()
        self.assertEqual(layout.affected(["top"]), ("top",))
        self.assertEqual(layout.affected(["mid"]), ("mid", "top"))
        self.assertEqual(layout.affected(["low"]), ("low", "mid", "side", "top"))
        self.assertEqual(layout.affected(["side", "mid"]), ("mid", "side", "top"))

    def test_a_cleared_upper_package_runs_only_itself_and_its_dependents(self) -> None:
        layout = fixture_layout()
        scope, reason = ci_scope.classify(["src/mid/a.zig", "doc/A.md"], layout=layout)
        self.assertEqual(scope, "packages")
        self.assertIn("the affected packages are mid, top", reason)
        chosen = ci_scope.select(scope, [("M", "src/mid/a.zig"), ("M", "doc/A.md")], layout)
        self.assertEqual(chosen.packages, ("mid", "top"))
        self.assertEqual(chosen.package_tests, ("test:mid", "test:top"))
        self.assertEqual((chosen.suites, chosen.tty, chosen.units, chosen.product, chosen.complete),
                         (True, True, True, True, False))

    def test_a_package_left_in_the_baseline_is_the_full_scope(self) -> None:
        layout = fixture_layout()
        for paths, named in ((["src/side/a.zig"], "side (1)"), (["src/low.zig"], "low (1)"),
                             (["src/mid/a.zig", "src/side/b.zig"], "side (1)")):
            with self.subTest(paths=paths):
                scope, reason = ci_scope.classify(paths, layout=layout)
                self.assertEqual(scope, "full")
                self.assertIn(named, reason)
                self.assertEqual(ci_scope.select(scope, [("M", path) for path in paths], layout).packages,
                                 layout.products)
        # Cleared in the baseline, then narrowed: the scope opens up as the
        # migration empties layer_baseline.zon.
        self.assertEqual(ci_scope.classify(["src/side/a.zig"], layout=fixture_layout(".{}"))[0], "full")
        self.assertIn("no test:<package> step", ci_scope.classify(["src/side/a.zig"], layout=fixture_layout(".{}"))[1])
        self.assertEqual(ci_scope.classify(["src/low/x.zig"], layout=fixture_layout(".{}").cleared())[0], "packages")

    def test_an_affected_package_without_its_test_step_is_the_full_scope(self) -> None:
        layout = fixture_layout(build=FIXTURE_BUILD.replace('"test:top"', '"test:top-other"'))
        scope, reason = ci_scope.classify(["src/mid/a.zig"], layout=layout)
        self.assertEqual(scope, "full")
        self.assertIn("top", reason)

    def test_infrastructure_is_the_full_scope(self) -> None:
        layout = fixture_layout()
        for path in ("build.zig", "build.zig.zon", "layers.zon", "layer_baseline.zon", "tests/helpers/fake.zig",
                     ".github/workflows/ci.yml", "vendor/tinykg/x.c", "scripts/ci_scope.py", "scripts/tests/fixture.json",
                     "src/unowned.zig", "release/documents.json", "control-plane/lean/X.lean", "sdk/node/x.js"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify(["src/mid/a.zig", path], layout=layout)[0], "full")
                self.assertEqual(ci_scope.classify(["tests/tty/cases/a.py", path], layout=layout)[0], "full")

    def test_only_tests_run_only_their_suites(self) -> None:
        layout = fixture_layout()

        def chosen(changes):
            scope, _ = ci_scope.classify([path for _, path in changes], layout=layout)
            self.assertEqual(scope, "tests")
            got = ci_scope.select(scope, changes, layout)
            return got.tty, got.units, got.product, got.script_tests, got.complete

        self.assertEqual(chosen([("M", "tests/tty/cases/a.py")]), (True, False, False, (), False))
        self.assertEqual(chosen([("A", "scripts/tests/test_lint.py"), ("D", "scripts/tests/test_old.py")]),
                         (False, False, False, ("scripts.tests.test_lint",), False))
        # A shared fixture may feed the TTY cases too.
        self.assertEqual(chosen([("M", "tests/fixtures/vterm/screen_parity.jsonl")]), (True, True, True, (), True))
        self.assertEqual(chosen([("M", "tests/component/x_test.zig"), ("M", "scripts/eval/cli.py")]),
                         (True, True, True, (), True))
        # A suite build.zig runs (on every platform) keeps test:units; only
        # the others run by name, and a complete run names none, so no test
        # runs twice and records twice.
        self.assertEqual(chosen([("M", "scripts/tests/test_everywhere.py"), ("M", "scripts/tests/test_lint.py")]),
                         (False, True, False, ("scripts.tests.test_lint",), False))
        self.assertEqual(chosen([("M", "tests/component/x_test.zig"), ("M", "scripts/tests/test_lint.py")]),
                         (True, True, True, (), True))
        # A suite test next to a package change keeps all of test:units.
        both = ci_scope.select("packages", [("M", "src/top/a.zig"), ("M", "tests/component/x_test.zig")], layout)
        self.assertEqual((both.packages, both.package_tests, both.complete), (("top",), (), True))
        script = ci_scope.select("packages", [("M", "src/top/a.zig"), ("M", "scripts/tests/test_lint.py")], layout)
        self.assertEqual((script.package_tests, script.script_tests), (("test:top",), ("scripts.tests.test_lint",)))

    def test_a_package_outside_src_is_still_a_product_dependent(self) -> None:
        moved = fixture_layout(".{}").cleared()
        moved = ci_scope.replace(moved, paths=tuple(("apps/top/", owner) if owner == "top" else (entry, owner)
                                                     for entry, owner in moved.paths))
        self.assertEqual(moved.affected(["mid"]), ("mid", "top"))
        self.assertEqual(ci_scope.classify(["apps/top/main.zig"], layout=moved)[0], "packages")
        # A test kept inside a package directory selects that package.
        layout = ci_scope.replace(moved, paths=moved.paths + (("apps/top/tests/", "tests"),))
        self.assertEqual(layout.owner("apps/top/tests/component/a_test.zig"), "tests")
        self.assertEqual(layout.package("apps/top/tests/component/a_test.zig"), "top")
        self.assertIsNone(layout.package("tests/component/a_test.zig"))
        self.assertIsNone(layout.package("tests/helpers/fake.zig"))
        changes = [("M", "apps/top/tests/component/a_test.zig")]
        scope, _ = ci_scope.classify([path for _, path in changes], layout=layout)
        self.assertEqual(scope, "packages")
        self.assertEqual(ci_scope.select(scope, changes, layout).package_tests, ("test:top",))
        self.assertEqual(ci_scope.classify(["tests/component/a_test.zig"], layout=layout)[0], "tests")

    def test_a_migration_pull_request_is_the_full_scope(self) -> None:
        def diff(base, candidate):
            return [("M", "doc/A.md")]

        self.assertEqual(ci_scope.decide("pull_request", "HEAD^1", "HEAD", diff)[0], "docs")
        scope, reason = ci_scope.decide("pull_request", "HEAD^1", "HEAD", diff, labels=["bug", "migration"])
        self.assertEqual(scope, "full")
        self.assertIn("migration", reason)

    def test_product_runtime_still_runs_for_a_tui_only_change(self) -> None:
        layout = ci_scope.load_layout(ci_scope.tree_reader(ROOT, None))
        paths = ["apps/cli/src/repl/tui/theme.zig", "apps/cli/tests/component/theme_test.zig", "README.md"]
        for extra, target in (([], "test:product-runtime"), (["scripts/eval/cli.py"], "test:product"),
                              (["tests/tty/slow_mock_server.py"], "test:product")):
            changes = [("M", path) for path in paths + extra]
            scope, _ = ci_scope.classify(paths + extra, layout=layout)
            selection = ci_scope.select(scope, changes, layout)
            self.assertEqual(selection.offline_eval, bool(extra))
            self.assertIn(target, ci_scope.local_commands(scope, selection)[0])
            self.assertFalse(ci_scope.needs_model_eval(changes, [], ROOT, None))

    def test_local_commands_follow_the_selection(self) -> None:
        layout = fixture_layout()
        narrowed = ci_scope.select("packages", [("M", "src/mid/a.zig"), ("M", "scripts/tests/test_x.py")], layout)
        commands = ci_scope.local_commands("packages", narrowed, "zig", scripts=("scripts.tests.test_x",))
        self.assertEqual(commands[0], ["zig", "build", "test:mid", "test:top", "test:integration", "test:product", "test:contract"])
        self.assertEqual(commands[1][1:], ["-m", "unittest", "scripts.tests.test_x"])
        # CI runs a changed suite build.zig does not name on a checks-leg step,
        # even on a complete run that leaves script_tests empty; so does the
        # local run.
        mixed = [("M", "tests/component/vterm_test.zig"), ("M", "scripts/tests/test_lint.py"), ("D", "scripts/tests/test_old.py")]
        complete = ci_scope.select("tests", mixed, layout)
        self.assertEqual((complete.complete, complete.script_tests), (True, ()))
        self.assertEqual(ci_scope.script_suites(mixed), ("scripts.tests.test_lint",))
        local = ci_scope.local_commands("tests", complete, "zig", scripts=ci_scope.script_suites(mixed))
        self.assertIn([sys.executable, "-m", "unittest", "scripts.tests.test_lint"], local)
        self.assertEqual(ci_scope.local_commands("full", ci_scope.select("full"), "zig", scripts=("scripts.tests.test_x",))[1][1:],
                         ["-m", "unittest", "scripts.tests.test_x"])
        self.assertIn(["zig", "build", "dev", "test:harness"], commands)
        self.assertEqual(ci_scope.local_commands("full", ci_scope.select("full"), "zig"), [["zig", "build", "test"]])
        self.assertEqual(ci_scope.local_commands("docs", ci_scope.select("docs"), "zig"), [])
        tty = ci_scope.select("tests", [("M", "tests/tty/cases/a.py")], layout)
        self.assertEqual(ci_scope.local_commands("tests", tty, "zig")[0], ["zig", "build", "test:contract"])
        self.assertEqual(ci_scope.local_commands("tests", tty, "zig", windows=True)[1:],
                         [["zig", "build", "windows:tty", "-Dtarget=x86_64-windows-gnu"]])

    def test_the_local_run_never_reaches_a_real_model(self) -> None:
        seen = []

        def run(command, cwd, env, check):
            seen.append(env.get("TTY_SKIP_MODEL"))
            return subprocess.CompletedProcess(command, 0)

        tty = ci_scope.select("tests", [("M", "tests/tty/cases/a.py")], fixture_layout())
        with mock.patch.dict(os.environ, {"TTY_SKIP_MODEL": ""}), mock.patch.object(ci_scope.subprocess, "run", run), \
                redirect_stdout(io.StringIO()):
            self.assertEqual(ci_scope.run_local(ROOT, "tests", tty, "zig"), 0)
        self.assertTrue(seen)
        self.assertEqual(set(seen), {"1"})


class PackageScopeMainTest(unittest.TestCase):
    """layers.zon, layer_baseline.zon and build.zig as committed in a fixture
    repository, through main() and through the replay of main's commits."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "ci@example.invalid")
        self.git("config", "user.name", "ci")
        (self.repo / ".gitignore").write_text("github-output\nsummary.md\n", encoding="utf-8")
        (self.repo / "release").mkdir()
        (self.repo / "README.md").write_text("readme\n", encoding="utf-8")
        (self.repo / "build.zig.zon").write_text('.{ .version = "1.2.3-dev" }\n', encoding="utf-8")
        (self.repo / "release/documents.json").write_text(json.dumps({
            "schema": "metacodes.release-documents/v1", "files": [
                {"source": "README.md", "destination": "share/doc/README.md"}]}), encoding="utf-8")
        (self.repo / "evals/plugin-v1").mkdir(parents=True)
        (self.repo / ci_scope.PROTOCOL).write_text(json.dumps({"implementation_paths": ["build.zig"]}), encoding="utf-8")
        suite = self.repo / ci_scope.CORE_E2E_SUITE
        suite.parent.mkdir(parents=True)
        suite.write_bytes((ROOT / ci_scope.CORE_E2E_SUITE).read_bytes())
        (self.repo / ci_scope.LAYERS).write_text(FIXTURE_LAYERS, encoding="utf-8")
        (self.repo / ci_scope.LAYER_BASELINE).write_text(FIXTURE_BASELINE, encoding="utf-8")
        (self.repo / ci_scope.BUILD).write_text(FIXTURE_BUILD, encoding="utf-8")
        for path in ("src/mid/a.zig", "src/side/a.zig", "tests/tty/cases/a.py"):
            (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (self.repo / path).write_text("x\n", encoding="utf-8")
        self.commit("base")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *argv: str) -> str:
        return subprocess.run(["git", *argv], cwd=str(self.repo), check=True, capture_output=True, text=True).stdout

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def edit(self, path: str) -> None:
        with open(self.repo / path, "a", encoding="utf-8") as handle:
            handle.write("y\n")

    def run_main(self, *argv: str) -> dict:
        out = self.repo / "github-output"
        out.write_text("", encoding="utf-8")
        with redirect_stdout(io.StringIO()):
            code = ci_scope.main([*argv, "--github-output", str(out), "--repo-root", str(self.repo),
                                  "--github-summary", str(self.repo / "summary.md")])
        self.assertEqual(code, 0)
        return dict(line.split("=", 1) for line in out.read_text(encoding="utf-8").splitlines())

    def test_a_cleared_package_writes_its_closure_and_test_steps(self) -> None:
        self.edit("src/mid/a.zig")
        self.commit("mid (#7)")
        got = self.run_main("--event", "pull_request", "--base", "HEAD^1")
        self.assertEqual((got["scope"], got["packages"], got["package_tests"]), ("packages", "mid,top", "test:mid test:top"))
        self.assertEqual((got["suites"], got["units"], got["product"], got["tty"], got["complete"]),
                         ("true", "true", "true", "true", "false"))
        summary = (self.repo / "summary.md").read_text(encoding="utf-8")
        self.assertIn("Packages: mid, top", summary)
        self.assertIn("| M | src/mid/a.zig | packages |", summary)

    def test_a_package_left_in_the_baseline_runs_in_full(self) -> None:
        self.edit("src/side/a.zig")
        self.commit("side")
        got = self.run_main("--event", "pull_request", "--base", "HEAD^1")
        self.assertEqual((got["scope"], got["package_tests"], got["complete"]), ("full", "", "true"))
        self.assertEqual(got["packages"], "low,mid,side,top")
        self.assertIn("side (1)", got["reason"])

    def test_the_rules_come_from_the_candidate(self) -> None:
        # The change that clears side's entry narrows its own run.
        (self.repo / ci_scope.LAYER_BASELINE).write_text(".{}\n", encoding="utf-8")
        (self.repo / ci_scope.BUILD).write_text(FIXTURE_BUILD + 'const s = b.step("test:side", "");\n', encoding="utf-8")
        self.commit("clear side")
        self.edit("src/side/a.zig")
        self.commit("side")
        self.assertEqual(self.run_main("--event", "pull_request", "--base", "HEAD^1")["scope"], "packages")
        self.assertEqual(self.run_main("--event", "pull_request", "--base", "HEAD~2")["scope"], "full")

    def test_a_migration_label_writes_the_full_scope_and_the_record(self) -> None:
        self.edit("src/mid/a.zig")
        self.commit("mid")
        record = self.repo / "record.json"
        got = self.run_main("--event", "pull_request", "--base", "HEAD^1", "--labels", "migration,ci", "--record", str(record))
        self.assertEqual((got["scope"], got["complete"]), ("full", "true"))
        self.assertEqual(json.loads(record.read_text(encoding="utf-8"))["scope"], "full")
        narrowed = self.run_main("--event", "pull_request", "--base", "HEAD^1", "--labels", "", "--record", str(record))
        self.assertEqual(json.loads(record.read_text(encoding="utf-8")),
                         {"scope": "packages", "packages": ["mid", "top"], "reason": narrowed["reason"], "fast_path": False})
        self.run_main("--event", "pull_request", "--base", "HEAD^1", "--fast-path", "true", "--record", str(record))
        self.assertTrue(json.loads(record.read_text(encoding="utf-8"))["fast_path"])

    def test_model_comparison_follows_the_diff_even_on_a_full_migration(self) -> None:
        (self.repo / "packages/kernel/src").mkdir(parents=True)
        self.edit("packages/kernel/src/loop.zig")
        self.commit("loop")
        for labels in ([], ["--labels", "migration"]):
            got = self.run_main("--event", "pull_request", "--base", "HEAD^1", *labels)
            self.assertEqual((got["offline_eval"], got["model_eval"]), ("true", "true"))
        self.git("mv", "packages/kernel/src/loop.zig", "moved.zig")
        self.commit("move")
        got = self.run_main("--event", "merge_group", "--base", "HEAD^1")
        self.assertEqual(got["model_eval"], "true")
        self.edit("README.md")
        self.commit("docs")
        for label, offline, model in (("", "false", "false"), ("migration", "true", "false"),
                                      ("model-eval", "true", "true")):
            got = self.run_main("--event", "pull_request", "--base", "HEAD^1", "--labels", label)
            self.assertEqual((got["offline_eval"], got["model_eval"]), (offline, model))

    def test_model_comparison_tracks_individual_suite_inputs_and_runtime_files(self) -> None:
        conf = "tests/e2e/scenarios/13_perm_interactive.conf"
        (self.repo / conf).parent.mkdir(parents=True)
        (self.repo / conf).write_bytes((ROOT / conf).read_bytes())
        self.commit("install the core scenario configuration")
        for path, required in (
            ("tests/e2e/scenarios/00_smoke.txt", True),
            ("tests/e2e/scenarios/02_html_game.conf", True),
            ("tests/e2e/fixtures/answers_13.txt", True),
            ("tests/e2e/scenarios/01_game_design.txt", False),
            ("packages/kernel/src/loop_test.zig", False),
            ("packages/ai/src/api/model_error_test.zig", False),
            ("packages/ai/src/provider/capability_matrix_test.zig", False),
            ("packages/kernel/tests/loop.zig", False),
            ("packages/kernel/src/loop.zig", True),
            ("packages/coding/src/core/test_integrity.zig", True),
            ("packages/guard/src/core/goal.zig", True),
            ("packages/session/src/core/agent_session.zig", True),
            ("packages/base/src/api/model_name.zig", True),
        ):
            with self.subTest(path=path):
                (self.repo / path).parent.mkdir(parents=True, exist_ok=True)
                self.edit(path)
                self.commit(path)
                got = self.run_main("--event", "pull_request", "--base", "HEAD^1")
                self.assertEqual((got["model_eval"], got["offline_eval"]), (str(required).lower(), "true"))
        (self.repo / conf).unlink()
        changes = [("M", "tests/e2e/fixtures/answers_13.txt")]
        self.assertTrue(ci_scope.needs_model_eval(changes, [], self.repo, "HEAD"))
        self.assertFalse(ci_scope.needs_model_eval(changes, [], self.repo, None))
        self.assertTrue(ci_scope.needs_model_eval([("D", conf)], [], self.repo, None))

    def test_local_suite_selects_its_declared_fixture_and_validator(self) -> None:
        manifest = self.repo / ci_scope.CORE_E2E_SUITE
        suite = json.loads(manifest.read_text(encoding="utf-8"))
        task = suite["tasks"][0]
        fixture = "tests/e2e/fixtures/new.json"
        validator = "evals/validators/new.py"
        task["environment"]["fixtures"] = [fixture]
        task["success"]["checks"].append({"type": "validator", "validator": validator})
        manifest.write_text(json.dumps(suite), encoding="utf-8")
        for path in (fixture, validator):
            with self.subTest(path=path):
                self.assertTrue(ci_scope.needs_model_eval([("D", path)], [], self.repo, None))
                self.assertFalse(ci_scope.needs_model_eval([("D", path)], [], self.repo, "HEAD"))

    def test_the_nightly_report_reads_what_each_pull_request_recorded(self) -> None:
        self.edit("src/mid/a.zig")
        self.commit("mid (#7)")
        self.edit("src/side/a.zig")
        self.commit("side (#8)")
        (self.repo / "build.zig.zon").write_text('.{ .version = "1.2.4" }\n', encoding="utf-8")
        self.commit("release (#9)")
        mid, side, release = (self.git("rev-parse", rev).strip() for rev in ("HEAD~2", "HEAD^1", "HEAD"))

        def query(path):
            if "/commits/" in path:
                sha = path.split("/commits/")[1].split("/")[0]
                return [{"merged_at": "x", "merge_commit_sha": sha, "head": {"sha": "h" + sha[:8]}}]
            return {"workflow_runs": [{"id": 1, "created_at": "a"}, {"id": 2, "created_at": "b"}]}

        # side's newest run recorded nothing: an older run's record (with
        # other labels, say) is not its scope.
        records = {("h" + mid[:8], 2): {"scope": "packages", "packages": ["mid", "top"], "reason": "r"},
                   ("h" + side[:8], 1): {"scope": "docs", "packages": [], "reason": "old"},
                   ("h" + release[:8], 2): {"scope": "full", "packages": [], "reason": "r", "fast_path": True}}
        asked = []

        def download(repository, run_id):
            asked.append(run_id)
            return records.get((asked_head[0], run_id))

        asked_head = [""]

        def tracking_query(path):
            if "head_sha=" in path:
                asked_head[0] = path.split("head_sha=")[1].split("&")[0]
            return query(path)

        rows = ci_scope.merged(self.repo, [release, side, mid], "o/r", tracking_query, download)
        self.assertEqual([(scope, packages) for _, _, scope, packages, _ in rows],
                         [("fast-path", ()), ("unknown", ()), ("packages", ("mid", "top"))])
        self.assertEqual(asked, [2, 2, 2])
        report = ci_scope.replay_report(rows, "Merged")
        self.assertIn("| unknown | 1 | 33% |", report)
        self.assertIn("| fast-path | 1 | 33% |", report)
        self.assertIn("| #8 | unknown | - |", report)
        self.assertIn("reused from the base", report)

    def test_replay_keeps_a_documentation_only_protocol_edit_in_docs(self) -> None:
        (self.repo / "doc").mkdir()
        (self.repo / "doc/A.md").write_text("a\n", encoding="utf-8")
        (self.repo / ci_scope.PROTOCOL).write_text(json.dumps({"implementation_paths": ["build.zig", "doc/A.md"]}),
                                                   encoding="utf-8")
        self.commit("pin a document")
        self.git("mv", "doc/A.md", "doc/B.md")
        (self.repo / ci_scope.PROTOCOL).write_text(json.dumps({"implementation_paths": ["build.zig", "doc/B.md"]}),
                                                   encoding="utf-8")
        self.commit("move it")
        rows = ci_scope.replay(self.repo, [self.git("rev-parse", "HEAD").strip()], None, False)
        self.assertEqual(rows[0][2], "docs")

    def test_a_local_run_diffs_the_working_tree_against_the_merge_base(self) -> None:
        self.git("branch", "main-copy")
        self.edit("tests/tty/cases/a.py")
        (self.repo / "tests/tty/cases/b.py").write_text("new\n", encoding="utf-8")
        got = self.run_main("--event", "local", "--base", "main-copy", "--candidate", "")
        self.assertEqual((got["scope"], got["tty"], got["units"]), ("tests", "true", "false"))
        summary = (self.repo / "summary.md").read_text(encoding="utf-8")
        self.assertIn("| A | tests/tty/cases/b.py | tests |", summary)

    def test_replay_reports_each_merge_with_its_scope(self) -> None:
        self.edit("src/mid/a.zig")
        self.commit("mid (#7)")
        self.edit("src/side/a.zig")
        self.commit("side (#8)")
        rows = ci_scope.replay(self.repo, [self.git("rev-parse", rev).strip() for rev in ("HEAD", "HEAD^1")], None, False)
        self.assertEqual([(scope, packages) for _, _, scope, packages, _ in rows],
                         [("full", ()), ("packages", ("mid", "top"))])
        report = ci_scope.replay_report(rows, "Scopes")
        self.assertIn("| packages | 1 | 50% |", report)
        self.assertIn("| #8 | full | - |", report)
        self.assertIn("| #7 | packages | mid, top |", report)
        cleared = ci_scope.replay(self.repo, [self.git("rev-parse", "HEAD").strip()], "HEAD", True)
        self.assertEqual(cleared[0][2:4], ("packages", ("side",)))


def load_workflow():
    try:
        import yaml
    except ImportError:  # requirements-dev.txt
        raise unittest.SkipTest("PyYAML is not installed")
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def step_label(step: dict) -> str:
    return step.get("name") or step.get("uses", "")


class WorkflowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = load_workflow()
        self.jobs = self.workflow["jobs"]

    def test_the_merge_queue_runs_the_workflow(self) -> None:
        triggers = self.workflow.get("on", self.workflow.get(True))  # YAML 1.1 reads `on` as true
        self.assertIn("merge_group", triggers)
        self.assertIn("pull_request", triggers)
        self.assertNotIn("push", triggers)  # no duplicate full run after merging

    def test_extended_architectures_are_release_only_and_block_publishing(self) -> None:
        import yaml
        release = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())
        targets = release["jobs"]["build-posix"]["strategy"]["matrix"]["include"]
        self.assertTrue(any(t["zig_target"] == "x86_64-macos" and t["runner"] == "macos-15-intel" for t in targets))
        self.assertTrue(any(t["zig_target"] == "aarch64-linux-gnu" and t["runner"] == "ubuntu-24.04-arm" for t in targets))
        self.assertNotIn("cross", {t["leg"] for t in self.jobs["gates-linux"]["strategy"]["matrix"]["include"]})
        baseline = next(s for s in self.jobs["gates-macos"]["steps"] if s.get("name") == "macOS release executables need no more than their targets")
        self.assertNotIn("x86_64-macos", baseline["run"])
        self.assertIn("aarch64-macos.13.0", baseline["run"])
        arm = release["jobs"]["windows-arm-cross"]
        self.assertEqual(arm["strategy"]["matrix"]["target"], ["aarch64-windows-gnu", "aarch64-windows-msvc"])
        self.assertIn("agentcore:bundle", arm["steps"][-1]["run"])
        self.assertIn("windows-arm-cross", release["jobs"]["publish"]["needs"])
        self.assertTrue(any("tinykg:stage -Dtarget=aarch64-linux-musl" in s.get("run", "")
                            for s in release["jobs"]["build-posix"]["steps"]))

    def test_full_evidence_requires_all_suites_and_excludes_scope_fast_paths(self) -> None:
        job = self.jobs["full-pr-evidence"]
        # macOS and Windows through their result jobs: a pool job or the hosted legs.
        self.assertEqual(set(job["needs"]), {"release-fast-path", "scope", "gates-linux-result", "gates-macos-result",
                                            "gates-windows-result", "tty-linux", "tty-windows", "sdk-bindings"})
        self.assertIn("needs.scope.outputs.scope == 'full'", job["if"])
        self.assertIn("needs.release-fast-path.outputs.fast == 'false'", job["if"])
        self.assertIn("github.event_name == 'pull_request'", job["if"])
        self.assertIn('.result == "success"', job["steps"][0]["run"])
        self.assertIn("ci_evidence.py", job["steps"][2]["run"])

    def test_every_leg_reads_its_scope(self) -> None:
        for job, var in LEG_JOBS:
            with self.subTest(job=job):
                spec = self.jobs[job]
                # The macOS and Windows jobs also wait for where they run (test_ci_pool_plan.py).
                self.assertLessEqual({"release-fast-path", "scope"}, set(spec["needs"]))
                self.assertTrue(spec["if"].startswith("${{ !cancelled()"), spec["if"])
                self.assertEqual(spec["env"][var], "${{ needs.scope.outputs.%s }}" % var.lower())

    def test_only_the_documentation_checks_run_on_a_docs_change(self) -> None:
        running = set()
        for step in self.jobs["gates-linux"]["steps"]:
            condition = step.get("if", "")
            if "env.SUITES != 'false'" not in condition:
                running.add(step_label(step))
            else:
                self.assertIn("env.FAST_PATH != 'true'", condition, step_label(step))
        self.assertEqual(running, DOC_STEPS)

    def test_document_switches_do_not_enable_product_builds(self) -> None:
        def selected(step, references, release_docs, os_name="Linux", checks=True):
            values = {"env.FAST_PATH": "false", "env.SUITES": "false",
                      "env.DOC_REFERENCES": references, "env.RELEASE_DOCS": release_docs,
                      "runner.os": os_name, "matrix.checks": checks}
            condition = step.get("if", "True")
            condition = re.sub(r"\b(?:env|matrix|runner)\.\w+|\bsteps\.[\w.-]+",
                               lambda match: repr(values.get(match.group(), False)), condition)
            condition = condition.replace("&&", "and").replace("||", "or")
            return eval(condition, {"__builtins__": {}}, {})

        steps = self.jobs["gates-linux"]["steps"]
        zig = next(step for step in steps if step.get("uses", "").startswith("mlugg/setup-zig@"))
        for references, release_docs in (("false", "false"), ("true", "false"),
                                          ("false", "true"), ("true", "true")):
            with self.subTest(references=references, release_docs=release_docs):
                ran = [step for step in steps if selected(step, references, release_docs)]
                commands = [step["run"] for step in ran if "zig build " in step.get("run", "")]
                self.assertEqual(commands, [
                    'zig build release:docs:check --prefix "$RUNNER_TEMP/release-documents" --summary all'
                ] if release_docs == "true" else [])
                names = {step_label(step) for step in ran}
                self.assertEqual("Protocol document references" in names, references == "true")
                self.assertEqual(selected(zig, references, release_docs), release_docs == "true")
                self.assertFalse(selected(zig, references, release_docs, os_name="macOS"))
                self.assertFalse(selected(zig, references, release_docs, checks=False))

    def test_document_outputs_are_wired_to_the_posix_legs(self) -> None:
        for name in ("doc_references", "release_docs"):
            self.assertEqual(self.jobs["scope"]["outputs"][name], "${{ steps.decide.outputs.%s }}" % name)
            for job in ("gates-linux", "gates-macos"):
                self.assertEqual(self.jobs[job]["env"][name.upper()], "${{ needs.scope.outputs.%s }}" % name)
        notices = next(step for step in self.jobs["gates-linux"]["steps"]
                       if step.get("name") == "Third-party notices unit tests")
        self.assertTrue(runs_on(notices, "macOS"))

    def test_every_other_step_of_a_leg_fails_open(self) -> None:
        for job, var in (("windows-gates", "SUITES"), ("tty-linux", "TTY"), ("tty-windows", "TTY")):
            for step in self.jobs[job]["steps"]:
                label = step_label(step)
                if label in ECHO_STEPS:
                    continue
                with self.subTest(job=job, step=label):
                    # `!= 'false'`, never `== 'true'`: an empty output (the
                    # scope job failed) runs the step.
                    self.assertIn("env.%s != 'false'" % var, step.get("if", ""))
                    self.assertIn("env.FAST_PATH != 'true'", step.get("if", ""))

    def test_each_required_check_is_a_result_job_over_its_legs(self) -> None:
        by_name = {}
        for job_id, spec in self.jobs.items():
            by_name.setdefault(spec.get("name", job_id), []).append(job_id)
        for name, legs in RESULT_JOBS.items():
            with self.subTest(check=name):
                self.assertEqual(len(by_name.get(name, [])), 1, by_name.get(name))
                spec = self.jobs[by_name[name][0]]
                self.assertNotIn("strategy", spec)  # a matrix name is not the literal check name
                self.assertEqual(spec["needs"], legs)
                # Never skipped: a skipped job passes a required check.
                self.assertEqual(spec["if"], "${{ always() }}")
                if name not in ("Gates (Linux)", "Gates (macOS)", "Gates (Windows)"):
                    self.assertEqual(spec["steps"], self.jobs["tty-linux-result"]["steps"])

    @unittest.skipIf(os.name == "nt", "bash and jq")
    def test_gates_linux_passes_only_when_its_legs_and_the_test_id_comparison_did(self) -> None:
        step = self.jobs["gates-linux-result"]["steps"][0]
        self.assertEqual(step["env"]["NEEDS"], "${{ toJSON(needs) }}")
        for legs, test_ids, passes in (
            ("success", "success", True),
            ("success", "skipped", True),
            ("success", "failure", False),
            ("success", "cancelled", False),
            ("failure", "skipped", False),
            ("skipped", "skipped", False),
        ):
            needs = {"gates-linux": {"result": legs}, "test-ids": {"result": test_ids}}
            with self.subTest(needs=needs):
                proc = subprocess.run([*BASH, step["run"]], env=dict(os.environ, NEEDS=json.dumps(needs)),
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode == 0, passes, proc.stdout + proc.stderr)

    @unittest.skipIf(os.name == "nt", "bash and jq")
    def test_a_result_job_passes_only_when_every_leg_succeeded(self) -> None:
        step = self.jobs["tty-linux-result"]["steps"][0]
        self.assertEqual(step["env"]["NEEDS"], "${{ toJSON(needs) }}")
        cases = (
            ({"gates-linux": {"result": "success", "outputs": {}}}, True),
            ({"gates-linux": {"result": "failure", "outputs": {}}}, False),
            ({"gates-linux": {"result": "cancelled", "outputs": {}}}, False),
            ({"gates-linux": {"result": "skipped", "outputs": {}}}, False),
            ({"a": {"result": "success"}, "b": {"result": "failure"}}, False),
            ({}, False),
        )
        for needs, passes in cases:
            with self.subTest(needs=needs):
                proc = subprocess.run([*BASH, step["run"]], env=dict(os.environ, NEEDS=json.dumps(needs)),
                                      capture_output=True, text=True)
                self.assertEqual(proc.returncode == 0, passes, proc.stdout + proc.stderr)

    @unittest.skipIf(os.name == "nt", "bash and jq")
    def test_model_eval_requires_latest_success_for_this_pair_with_a_report(self) -> None:
        step = self.jobs["gates-linux-result"]["steps"][1]
        self.assertIn("needs.scope.outputs.model_eval != 'false'", step["if"])
        self.assertEqual(self.jobs["gates-linux-result"]["permissions"], {"statuses": "read"})
        context = "model-eval/" + "b" * 40
        passed = {"context": context, "state": "success", "target_url": "https://example.org/report"}
        args = '[[ "$*" == "api --paginate --slurp repos/org/repo/commits/head/statuses?per_page=100" ]]'
        stub = 'gh() { ' + args + ' && echo "$PAGES"; }\n'
        for pages, ok in (([[], [passed]], True), ([[]], False), ([[dict(passed, context="other")]], False),
                          ([[dict(passed, state="pending"), passed]], False), ([[dict(passed, target_url=None)]], False)):
            with self.subTest(pages=pages):
                env = dict(os.environ, GITHUB_REPOSITORY="org/repo", BASE_SHA="b" * 40,
                           HEAD_SHA="head", PAGES=json.dumps(pages))
                result = subprocess.run([*BASH, stub + step["run"]], env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, ok, result.stderr)

    def test_every_leg_flag_a_step_reads_is_set_by_a_leg(self) -> None:
        # A flag no leg sets is a step that runs on no runner at all. A step
        # the OS condition keeps off this platform (the arm64 cross-stage on
        # macOS) does not count.
        for job, os_name, flags in GATE_JOBS:
            with self.subTest(job=job):
                spec = self.jobs[job]
                read = set()
                for step in spec["steps"]:
                    if runs_on(step, os_name):
                        read |= leg_flags(step)
                self.assertLessEqual(read, LEG_FLAGS)
                legs = spec["strategy"]["matrix"]["include"]
                set_by_legs = {key for leg in legs for key, value in leg.items() if value is True}
                self.assertEqual(read, flags)
                self.assertEqual(set_by_legs, flags)
                self.assertEqual(len({leg["leg"] for leg in legs}), len(legs))
                self.assertIn("${{ matrix.leg }}", spec["name"])

    def test_every_gate_job_sets_the_build_runner_jobs_its_suite_steps_pass(self) -> None:
        # An unset ZIG_BUILD_JOBS turns `-j"$ZIG_BUILD_JOBS"` into a bare `-j`.
        for job, _, _ in GATE_JOBS:
            with self.subTest(job=job):
                spec = self.jobs[job]
                if job.endswith("-vm"):
                    # Sized to the VM in .github/runner-pools.json, a positive
                    # integer (test_ci_pool_plan.py).
                    platform = "macos" if job.startswith("gates-macos") else "windows"
                    self.assertEqual(spec["env"]["ZIG_BUILD_JOBS"],
                                     "${{ needs.runner-plan.outputs.%s_zig_build_jobs }}" % platform)
                else:
                    self.assertRegex(str(spec["env"].get("ZIG_BUILD_JOBS", "")), r"^[1-9][0-9]*$")
                uses = [step for step in spec["steps"] if "ZIG_BUILD_JOBS" in step.get("run", "")]
                self.assertTrue(uses)
                for step in uses:
                    self.assertTrue(all("test:" in line or "PACKAGE_TESTS" in line
                                        for line in step["run"].splitlines() if "ZIG_BUILD_JOBS" in line))

    def test_only_environment_setup_runs_on_every_leg(self) -> None:
        for job, setup in SETUP_STEPS.items():
            with self.subTest(job=job):
                unflagged = {step_label(step) for step in self.jobs[job]["steps"] if not leg_flags(step)}
                self.assertEqual(unflagged, setup)

    def test_every_gate_leg_runs_the_source_level_guards_first(self) -> None:
        # `zig build gate:static` takes seconds, and a failed guard inside a
        # suite step is reported only when the step ends (#587): every leg
        # runs it before anything else that builds.
        for job, os_name, flags in GATE_JOBS:
            with self.subTest(job=job):
                steps = [step for step in self.jobs[job]["steps"] if runs_on(step, os_name)]
                guards = [i for i, step in enumerate(steps) if step.get("run", "").strip() == "zig build gate:static"]
                self.assertEqual(len(guards), 1)
                guard = steps[guards[0]]
                self.assertEqual(leg_flags(guard), flags)
                self.assertNotIn("runner.os", guard["if"])
                for step in steps[:guards[0]]:
                    run = step.get("run", "")
                    self.assertNotRegex(run, r"\b(zig|lake) ", step_label(step))

    def test_every_platform_runs_every_part_of_the_suite(self) -> None:
        # `zig build test` is exactly its three parts (build.zig); each
        # platform must run all three on legs it has.
        for job, os_name, _ in GATE_JOBS:
            with self.subTest(job=job):
                spec = self.jobs[job]
                legs = spec["strategy"]["matrix"]["include"]
                ran = set()
                for step in spec["steps"]:
                    if not runs_on(step, os_name) or "run" not in step:
                        continue
                    flags = leg_flags(step)
                    if not any(leg.get(flag) is True for leg in legs for flag in flags):
                        continue
                    for words in (line.split() for line in step["run"].splitlines()):
                        if words[:2] == ["zig", "build"]:
                            ran |= TEST_PARTS & set(words[2:])
                self.assertEqual(ran, TEST_PARTS)

    def test_both_posix_gates_and_both_tty_platforms_run_one_step_list(self) -> None:
        self.assertEqual(self.jobs["gates-macos"]["steps"], self.jobs["gates-linux"]["steps"])
        self.assertEqual(self.jobs["gates-macos-vm"]["steps"], self.jobs["gates-linux"]["steps"])
        self.assertEqual(self.jobs["windows-gates-vm"]["steps"], self.jobs["windows-gates"]["steps"])
        self.assertEqual(self.jobs["tty-windows"]["steps"], self.jobs["tty-linux"]["steps"])

    def test_the_tty_shards_cover_the_suite(self) -> None:
        for job in ("tty-linux", "tty-windows"):
            with self.subTest(job=job):
                spec = self.jobs[job]
                shards = spec["strategy"]["matrix"]["shard"]
                self.assertEqual(shards, list(range(1, len(shards) + 1)))
                self.assertEqual(spec["env"]["TTY_SHARD"], "${{ matrix.shard }}/${{ strategy.job-total }}")

    def test_the_sdk_job_reports_on_every_run(self) -> None:
        # Not a required check today; reporting under its own name on every
        # run keeps it safe to make one.
        spec = self.jobs["sdk-bindings"]
        self.assertEqual(spec["if"], "${{ !cancelled() }}")
        self.assertEqual(spec["env"]["SDK"], "${{ needs.scope.outputs.tty }}")
        for step in spec["steps"]:
            label = step_label(step)
            if label in ECHO_STEPS:
                continue
            with self.subTest(step=label):
                if step.get("uses", "").startswith(("actions/cache/restore@", "actions/cache/save@")):
                    self.assertTrue(step.get("if", "").endswith(" && env.SDK != 'false'"))  # CacheTest
                else:
                    self.assertEqual(step.get("if"), "env.SDK != 'false'")

    def test_the_selection_outputs_reach_the_suite_steps(self) -> None:
        for name in ("units", "product", "packages", "package_tests", "script_tests", "complete"):
            self.assertEqual(self.jobs["scope"]["outputs"][name], "${{ steps.decide.outputs.%s }}" % name)
        for job, names in (("gates-linux", ("units", "product", "package_tests", "script_tests", "complete")),
                           ("gates-macos", ("units", "product", "package_tests", "script_tests", "complete")),
                           ("gates-macos-vm", ("units", "product", "package_tests", "script_tests", "complete")),
                           ("windows-gates", ("units", "product", "package_tests")),
                           ("windows-gates-vm", ("units", "product", "package_tests"))):
            for name in names:
                with self.subTest(job=job, output=name):
                    self.assertEqual(self.jobs[job]["env"][name.upper()], "${{ needs.scope.outputs.%s }}" % name)

    def test_a_narrowed_scope_skips_only_the_suites_it_does_not_select(self) -> None:
        # Fail open: an empty output (the scope job failed) runs test:units,
        # integration and product, never the package steps alone.
        for job in ("gates-linux", "windows-gates"):
            steps = {step_label(step): step for step in self.jobs[job]["steps"]}
            with self.subTest(job=job):
                units = "Offline test suite (units and integration)" if job == "gates-linux" else "Offline test suite (units)"
                packages = ("Offline test suite (affected packages and integration)" if job == "gates-linux"
                            else "Offline test suite (affected packages)")
                self.assertTrue(steps[units]["if"].endswith("&& env.UNITS != 'false' && env.PACKAGE_TESTS == ''"))
                self.assertTrue(steps[packages]["if"].endswith("&& env.UNITS != 'false' && env.PACKAGE_TESTS != ''"))
                self.assertIn("PACKAGE_TESTS", steps[packages]["run"])
                self.assertNotIn("test:units", steps[packages]["run"])
                for name, condition, target in (("product", "!=", "test:product"),
                                                ("product runtime", "==", "test:product-runtime")):
                    step = steps[f"Offline test suite ({name})"]
                    self.assertTrue(step["if"].endswith(f"&& env.PRODUCT != 'false' && env.OFFLINE_EVAL {condition} 'false'"))
                    self.assertIn(f"zig build {target} ", step["run"])
                # The lower packages' other unit runs skip with test:units.
                self.assertTrue(steps["Native platform modules"]["if"].endswith("&& env.PACKAGE_TESTS == ''"))
        core = next(step for step in self.jobs["gates-linux"]["steps"] if step.get("name") == "ReleaseSafe core gate")
        self.assertTrue(core["if"].endswith("&& env.PACKAGE_TESTS == ''"))
        integration = next(step for step in self.jobs["windows-gates"]["steps"]
                           if step.get("name") == "Offline test suite (integration)")
        self.assertTrue(integration["if"].endswith("&& env.UNITS != 'false'"))
        changed = next(step for step in self.jobs["gates-linux"]["steps"] if step.get("name") == "Changed script unit suites")
        self.assertTrue(changed["if"].startswith("matrix.checks &&"))
        self.assertTrue(changed["if"].endswith("&& env.SCRIPT_TESTS != ''"))
        self.assertIn('python3 -m unittest "${modules[@]}" -v', changed["run"])

    @unittest.skipIf(os.name == "nt", "bash")
    def test_the_package_steps_split_the_selection_into_words(self) -> None:
        step = next(step for step in self.jobs["gates-linux"]["steps"]
                    if step.get("name") == "Offline test suite (affected packages and integration)")
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "zig"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n', encoding="utf-8")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}{os.pathsep}{os.environ['PATH']}",
                       PACKAGE_TESTS="test:mid test:top", ZIG_BUILD_JOBS="4")
            proc = subprocess.run([*BASH, step["run"]], env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.splitlines()[:4], ["build", "test:mid", "test:top", "test:integration"])

    def test_only_a_complete_run_records_and_keeps_its_test_ids(self) -> None:
        steps = {step_label(step): step for step in self.jobs["gates-linux"]["steps"]}
        for name in ("Record the executed test IDs", "Upload the executed test IDs"):
            self.assertTrue(steps[name]["if"].endswith("&& env.COMPLETE != 'false'"), name)
        job = self.jobs["test-ids"]
        kept = [step for step in job["steps"] if step.get("uses", "").startswith(("actions/download-artifact@", "actions/upload-artifact@"))
                or step.get("name") == "Collect the executed test IDs"]
        self.assertEqual(len(kept), 3)
        for step in kept:
            self.assertEqual(step["if"], "needs.scope.outputs.complete != 'false'", step_label(step))
        compare = next(step for step in job["steps"] if step.get("name") == "Compare with the base's test IDs")
        self.assertEqual(compare["env"]["COMPLETE"], "${{ needs.scope.outputs.complete }}")
        self.assertIn('--scope-complete "$COMPLETE"', compare["run"])

    def test_the_nightly_run_lists_the_scopes_of_the_days_merges(self) -> None:
        job = self.jobs["merged-scopes"]
        self.assertEqual(job["if"], "${{ github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' }}")
        self.assertNotIn("needs", job)
        self.assertEqual(job["steps"][0]["with"]["fetch-depth"], 0)
        self.assertEqual(job["steps"][1]["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertIn('python3 scripts/ci_scope.py merged --since "24 hours ago" --repository "$GITHUB_REPOSITORY"',
                      job["steps"][1]["run"])
        decide = next(step for step in self.jobs["scope"]["steps"] if step.get("id") == "decide")
        self.assertEqual(decide["env"]["PR_LABELS"], "${{ join(github.event.pull_request.labels.*.name, ',') }}")
        self.assertIn('--labels "$PR_LABELS" --record "$RUNNER_TEMP/change-scope.json" --fast-path "$FAST_PATH"', decide["run"])
        self.assertEqual(decide["env"]["FAST_PATH"], "${{ needs.release-fast-path.outputs.fast }}")
        self.assertEqual((self.jobs["scope"]["needs"], self.jobs["scope"]["if"]), ("release-fast-path", "${{ !cancelled() }}"))
        upload = self.jobs["scope"]["steps"][-1]
        self.assertTrue(upload["uses"].startswith("actions/upload-artifact@"))
        self.assertEqual((upload["with"]["name"], upload["with"]["path"]),
                         (ci_scope.SCOPE_ARTIFACT, "${{ runner.temp }}/" + ci_scope.SCOPE_RECORD))
        triggers = self.workflow.get("on", self.workflow.get(True))
        self.assertIn("schedule", triggers)
        self.assertIn("workflow_dispatch", triggers)
        for result in ("gates-linux-result", "gates-macos-result", "gates-windows-result", "tty-linux-result", "full-pr-evidence"):
            self.assertNotIn("merged-scopes", self.jobs[result]["needs"])

    def run_decide(self, job: str, event: str) -> tuple:
        step = next(s for s in self.jobs[job]["steps"] if s.get("name") == "Decide")
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            log = Path(tmp) / "calls.log"
            for name in ("git", "python3"):
                fake = bindir / name
                fake.write_text('#!/bin/sh\necho "%s $*" >> "$FAKE_LOG"\n' % name, encoding="utf-8")
                fake.chmod(0o755)
            output = Path(tmp) / "github-output"
            output.write_text("", encoding="utf-8")
            env = dict(os.environ, PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}", FAKE_LOG=str(log),
                       GITHUB_EVENT_NAME=event, GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY="o/r",
                       MERGE_GROUP_BASE_SHA="b" * 40 if event == "merge_group" else "")
            proc = subprocess.run([*BASH, step["run"]], env=env, capture_output=True, text=True)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return proc, calls, output.read_text(encoding="utf-8")

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_each_decision_takes_the_base_of_its_event(self) -> None:
        for job, script in (("release-fast-path", "scripts/release_fast_path.py"), ("scope", "scripts/ci_scope.py")):
            with self.subTest(job=job, event="pull_request"):
                proc, calls, _ = self.run_decide(job, "pull_request")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(len(calls), 1, calls)
                self.assertTrue(calls[0].startswith(f"python3 {script} "), calls)
                self.assertIn("--base HEAD^1 --candidate HEAD", calls[0])
            with self.subTest(job=job, event="merge_group"):
                proc, calls, _ = self.run_decide(job, "merge_group")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(calls[0], "git fetch -q --no-tags --depth=1 origin " + "b" * 40)
                self.assertIn("--base %s --candidate HEAD" % ("b" * 40), calls[1])

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_a_push_is_not_a_narrow_scope_event(self) -> None:
        proc, calls, output = self.run_decide("release-fast-path", "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])
        self.assertIn("fast=false", output)
        proc, calls, _ = self.run_decide("scope", "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith('python3 scripts/ci_scope.py --event push --base  --candidate HEAD '), calls)

    def test_scope_uses_only_checkout_inputs(self) -> None:
        self.assertEqual(self.jobs["scope"]["permissions"], {"contents": "read"})
        step = next(s for s in self.jobs["scope"]["steps"] if s.get("id") == "decide")
        self.assertNotIn("GH_TOKEN", step["env"])
        self.assertNotIn("PUSH_BASE_SHA", step["env"])



class AgentCoreWorkflowTest(unittest.TestCase):
    """agentcore-windows.yml's scope step, with its `${{ }}` expressions
    rendered the way the runner renders them."""

    def setUp(self) -> None:
        try:
            import yaml
        except ImportError:  # requirements-dev.txt
            self.skipTest("PyYAML is not installed")
        workflow = yaml.safe_load(AGENTCORE_WORKFLOW.read_text(encoding="utf-8"))
        self.workflow = workflow
        self.step = next(s for s in workflow["jobs"]["native-windows-gate"]["steps"] if s.get("id") == "scope")

    def test_the_merge_queue_runs_the_workflow(self) -> None:
        self.assertIn("merge_group", self.workflow.get("on", self.workflow.get(True)))
        self.assertNotIn("push", self.workflow.get("on", self.workflow.get(True)))

    def render(self, event: str) -> str:
        values = {
            "github.event_name": event,
            "github.event.pull_request.base.sha": "p" * 40 if event == "pull_request" else "",
            "github.event.merge_group.base_sha": "m" * 40 if event == "merge_group" else "",
        }
        rendered = re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda m: values[m.group(1)], self.step["run"])
        self.assertNotIn("${{", rendered)
        return rendered

    def run_step(self, event: str, changed: str) -> tuple:
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            log = Path(tmp) / "calls.log"
            fake = bindir / "git"
            fake.write_text('#!/bin/sh\necho "git $*" >> "$FAKE_LOG"\n'
                            'case "$1" in diff) printf "%s\\n" "$FAKE_CHANGED" ;; esac\n', encoding="utf-8")
            fake.chmod(0o755)
            output = Path(tmp) / "github-output"
            output.write_text("", encoding="utf-8")
            env = dict(os.environ, PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}", FAKE_LOG=str(log),
                       FAKE_CHANGED=changed, GITHUB_OUTPUT=str(output))
            proc = subprocess.run([*BASH, self.render(event)], env=env, capture_output=True, text=True)
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return proc, calls, output.read_text(encoding="utf-8")

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_a_merge_group_is_judged_by_its_diff_against_the_group_base(self) -> None:
        proc, calls, output = self.run_step("merge_group", "doc/API.md")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, ["git fetch -q --depth=1 origin " + "m" * 40, "git diff --name-only %s HEAD" % ("m" * 40)])
        self.assertIn("relevant=false", output)
        proc, _, output = self.run_step("merge_group", "packages/agentcore/abi_v1.zig")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("relevant=true", output)

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture")
    def test_a_pull_request_uses_its_base_and_unknown_events_run_in_full(self) -> None:
        proc, calls, _ = self.run_step("pull_request", "doc/API.md")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls[0], "git fetch -q --depth=1 origin " + "p" * 40)
        proc, calls, output = self.run_step("push", "")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])
        self.assertIn("relevant=true", output)

    def test_native_steps_read_relevance(self) -> None:
        steps = self.workflow["jobs"]["native-windows-gate"]["steps"]
        for step in steps:
            if step.get("uses") == CHECKOUT or step.get("id") == "scope":
                continue
            if step.get("uses", "").startswith(("actions/cache/restore@", "actions/cache/save@")):
                self.assertTrue(step.get("if", "").endswith(" && steps.scope.outputs.relevant == 'true'"))  # CacheTest
            else:
                self.assertEqual(step.get("if"), "steps.scope.outputs.relevant == 'true'")


def render_warm_cache(expression: str, ref: str, event: str) -> bool:
    """The WARM_CACHE expression as the runner evaluates it for one run."""
    body = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", expression).group(1)
    body = body.replace("github.event_name", repr(event)).replace("github.ref", repr(ref))
    return eval(body.replace("&&", " and ").replace("||", " or "), {"__builtins__": {}}, {})


def zig_cache_steps(steps: list, action: str) -> list:
    return [step for step in steps
            if step.get("uses", "").startswith(action) and step.get("with", {}).get("path") == ".zig-cache"]


class CacheTest(unittest.TestCase):
    """Pull requests restore the caches main's nightly run saves, and save
    none (doc/CI_DESIGN.md §5): a pull request can read its base branch's
    caches but no other pull request's, and pull requests that saved their own
    filled the repository's 10 GB with copies nobody else could read."""

    def setUp(self) -> None:
        try:
            import yaml
        except ImportError:  # requirements-dev.txt
            self.skipTest("PyYAML is not installed")
        self.workflows = {path.name: yaml.safe_load(path.read_text(encoding="utf-8"))
                          for path in (WORKFLOW, AGENTCORE_WORKFLOW)}

    def test_only_mains_scheduled_or_dispatched_run_warms(self) -> None:
        for name, workflow in self.workflows.items():
            with self.subTest(workflow=name):
                triggers = workflow.get("on", workflow.get(True))
                self.assertNotIn("push", triggers)  # no full run after every merge
                self.assertTrue(triggers["schedule"][0]["cron"])
                expression = workflow["env"]["WARM_CACHE"]
                for ref, event, warm in (("refs/heads/main", "schedule", True),
                                         ("refs/heads/main", "workflow_dispatch", True),
                                         ("refs/pull/7/merge", "pull_request", False),
                                         ("refs/heads/topic", "workflow_dispatch", False),
                                         ("refs/heads/gh-readonly-queue/main/pr-7-" + "a" * 40, "merge_group", False)):
                    self.assertEqual(render_warm_cache(expression, ref, event), warm, (ref, event))

    def test_nothing_saves_outside_the_warm_run(self) -> None:
        for name, workflow in self.workflows.items():
            for job_id, job in workflow["jobs"].items():
                for step in job.get("steps", []):
                    uses = step.get("uses", "")
                    with self.subTest(workflow=name, job=job_id, step=step_label(step)):
                        # actions/cache and setup-zig's own cache save at the end of every run.
                        self.assertFalse(uses.startswith("actions/cache@"))
                        if uses.startswith("mlugg/setup-zig@"):
                            self.assertIs(step["with"]["use-cache"], False)
                        if uses.startswith("actions/cache/save@"):
                            self.assertTrue(step["if"].startswith("env.WARM_CACHE == 'true' && "), step["if"])

    def test_every_zig_job_restores_exactly_what_main_saves(self) -> None:
        for name, workflow in self.workflows.items():
            for job_id, job in workflow["jobs"].items():
                steps = job.get("steps", [])
                zig = [step for step in steps if step.get("uses", "").startswith("mlugg/setup-zig@")]
                if not zig:
                    continue
                with self.subTest(workflow=name, job=job_id):
                    restores = zig_cache_steps(steps, "actions/cache/restore@")
                    saves = zig_cache_steps(steps, "actions/cache/save@")
                    self.assertEqual((len(zig), len(restores), len(saves)), (1, 1, 1))
                    zig, restore, save = zig[0], restores[0], saves[0]
                    key = save["with"]["key"]
                    self.assertTrue(key.endswith(RUN_SUFFIX), key)
                    self.assertTrue(key.startswith("zig-0.16.0-${{ runner.os }}-${{ runner.arch }}-"), key)
                    self.assertEqual(restore["with"]["key"], key[: -len(RUN_SUFFIX)])
                    self.assertEqual(restore["with"]["restore-keys"], restore["with"]["key"])
                    # Both run wherever Zig is set up: the restore first, the save last.
                    # A job sharing the pool job's steps reads neither on the pool host.
                    pool = "env.POOL_JOB != 'true' && " if any(
                        step.get("name") == HOST_CACHE_STEP for step in steps) else ""
                    self.assertEqual(restore["if"], "env.WARM_CACHE != 'true' && " + pool + zig["if"])
                    self.assertTrue(save["if"].startswith("env.WARM_CACHE == 'true' && " + pool), save["if"])
                    self.assertTrue(save["if"].endswith(" && " + zig["if"]), save["if"])
                    self.assertEqual(steps.index(restore), steps.index(zig) + 1)
                    self.assertEqual(steps.index(save), len(steps) - 1)

    def test_the_pool_host_keeps_its_caches_on_disk(self) -> None:
        jobs = self.workflows["ci.yml"]["jobs"]
        steps = jobs["gates-macos-vm"]["steps"]
        host = next(step for step in steps if step.get("name") == HOST_CACHE_STEP)
        self.assertTrue(host["if"].startswith("env.POOL_JOB == 'true' && "), host["if"])
        self.assertIn("git clean -ffdx -e /.zig-cache -e /control-plane/lean/.lake", host["run"])
        checkout = next(step for step in steps if step.get("uses") == CHECKOUT)
        self.assertEqual(checkout["with"]["clean"], "${{ env.POOL_JOB != 'true' }}")
        self.assertTrue(host["run"].rstrip().endswith('test -z "$(git status --porcelain --untracked-files=normal)"'))
        self.assertLess(steps.index(host), next(i for i, step in enumerate(steps)
                                                if step.get("uses", "").startswith("mlugg/setup-zig@")))
        for step in steps:
            if step.get("uses", "").startswith(("actions/cache/restore@", "actions/cache/save@")):
                with self.subTest(step=step_label(step)):
                    self.assertIn("env.POOL_JOB != 'true' && ", step["if"])

    def test_lean_products_are_restored_everywhere_and_saved_by_the_warm_run(self) -> None:
        jobs = self.workflows["ci.yml"]["jobs"]
        for job_id in ("gates-linux", "gates-macos", "windows-gates"):
            with self.subTest(job=job_id):
                steps = jobs[job_id]["steps"]
                restore = next(s for s in steps if s.get("name") == "Restore Lean toolchain and build products")
                save = next(s for s in steps if s.get("name") == "Save Lean toolchain and build products")
                self.assertEqual(restore["id"], "lean")
                self.assertTrue(restore["uses"].startswith("actions/cache/restore@"))
                self.assertEqual(save["with"]["path"], restore["with"]["path"])
                self.assertEqual(save["with"]["key"], "${{ steps.lean.outputs.cache-primary-key }}")
                # One leg per platform, and only when main does not hold this state of the sources.
                self.assertIn("matrix.units", save["if"])
                self.assertIn("steps.lean.outputs.cache-hit != 'true'", save["if"])
                self.assertLess(steps.index(restore), steps.index(save))


if __name__ == "__main__":
    unittest.main()
