"""Run the unit tests under tests/ and report them like pytest's summary:
the failure details first, then one `FAILED <test> - <reason>` line per
failing test and a count line. Exit status 1 when anything failed."""
import os
import sys
import unittest


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    sys.path.insert(0, root)
    suite = unittest.defaultTestLoader.discover(here, pattern="test_*.py", top_level_dir=root)
    result = unittest.TestResult()
    suite.run(result)
    failed = result.failures + result.errors
    for test, trace in failed:
        print("_" * 12 + " " + test.id() + " " + "_" * 12)
        print(trace.rstrip())
        print()
    failing_methods = set()
    for test, trace in failed:
        # A failing subTest reports the test method it belongs to.
        case = getattr(test, "test_case", test)
        failing_methods.add(case.id())
        parts = case.id().rsplit(".", 2)
        if len(parts) == 3:
            module, cls, method = parts
            name = "%s.py::%s::%s" % (module.replace(".", "/"), cls, method)
        else:
            name = case.id()
        if case is not test:
            name += " " + test._subDescription()
        lines = trace.strip().splitlines()
        reason = lines[-1] if lines else ""
        print("FAILED %s - %s" % (name, reason))
    print("%d failed, %d passed" % (len(failing_methods), result.testsRun - len(failing_methods)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
