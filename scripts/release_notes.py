#!/usr/bin/env python3
"""Print one release's section of CHANGELOG.md (`## <version> — <date>` up to
the next `## ` heading) as the GitHub release notes.

`release.yml`'s publish job pipes this into `gh release create --notes-file`;
doc/RELEASE_AUTOMATION_DESIGN.md stage C. A section over GitHub's release body
limit is cut after the last whole entry that fits and ends with a pointer to
the full text. The notes lead with the AgentCore this release includes: its
version, ABI revision and package versions, then its changes and migration steps
from `sdk/CHANGELOG.md`, or the release that built it when it is reused. A main
release the ledger does not map to an AgentCore has no notes.
Python 3.9, stdlib only.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentcore_contract  # noqa: E402
import release_cut  # noqa: E402

# GitHub refuses a longer release body (125,000 characters); measured in UTF-8
# bytes like release_cut.PR_BODY_LIMIT, which never undercounts it.
RELEASE_BODY_LIMIT = 125000
# AgentCore's block goes first and may take this much; the main section keeps
# the rest, however long AgentCore's changes run.
AGENTCORE_NOTES_LIMIT = 40000


def fit_notes(section: str, version: str, limit: int = RELEASE_BODY_LIMIT, tail_for=None) -> str:
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
        tail = (tail_for or pointer)(version, len(lines) - k)
        if prefix[k] + release_cut.body_size(tail) <= limit:
            return "\n".join(lines[:k]).rstrip("\n") + "\n" + tail
    raise release_cut.CutError(f"the notes for {version} do not fit GitHub's {limit:,} even as a heading and a pointer")


def pointer(version: str, dropped: int) -> str:
    return (
        f"\n_The notes stop here: {dropped} more lines do not fit a GitHub release. The full section is in "
        f"`CHANGELOG.md` at tag `{version}`, and every archive below carries it as "
        f"`share/doc/CHANGELOG-{version}.md`._\n"
    )


def agentcore_notes(root: Path, main_version: str) -> str:
    """What this release includes of AgentCore, ahead of the main section."""
    ledger = agentcore_contract.load_ledger(root)
    entry = ledger.by_main_release(main_version)
    if entry is None:
        raise release_cut.CutError(f"{agentcore_contract.LEDGER} does not say which AgentCore release {main_version} carries")
    lines = [
        f"## AgentCore {entry.version}",
        "",
        f"This release includes AgentCore **{entry.version}**, binary ABI v{entry.abi_version} revision {entry.abi_revision}: "
        f"`metacodes` {agentcore_contract.python_version(entry.version)} on Python, `metacodes` {agentcore_contract.node_version(entry.version)} on Node, "
        f"and the `metask-agentcore-{entry.version}-*` archives for C, C++, Zig and Rust.",
        "",
    ]
    if entry.built_by != main_version:
        lines.append(
            f"AgentCore is unchanged since metacodes {entry.built_by}: it keeps its version and these are the same artifacts, byte for byte. "
            f"Its changes and migration steps are in the notes of metacodes {entry.built_by}. No migration is needed for this release."
        )
        return "\n".join(lines) + "\n\n"
    section = release_cut.release_section(
        release_cut.read(root, agentcore_contract.SDK_CHANGELOG), entry.version, agentcore_contract.SDK_CHANGELOG
    ).rstrip("\n").splitlines()[1:]
    if "### Migration" not in section:
        section += ["", "### Migration", "", "- No migration steps."]
    body = "\n".join(line if not line.startswith("### ") else "#" + line for line in section).strip("\n")
    block = "\n".join(lines) + "\n" + body + "\n\n"
    return fit_notes(block, entry.version, AGENTCORE_NOTES_LIMIT, sdk_pointer)


def sdk_pointer(version: str, dropped: int) -> str:
    return f"\n_{dropped} more lines of AgentCore's notes do not fit here. The full section is in `{agentcore_contract.SDK_CHANGELOG}` at this tag, under `## {version}`._\n\n"


def release_notes(root: Path, version: str) -> str:
    block = agentcore_notes(root, version)
    section = release_cut.release_section(release_cut.read(root, release_cut.CHANGELOG), version)
    return block + fit_notes(section, version, RELEASE_BODY_LIMIT - release_cut.body_size(block))


def main(argv: list) -> int:
    if len(argv) != 2 or not release_cut.TAG_RE.match(argv[1]):
        print("usage: release_notes.py X.Y.Z", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parents[1]
    try:
        sys.stdout.write(release_notes(root, argv[1]))
    except release_cut.CutError as exc:
        print(f"release_notes: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
