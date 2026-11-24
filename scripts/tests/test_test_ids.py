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


def raw(*records, root=""):
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "zig-suite-Debug--1.tsv").write_text(f"root\t{root}\n" + "".join(f"pass\t{name}\n" for name in records),
                                                       encoding="utf-8")
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

    def test_the_test_root_qualifies_the_namespace(self):
        self.assertEqual(test_ids.zig_entry("platform.process.test.echo", "src"), ("zig:echo", "src.platform.process"))
        self.assertEqual(test_ids.zig_entry("process.test.echo", "src/platform"), ("zig:echo", "src.platform.process"))
        self.assertEqual(test_ids.python_entry("test_analysis.AnalysisTest.test_x", "scripts/eval/tests"),
                         ("py:AnalysisTest.test_x", "scripts.eval.tests.test_analysis"))

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
        self.write("zig-metacodes-core-test-Debug-0of2--a1.tsv", "root\tsrc\npass\tcore.a.test.same name\nskip\tcore.b.test.skipped\n")
        self.write("zig-metacodes-core-test-Debug-1of2--b2.tsv", "root\tsrc\npass\ttools.a.test.same name\npass\tcore.a.test_0\n")
        self.write("zig-provider-test-Debug--c3.tsv", "root\tsrc/provider\npass\tcapability.test.unique\n")
        self.write("py-scripts-tests--abc.tsv", "root\t\npass\tscripts.tests.test_x.XTest.test_one\n")
        counts, sources = test_ids.collect(self.raw, None)
        self.assertEqual(test_ids.format_ids(counts),
                         "py:XTest.test_one\tscripts.tests.test_x\tpass\t1\n"
                         "zig:<unnamed>\tsrc.core.a\tpass\t1\n"
                         "zig:same name\tsrc.core.a\tpass\t1\n"
                         "zig:same name\tsrc.tools.a\tpass\t1\n"
                         "zig:skipped\tsrc.core.b\tskip\t1\n"
                         "zig:unique\tsrc.provider.capability\tpass\t1\n")
        self.assertEqual(sources, {"zig-metacodes-core-test-Debug": Counter({"pass": 3, "skip": 1}),
                                   "zig-provider-test-Debug": Counter({"pass": 1}),
                                   "py-scripts-tests": Counter({"pass": 1})})

    def test_a_failed_run_is_not_a_test_id_set(self):
        self.write("zig-suite-Debug--1.tsv", "root\tsrc\nfail\tcore.a.test.broken\n")
        with self.assertRaisesRegex(test_ids.TestIdError, "1 tests failed"):
            test_ids.collect(self.raw, None)

    def test_malformed_and_missing_records_fail(self):
        with self.assertRaisesRegex(test_ids.TestIdError, "no test ID records"):
            test_ids.collect(self.raw, None)
        self.write("zig-suite-Debug--1.tsv", "root\tsrc\nok core.a.test.x\n")
        with self.assertRaisesRegex(test_ids.TestIdError, "malformed record"):
            test_ids.collect(self.raw, None)
        self.write("zig-suite-Debug--1.tsv", "pass\tcore.a.test.x\n")
        with self.assertRaisesRegex(test_ids.TestIdError, "without the test root"):
            test_ids.collect(self.raw, None)

    def test_tty_cases_are_listed_by_function_name(self):
        cases = self.raw / "cases"
        cases.mkdir()
        (cases / "test_menu.py").write_text("from x import test_helper\n\ndef test_opens():\n    pass\n\ndef helper():\n    pass\n",
                                            encoding="utf-8")
        (cases / "helpers.py").write_text("def test_not_a_case():\n    pass\n", encoding="utf-8")
        self.write("py-eval--1.tsv", "root\tscripts/eval/tests\npass\ttest_a.ATest.test_a\n")
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
                       "unittest.TextTestRunner(resultclass=test_ids.recording_result_class('sample', 'suite')).run(suite)\n")
            subprocess.run([sys.executable, "-c", program, str(ROOT), str(suite_dir)], check=True, capture_output=True,
                           env={**os.environ, test_ids.IDS_DIR_ENV: str(raw_dir)})
            counts, sources = test_ids.collect(raw_dir, None)
        self.assertEqual(test_ids.format_ids(counts),
                         "py:SampleTest.test_runs\tsuite.test_sample\tpass\t1\npy:SampleTest.test_skipped\tsuite.test_sample\tskip\t1\n")
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

    def test_one_file_compiled_into_two_roots_is_one_place(self):
        def run(cc_names, platform_names):
            cc, platform = raw(*cc_names, root="src"), raw(*platform_names, root="src/platform")
            return Counter(cc) + Counter(platform)

        base = run(["platform.process.test_0", "platform.fs.test_0"], ["process.test_0", "fs.test_0"])
        self.assertEqual(test_ids.locations(base), {"zig:<unnamed>": {"src.platform.process", "src.platform.fs"}})
        head = run(["base.platform.process.test_0", "base.platform.fs.test_0"], ["process.test_0", "fs.test_0"])
        self.assertEqual(missing(base, head), ["zig:<unnamed> @src.platform.fs", "zig:<unnamed> @src.platform.process"])
        self.assertEqual(missing(base, head, [("@src.platform", "@src.base.platform")]), [])

    def test_a_new_file_whose_namespace_ends_like_another_is_not_that_file(self):
        self.assertEqual(missing(raw("a.test.dup", "b.test.dup"), raw("a.test.dup", "b.test.dup", "sub.a.test.dup")), [])
        self.assertEqual(missing(raw("root.test_0", "alpha.root.test_0"), raw("alpha.root.test_0", "beta.alpha.root.test_0")),
                         ["zig:<unnamed> @root"])

    def test_a_partial_move_keeps_every_run_of_the_test(self):
        base = raw("old.test.a", "old.test.a")
        head = raw("old.test.a", "new.test.a")
        self.assertEqual(missing(base, head, [("@old", "@new")]), [])

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


if __name__ == "__main__":
    unittest.main()
