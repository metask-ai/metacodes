#!/usr/bin/env python3
"""Grade the check-gate-v1 `csvline` task: the visible README cases plus hidden
edge cases derived from the same specification. Imports `csvline.py` from the
workspace; never reads the workspace's tests."""
import importlib.util
import sys
from pathlib import Path

FAILURES = []


def load(workspace):
    path = workspace / "csvline.py"
    if not path.is_file():
        print("csvline.py missing")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("csvline", path)
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
    p = m.parse_line
    # Visible cases.
    equal("plain", lambda: p("a,b,c"), ["a", "b", "c"])
    equal("quoted comma", lambda: p('x,"y,z"'), ["x", "y,z"])
    equal("escaped quote", lambda: p('"say ""hi"""'), ['say "hi"'])
    equal("trailing comma", lambda: p("a,"), ["a", ""])
    # Hidden cases.
    equal("empty line", lambda: p(""), [""])
    equal("lone comma", lambda: p(","), ["", ""])
    equal("spaces kept", lambda: p(" a , b "), [" a ", " b "])
    equal("quote inside unquoted field", lambda: p('a"b'), ['a"b'])
    equal("empty quoted field", lambda: p('""'), [""])
    equal("two empty quoted fields", lambda: p('"",""'), ["", ""])
    equal("doubled quote mid-field", lambda: p('"a""b"'), ['a"b'])
    equal("leading space means unquoted", lambda: p(' "a"'), [' "a"'])
    equal("mixed", lambda: p('a,"b,c",d'), ["a", "b,c", "d"])
    equal("quote at end of quoted field", lambda: p('"x"""'), ['x"'])
    equal("README example", lambda: p('"x,y","say ""hi"""'), ["x,y", 'say "hi"'])
    for bad in ['"a"b', '"abc', '"', 'a,"b', '"a" ,b']:
        raises("invalid %r" % bad, lambda bad=bad: p(bad))
    return finish("csvline")


if __name__ == "__main__":
    sys.exit(main())
