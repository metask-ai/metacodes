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


class IdTest(unittest.TestCase):
    def test_a_zig_id_drops_the_file_and_namespace(self):
        self.assertEqual(test_ids.zig_id("core.agent_loop.test.stops at max turns"), "zig:stops at max turns")
        self.assertEqual(test_ids.zig_id("kernel.loop.test.stops at max turns"), "zig:stops at max turns")
        self.assertEqual(test_ids.zig_id("main.S.test.in struct"), "zig:in struct")
        self.assertEqual(test_ids.zig_id("sub.b.test.name with .test. inside"), "zig:name with .test. inside")
        self.assertEqual(test_ids.zig_id("main.decltest.foo"), "zig:decltest foo")
        self.assertEqual(test_ids.zig_id("sub.b.test_3"), "zig:<unnamed>")

    def test_a_python_id_drops_the_module(self):
        self.assertEqual(test_ids.python_id("scripts.tests.test_ci_scope.ScopeTest.test_docs"), "py:ScopeTest.test_docs")
        self.assertEqual(test_ids.python_id("test_analysis.AnalysisTest.test_x"), "py:AnalysisTest.test_x")


class CollectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.raw = Path(self.tmp.name)

    def write(self, name, text):
        (self.raw / name).write_text(text, encoding="utf-8")

    def test_records_become_sorted_counts_with_skips_apart(self):
        self.write("zig-metacodes-core-test-Debug-0of2.tsv", "pass\tcore.a.test.same name\nskip\tcore.b.test.skipped\n")
        self.write("zig-metacodes-core-test-Debug-1of2.tsv", "pass\ttools.c.test.same name\npass\tcore.a.test_0\n")
        self.write("py-scripts-tests--abc.tsv", "pass\tscripts.tests.test_x.XTest.test_one\n")
        counts, sources = test_ids.collect(self.raw, None)
        self.assertEqual(test_ids.format_ids(counts),
                         "py:XTest.test_one\tpass\t1\n"
                         "zig:<unnamed>\tpass\t1\n"
                         "zig:same name\tpass\t2\n"
                         "zig:skipped\tskip\t1\n")
        self.assertEqual(sources, {"zig-metacodes-core-test-Debug": Counter({"pass": 3, "skip": 1}),
                                   "py-scripts-tests": Counter({"pass": 1})})

    def test_a_failed_run_is_not_a_test_id_set(self):
        self.write("zig-suite-Debug-0of1.tsv", "fail\tcore.a.test.broken\n")
        with self.assertRaisesRegex(test_ids.TestIdError, "1 tests failed"):
            test_ids.collect(self.raw, None)

    def test_malformed_and_missing_records_fail(self):
        with self.assertRaisesRegex(test_ids.TestIdError, "no test ID records"):
            test_ids.collect(self.raw, None)
        self.write("zig-suite-Debug-0of1.tsv", "ok core.a.test.x\n")
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
        self.assertEqual(counts[("tty:test_opens", "listed")], 1)
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
            raw = Path(tmp) / "raw"
            raw.mkdir()
            program = ("import sys, unittest\nsys.path.insert(0, sys.argv[1])\nfrom scripts import test_ids\n"
                       "suite = unittest.defaultTestLoader.discover(sys.argv[2])\n"
                       "unittest.TextTestRunner(resultclass=test_ids.recording_result_class('sample')).run(suite)\n")
            subprocess.run([sys.executable, "-c", program, str(ROOT), str(suite_dir)], check=True, capture_output=True,
                           env={**os.environ, test_ids.IDS_DIR_ENV: str(raw)})
            counts, sources = test_ids.collect(raw, None)
        self.assertEqual(test_ids.format_ids(counts), "py:SampleTest.test_runs\tpass\t1\npy:SampleTest.test_skipped\tskip\t1\n")
        self.assertEqual(list(sources), ["py-sample"])

    def test_without_the_directory_nothing_is_recorded(self):
        with mock.patch.dict(os.environ, {test_ids.IDS_DIR_ENV: ""}):
            self.assertIsNone(test_ids.recording_result_class("sample"))


class CompareTest(unittest.TestCase):
    BASE = ids("zig:a\tpass\t1", "zig:b\tpass\t2", "zig:c\tskip\t1", "py:T.test_x\tpass\t1", "tty:test_t\tlisted\t1")

    def test_moving_a_file_changes_nothing(self):
        result = test_ids.compare(self.BASE, self.BASE, [], {})
        self.assertEqual((result.missing, result.added, result.renamed, result.removed), ([], [], [], []))

    def test_a_deleted_test_is_missing(self):
        head = ids("zig:b\tpass\t2", "zig:c\tskip\t1", "py:T.test_x\tpass\t1", "tty:test_t\tlisted\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual([change.test_id for change in result.missing], ["zig:a"])
        self.assertIn("zig:a", test_ids.render(result, self.BASE, head, "", True))

    def test_one_of_two_same_named_tests_deleted_is_missing(self):
        head = ids("zig:a\tpass\t1", "zig:b\tpass\t1", "zig:c\tskip\t1", "py:T.test_x\tpass\t1")
        self.assertEqual([change.test_id for change in test_ids.compare(self.BASE, head, [], {}).missing], ["zig:b"])

    def test_a_test_that_now_skips_no_longer_runs(self):
        head = ids("zig:a\tskip\t1", "zig:b\tpass\t2", "zig:c\tskip\t1", "py:T.test_x\tpass\t1")
        missing = test_ids.compare(self.BASE, head, [], {}).missing
        self.assertEqual([(change.test_id, change.note) for change in missing], [("zig:a", "no longer runs")])

    def test_a_skipped_test_that_now_runs_is_added(self):
        head = ids("zig:a\tpass\t1", "zig:b\tpass\t2", "zig:c\tpass\t1", "py:T.test_x\tpass\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual((result.missing, [change.test_id for change in result.added]), ([], ["zig:c"]))

    def test_a_rename_entry_explains_a_renamed_test(self):
        head = ids("zig:a2\tpass\t1", "zig:b\tpass\t2", "zig:c\tskip\t1", "py:T.test_x\tpass\t1")
        result = test_ids.compare(self.BASE, head, [("zig:a", "zig:a2")], {})
        self.assertEqual((result.missing, result.added), ([], []))
        self.assertEqual([(change.test_id, change.head) for change in result.renamed], [("zig:a", (1, 0))])

    def test_a_rename_to_a_test_that_does_not_run_explains_nothing(self):
        head = ids("zig:b\tpass\t2", "zig:c\tskip\t1", "py:T.test_x\tpass\t1")
        result = test_ids.compare(self.BASE, head, [("zig:a", "zig:a2")], {"py:T.test_gone": "reason"})
        self.assertEqual([change.test_id for change in result.missing], ["zig:a"])
        self.assertEqual(len(result.unused), 2)

    def test_a_removed_entry_explains_a_deleted_test(self):
        head = ids("zig:b\tpass\t2", "zig:c\tskip\t1")
        result = test_ids.compare(self.BASE, head, [], {"zig:a": "duplicate of zig:b", "py:T.test_x": "script deleted"})
        self.assertEqual(result.missing, [])
        self.assertEqual([change.note for change in result.removed], ["script deleted", "duplicate of zig:b"])

    def test_tty_cases_are_reported_not_enforced(self):
        head = ids("zig:a\tpass\t1", "zig:b\tpass\t2", "zig:c\tskip\t1", "py:T.test_x\tpass\t1", "tty:test_u\tlisted\t1")
        result = test_ids.compare(self.BASE, head, [], {})
        self.assertEqual((result.missing, result.tty_missing, result.tty_added), ([], ["tty:test_t"], ["tty:test_u"]))

    def test_cli_compare_fails_only_when_enforced(self):
        with tempfile.TemporaryDirectory() as tmp:
            base, head = Path(tmp) / "base.tsv", Path(tmp) / "head.tsv"
            base.write_text(test_ids.format_ids(self.BASE), encoding="utf-8")
            head.write_text("zig:b\tpass\t2\n", encoding="utf-8")
            argv = ["compare", "--base", str(base), "--head", str(head), "--root", tmp]
            with mock.patch("sys.stdout"):
                self.assertEqual(test_ids.main(argv), 0)
                self.assertEqual(test_ids.main(argv + ["--enforce"]), 1)


class ExplanationTest(unittest.TestCase):
    def check(self, renamed="", removed=""):
        with tempfile.TemporaryDirectory() as tmp:
            for rel, text in ((test_ids.RENAMED, renamed), (test_ids.REMOVED, removed)):
                (Path(tmp) / rel).parent.mkdir(parents=True, exist_ok=True)
                (Path(tmp) / rel).write_text(text, encoding="utf-8")
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
            ("", "zig:a\tx\nzig:a\ty\n", "listed twice"),
        ):
            with self.subTest(renamed=renamed, removed=removed):
                with self.assertRaisesRegex(test_ids.TestIdError, message):
                    self.check(renamed, removed)

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
        found = {7: (ids("zig:a\tpass\t1"), {"tree": "t"})}
        counts, note = test_ids.find_base("o/r", "b" * 40, "t", self.query, lambda repo, run: found.get(run))
        self.assertEqual(counts, ids("zig:a\tpass\t1"))
        self.assertIn("run 7 on the same tree", note)

    def test_another_tree_falls_back_to_mains_latest_run(self):
        found = {7: (ids("zig:a\tpass\t1"), {"tree": "other"}), 9: (ids("zig:b\tpass\t1"), {"tree": "u", "commit": "c" * 40})}
        counts, note = test_ids.find_base("o/r", "b" * 40, "t", self.query, lambda repo, run: found.get(run))
        self.assertEqual(counts, ids("zig:b\tpass\t1"))
        self.assertIn("using main's run 9", note)

    def test_no_recorded_ids_compares_nothing(self):
        counts, note = test_ids.find_base("o/r", "b" * 40, "t", self.query, lambda repo, run: None)
        self.assertIsNone(counts)
        self.assertIn("nothing to compare", note)


if __name__ == "__main__":
    unittest.main()
