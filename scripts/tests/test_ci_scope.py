"""scripts/ci_scope.py and how ci.yml uses it (doc/CI_DESIGN.md §2-§4).

The classification is a pure function of the changed paths. The workflow
tests pin the wiring: which gate steps still run on a documentation-only
change, that every other step of a leg or shard reads its scope, that the
scope fails open, that each required check is a result job that passes only
when all of its legs did, and that the decision steps pick the right base for
a pull request, a merge queue group and a push."""
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
from unittest.mock import patch

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
    "Gate manifest unit tests",
    "Diff whitespace check",
}
ECHO_STEPS = {"Release fast path", "Change scope"}
# The jobs that do the work, one runner per leg or shard (doc/CI_DESIGN.md §4),
# and the switch each one's steps read.
LEG_JOBS = (("gates-linux", "SUITES"), ("gates-macos", "SUITES"), ("windows-gates", "SUITES"),
            ("tty-linux", "TTY"), ("tty-windows", "TTY"))
# The checks the `Protect main` ruleset requires, plus TTY (Windows), and the
# job whose legs or shards each one reports.
RESULT_JOBS = {
    "Gates (Linux)": "gates-linux",
    "Gates (macOS)": "gates-macos",
    "Gates (Windows)": "windows-gates",
    "TTY (Linux)": "tty-linux",
    "TTY (Windows)": "tty-windows",
}
# The leg flags a gate step may be gated on; a step without one runs on every leg.
LEG_FLAGS = {"units", "integration", "product", "release", "cross", "checks"}
# Each gate job, its runner OS and the flags its steps read there.
GATE_JOBS = (("gates-linux", "Linux", {"units", "product", "release", "cross", "checks"}),
             ("gates-macos", "macOS", {"units", "product", "release", "checks"}),
             ("windows-gates", "Windows", {"units", "integration", "product", "release"}))
TEST_PARTS = {"test:units", "test:integration", "test:product"}
# The gate steps without a leg flag: environment setup, which runs on every
# leg. A new step names the leg it belongs to; added here instead, it runs on
# all twelve gate runners.
SETUP_STEPS = {
    "gates-linux": {
        "Release fast path", "Change scope", CHECKOUT,
        "mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29",
        "Restore Lean toolchain and build products", "Install pinned elan", "Build pinned Lean kernel",
        "Install ripgrep", "Install bubblewrap", "Install Python development dependencies",
    },
    "windows-gates": {
        "Release fast path", "Change scope", CHECKOUT,
        "mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29",
        "Normalize line endings of the checkout", "Install Python development dependencies",
        "Restore Lean toolchain and build products", "Install pinned elan",
    },
}


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

    def test_markdown_the_release_layout_installs_is_not_documentation(self) -> None:
        # build.zig installs these into share/doc and share/licenses, and
        # gen_third_party_notices.py --check regenerates the notices.
        for path in ("README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md"):
            with self.subTest(path=path):
                self.assertEqual(ci_scope.classify([path])[0], "full")
                self.assertEqual(ci_scope.classify(["doc/API.md", path])[0], "full")

    def test_every_top_level_file_build_zig_installs_is_excluded(self) -> None:
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        installed = set(re.findall(r'\.source = "([^"/]+\.md)"', build))
        self.assertIn("THIRD_PARTY_NOTICES.md", installed)  # the pattern still finds them
        self.assertEqual(installed - set(ci_scope.RELEASE_DOCS), set())

    def test_a_removed_documentation_file_is_the_full_scope(self) -> None:
        # evals/plugin-v1/protocol.json pins doc paths that zig build test resolves.
        scope, reason = ci_scope.classify(["doc/CORE_REFERENCE.md", "doc/history/CORE_REFERENCE.md"],
                                          deleted=["doc/CORE_REFERENCE.md"])
        self.assertEqual(scope, "full")
        self.assertIn("doc/CORE_REFERENCE.md removed", reason)
        # Removing harness files keeps the eval scope; only doc removals widen it.
        self.assertEqual(ci_scope.classify(["scripts/eval/old.py"], deleted=["scripts/eval/old.py"])[0], "eval")

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

        for event in ("workflow_dispatch", ""):
            with self.subTest(event=event):
                self.assertEqual(ci_scope.decide(event, "abc", "HEAD", no_diff)[0], "full")

    def test_a_narrow_push_requires_successful_ci_on_its_base(self) -> None:
        for path, expected in (("doc/API.md", "docs"), ("scripts/eval/cli.py", "eval")):
            for state in ("success", "pending", "failure", "unknown"):
                with self.subTest(path=path, state=state):
                    seen = []

                    def baseline(sha):
                        seen.append(sha)
                        return state

                    scope, reason = ci_scope.decide("push", "before-sha", "HEAD",
                                                   lambda b, c: [("M", path)], baseline)
                    self.assertEqual(scope, expected if state == "success" else "full")
                    self.assertEqual(seen, ["before-sha"])
                    self.assertIn("before-sha", reason)

    def test_a_failed_or_missing_base_query_runs_in_full(self) -> None:
        def broken(sha):
            raise RuntimeError("API unavailable")

        changes = lambda b, c: [("M", "doc/API.md")]
        self.assertEqual(ci_scope.decide("push", "base", "HEAD", changes)[0], "full")
        scope, reason = ci_scope.decide("push", "base", "HEAD", changes, broken)
        self.assertEqual(scope, "full")
        self.assertIn("API unavailable", reason)

    def test_full_pushes_and_prs_do_not_query_base_ci(self) -> None:
        def unexpected(sha):
            raise AssertionError("must not query base CI")

        for event, path, expected in (("push", "src/main.zig", "full"),
                                      ("pull_request", "doc/API.md", "docs"),
                                      ("merge_group", "doc/API.md", "docs")):
            scope, reason = ci_scope.decide(event, "base", "HEAD", lambda b, c: [("M", path)], unexpected)
            self.assertEqual(scope, expected)
            self.assertNotIn("scope check failed", reason)

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
        (self.repo / "doc").mkdir()
        (self.repo / "doc" / "A.md").write_text("a\n", encoding="utf-8")
        (self.repo / "main.zig").write_text("x\n", encoding="utf-8")
        self.commit("base")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def git(self, *argv: str) -> str:
        return subprocess.run(["git", *argv], cwd=str(self.repo), check=True, capture_output=True, text=True).stdout

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def run_main(self, event: str, base: str, state: str = "success") -> dict:
        out = self.repo / "github-output"
        out.write_text("", encoding="utf-8")
        with redirect_stdout(io.StringIO()), patch("release_fast_path.base_ci_state", return_value=state):
            code = ci_scope.main(["--event", event, "--base", base, "--candidate", "HEAD",
                                  "--github-output", str(out), "--repo-root", str(self.repo),
                                  "--repository", "o/r", "--github-summary", str(self.repo / "summary.md")])
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

    def test_push_uses_the_whole_batch_instead_of_just_the_last_commit(self) -> None:
        base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "main.zig").write_text("code change\n", encoding="utf-8")
        self.commit("code")
        (self.repo / "doc" / "A.md").write_text("docs\n", encoding="utf-8")
        self.commit("docs")
        self.assertEqual(self.run_main("push", base)["scope"], "full")
        self.assertEqual(self.run_main("push", "HEAD^1")["scope"], "docs")

    def test_push_baseline_evidence_reaches_the_cli_decision(self) -> None:
        (self.repo / "doc" / "A.md").write_text("b\n", encoding="utf-8")
        self.commit("docs")
        for state in ("success", "pending", "failure"):
            self.assertEqual(self.run_main("push", "HEAD^1", state)["scope"],
                             "docs" if state == "success" else "full")

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

    def test_a_move_within_doc_is_the_full_scope(self) -> None:
        (self.repo / "doc" / "history").mkdir()
        self.git("mv", "doc/A.md", "doc/history/A.md")
        self.commit("retire")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual((got["scope"], got["suites"], got["tty"]), ("full", "true", "true"))
        self.assertIn("doc/A.md removed", got["reason"])

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_a_documentation_file_turned_into_a_symlink_is_the_full_scope(self) -> None:
        # plugin_release_gate refuses a pinned path that is a symlink.
        (self.repo / "doc" / "A.md").unlink()
        os.symlink("../main.zig", self.repo / "doc" / "A.md")
        self.commit("symlink")
        got = self.run_main("pull_request", "HEAD^1")
        self.assertEqual(got["scope"], "full")
        self.assertIn("doc/A.md removed or changed type", got["reason"])

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

    def test_every_leg_reads_its_scope(self) -> None:
        for job, var in LEG_JOBS:
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertEqual(sorted(spec["needs"]), ["release-fast-path", "scope"])
                self.assertEqual(spec["if"], "${{ !cancelled() }}")
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
            env["PUSH_BASE_SHA"] = "c" * 40 if event == "push" else ""
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
    def test_a_push_run_uses_before_and_release_bumps_still_run_in_full(self) -> None:
        proc, calls, output = self.run_decide("release-fast-path", "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, [])
        self.assertIn("fast=false", output)
        proc, calls, _ = self.run_decide("scope", "push")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls[0], "git fetch -q --no-tags --depth=1 origin " + "c" * 40)
        self.assertTrue(calls[1].startswith("python3 scripts/ci_scope.py --event push --base %s --candidate HEAD " % ("c" * 40)), calls)

    def test_scope_can_read_base_ci_without_granting_write_access(self) -> None:
        self.assertEqual(self.jobs["scope"]["permissions"], {"contents": "read", "actions": "read"})
        step = next(s for s in self.jobs["scope"]["steps"] if s.get("id") == "decide")
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        self.assertEqual(step["env"]["PUSH_BASE_SHA"], "${{ github.event.before }}")



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
            python = bindir / "python"
            python.write_text('#!/bin/sh\necho "python $*" >> "$FAKE_LOG"\n'
                              'printf "scope=docs\\nsuites=false\\nnative=false\\n" >> "$GITHUB_OUTPUT"\n', encoding="utf-8")
            python.chmod(0o755)
            output = Path(tmp) / "github-output"
            output.write_text("", encoding="utf-8")
            env = dict(os.environ, PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}", FAKE_LOG=str(log),
                       FAKE_CHANGED=changed, GITHUB_OUTPUT=str(output), PUSH_BASE_SHA="b" * 40)
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
    def test_a_pull_request_uses_its_base_and_a_push_uses_the_shared_scope(self) -> None:
        proc, calls, _ = self.run_step("pull_request", "doc/API.md")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls[0], "git fetch -q --depth=1 origin " + "p" * 40)
        proc, calls, output = self.run_step("push", "")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls[0], "git fetch -q --no-tags --depth=1 origin " + "b" * 40)
        self.assertIn("python scripts/ci_scope.py --event push --base " + "b" * 40, calls[1])
        self.assertIn("native=false", output)

    def test_native_steps_read_both_scopes_and_default_to_running(self) -> None:
        steps = self.workflow["jobs"]["native-windows-gate"]["steps"]
        for step in steps:
            if step.get("uses") == CHECKOUT or step.get("id") == "scope":
                continue
            self.assertEqual(step.get("if"), "steps.scope.outputs.relevant != 'false' && steps.scope.outputs.native != 'false'")


if __name__ == "__main__":
    unittest.main()
