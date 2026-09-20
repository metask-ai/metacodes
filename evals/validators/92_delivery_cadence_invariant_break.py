#!/usr/bin/env python3
"""Grade report.md for the invariant_break case: exactly one FINDING line naming
workers.reindex_shards (the run() that returns without ack)."""
import sys
from pathlib import Path

EXPECTED = "reindex_shards"


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
    ok = EXPECTED in findings[0]
    print("line:", findings[0][:200])
    print("correct" if ok else "incorrect")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
