#!/usr/bin/env python3
"""Grade the check-gate-v1 `roman` task: the visible README cases plus hidden
edge cases derived from the same specification. Imports `roman.py` from the
workspace; never reads the workspace's tests."""
import importlib.util
import sys
from pathlib import Path

FAILURES = []


def load(workspace):
    path = workspace / "roman.py"
    if not path.is_file():
        print("roman.py missing")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("roman", path)
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
    # Visible cases.
    equal("to 1994", lambda: m.to_roman(1994), "MCMXCIV")
    equal("to 4", lambda: m.to_roman(4), "IV")
    equal("from 1994", lambda: m.from_roman("MCMXCIV"), 1994)
    raises("to 0", lambda: m.to_roman(0))
    raises("from IIII", lambda: m.from_roman("IIII"))
    # Hidden cases.
    equal("to 3999", lambda: m.to_roman(3999), "MMMCMXCIX")
    equal("to 49", lambda: m.to_roman(49), "XLIX")
    raises("to 4000", lambda: m.to_roman(4000))
    raises("to -1", lambda: m.to_roman(-1))
    raises("to True", lambda: m.to_roman(True), TypeError)
    raises("to 2.0", lambda: m.to_roman(2.0), TypeError)
    raises("to '5'", lambda: m.to_roman("5"), TypeError)
    for bad in ["VV", "IC", "XM", "IIV", "MMMM", "iv", "", "IL", "VX", "LL", "DD",
                "CCCC", "XXXX", "IXIX", "MCMXCIV ", " IV", "IIX", "XCX"]:
        raises("from %r" % bad, lambda bad=bad: m.from_roman(bad))
    roundtrip_failures = []
    for n in range(1, 4000):
        try:
            if m.from_roman(m.to_roman(n)) != n:
                roundtrip_failures.append(n)
        except Exception:  # noqa: BLE001
            roundtrip_failures.append(n)
    if roundtrip_failures:
        FAILURES.append("round trip fails for %d values, first %r" % (len(roundtrip_failures), roundtrip_failures[:5]))
    return finish("roman")


if __name__ == "__main__":
    sys.exit(main())
