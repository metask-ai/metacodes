#!/usr/bin/env python3
"""Grade the check-gate-v2 `todo` task: run the pristine visible tests (the
acceptance test included) plus hidden tests derived from ISSUE.md against a
copy of the workspace whose own tests/ directory is replaced. Editing the
workspace's tests changes nothing here."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEST_FILES = {'tests/__init__.py': '# Unit tests.\n', 'tests/test_model.py': 'import unittest\n\nfrom todo.model import Task\n\n\nclass TaskTest(unittest.TestCase):\n    def test_defaults(self):\n        task = Task(1, "Water plants")\n        self.assertEqual((task.priority, task.due, task.done), ("normal", None, False))\n\n    def test_validation(self):\n        with self.assertRaises(ValueError):\n            Task(1, "x", priority="urgent")\n        with self.assertRaises(ValueError):\n            Task(1, "   ")\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_store.py': 'import datetime\nimport unittest\n\nfrom todo.store import TaskStore\n\n\nclass StoreTest(unittest.TestCase):\n    def test_ids_and_completion(self):\n        store = TaskStore()\n        store.add("first", "low")\n        store.add("second", "high")\n        store.complete(2)\n        self.assertTrue(store.get(2).done)\n        with self.assertRaises(KeyError):\n            store.get(9)\n\n    def test_all_is_in_id_order(self):\n        store = TaskStore()\n        store.add("later", "low")\n        store.add("now", "high", datetime.date(2026, 10, 9))\n        store.add("soon", "normal")\n        self.assertEqual([t.id for t in store.all()], [1, 2, 3])\n\n    def test_json_round_trip(self):\n        store = TaskStore()\n        store.add("a", "low")\n        store.add("b", "high", datetime.date(2026, 11, 1))\n        store.complete(1)\n        again = TaskStore.from_json(store.to_json())\n        self.assertEqual([(t.id, t.title, t.priority, t.due, t.done) for t in again.all()],\n                         [(1, "a", "low", None, True), (2, "b", "high", datetime.date(2026, 11, 1), False)])\n        self.assertEqual(again.add("c").id, 3)\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_export.py': 'import datetime\nimport unittest\n\nfrom todo.export import to_csv\nfrom todo.store import TaskStore\n\n\nclass ExportTest(unittest.TestCase):\n    def test_rows_in_id_order(self):\n        store = TaskStore()\n        store.add("Taxes", "low", datetime.date(2027, 4, 15))\n        store.add("Fix leak", "high")\n        store.add("Call Bo", "normal", datetime.date(2026, 10, 12))\n        store.complete(2)\n        self.assertEqual(to_csv(store), (\n            "id,title,priority,due,done\\n"\n            "1,Taxes,low,2027-04-15,no\\n"\n            "2,Fix leak,high,,yes\\n"\n            "3,Call Bo,normal,2026-10-12,no\\n"))\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_cli.py': 'import unittest\n\nfrom todo import cli\nfrom todo.store import TaskStore\n\n\nclass CliTest(unittest.TestCase):\n    def test_add_list_done(self):\n        store = TaskStore()\n        out = []\n        cli.main(["add", "Write report", "high", "2026-10-09"], store, out)\n        cli.main(["add", "Buy milk"], store, out)\n        cli.main(["done", "2"], store, out)\n        out.clear()\n        cli.main(["list"], store, out)\n        self.assertEqual(out, ["[ ] 1 Write report (high, due 2026-10-09)", "[x] 2 Buy milk (normal)"])\n\n    def test_unknown_command(self):\n        with self.assertRaises(ValueError):\n            cli.main(["frobnicate"], TaskStore(), [])\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_urgency.py': 'import unittest\n\nfrom todo import cli\nfrom todo.store import TaskStore\n\n\nclass UrgencyTest(unittest.TestCase):\n    def test_priority_then_due_date(self):\n        store = TaskStore()\n        out = []\n        cli.main(["add", "Sort photos", "low"], store, out)\n        cli.main(["add", "Pay rent", "high"], store, out)\n        cli.main(["add", "Book flights", "normal", "2026-12-01"], store, out)\n        cli.main(["add", "Renew passport", "normal", "2026-10-20"], store, out)\n        out.clear()\n        cli.main(["list"], store, out)\n        self.assertEqual([line.split()[2] for line in out], ["2", "4", "3", "1"])\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/run.py': '"""Run the unit tests under tests/ and report them like pytest\'s summary:\nthe failure details first, then one `FAILED <test> - <reason>` line per\nfailing test and a count line. Exit status 1 when anything failed."""\nimport os\nimport sys\nimport unittest\n\n\ndef main():\n    here = os.path.dirname(os.path.abspath(__file__))\n    root = os.path.dirname(here)\n    sys.path.insert(0, root)\n    suite = unittest.defaultTestLoader.discover(here, pattern="test_*.py", top_level_dir=root)\n    result = unittest.TestResult()\n    suite.run(result)\n    failed = result.failures + result.errors\n    for test, trace in failed:\n        print("_" * 12 + " " + test.id() + " " + "_" * 12)\n        print(trace.rstrip())\n        print()\n    failing_methods = set()\n    for test, trace in failed:\n        case = getattr(test, "test_case", test)\n        failing_methods.add(case.id())\n        parts = case.id().rsplit(".", 2)\n        if len(parts) == 3:\n            module, cls, method = parts\n            name = "%s.py::%s::%s" % (module.replace(".", "/"), cls, method)\n        else:\n            name = case.id()\n        if case is not test:\n            name += " " + test._subDescription()\n        lines = trace.strip().splitlines()\n        reason = lines[-1] if lines else ""\n        print("FAILED %s - %s" % (name, reason))\n    print("%d failed, %d passed" % (len(failing_methods), result.testsRun - len(failing_methods)))\n    return 1 if failed else 0\n\n\nif __name__ == "__main__":\n    sys.exit(main())\n', 'tests/test_hidden_todo.py': 'import datetime\nimport re\nimport unittest\n\nfrom todo import cli\nfrom todo.export import to_csv\nfrom todo.store import TaskStore\n\nD = datetime.date\n\n\ndef build():\n    store = TaskStore()\n    store.add("a", "low")\n    store.add("b", "high", D(2026, 11, 1))\n    store.add("c", "high")\n    store.add("d", "normal", D(2026, 10, 20))\n    store.add("e", "high", D(2026, 10, 15))\n    store.add("f", "normal")\n    store.complete(5)\n    store.complete(1)\n    return store\n\n\ndef listed_ids(store):\n    out = []\n    cli.main(["list"], store, out)\n    return [int(re.match(r"^\\[.\\] (\\d+) ", line).group(1)) for line in out]\n\n\nclass HiddenUrgencyTest(unittest.TestCase):\n    def test_full_order(self):\n        self.assertEqual(listed_ids(build()), [2, 3, 4, 6, 1, 5])\n\n    def test_ties_by_id(self):\n        store = TaskStore()\n        store.add("x", "normal", D(2026, 10, 10))\n        store.add("y", "normal", D(2026, 10, 10))\n        store.add("z", "normal", D(2026, 10, 9))\n        self.assertEqual(listed_ids(store), [3, 1, 2])\n\n    def test_done_tasks_last_in_id_order(self):\n        store = TaskStore()\n        store.add("p", "high")\n        store.add("q", "low")\n        store.add("r", "high")\n        store.complete(3)\n        store.complete(1)\n        self.assertEqual(listed_ids(store), [2, 1, 3])\n\n    def test_line_format_unchanged(self):\n        out = []\n        cli.main(["list"], build(), out)\n        self.assertEqual(out[0], "[ ] 2 b (high, due 2026-11-01)")\n        self.assertEqual(out[-1], "[x] 5 e (high, due 2026-10-15)")\n\n    def test_export_and_store_keep_id_order(self):\n        store = build()\n        self.assertEqual([t.id for t in store.all()], [1, 2, 3, 4, 5, 6])\n        rows = to_csv(store).splitlines()[1:]\n        self.assertEqual([int(r.split(",")[0]) for r in rows], [1, 2, 3, 4, 5, 6])\n\n\nif __name__ == "__main__":\n    unittest.main()\n'}

SKIP = {"tests", ".git", ".home", "__pycache__", "events.jsonl"}


def main():
    workspace = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "workspace"
        root.mkdir()
        for entry in workspace.iterdir():
            if entry.name in SKIP or entry.name.startswith(".") or entry.is_symlink():
                continue
            if entry.is_dir():
                shutil.copytree(entry, root / entry.name, symlinks=False,
                                ignore=shutil.ignore_patterns("__pycache__"))
            elif entry.is_file():
                shutil.copy2(entry, root / entry.name)
        for rel, text in TEST_FILES.items():
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        try:
            result = subprocess.run([sys.executable, "tests/run.py"], cwd=root, capture_output=True,
                                    text=True, timeout=90)
        except subprocess.TimeoutExpired:
            print("tests timed out")
            return 1
        output = result.stdout + result.stderr
        print(output[-4000:])
        return 0 if result.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
