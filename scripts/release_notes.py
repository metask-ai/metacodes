#!/usr/bin/env python3
"""Print one release's section of CHANGELOG.md (`## <version> — <date>` up to
the next `## ` heading) as the GitHub release notes.

`release.yml`'s publish job pipes this into `gh release create --notes-file`;
doc/RELEASE_AUTOMATION_DESIGN.md stage C. A section over GitHub's release body
limit is cut after the last whole entry that fits and ends with a pointer to
the full text. Python 3.9, stdlib only.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_cut  # noqa: E402

# GitHub refuses a longer release body (125,000 characters); measured in UTF-8
# bytes like release_cut.PR_BODY_LIMIT, which never undercounts it.
RELEASE_BODY_LIMIT = 125000


def fit_notes(section: str, version: str, limit: int = RELEASE_BODY_LIMIT) -> str:
    """The section unchanged, or, over `limit`, its heading and entries up to
    the last whole `- ` entry or `### ` subsection that fits, then a pointer."""
    if release_cut.body_size(section) <= limit:
        return section
    lines = section.rstrip("\n").splitlines()
    prefix = [0]
    for line in lines:
        prefix.append(prefix[-1] + release_cut.body_size(line) + 1)
    cuts = [k for k in range(len(lines) - 1, 0, -1) if k == 1 or lines[k].startswith(("- ", "### "))]
    for k in cuts:
        tail = pointer(version, len(lines) - k)
        if prefix[k] + release_cut.body_size(tail) <= limit:
            return "\n".join(lines[:k]).rstrip("\n") + "\n" + tail
    raise release_cut.CutError(f"the notes for {version} do not fit GitHub's {limit:,} even as a heading and a pointer")


def pointer(version: str, dropped: int) -> str:
    return (
        f"\n_The notes stop here: {dropped} more lines do not fit a GitHub release. The full section is in "
        f"`CHANGELOG.md` at tag `{version}`, and every archive below carries it as "
        f"`share/doc/CHANGELOG-{version}.md`._\n"
    )


def main(argv: list) -> int:
    if len(argv) != 2 or not release_cut.TAG_RE.match(argv[1]):
        print("usage: release_notes.py X.Y.Z", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[1]
    try:
        section = release_cut.release_section(release_cut.read(root, release_cut.CHANGELOG), argv[1])
        sys.stdout.write(fit_notes(section, argv[1]))
    except release_cut.CutError as exc:
        print(f"release_notes: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
