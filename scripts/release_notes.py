#!/usr/bin/env python3
"""Print one release's section of CHANGELOG.md (`## <version> — <date>` up to
the next `## ` heading) as the GitHub release notes.

`release.yml`'s publish job pipes this into `gh release create --notes-file`;
doc/RELEASE_AUTOMATION_DESIGN.md stage C. Python 3.9, stdlib only.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_cut  # noqa: E402


def main(argv: list) -> int:
    if len(argv) != 2 or not release_cut.TAG_RE.match(argv[1]):
        print("usage: release_notes.py X.Y.Z", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[1]
    try:
        sys.stdout.write(release_cut.release_section(release_cut.read(root, release_cut.CHANGELOG), argv[1]))
    except release_cut.CutError as exc:
        print(f"release_notes: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
