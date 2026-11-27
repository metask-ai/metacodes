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

import concurrent.futures
import faulthandler
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BENCH_MODULE_PREFIXES = ("test_bench_", "test_harbor_")
# The slowest shard takes about 5 minutes on a Linux CI runner and up to about
# 10.5 minutes on macOS. 20 minutes leaves room for the slowest runner and still
# fails well before the job's own 45-minute timeout.
SHARD_TIMEOUT_S = 20 * 60


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


def module_name(suite) -> str:
    test = _first_test(suite)
    if test is None:
        return ""
    mod = type(test).__module__
    if mod == "unittest.loader":
        return getattr(test, "_testMethodName", "")
    return mod


def is_bench_module(name: str) -> bool:
    return name.startswith(BENCH_MODULE_PREFIXES)


def filter_modules(modules: list, *, bench_only: bool = False) -> list:
    if not bench_only:
        return modules
    return [module for module in modules if is_bench_module(module_name(module))]


def module_group(suite) -> str:
    """A discovered module's EVAL_SHARD_GROUP, or a key of its own."""
    test = _first_test(suite)
    if test is None:
        return "empty:%d" % id(suite)
    module = sys.modules.get(type(test).__module__)
    declared = getattr(module, "EVAL_SHARD_GROUP", None) if module is not None else None
    return "group:" + declared if isinstance(declared, str) and declared else "test:" + test.id()


def run_parallel_groups(groups: list, jobs: int, verbose: bool) -> int:
    ordered = sorted(
        groups,
        key=lambda group: sum(module.countTestCases() for module in group),
        reverse=True,
    )
    total_tests = sum(module.countTestCases() for group in ordered for module in group)
    total_modules = sum(len(group) for group in ordered)
    workers = max(1, min(jobs, len(ordered)))
    print(
        f"evaluation suite parallel run ({workers} workers): {total_tests} tests"
        f" from {total_modules} modules",
        file=sys.stderr,
    )

    def run_group(group: list) -> tuple[list[str], int, str]:
        names = [module_name(module) for module in group]
        targets = [f"scripts.eval.tests.{name}" for name in names]
        cmd = [sys.executable, "-m", "unittest", *(["-v"] if verbose else []), *targets]
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(ROOT),
                capture_output=True,
                text=True,
                timeout=SHARD_TIMEOUT_S,
                check=False,
            )
            return names, proc.returncode, (proc.stdout or "") + (proc.stderr or "")
        except subprocess.TimeoutExpired as exc:
            out = (exc.stdout or "") if isinstance(exc.stdout, str) else ""
            err = (exc.stderr or "") if isinstance(exc.stderr, str) else ""
            return names, 1, f"{out}{err}\nTimeout after {SHARD_TIMEOUT_S}s running {', '.join(names)}\n"

    failed = False
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(run_group, group) for group in ordered]
        for future in concurrent.futures.as_completed(futures):
            names, code, output = future.result()
            if code != 0:
                failed = True
            header = f"=== {', '.join(names)} ({'PASS' if code == 0 else f'FAIL rc={code}'}) ==="
            print(header, file=sys.stderr)
            if output:
                print(output, file=sys.stderr, end="" if output.endswith("\n") else "\n")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    bench_only = False
    verbose = False
    jobs: int | None = None
    shard_arg: str | None = None
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--bench-only":
            bench_only = True
        elif arg == "-v":
            verbose = True
        elif arg == "--jobs":
            if index + 1 >= len(argv) or not argv[index + 1].isdigit() or int(argv[index + 1]) < 1:
                print("usage: run_shard.py [--bench-only] (K/N | --jobs M) [-v]", file=sys.stderr)
                return 2
            jobs = int(argv[index + 1])
            index += 1
        elif shard_arg is None:
            shard_arg = arg
        else:
            print("usage: run_shard.py [--bench-only] (K/N | --jobs M) [-v]", file=sys.stderr)
            return 2
        index += 1
    if (shard_arg is None) == (jobs is None):
        print("usage: run_shard.py [--bench-only] (K/N | --jobs M) [-v]", file=sys.stderr)
        return 2
    # `python3 -m unittest` has the working directory, the repository root,
    # on sys.path; the suite imports `scripts.eval`.
    sys.path.insert(0, str(ROOT))
    from scripts import test_ids

    modules = filter_modules(list(unittest.defaultTestLoader.discover(str(HERE))), bench_only=bench_only)
    groups = group_modules(modules, module_group)
    if not groups:
        print("this selection matches no test modules", file=sys.stderr)
        return 1
    if jobs is not None:
        return run_parallel_groups(groups, jobs, verbose)

    shard = parse_shard(shard_arg)
    if shard is None:
        print("usage: run_shard.py [--bench-only] (K/N | --jobs M) [-v]", file=sys.stderr)
        return 2
    shard_index, count = shard
    selected_groups = select_shard(groups, shard_index, count)
    selected = unittest.TestSuite([module for group in selected_groups for module in group])
    print(
        f"evaluation suite shard {shard_index}/{count}: {selected.countTestCases()} tests"
        f" from {sum(len(group) for group in selected_groups)} of {len(modules)} modules",
        file=sys.stderr,
    )
    if selected.countTestCases() == 0:
        print("this shard selects no tests", file=sys.stderr)
        return 1
    verbosity = 2 if verbose else 1
    arm_watchdog(SHARD_TIMEOUT_S)
    result_class = test_ids.recording_result_class("eval", "scripts/eval/tests")
    result = unittest.TextTestRunner(verbosity=verbosity, resultclass=result_class).run(selected)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
