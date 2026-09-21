#!/usr/bin/env python3
"""Grade report.md for the unused_setting case: exactly one UNUSED line naming
mail.retry_backoff_ms."""
import sys
from pathlib import Path

EXPECTED = "mail.retry_backoff_ms"


def main() -> int:
    workspace = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    report = workspace / "report.md"
    if not report.is_file():
        print("report.md missing")
        return 1
    text = report.read_text(encoding="utf-8", errors="replace")
    lines = [line.strip() for line in text.splitlines() if line.strip().upper().startswith("UNUSED")]
    print("unused lines:", len(lines))
    if len(lines) != 1:
        return 1
    ok = EXPECTED in lines[0]
    print("line:", lines[0][:200])
    print("correct" if ok else "incorrect")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
