#!/usr/bin/env python3
"""Semantic validator for the historical POSIX POLLHUP drain regression."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    workspace = Path(sys.argv[1])
    source_path = workspace / "src/platform/process.zig"
    handoff_path = workspace / "HANDOFF.md"
    failures: list[str] = []
    try:
        source = source_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"cannot read {source_path}: {exc}")
        return 1
    handoff = handoff_path.read_text(encoding="utf-8") if handoff_path.is_file() else ""

    terminal = re.search(r"terminal_events\s*=\s*([^;]+);", source)
    require(terminal is not None, "terminal event mask is missing", failures)
    if terminal is not None:
        for token in ("POLL.HUP", "POLL.ERR", "POLL.NVAL"):
            require(token in terminal.group(1), f"terminal mask omits {token}", failures)
    require(
        len(re.findall(r"revents\s*&\s*\([^\n]*POLL\.IN[^\n]*terminal_events", source)) >= 2,
        "stdout and stderr must both read on POLLIN or terminal events",
        failures,
    )
    require(source.count("if (n < 0)") >= 2, "negative reads must be errors on both pipes", failures)
    require(source.count("if (n == 0)") >= 2, "EOF must close both pipe drains", failures)
    require("return error.ReadError" in source, "negative read path must report ReadError", failures)
    require("hup-drained" in source, "short-lived child regression test is missing", failures)
    for token in ("POLLHUP", "buffered-bytes-before-EOF", "negative-read=ReadError"):
        require(token in handoff, f"HANDOFF.md omits {token}", failures)

    if failures:
        print("; ".join(failures))
        return 1
    print("POSIX HUP drain semantics and handoff are complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
