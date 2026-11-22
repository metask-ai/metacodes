#!/usr/bin/env python3
"""A change's CHANGELOG entries are its own and sit under ``## Unreleased``.

``.gitattributes`` merges ``CHANGELOG.md`` with git's ``union`` driver, which
keeps both sides' lines where a merge used to conflict. Two things it can get
wrong are checked here, comparing the candidate with ``--base``:

- An entry (a line starting ``- ``) a released section gained: across a
  release cut, union leaves a branch's entry under the released heading.
- An entry the candidate has more often than the base, beyond what the
  change wrote itself: when main rewrote, moved or removed an entry next to
  where the branch added one, union keeps main's old version.

Run from the repository root:
    python3 scripts/check_changelog_sections.py --base <commit>
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from collections import Counter
from pathlib import Path

CHANGELOG = "CHANGELOG.md"
UNRELEASED = "## Unreleased"


def sections(text: str) -> dict[str, list[str]]:
    """Each ``## `` heading and the lines under it, up to the next one."""
    result: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in text.splitlines():
        if line.startswith("## "):
            current = result.setdefault(line.rstrip(), [])
        elif current is not None:
            current.append(line)
    return result


def entries(lines: list[str]) -> list[str]:
    return [line for line in lines if line.startswith("- ")]


def misplaced(base: str, candidate: str) -> list[tuple[str, str]]:
    """(heading, entry) for the new entries of a released section that gained some."""
    before = sections(base)
    found = []
    for heading, lines in sections(candidate).items():
        if heading == UNRELEASED or heading not in before:
            continue
        old = entries(before[heading])
        new = entries(lines)
        if len(new) > len(old):
            found.extend((heading, line) for line in new if line not in old)
    return found


def stale(base: str, candidate: str, own: Counter[str]) -> list[str]:
    """Entries the candidate has more often than the base plus the change's own additions."""
    before = Counter(entries(base.splitlines()))
    after = Counter(entries(candidate.splitlines()))
    return [line for line, count in after.items() if count - before[line] > own[line]]


def own_additions(base: str, path: str) -> Counter[str]:
    """Entries ``base..HEAD`` wrote itself: added by a non-merge commit, or by a merge
    resolution that is in neither parent. Union only ever keeps a parent's line."""
    def log(*args: str) -> list[str]:
        return subprocess.run(["git", "log", *args, "--format=", "-p", f"{base}..HEAD", "--", path],
                              capture_output=True, text=True, encoding="utf-8", check=True).stdout.splitlines()

    added = Counter(line[1:] for line in log("--no-merges") if line.startswith("+- "))
    added.update(line[2:] for line in log("--merges", "--cc") if line.startswith("++- "))
    return added


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="commit the change is measured against")
    parser.add_argument("--file", default=CHANGELOG, help="changelog path, relative to the repository root")
    args = parser.parse_args(argv)
    shown = subprocess.run(["git", "show", f"{args.base}:{args.file}"], capture_output=True, text=True,
                           encoding="utf-8")
    if shown.returncode != 0:
        print(f"{args.file}: cannot read it at {args.base}: {shown.stderr.strip()}", file=sys.stderr)
        return 1
    candidate = Path(args.file).read_text(encoding="utf-8")
    found = misplaced(shown.stdout, candidate)
    for heading, entry in found:
        print(f"{args.file}: a new entry is under the released section '{heading}'; move it to "
              f"'{UNRELEASED}' (a union merge across a release cut puts it there): {entry[:100]}")
    leftovers = stale(shown.stdout, candidate, own_additions(args.base, args.file))
    for entry in leftovers:
        print(f"{args.file}: this entry was not written by this change, so a union merge of main "
              f"kept a version main has since rewritten, moved or removed; delete it: {entry[:100]}")
    return 1 if found or leftovers else 0


if __name__ == "__main__":
    sys.exit(main())
