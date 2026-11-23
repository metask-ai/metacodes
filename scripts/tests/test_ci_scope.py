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
    "Gates (Linux)": "gates-linux",
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
        before = {"implementation_paths": ["src/main.zig", "doc/A.md"], "budget": 0}
        moved = {"implementation_paths": ["src/main.zig", "doc/B.md"], "budget": 0}
        self.assertTrue(ci_scope.protocol_documents_only(before, moved))
        for after in ({**moved, "budget": 1}, {**moved, "budget": False},
                      {**moved, "implementation_paths": ["src/other.zig", "doc/B.md"]}):
            self.assertFalse(ci_scope.protocol_documents_only(before, after))

    def test_markdown_outside_doc_and_the_top_level_is_an_input(self) -> None:
        # Prompt templates are @embedFile'd; agent and Skill fixtures are read by tests.
        for path in ("src/core/templates/compact/prompt.md", "tests/e2e/fixtures/agents/release-mcp.md", "sdk/README.md"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")

    def test_the_evaluation_harness_is_the_eval_scope(self) -> None:
        for paths in (["scripts/eval/chained_runner.py"], ["evals/experiments/learning-turn-v1.md"],
                      ["evals/validators/d1_check_gate_v3_cron.py", "doc/README.md"]):
            with self.subTest(paths=paths):
                self.assertEqual(ci_scope.classify(paths)[0], "eval")

    def test_anything_else_is_the_full_scope_and_is_named(self) -> None:
        scope, reason = ci_scope.classify(["scripts/eval/cli.py", "src/main.zig"])
        self.assertEqual(scope, "full")
        self.assertIn("src/main.zig", reason)
        self.assertNotIn("scripts/eval/cli.py", reason)
        for path in ("build.zig", "scripts/release_cut.py", ".github/workflows/ci.yml", "tests/tty/tty_driver.py", "scripts/evaluate.py"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")

    def test_no_paths_is_the_full_scope(self) -> None:
        self.assertEqual(ci_scope.classify([])[0], "full")

    def test_outputs_fail_open(self) -> None:
        self.assertEqual(ci_scope.outputs("docs"), (False, False))
        self.assertEqual(ci_scope.outputs("eval"), (True, False))
        self.assertEqual(ci_scope.outputs("full"), (True, True))


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
        changes = [("M", name)] + [("M", f"doc/{i}.md") for i in range(200)] + [("M", "src/main.zig")]
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
        self.assertEqual(set(job["needs"]), {"release-fast-path", "scope", "gates-linux", "gates-macos-result",
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
                if name not in ("Gates (macOS)", "Gates (Windows)"):
                    self.assertEqual(spec["steps"], self.jobs["gates-linux-result"]["steps"])

    @unittest.skipIf(os.name == "nt", "bash and jq")
    def test_a_result_job_passes_only_when_every_leg_succeeded(self) -> None:
        step = self.jobs["gates-linux-result"]["steps"][0]
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
                    self.assertTrue(all("test:" in line for line in step["run"].splitlines() if "ZIG_BUILD_JOBS" in line))

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
        proc, _, output = self.run_step("merge_group", "src/agentcore/abi_v1.zig")
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
        self.assertIn('ln -s "$root/zig-cache" .zig-cache', host["run"])
        self.assertIn('ln -s "$root/lean-lake" control-plane/lean/.lake', host["run"])
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
