#!/usr/bin/env python3
"""Grade the check-gate-v1 `wrap` task: the visible README cases plus hidden
edge cases derived from the same specification. Imports `wrap.py` from the
workspace; never reads the workspace's tests."""
import importlib.util
import sys
from pathlib import Path

FAILURES = []


def load(workspace):
    path = workspace / "wrap.py"
    if not path.is_file():
        print("wrap.py missing")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("wrap", path)
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
    w = m.wrap
    # Visible cases.
    equal("greedy", lambda: w("the quick brown fox", 10), "the quick\nbrown fox")
    equal("paragraphs", lambda: w("a b\n\nc", 10), "a b\n\nc")
    raises("width 0", lambda: w("a", 0))
    # Hidden cases.
    equal("long word", lambda: w("abcdefghij", 4), "abcd\nefgh\nij")
    equal("long word after text", lambda: w("hi abcdefghij", 4), "hi\nabcd\nefgh\nij")
    equal("continue after last piece", lambda: w("abcdef g", 4), "abcd\nef g")
    equal("runs of spaces", lambda: w("a    b", 10), "a b")
    equal("line break inside paragraph", lambda: w("a\nb", 10), "a b")
    equal("many blank lines", lambda: w("a\n\n\n\nb", 10), "a\n\nb")
    equal("blank line with spaces", lambda: w("a\n   \nb", 10), "a\n\nb")
    equal("leading and trailing blank lines", lambda: w("\n\na\n\n", 10), "a")
    equal("empty", lambda: w("", 5), "")
    equal("only whitespace", lambda: w("   \n  ", 5), "")
    equal("exact fit", lambda: w("abcd efgh", 4), "abcd\nefgh")
    equal("width one", lambda: w("ab c", 1), "a\nb\nc")
    equal("leading spaces", lambda: w("   x y", 10), "x y")
    raises("negative width", lambda: w("a", -1))
    raises("float width", lambda: w("a", 2.5))
    return finish("wrap")


if __name__ == "__main__":
    sys.exit(main())
