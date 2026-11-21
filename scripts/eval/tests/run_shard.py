#!/usr/bin/env python3
"""Run one shard of the evaluation suite: `run_shard.py K/N [-v]`.

`zig build test:product` runs `scripts/eval/tests` as N shards at once
(build.zig). One `python3 -m unittest discover -s scripts/eval/tests` used to
run behind every smoke: the build runner runs a command that inherits the
terminal one at a time, and that command was the longest of them. Shards with
captured output run beside the smokes and beside each other
(doc/CI_DESIGN.md §4).

Shards run concurrently, so modules that share state outside their own
temporary directories must not be split across them. Such a module declares
`EVAL_SHARD_GROUP = "<name>"`; every module of a group runs in one shard, in
the suite's order, as all of them did in the single process. The plugin-v1
modules are one group: test_plugin_frozen_run edits a pinned input of the live
checkout and restores it, and the others hash that file.

The groups (a module without the attribute is a group of its own), in the
order `unittest discover` finds their first module, are dealt round-robin: the
K-th shard of N takes every N-th group from the K-th, so N shards run every
module exactly once (test_run_shard.py). A module that fails to import is a
group of its own and fails its shard.

A shard runs under a watchdog. zig's --test-timeout covers zig test runners,
not these commands, so a hung case used to hold its CI leg until the job's
45-minute timeout, and the cancelled job showed no output from the shard. After
SHARD_TIMEOUT_S the watchdog prints every thread's stack, naming the hung case,
and exits non-zero. Python 3.9, stdlib only.
"""
from __future__ import annotations

import faulthandler
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
# A whole shard takes about 5 minutes on a Linux CI runner. 15 minutes leaves
# room for slower runners and still fails well before the job's own timeout.
SHARD_TIMEOUT_S = 15 * 60


def arm_watchdog(seconds: float) -> None:
    """After `seconds`, dump every thread's stack to stderr and exit with 1."""
    faulthandler.dump_traceback_later(seconds, exit=True)


def parse_shard(text: str) -> tuple[int, int] | None:
    """`K/N` with 1 <= K <= N, or None."""
    parts = text.split("/")
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        return None
    index, count = int(parts[0]), int(parts[1])
    if count < 1 or not 1 <= index <= count:
        return None
    return index, count


def select_shard(modules: list, index: int, count: int) -> list:
    """Shard `index` (from 1) of `count`: every count-th item from the index-th."""
    return [module for position, module in enumerate(modules) if position % count == index - 1]


def group_modules(modules: list, group_of) -> list:
    """Modules sharing a group key, kept together in first-appearance order."""
    groups: dict = {}
    for module in modules:
        groups.setdefault(group_of(module), []).append(module)
    return list(groups.values())


def _first_test(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            found = _first_test(item)
            if found is not None:
                return found
        else:
            return item
    return None


def module_group(suite) -> str:
    """A discovered module's EVAL_SHARD_GROUP, or a key of its own."""
    test = _first_test(suite)
    if test is None:
        return "empty:%d" % id(suite)
    module = sys.modules.get(type(test).__module__)
    declared = getattr(module, "EVAL_SHARD_GROUP", None) if module is not None else None
    return "group:" + declared if isinstance(declared, str) and declared else "test:" + test.id()


def main(argv: list[str]) -> int:
    shard = parse_shard(argv[0]) if argv else None
    if shard is None:
        print("usage: run_shard.py K/N [-v]  (1 <= K <= N)", file=sys.stderr)
        return 2
    index, count = shard
    # `python3 -m unittest` has the working directory, the repository root,
    # on sys.path; the suite imports `scripts.eval`.
    sys.path.insert(0, str(ROOT))
    modules = list(unittest.defaultTestLoader.discover(str(HERE)))
    groups = select_shard(group_modules(modules, module_group), index, count)
    selected = unittest.TestSuite([module for group in groups for module in group])
    print(
        f"evaluation suite shard {index}/{count}: {selected.countTestCases()} tests"
        f" from {sum(len(group) for group in groups)} of {len(modules)} modules",
        file=sys.stderr,
    )
    if selected.countTestCases() == 0:
        print("this shard selects no tests", file=sys.stderr)
        return 1
    verbosity = 2 if "-v" in argv[1:] else 1
    arm_watchdog(SHARD_TIMEOUT_S)
    result = unittest.TextTestRunner(verbosity=verbosity).run(selected)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
