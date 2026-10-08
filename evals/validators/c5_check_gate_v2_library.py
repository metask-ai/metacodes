#!/usr/bin/env python3
"""Grade the check-gate-v2 `library` task: run the pristine visible tests (the
acceptance test included) plus hidden tests derived from ISSUE.md against a
copy of the workspace whose own tests/ directory is replaced. Editing the
workspace's tests changes nothing here."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEST_FILES = {'tests/__init__.py': '# Unit tests.\n', 'tests/test_fees.py': 'import unittest\n\nfrom library.fees import late_fee\n\n\nclass FeesTest(unittest.TestCase):\n    def test_per_day_and_cap(self):\n        self.assertEqual(late_fee(0), 0)\n        self.assertEqual(late_fee(3), 75)\n        self.assertEqual(late_fee(30), 500)\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_loans.py': 'import datetime\nimport unittest\n\nfrom library.loans import Loan, days_late, due_date\n\n\nclass LoansTest(unittest.TestCase):\n    def test_due_date_and_lateness(self):\n        loan = Loan("m1", "B1", datetime.date(2026, 10, 1))\n        self.assertEqual(due_date(loan), datetime.date(2026, 10, 15))\n        self.assertEqual(days_late(loan, datetime.date(2026, 10, 15)), 0)\n        self.assertEqual(days_late(loan, datetime.date(2026, 10, 18)), 3)\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_members.py': 'import unittest\n\nfrom library.members import Member, load_members\n\n\nclass MembersTest(unittest.TestCase):\n    def test_load(self):\n        members = load_members(\'[{"id": "m1", "name": "Ann"}, {"id": "m2", "name": "Bo"}]\')\n        self.assertEqual(members["m1"].name, "Ann")\n        self.assertEqual(sorted(members), ["m1", "m2"])\n\n    def test_construct(self):\n        self.assertEqual(Member("m3", "Cy").name, "Cy")\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_notices.py': 'import datetime\nimport unittest\n\nfrom library.loans import Loan\nfrom library.members import Member\nfrom library.notices import overdue_notice\n\n\nclass NoticesTest(unittest.TestCase):\n    def test_standard_notice(self):\n        loan = Loan("m1", "B1", datetime.date(2026, 10, 1))\n        member = Member("m1", "Ann")\n        self.assertEqual(overdue_notice(loan, member, datetime.date(2026, 10, 18)),\n                         "Dear Ann, \'Dune\' was due on 2026-10-15. Late fee so far: 0.75.")\n        self.assertIsNone(overdue_notice(loan, member, datetime.date(2026, 10, 10)))\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/test_premium.py': 'import datetime\nimport unittest\n\nfrom library.loans import Loan\nfrom library.members import load_members\nfrom library.notices import overdue_notice\n\n\nclass PremiumTest(unittest.TestCase):\n    def test_premium_notice(self):\n        members = load_members(\'[{"id": "m2", "name": "Bo", "tier": "premium"}]\')\n        loan = Loan("m2", "B2", datetime.date(2026, 10, 1))\n        self.assertEqual(overdue_notice(loan, members["m2"], datetime.date(2026, 11, 1)),\n                         "Dear Bo, \'Emma\' was due on 2026-10-29. Late fee so far: 0.30.")\n\n\nif __name__ == "__main__":\n    unittest.main()\n', 'tests/run.py': '"""Run the unit tests under tests/ and report them like pytest\'s summary:\nthe failure details first, then one `FAILED <test> - <reason>` line per\nfailing test and a count line. Exit status 1 when anything failed."""\nimport os\nimport sys\nimport unittest\n\n\ndef main():\n    here = os.path.dirname(os.path.abspath(__file__))\n    root = os.path.dirname(here)\n    sys.path.insert(0, root)\n    suite = unittest.defaultTestLoader.discover(here, pattern="test_*.py", top_level_dir=root)\n    result = unittest.TestResult()\n    suite.run(result)\n    failed = result.failures + result.errors\n    for test, trace in failed:\n        print("_" * 12 + " " + test.id() + " " + "_" * 12)\n        print(trace.rstrip())\n        print()\n    failing_methods = set()\n    for test, trace in failed:\n        case = getattr(test, "test_case", test)\n        failing_methods.add(case.id())\n        parts = case.id().rsplit(".", 2)\n        if len(parts) == 3:\n            module, cls, method = parts\n            name = "%s.py::%s::%s" % (module.replace(".", "/"), cls, method)\n        else:\n            name = case.id()\n        if case is not test:\n            name += " " + test._subDescription()\n        lines = trace.strip().splitlines()\n        reason = lines[-1] if lines else ""\n        print("FAILED %s - %s" % (name, reason))\n    print("%d failed, %d passed" % (len(failing_methods), result.testsRun - len(failing_methods)))\n    return 1 if failed else 0\n\n\nif __name__ == "__main__":\n    sys.exit(main())\n', 'tests/test_hidden_library.py': 'import datetime\nimport unittest\n\nfrom library.loans import Loan\nfrom library.members import load_members\nfrom library.notices import overdue_notice\n\nD = datetime.date\nMEMBERS = load_members(\'[{"id": "m1", "name": "Ann"}, {"id": "m2", "name": "Bo", "tier": "premium"},\'\n                       \' {"id": "m3", "name": "Cy", "tier": "standard"}]\')\n\n\nclass HiddenPremiumTest(unittest.TestCase):\n    def test_tiers_load(self):\n        self.assertEqual([MEMBERS[k].tier for k in ("m1", "m2", "m3")], ["standard", "premium", "standard"])\n\n    def test_unknown_tier_raises(self):\n        with self.assertRaises(ValueError):\n            load_members(\'[{"id": "m9", "name": "Q", "tier": "gold"}]\')\n\n    def test_premium_fee_cap(self):\n        loan = Loan("m2", "B3", D(2026, 9, 1))\n        self.assertEqual(overdue_notice(loan, MEMBERS["m2"], D(2026, 11, 8)),\n                         "Dear Bo, \'Ulysses\' was due on 2026-09-29. Late fee so far: 3.00.")\n\n    def test_premium_not_late_within_28_days(self):\n        loan = Loan("m2", "B1", D(2026, 10, 1))\n        self.assertIsNone(overdue_notice(loan, MEMBERS["m2"], D(2026, 10, 20)))\n        self.assertIsNotNone(overdue_notice(loan, MEMBERS["m1"], D(2026, 10, 20)))\n\n    def test_standard_unchanged(self):\n        loan = Loan("m3", "B1", D(2026, 10, 1))\n        self.assertEqual(overdue_notice(loan, MEMBERS["m3"], D(2026, 12, 31)),\n                         "Dear Cy, \'Dune\' was due on 2026-10-15. Late fee so far: 5.00.")\n\n\nif __name__ == "__main__":\n    unittest.main()\n'}

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
