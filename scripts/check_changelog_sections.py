#!/usr/bin/env python3
"""New CHANGELOG entries go under ``## Unreleased``, never a released version.

``.gitattributes`` merges ``CHANGELOG.md`` with git's ``union`` driver, so a
branch that merges main no longer stops on the entry both sides added at the
top of ``## Unreleased``. Union keeps both sides' lines without knowing what a
section is: when main has just cut a release (``## Unreleased`` renamed to
``## <version> — <date>``, an empty one reinserted), the branch's entry can
land under the released heading. release.yml takes the release notes from
that section, so this check stands in for the conflict a person used to see.

A section heading present on both the base and the candidate, other than
``## Unreleased``, must not gain a top-level entry (a line starting ``- ``).
Rewording an existing entry is still allowed; a release cut adds a heading the
base does not have, which this check leaves alone.

Run from the repository root:
    python3 scripts/check_changelog_sections.py --base <commit>
Exit status 0 when no released section gained an entry, 1 otherwise.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
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


def misplaced(base: str, candidate: str) -> list[tuple[str, str]]:
    """(heading, entry) for every entry a released section gained."""
    before = sections(base)
    found = []
    for heading, lines in sections(candidate).items():
        if heading == UNRELEASED or heading not in before:
            continue
        old = {line for line in before[heading] if line.startswith("- ")}
        found.extend((heading, line) for line in lines if line.startswith("- ") and line not in old)
    return found


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
    found = misplaced(shown.stdout, Path(args.file).read_text(encoding="utf-8"))
    for heading, entry in found:
        print(f"{args.file}: a new entry is under the released section '{heading}'; move it to "
              f"'{UNRELEASED}' (a union merge across a release cut puts it there): {entry[:100]}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
