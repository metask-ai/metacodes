#!/usr/bin/env python3
"""Grade the check-gate-v1 `semver` task: the visible README cases plus hidden
edge cases derived from the same specification. Imports `semver.py` from the
workspace; never reads the workspace's tests."""
import importlib.util
import sys
from pathlib import Path

FAILURES = []


def load(workspace):
    path = workspace / "semver.py"
    if not path.is_file():
        print("semver.py missing")
        sys.exit(1)
    spec = importlib.util.spec_from_file_location("semver", path)
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
    c = m.compare
    # Visible cases.
    equal("equal cores", lambda: c("1.2.3", "1.2.3"), 0)
    equal("minor numeric", lambda: c("1.10.0", "1.9.0"), 1)
    equal("major numeric", lambda: c("2.0.0", "10.0.0"), -1)
    equal("pre-release below release", lambda: c("1.0.0-alpha", "1.0.0"), -1)
    equal("release above rc", lambda: c("1.0.0", "1.0.0-rc.1"), 1)
    equal("numeric identifiers", lambda: c("1.0.0-beta.2", "1.0.0-beta.11"), -1)
    equal("build ignored", lambda: c("1.0.0+build.1", "1.0.0+build.2"), 0)
    for bad in ["", "1.0", "1.0.x", "01.0.0"]:
        raises("invalid %r" % bad, lambda bad=bad: c(bad, "1.0.0"))
    # Hidden cases.
    chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
             "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
    for i, low in enumerate(chain):
        for high in chain[i + 1:]:
            equal("%s < %s" % (low, high), lambda low=low, high=high: c(low, high), -1)
            equal("%s > %s" % (high, low), lambda low=low, high=high: c(high, low), 1)
    equal("numeric below alphanumeric", lambda: c("1.0.0-1", "1.0.0-alpha"), -1)
    equal("ASCII order", lambda: c("1.0.0-Beta", "1.0.0-alpha"), -1)
    equal("zero identifier valid", lambda: c("1.0.0-0", "1.0.0-1"), -1)
    equal("alphanumeric may start with 0", lambda: c("1.0.0-0a", "1.0.0-1"), 1)
    equal("hyphen in identifier", lambda: c("1.0.0-x-y.1", "1.0.0-x-y.2"), -1)
    equal("build ignored with pre-release", lambda: c("1.0.0-alpha+001", "1.0.0-alpha"), 0)
    equal("build may have leading zeros", lambda: c("1.0.0+001", "1.0.0"), 0)
    equal("patch numeric", lambda: c("1.0.10", "1.0.9"), 1)
    for bad in ["1.0.0-01", "1.0.0-alpha..1", "1.0.0-", "1.0.0+", " 1.0.0", "1.0.0 ",
                "1.0.0.0", "1.0.0-al$pha", "1.01.0", "a.b.c"]:
        raises("invalid %r" % bad, lambda bad=bad: c(bad, "1.0.0"))
    raises("second argument validated", lambda: c("1.0.0", "1.0"))
    return finish("semver")


if __name__ == "__main__":
    sys.exit(main())
