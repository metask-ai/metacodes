#!/usr/bin/env python3
"""Semantic validator for the historical Windows swarm lock liveness fix."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    workspace = Path(sys.argv[1])
    try:
        lock = (workspace / "src/swarm/file_lock.zig").read_text(encoding="utf-8")
        teammate = (workspace / "src/swarm/teammate.zig").read_text(encoding="utf-8")
        runtime_test = (workspace / "tests/component/teammate_runtime_test.zig").read_text(
            encoding="utf-8"
        )
    except OSError as exc:
        print(f"cannot read snapshot source: {exc}")
        return 1
    handoff_path = workspace / "HANDOFF.md"
    handoff = handoff_path.read_text(encoding="utf-8") if handoff_path.is_file() else ""
    failures: list[str] = []

    require(re.search(r"retries:\s*u32\s*=\s*100", lock) is not None, "retry budget is not 100", failures)
    require("while (std.c.unlink" in lock, "release does not retry unlink", failures)
    require("attempt > 20" in lock, "release retry ceiling is not bounded at 20", failures)
    require("pfs.exists" in lock and "sleepMs(2)" in lock, "release retry lacks disappearance check/backoff", failures)
    require(
        re.search(r"if \(is_windows\)\s*\n\s*lockMtimeMs", lock) is not None,
        "Windows stale probe is not mtime-only",
        failures,
    )
    require("fn stealRename" in lock and "std.c.rename" in lock, "stale steal is not rename-linearized", failures)
    require("const jittered" in lock, "acquire retry lacks jitter", failures)
    require(
        "setMemberActiveBestEffort(a, e.config_path, e.name, true);" in teammate,
        "pre-turn active-state scheduling point was removed",
        failures,
    )
    require(runtime_test.count("1500") >= 2, "slow-server regression bounds were not reduced", failures)
    require(
        re.search(r"startCassette\(&bodies,\s*(?:3000|5000)\)", runtime_test) is None,
        "old pathological slow-server delays remain",
        failures,
    )
    for token in (
        "stale_ms=10000",
        "retry_budget≈9700ms",
        "release_retries=20",
        "windows_probe=mtime_only",
    ):
        require(token in handoff, f"HANDOFF.md omits {token}", failures)

    if failures:
        print("; ".join(failures))
        return 1
    print("Windows lock liveness and teardown invariants are complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
