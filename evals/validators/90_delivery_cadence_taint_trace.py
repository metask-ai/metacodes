#!/usr/bin/env python3
"""Grade report.md for the taint_trace case: exactly one FINDING line naming
the unguarded chain (handlers.export -> exec_backend.run_command)."""
import re
import sys
from pathlib import Path

EXPECTED_SOURCE = "handlers.export"
EXPECTED_SINK = "exec_backend.run_command"


def main() -> int:
    workspace = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    report = workspace / "report.md"
    if not report.is_file():
        print("report.md missing")
        return 1
    text = report.read_text(encoding="utf-8", errors="replace")
    findings = [line.strip() for line in text.splitlines() if line.strip().upper().startswith("FINDING")]
    print("finding lines:", len(findings))
    if len(findings) != 1:
        return 1
    line = findings[0]
    ok = EXPECTED_SOURCE in line and EXPECTED_SINK in line
    print("line:", line[:200])
    print("correct" if ok else "incorrect")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
