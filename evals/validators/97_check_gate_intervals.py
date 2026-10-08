#!/usr/bin/env python3
"""Grade the check-gate-v1 `intervals` task: the visible README cases plus hidden
edge cases derived from the same specification. Imports `intervals.py` from the
workspace; never reads the workspace's tests."""
import importlib.util
import sys
from pathlib import Path

FAILURES = []


def load(workspace):
    path = workspace / "intervals.py"
    if not path.is_file():
        print("intervals.py missing")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("intervals", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def equal(label, thunk, expected):
    try:
        got = thunk()
    except Exception as exc:  # noqa: BLE001 - any exception is a failure here
        FAILURES.append("%s: raised %s: %s" % (label, type(exc).__name__, exc))
        return
    if type(got) is not type(expected) or got != expected:
        FAILURES.append("%s: expected %r, got %r" % (label, expected, got))


def raises(label, thunk, error=ValueError):
    try:
        got = thunk()
    except error:
        return
    except Exception as exc:  # noqa: BLE001
        FAILURES.append("%s: expected %s, raised %s" % (label, error.__name__, type(exc).__name__))
        return
    FAILURES.append("%s: expected %s, returned %r" % (label, error.__name__, got))


def finish(total_label):
    for line in FAILURES:
        print("FAIL", line)
    print("%s: %d failing case(s)" % (total_label, len(FAILURES)))
    return 1 if FAILURES else 0

def main():
    workspace = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    m = load(workspace)
    g = m.merge
    # Visible cases.
    equal("overlapping", lambda: g([(1, 3), (2, 6), (8, 10)]), [(1, 6), (8, 10)])
    equal("unsorted", lambda: g([(8, 10), (1, 3)]), [(1, 3), (8, 10)])
    raises("reversed", lambda: g([(5, 1)]))
    # Hidden cases.
    equal("touching merges", lambda: g([(1, 3), (3, 5)]), [(1, 5)])
    equal("gap does not merge", lambda: g([(1, 2), (3, 4)]), [(1, 2), (3, 4)])
    equal("empty dropped", lambda: g([(2, 2)]), [])
    equal("empty among others", lambda: g([(5, 5), (1, 2)]), [(1, 2)])
    equal("empty at a boundary", lambda: g([(0, 0), (0, 1)]), [(0, 1)])
    equal("nested", lambda: g([(1, 10), (2, 3)]), [(1, 10)])
    equal("negative", lambda: g([(-5, -1), (-2, 3)]), [(-5, 3)])
    equal("no input", lambda: g([]), [])
    equal("duplicates", lambda: g([(1, 2), (1, 2)]), [(1, 2)])
    equal("chain", lambda: g([(6, 8), (1, 3), (2, 4), (4, 6), (10, 11)]), [(1, 8), (10, 11)])
    raises("reversed among valid", lambda: g([(1, 2), (4, 3)]))
    data = [(3, 4), (1, 2)]
    copy = list(data)
    try:
        g(data)
    except Exception:  # noqa: BLE001
        pass
    if data != copy:
        FAILURES.append("input modified: %r" % (data,))
    return finish("intervals")


if __name__ == "__main__":
    sys.exit(main())
