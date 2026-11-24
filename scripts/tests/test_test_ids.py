import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

from scripts import test_ids

ROOT = Path(__file__).resolve().parents[2]


def ids(*lines):
    return test_ids.parse_ids("".join(line + "\n" for line in lines))


def raw(*records):
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "zig-suite-Debug--1.tsv").write_text("".join(f"pass\t{name}\n" for name in records), encoding="utf-8")
        return test_ids.collect(Path(tmp), None)[0]


def missing(base, head, renamed=(), removed=None):
    return [change.key for change in test_ids.compare(base, head, list(renamed), removed or {}).missing]


class EntryTest(unittest.TestCase):
    def test_a_zig_entry_is_the_test_name_and_its_file(self):
        self.assertEqual(test_ids.zig_entry("core.agent_loop.test.stops at max turns"), ("zig:stops at max turns", "core.agent_loop"))
        self.assertEqual(test_ids.zig_entry("main.S.test.in struct"), ("zig:in struct", "main.S"))
        self.assertEqual(test_ids.zig_entry("sub.b.test.name with .test. inside"), ("zig:name with .test. inside", "sub.b"))
        self.assertEqual(test_ids.zig_entry("main.decltest.foo"), ("zig:decltest foo", "main"))
        self.assertEqual(test_ids.zig_entry("sub.b.test_3"), ("zig:<unnamed>", "sub.b"))

    def test_a_python_entry_is_the_class_method_and_its_module(self):
        self.assertEqual(test_ids.python_entry("scripts.tests.test_ci_scope.ScopeTest.test_docs"), ("py:ScopeTest.test_docs", "scripts.tests.test_ci_scope"))
        self.assertEqual(test_ids.python_entry("test_analysis.AnalysisTest.test_x"), ("py:AnalysisTest.test_x", "test_analysis"))


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.raw = Path(self.tmp.name)

    def write(self, name, text):
        (self.raw / name).write_text(text, encoding="utf-8")

    def test_records_become_sorted_counts_with_skips_apart(self):
        self.write("zig-metacodes-core-test-Debug-0of2--a1.tsv", "pass\tcore.a.test.same name\nskip\tcore.b.test.skipped\n")
        self.write("zig-metacodes-core-test-Debug-1of2--b2.tsv", "pass\ttools.a.test.same name\npass\tcore.a.test_0\n")
        self.write("zig-provider-test-Debug--c3.tsv", "pass\tcapability.test.unique\n")
        self.write("py-scripts-tests--abc.tsv", "pass\tscripts.tests.test_x.XTest.test_one\n")
        counts, sources = test_ids.collect(self.raw, None)
        self.assertEqual(test_ids.format_ids(counts),
                         "py:XTest.test_one\tscripts.tests.test_x\tpass\t1\n"
                         "zig:<unnamed>\tcore.a\tpass\t1\n"
                         "zig:same name\tcore.a\tpass\t1\n"
                         "zig:same name\ttools.a\tpass\t1\n"
                         "zig:skipped\tcore.b\tskip\t1\n"
                         "zig:unique\tcapability\tpass\t1\n")
        self.assertEqual(sources, {"zig-metacodes-core-test-Debug": Counter({"pass": 3, "skip": 1}),
                                   "zig-provider-test-Debug": Counter({"pass": 1}),
                                   "py-scripts-tests": Counter({"pass": 1})})

    def test_a_failed_run_is_not_a_test_id_set(self):
        self.write("zig-suite-Debug--1.tsv", "fail\tcore.a.test.broken\n")
        with self.assertRaisesRegex(test_ids.TestIdError, "1 tests failed"):
            test_ids.collect(self.raw, None)

    def test_malformed_and_missing_records_fail(self):
        with self.assertRaisesRegex(test_ids.TestIdError, "no test ID records"):
            test_ids.collect(self.raw, None)
        self.write("zig-suite-Debug--1.tsv", "ok core.a.test.x\n")
        with self.assertRaisesRegex(test_ids.TestIdError, "malformed record"):
            test_ids.collect(self.raw, None)

    def test_tty_cases_are_listed_by_function_name(self):
        cases = self.raw / "cases"
        cases.mkdir()
        (cases / "test_menu.py").write_text("from x import test_helper\n\ndef test_opens():\n    pass\n\ndef helper():\n    pass\n",
                                            encoding="utf-8")
        (cases / "helpers.py").write_text("def test_not_a_case():\n    pass\n", encoding="utf-8")
        self.write("py-eval--1.tsv", "pass\ttest_a.ATest.test_a\n")
        counts, sources = test_ids.collect(self.raw, cases)
        self.assertEqual(counts[("tty:test_opens", "test_menu", "listed")], 1)
        self.assertEqual(sources["tty-cases"], Counter(listed=1))

    def test_the_repository_tty_cases_are_listed(self):
        self.assertGreater(len(test_ids.tty_cases(ROOT / test_ids.TTY_CASES)), 100)


class RecordingTest(unittest.TestCase):
    def test_a_unittest_run_records_what_it_ran(self):
        with tempfile.TemporaryDirectory() as tmp:
            suite_dir = Path(tmp) / "suite"
            suite_dir.mkdir()
            (suite_dir / "test_sample.py").write_text(
                "import unittest\n"
                "class SampleTest(unittest.TestCase):\n"
                "    def test_runs(self):\n        pass\n"
                "    @unittest.skip('no')\n    def test_skipped(self):\n        pass\n",
                encoding="utf-8")
            raw_dir = Path(tmp) / "raw"
            raw_dir.mkdir()
            program = ("import sys, unittest\nsys.path.insert(0, sys.argv[1])\nfrom scripts import test_ids\n"
                       "suite = unittest.defaultTestLoader.discover(sys.argv[2])\n"
                       "unittest.TextTestRunner(resultclass=test_ids.recording_result_class('sample')).run(suite)\n")
            subprocess.run([sys.executable, "-c", program, str(ROOT), str(suite_dir)], check=True, capture_output=True,
                           env={**os.environ, test_ids.IDS_DIR_ENV: str(raw_dir)})
            counts, sources = test_ids.collect(raw_dir, None)
        self.assertEqual(test_ids.format_ids(counts),
                         "py:SampleTest.test_runs\ttest_sample\tpass\t1\npy:SampleTest.test_skipped\ttest_sample\tskip\t1\n")
        self.assertEqual(list(sources), ["py-sample"])

    def test_without_the_directory_nothing_is_recorded(self):
        with mock.patch.dict(os.environ, {test_ids.IDS_DIR_ENV: ""}):
            self.assertIsNone(test_ids.recording_result_class("sample"))


class CompareTest(unittest.TestCase):
    BASE = ids("zig:a\tx\tpass\t1", "zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1", "py:T.test_x\ttest_t\tpass\t1",
               "tty:test_t\ttest_menu\tlisted\t1")

    def test_moving_a_file_changes_nothing(self):
        base = raw("core.x.test.a", "core.x.test.b", "core.x.test.b")
        self.assertEqual(missing(base, raw("kernel.x.test.a", "kernel.x.test.b", "kernel.x.test.b")), [])
        self.assertEqual(missing(base, raw("core.y.test.a", "core.y.test.b", "core.y.test.b")), [])

    def test_a_deleted_test_is_missing(self):
        head = ids("zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1", "py:T.test_x\ttest_t\tpass\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual([change.key for change in result.missing], ["zig:a"])
        self.assertIn("zig:a", test_ids.render(result, self.BASE, head, "", True))

    def test_one_of_two_same_named_tests_deleted_is_missing(self):
        self.assertEqual(missing(raw("x.a.test.dup", "x.b.test.dup"), raw("x.a.test.dup")), ["zig:dup @x.b"])

    def test_a_same_count_swap_of_unnamed_tests_is_missing(self):
        self.assertEqual(missing(raw("core.a.test_0", "core.b.test_0"), raw("core.b.test_0", "core.c.test_0")), ["zig:<unnamed> @core.a"])

    def test_a_swap_between_same_named_files_in_other_directories_is_missing(self):
        base = raw("provider.openai.root.test_0", "provider.anthropic.root.test_0")
        head = raw("provider.anthropic.root.test_0", "provider.gemini.root.test_0")
        self.assertEqual(missing(base, head), ["zig:<unnamed> @provider.openai.root"])

    def test_one_test_compiled_into_two_roots_is_one_test(self):
        base = raw("platform.process.test_0", "process.test_0", "platform.fs.test_0", "fs.test_0")
        head = raw("base.platform.process.test_0", "process.test_0", "base.platform.fs.test_0", "fs.test_0")
        self.assertEqual(missing(base, head), ["zig:<unnamed> @platform.fs", "zig:<unnamed> @platform.process"])
        self.assertEqual(missing(base, head, [("@platform", "@base.platform")]), [])

    def test_a_directory_move_is_explained_by_one_namespace_entry(self):
        base = raw("core.tools.a.test_0", "core.tools.b.test_0", "core.c.test_0")
        head = raw("coding.tools.a.test_0", "coding.tools.b.test_0", "core.c.test_0")
        result = test_ids.compare(base, head, [("@core.tools", "@coding.tools"), ("@gone", "@elsewhere")], {})
        self.assertEqual((result.missing, result.unused), ([], ["tests/test_ids/renamed.tsv: @gone → @elsewhere"]))

    def test_a_same_count_swap_of_same_named_tests_is_missing(self):
        self.assertEqual(missing(raw("x.a.test.dup", "x.b.test.dup"), raw("x.b.test.dup", "x.c.test.dup")), ["zig:dup @x.a"])

    def test_a_new_test_with_an_existing_name_does_not_hide_or_fake_a_loss(self):
        self.assertEqual(missing(raw("x.a.test.dup"), raw("x.a.test.dup", "x.b.test.dup")), [])
        self.assertEqual(missing(raw("x.a.test.dup"), raw("x.c.test.dup", "x.b.test.dup")), ["zig:dup @x.a"])

    def test_a_moved_same_named_test_is_explained_by_a_rename(self):
        base, head = raw("x.a.test.dup", "x.b.test.dup"), raw("x.b.test.dup", "x.a2.test.dup")
        result = test_ids.compare(base, head, [("zig:dup @x.a", "zig:dup @x.a2")], {})
        self.assertEqual((result.missing, [change.key for change in result.renamed]), ([], ["zig:dup @x.a"]))

    def test_a_test_that_now_skips_no_longer_runs(self):
        head = ids("zig:a\tx\tskip\t1", "zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1", "py:T.test_x\ttest_t\tpass\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual([(change.key, change.note) for change in result.missing], [("zig:a", "no longer runs")])

    def test_a_skipped_test_that_now_runs_is_added(self):
        head = ids("zig:a\tx\tpass\t1", "zig:b\tx\tpass\t2", "zig:c\ty\tpass\t1", "py:T.test_x\ttest_t\tpass\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual((result.missing, [change.key for change in result.added]), ([], ["zig:c"]))

    def test_a_rename_entry_explains_a_renamed_test(self):
        head = ids("zig:a2\tx\tpass\t1", "zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1", "py:T.test_x\ttest_t\tpass\t1")
        result = test_ids.compare(self.BASE, head, [("zig:a", "zig:a2")], {})
        self.assertEqual((result.missing, result.added), ([], []))
        self.assertEqual([(change.key, change.head) for change in result.renamed], [("zig:a", (1, 0))])

    def test_a_rename_to_a_test_that_does_not_run_explains_nothing(self):
        head = ids("zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1", "py:T.test_x\ttest_t\tpass\t1")
        result = test_ids.compare(self.BASE, head, [("zig:a", "zig:a2")], {"py:T.test_gone": "reason"})
        self.assertEqual([change.key for change in result.missing], ["zig:a"])
        self.assertEqual(len(result.unused), 2)

    def test_a_removed_entry_explains_a_deleted_test(self):
        head = ids("zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1")
        result = test_ids.compare(self.BASE, head, [], {"zig:a": "duplicate of zig:b", "py:T.test_x": "script deleted"})
        self.assertEqual(result.missing, [])
        self.assertEqual([change.note for change in result.removed], ["script deleted", "duplicate of zig:b"])

    def test_tty_cases_are_reported_not_enforced(self):
        head = ids("zig:a\tx\tpass\t1", "zig:b\tx\tpass\t2", "zig:c\ty\tskip\t1", "py:T.test_x\ttest_t\tpass\t1",
                   "tty:test_u\ttest_menu\tlisted\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual((result.missing, result.tty_missing, result.tty_added), ([], ["tty:test_t"], ["tty:test_u"]))

    def test_cli_compare_fails_only_when_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            base, head = Path(tmp) / "base.tsv", Path(tmp) / "head.tsv"
            base.write_text(test_ids.format_ids(self.BASE), encoding="utf-8")
            head.write_text("zig:b\tx\tpass\t2\n", encoding="utf-8")
            argv = ["compare", "--base", str(base), "--head", str(head), "--root", tmp]
            with mock.patch("sys.stdout"):
                self.assertEqual(test_ids.main(argv), 0)
                self.assertEqual(test_ids.main(argv + ["--enforce"]), 1)


class ExplanationTest(unittest.TestCase):
    def write(self, root, renamed="", removed=""):
        for rel, text in ((test_ids.RENAMED, renamed), (test_ids.REMOVED, removed)):
            (Path(root) / rel).parent.mkdir(parents=True, exist_ok=True)
            (Path(root) / rel).write_text(text, encoding="utf-8")

    def check(self, renamed="", removed=""):
        with tempfile.TemporaryDirectory() as tmp:
            self.write(tmp, renamed, removed)
            return test_ids.read_explanations(Path(tmp))

    def test_well_formed_files_parse(self):
        self.assertEqual(self.check("zig:a\tzig:b\n", "py:T.test_x\tthe script is gone\n"),
                         ([("zig:a", "zig:b")], {"py:T.test_x": "the script is gone"}))

    def test_malformed_files_fail(self):
        for renamed, removed, message in (
            ("zig:a zig:b\n", "", "expected"),
            ("", "zig:a\t\n", "expected"),
            ("a\tzig:b\n", "", "does not start"),
            ("zig:a\tzig:a\n", "", "renamed to itself"),
            ("zig:a\tpy:T.a\n", "", "different kinds"),
            ("@core\tzig:a\n", "", "mixes a namespace move"),
            ("", "@core\treason\n", "does not start"),
            ("", "zig:a\tx\nzig:a\ty\n", "listed twice"),
        ):
            with self.subTest(renamed=renamed, removed=removed):
                with self.assertRaisesRegex(test_ids.TestIdError, message):
                    self.check(renamed, removed)

    def test_only_explanations_added_since_the_base_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            def git(*argv):
                subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *argv], cwd=tmp, check=True, capture_output=True)
            git("init", "-q")
            self.write(tmp, "zig:old\tzig:new\n", "zig:dup @x.a\tmerged into b\n")
            git("add", "-A")
            git("commit", "-qm", "base")
            self.write(tmp, "zig:old\tzig:new\nzig:x\tzig:y\n", "zig:dup @x.a\tmerged into b\nzig:gone\tobsolete\n")
            renamed, removed = test_ids.read_explanations(Path(tmp), "HEAD")
        self.assertEqual((renamed, removed), ([("zig:x", "zig:y")], {"zig:gone": "obsolete"}))
        base, head = raw("x.a.test.dup", "x.b.test.dup", "x.c.test.dup"), raw("x.b.test.dup")
        self.assertEqual(missing(base, head, renamed, removed), ["zig:dup @x.a", "zig:dup @x.c"])

    def test_the_repository_files_are_well_formed(self):
        self.assertEqual(test_ids.main(["check"]), 0)


class BaseTest(unittest.TestCase):
    def query(self, path):
        if "/commits/" in path:
            return [{"merged_at": "x", "merge_commit_sha": "b" * 40, "head": {"sha": "h" * 40}}]
        if "event=pull_request" in path:
            return {"workflow_runs": [{"id": 7}]}
        if "head_sha=" in path:
            return {"workflow_runs": []}
        return {"workflow_runs": [{"id": 9, "created_at": "2026-11-24"}]}

    def test_the_base_pull_requests_run_on_the_same_tree_is_used(self):
        found = {7: (ids("zig:a\tx\tpass\t1"), {"tree": "t"})}
        base = test_ids.find_base("o/r", "b" * 40, "t", self.query, lambda repo, run: found.get(run))
        self.assertEqual((base.counts, base.exact), (ids("zig:a\tx\tpass\t1"), True))
        self.assertIn("run 7 on the same tree", base.note)

    def test_another_tree_falls_back_to_mains_latest_run_for_a_report_only(self):
        found = {7: (ids("zig:a\tx\tpass\t1"), {"tree": "other"}), 9: (ids("zig:b\tx\tpass\t1"), {"tree": "u", "commit": "c" * 40})}
        base = test_ids.find_base("o/r", "b" * 40, "t", self.query, lambda repo, run: found.get(run))
        self.assertEqual((base.counts, base.exact), (ids("zig:b\tx\tpass\t1"), False))
        head = ids("zig:b\tx\tpass\t1")
        report, failed = test_ids.ci_report(head, base, [], {}, enforced=False)
        self.assertFalse(failed)
        self.assertIn("main's run 9", report)
        report, failed = test_ids.ci_report(head, base, [], {}, enforced=True)
        self.assertTrue(failed)
        self.assertIn("only with IDs recorded on its base's own tree", report)

    def test_an_exact_base_fails_a_migration_pr_only_when_a_test_is_missing(self):
        base = test_ids.Base(ids("zig:a\tx\tpass\t1", "zig:b\tx\tpass\t1"), "", True)
        self.assertFalse(test_ids.ci_report(ids("zig:a\tx\tpass\t1"), base, [], {}, enforced=False)[1])
        self.assertTrue(test_ids.ci_report(ids("zig:a\tx\tpass\t1"), base, [], {}, enforced=True)[1])
        self.assertFalse(test_ids.ci_report(base.counts, base, [], {}, enforced=True)[1])

    def test_no_recorded_ids_compares_nothing(self):
        base = test_ids.find_base("o/r", "b" * 40, "t", self.query, lambda repo, run: None)
        self.assertIsNone(base.counts)
        self.assertIn("nothing to compare", base.note)


class LabelVerdictTest(unittest.TestCase):
    HEAD = ids("zig:a\tx\tpass\t1")

    def query(self, jobs, labels=("migration",), runs=None):
        states = iter([{"id": 5, "status": "in_progress"}, {"id": 5, "status": "completed"}])

        def answer(path):
            if path.endswith("event=pull_request&per_page=20"):
                return {"workflow_runs": runs if runs is not None else [
                    {"id": 4, "created_at": "1", "status": "completed"}, {"id": 5, "created_at": "2", "status": "queued"}]}
            if path.endswith("/runs/5"):
                return next(states)
            if "/labels" in path:
                return [{"name": name} for name in labels]
            return {"jobs": jobs}
        return answer

    def verdict(self, jobs, labels=("migration",), tree="t", runs=None, judged=("compared", False)):
        calls = []

        def judge(head, base_sha, repository, enforced):
            calls.append((head, base_sha, enforced))
            return judged

        found = (self.HEAD, {"tree": tree})
        result = test_ids.label_verdict("o/r", 9, "h" * 40, "b" * 40, "t", 600, self.query(jobs, labels, runs),
                                        lambda repo, run: found, judge, sleep=lambda seconds: None, clock=lambda: 0)
        return result, calls

    LEGS = [{"name": "Gates (Linux) / units", "conclusion": "success"}, {"name": "Gates (Linux) / checks", "conclusion": "success"}]

    def test_adding_the_label_judges_the_finished_run_with_it(self):
        jobs = self.LEGS + [{"name": test_ids.CI_JOB, "conclusion": "success"}]
        (report, failed), calls = self.verdict(jobs, judged=("missing zig:b", True))
        self.assertEqual((report, failed), ("missing zig:b", True))
        self.assertEqual(calls, [(self.HEAD, "b" * 40, True)])
        (report, failed), calls = self.verdict(jobs, labels=(), judged=("report", False))
        self.assertEqual((failed, calls[0][2]), (False, False))

    def test_failed_legs_fail_whatever_the_labels(self):
        jobs = [{"name": "Gates (Linux) / units", "conclusion": "failure"}, {"name": test_ids.CI_JOB, "conclusion": "skipped"}]
        (report, failed), calls = self.verdict(jobs, labels=())
        self.assertTrue(failed)
        self.assertEqual(calls, [])

    def test_a_run_without_a_comparison_passes_with_its_legs(self):
        (report, failed), calls = self.verdict(self.LEGS + [{"name": test_ids.CI_JOB, "conclusion": "skipped"}])
        self.assertFalse(failed)
        self.assertIn("compared no test IDs", report)

    def test_a_migration_pr_tested_on_another_merge_fails(self):
        jobs = self.LEGS + [{"name": test_ids.CI_JOB, "conclusion": "success"}]
        (report, failed), calls = self.verdict(jobs, tree="older merge")
        self.assertTrue(failed)
        self.assertIn("another merge", report)

    def test_no_ci_run_yet_leaves_the_verdict_to_it(self):
        (report, failed), calls = self.verdict([], runs=[])
        self.assertFalse(failed)
        self.assertIn("No CI run", report)


if __name__ == "__main__":
    unittest.main()
