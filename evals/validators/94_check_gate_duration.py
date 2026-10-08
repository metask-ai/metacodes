#!/usr/bin/env python3
"""Grade the check-gate-v1 `duration` task: the visible README cases plus hidden
edge cases derived from the same specification. Imports `duration.py` from the
workspace; never reads the workspace's tests."""
import importlib.util
import sys
from pathlib import Path

FAILURES = []


def load(workspace):
    path = workspace / "duration.py"
    if not path.is_file():
        print("duration.py missing")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("duration", path)
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
    p = m.parse_duration
    # Visible cases.
    equal("1h30m", lambda: p("1h30m"), 5400)
    equal("90s", lambda: p("90s"), 90)
    equal("2d", lambda: p("2d"), 172800)
    equal("1.5h", lambda: p("1.5h"), 5400)
    for bad in ["", "1h1h", "h"]:
        raises("invalid %r" % bad, lambda bad=bad: p(bad))
    # Hidden cases.
    equal("all units", lambda: p("1d2h3m4s"), 93784)
    equal("zero", lambda: p("0s"), 0)
    equal("half minute", lambda: p("0.5m"), 30)
    equal("exact decimal minute", lambda: p("0.1m"), 6)
    equal("exact decimal hour", lambda: p("1.1h"), 3960)
    equal("subset in order", lambda: p("2d30m"), 174600)
    equal("leading zeros in number", lambda: p("007s"), 7)
    for bad in ["1.5s", "0.01m", "1m1h", "10", "1H", " 1h", "1h ", "1 h", ".5h", "5.h",
                "1.5.2h", "+1h", "-1h", "1x", "1s1m", "1d1d"]:
        raises("invalid %r" % bad, lambda bad=bad: p(bad))
    return finish("duration")


if __name__ == "__main__":
    sys.exit(main())
