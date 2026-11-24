import re
import shlex
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def checklist_commands():
    text = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    block = re.search(r"Before submitting:\s*\n\s*```sh\n(.*?)\n```", text, re.S)
    if not block:
        raise AssertionError("AGENTS.md has no Before submitting shell block")
    return [line.strip() for line in block.group(1).splitlines() if line.strip()]


def ci_commands():
    lines = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").splitlines()
    commands = []
    index = 0
    while index < len(lines):
        line = lines[index]
        match = re.match(r"^\s*run:\s*(.*)$", line)
        if match:
            value = match.group(1)
            if value in ("|", ">-"):
                index += 1
                while index < len(lines) and (not lines[index].strip() or len(lines[index]) - len(lines[index].lstrip()) > len(line) - len(line.lstrip())):
                    if lines[index].strip():
                        commands.append(lines[index].strip())
                    index += 1
                continue
            commands.append(value.strip())
        index += 1
    return commands


def normalized_words(command):
    words = shlex.split(command)
    if words and words[0] in ("python", "python3"):
        words[0] = "python"
    return words


# CI runs `zig build test` as its three parts, spread over the gate legs
# (doc/CI_DESIGN.md §4); build.zig makes `test` exactly these three.
TEST_PARTS = ("test:units", "test:integration", "test:product")


def present(words, ci):
    return any(actual[: len(words)] == words for actual in ci)


def test_part_commands(ci):
    """(parts, options) of every `zig build <test parts...> <options>` command."""
    found = []
    for words in ci:
        if words[:2] != ["zig", "build"]:
            continue
        steps = []
        for word in words[2:]:
            if word.startswith("-"):
                break
            steps.append(word)
        if steps and all(step in TEST_PARTS for step in steps):
            # -jN only schedules the build runner (each job sets its own
            # ZIG_BUILD_JOBS); it does not change what runs.
            options = [word for word in words[2 + len(steps):] if not word.startswith("-j")]
            found.append((steps, options))
    return found


# The repository's script suites that no PR run executes, each with where it
# does run. A new suite under scripts/tests/ runs from ci.yml or from
# build.zig's `test` graph, or is listed here with a reason.
SCRIPT_SUITES_RUN_ELSEWHERE = {
    # Builds two complete artifacts per test; rule-control.yml (dispatch only)
    # runs it as the evidence of the artifact-reproducibility rule.
    "test_artifact_reproducibility": ".github/workflows/rule-control.yml",
}


class GateManifestTest(unittest.TestCase):
    def test_every_script_suite_runs_on_every_pull_request(self):
        """A suite nothing runs passes forever. Every scripts/tests module is
        named by a ci.yml step or a build.zig command (the `test` graph runs on
        every pull request), unless it is listed above."""
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        for path in sorted((ROOT / "scripts" / "tests").glob("test_*.py")):
            module = "scripts.tests." + path.stem
            with self.subTest(suite=path.stem):
                named = re.search(re.escape(module) + r"\b", workflow) or ('"%s"' % module) in build
                if path.stem in SCRIPT_SUITES_RUN_ELSEWHERE:
                    self.assertFalse(named, "%s runs on pull requests now; drop its exemption" % path.stem)
                    self.assertIn(module, (ROOT / SCRIPT_SUITES_RUN_ELSEWHERE[path.stem]).read_text(encoding="utf-8")
                                  + (ROOT / "control-plane" / "rules.json").read_text(encoding="utf-8"))
                else:
                    self.assertTrue(named, "%s runs in no pull request run: add a ci.yml step or a build.zig command" % module)

    def test_checklist_commands_are_present_in_ci(self):
        ci = [normalized_words(command) for command in ci_commands()]
        parts = test_part_commands(ci)
        for expected in checklist_commands():
            words = normalized_words(expected)
            if words[:3] == ["zig", "build", "test"]:
                # Every part runs somewhere, with the checklist command's options.
                for part in TEST_PARTS:
                    self.assertTrue(
                        any(part in steps and options[: len(words) - 3] == words[3:] for steps, options in parts),
                        "missing checklist part: zig build %s" % part,
                    )
            else:
                self.assertTrue(present(words, ci), "missing checklist command: %s" % expected)

    def test_every_part_of_the_suite_runs_alike(self):
        """`zig build test` is its three parts (build.zig), and CI runs them on
        separate legs (doc/CI_DESIGN.md §4): every part must run, always with
        the same options, or the split drops or weakens part of the suite.
        Which legs of which platform run them: test_ci_scope.py."""
        parts = test_part_commands([normalized_words(command) for command in ci_commands()])
        self.assertEqual({step for steps, _ in parts for step in steps}, set(TEST_PARTS))
        self.assertEqual(len({tuple(options) for _, options in parts}), 1, parts)

    def test_the_source_level_guards_run_first(self):
        """`gate:static` holds the guards that only read the source, and the
        checklist runs it first: the build runner has no fail-fast, so inside
        `gate:pr` a failed guard surfaces only at the end (#587)."""
        self.assertEqual(checklist_commands()[0], "zig build gate:static")
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn('const gate_static_step = b.step("gate:static",', build)
        deps = set(re.findall(r"\bgate_static_step\.dependOn\(&?([\w.]+?)(?:\.step)?\)", build))
        self.assertTrue({"gate_fmt", "http_status_gate_run", "subsystem_boundary_run", "gate_diff_check"} <= deps, deps)
        # Source-only: the boundary gates' full steps carry their self-tests,
        # test binaries that build and install the fs-helper.
        self.assertFalse(deps & {"http_status_gate_step", "subsystem_boundary_step"}, deps)
        scans = re.findall(r'const (\w+) = b\.addSystemCommand\(&\.\{[^}]*?"scripts\.tests\.test_\w+_discipline"', build, re.S)
        self.assertTrue(scans)
        for scan in scans:
            self.assertIn(scan, deps, "a discipline scan is missing from gate:static")
        self.assertIn("gate_pr_step.dependOn(gate_static_step);", build)

    def test_the_contract_snapshots_run_on_the_linux_checks_leg(self):
        """tests/contract pins the bytes other services depend on. Its one entry
        is `test:contract`; the Linux checks leg runs it, and the Zig API scan,
        which only reads the source, is also in `gate:static` and `test:units`."""
        lines = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").splitlines()
        runs = [i for i, line in enumerate(lines) if line.strip() == "run: zig build test:contract --summary all"]
        self.assertEqual(len(runs), 1, "ci.yml runs zig build test:contract exactly once")
        condition = lines[runs[0] - 1].strip()
        self.assertTrue(condition.startswith("if: matrix.checks && runner.os == 'Linux'"), condition)
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn('b.step("test:contract",', build)
        self.assertIn('b.option(bool, "update-contract",', build)
        for step in ("gate_static_step", "units_test_step", "contract_step"):
            self.assertIn("%s.dependOn(&zig_api_snapshot.step);" % step, build)
        self.assertIn("contract_step.dependOn(&contract_run.step);", build)

    def test_the_linux_legs_record_the_tests_they_run(self):
        lines = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8").splitlines()
        names = [line.strip() for line in lines if line.strip().startswith("- name: ")]
        record = names.index("- name: Record the executed test IDs")
        for suite in ("- name: Offline test suite (units and integration)", "- name: Offline test suite (product)",
                      "- name: ReleaseSafe core gate", "- name: Gate manifest unit tests"):
            self.assertLess(record, names.index(suite), suite)
        self.assertGreater(names.index("- name: Upload the executed test IDs"), names.index("- name: Diff whitespace check"))
        workflow = "\n".join(lines)
        self.assertIn("name: Test IDs (Linux)\n    needs: [release-fast-path, scope, gates-linux]", workflow)
        self.assertIn("python3 scripts/test_ids.py collect --raw", workflow)
        self.assertIn("python3 scripts/test_ids.py ci-compare --head", workflow)
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn("gate_static_step.dependOn(&test_ids_check_cmd.step);", build)
        self.assertIn("units_test_step.dependOn(&test_ids_test_cmd.step);", build)
        self.assertIn('@import("test_id_record.zig")', (ROOT / "scripts" / "sharded_test_runner.zig").read_text(encoding="utf-8"))
        self.assertIn('@import("test_id_record.zig")', (ROOT / "scripts" / "recording_test_runner.zig").read_text(encoding="utf-8"))
        self.assertEqual(build.count("b.addTest("), 6, "a new test binary goes through addRecordedTest")
        self.assertIn("units_test_step.dependOn(&test_id_fixture_check.step);", build)
        self.assertIn("run: zig test src/platform/platform.zig -lc --test-runner scripts/recording_test_runner.zig --name native-platform", workflow)
        self.assertIn("  pull_request:\n    types: [opened, synchronize, reopened, labeled, unlabeled]\n", workflow)
        self.assertIn('run.setEnvironmentVariable("METACODES_TEST_ROOT",', build)
        self.assertIn("METACODES_TEST_ROOT: src/platform", workflow)
        self.assertIn("needs: [gates-linux, test-ids]", workflow)

    def test_the_test_step_is_exactly_its_three_parts(self):
        build = (ROOT / "build.zig").read_text(encoding="utf-8")
        self.assertIn('const units_test_step = b.step("test:units",', build)
        self.assertIn('const integration_test_step = b.step("test:integration",', build)
        self.assertIn('const product_test_step = b.step("test:product",', build)
        self.assertEqual(re.findall(r"\btest_step\.dependOn\((\w+)\)", build),
                         ["units_test_step", "integration_test_step", "product_test_step"])
        self.assertEqual(len(re.findall(r"\btest_step\.dependOn\(", build)), 3)


if __name__ == "__main__":
    unittest.main()
