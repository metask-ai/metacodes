#!/usr/bin/env python3
"""The pieces of the release cut that both the main project and AgentCore use:
version arithmetic, Conventional-Commit levels, changelog rewriting and argv-only
subprocesses. Split out of release_cut.py so that agentcore_contract.py,
release_archive.py and agentcore_release.py can share them without importing
the entry point (`python3 scripts/release_cut.py` runs as `__main__`, and a
second copy of it would carry a second CutError). Python 3.9, stdlib only.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import List, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]
ZON = "build.zig.zon"
VERSION_ZIG = "src/version.zig"
CHANGELOG = "CHANGELOG.md"
PROTOCOL = "evals/plugin-v1/protocol.json"

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-dev)?$")
ZON_VERSION_RE = re.compile(r'(\.version\s*=\s*")([^"]+)(")')
ZIG_VERSION_RE = re.compile(r'(pub const semver = ")([^"]+)(";)')
TAG_RE = re.compile(r"^\d+\.\d+\.\d+$")
SUBJECT_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)(\([^)]*\))?(!)?:\s")
UNRELEASED = "## Unreleased"
RELEASE_HEADING_RE = re.compile(r"^## (\d+\.\d+\.\d+) — (\d{4}-\d{2}-\d{2})$")
SUBSECTIONS = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security")

LEVELS = ("none", "patch", "minor", "major")
MINOR_TYPES = {"feat"}
PATCH_TYPES = {"fix", "perf"}


class CutError(ValueError):
    """A refusal with a message for the maintainer; nothing was written."""


# ---------------------------------------------------------------- versions


def parse_version(text: str) -> Tuple[int, int, int, bool]:
    match = VERSION_RE.match(text.strip())
    if match is None:
        raise CutError(f"not a version this script understands: {text!r} (want X.Y.Z or X.Y.Z-dev)")
    return int(match.group(1)), int(match.group(2)), int(match.group(3)), text.strip().endswith("-dev")


def bump(version: Tuple[int, int, int], level: str, pre_1: bool = True) -> Tuple[int, int, int]:
    major, minor, patch = version
    if level == "major" and pre_1 and major == 0:
        level = "minor"  # SemVer 0.x: breaking changes bump MINOR before 1.0.0
    if level == "major":
        return major + 1, 0, 0
    if level == "minor":
        return major, minor + 1, 0
    if level == "patch":
        return major, minor, patch + 1
    raise CutError(f"cannot bump with level {level!r}")


def classify_subject(subject: str) -> Tuple[str, str]:
    """(type, level) for one commit subject. Unknown shapes are ('?', 'none')."""
    match = SUBJECT_RE.match(subject)
    if match is None:
        return "?", "none"
    kind = match.group(1).lower()
    if match.group(3) == "!":
        return kind, "major"
    if kind in MINOR_TYPES:
        return kind, "minor"
    if kind in PATCH_TYPES:
        return kind, "patch"
    return kind, "none"


def derive_level(messages: Sequence[str]) -> Tuple[str, List[str]]:
    """Level from commit messages (subject + body) and the subjects that did
    not parse or are not in the table, for the reviewer."""
    level = "none"
    unknown: List[str] = []
    for message in messages:
        subject = message.splitlines()[0] if message else ""
        kind, commit_level = classify_subject(subject)
        if "BREAKING CHANGE:" in message:
            commit_level = "major"
        if kind == "?":
            unknown.append(subject)
        if LEVELS.index(commit_level) > LEVELS.index(level):
            level = commit_level
    return level, unknown


def fmt(version: Tuple[int, int, int]) -> str:
    return "%d.%d.%d" % version


def set_version_text(text: str, pattern: re.Pattern, version: str, label: str) -> str:
    new, count = pattern.subn(lambda m: m.group(1) + version + m.group(3), text)
    if count != 1:
        raise CutError(f"{label}: expected exactly one version declaration, found {count}")
    return new


def rewrite_changelog(text: str, version: str, date: str, label: str = CHANGELOG, subsections: Sequence[str] = SUBSECTIONS) -> Tuple[str, str]:
    """Turn `## Unreleased` into `## <version> — <date>` and reinsert an empty
    Unreleased block. Returns (new text, the released section). Fails closed."""
    lines = text.splitlines()
    heads = [i for i, line in enumerate(lines) if line == UNRELEASED]
    if len(heads) != 1:
        raise CutError(f"{label}: expected exactly one '{UNRELEASED}' heading, found {len(heads)}")
    for line in lines:
        m = RELEASE_HEADING_RE.match(line)
        if m and m.group(1) == version:
            raise CutError(f"{label}: '## {version}' already exists")
    start = heads[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    block = lines[start + 1:end]
    for line in block:
        if line.startswith("### ") and line[4:] not in subsections:
            raise CutError(f"{label}: subsection '{line}' is not one of {', '.join(subsections)}")
    if not any(line.startswith("- ") for line in block):
        raise CutError(f"{label}: the '{UNRELEASED}' block has no '- ' entry; a release needs release notes")
    heading = f"## {version} — {date}"
    section = "\n".join([heading] + block).rstrip("\n") + "\n"
    new_lines = lines[:start] + [UNRELEASED, "", heading] + block + lines[end:]
    return "\n".join(new_lines).rstrip("\n") + "\n", section


def ensure_unreleased(text: str, label: str = CHANGELOG) -> str:
    """Reopen: make sure an (empty) `## Unreleased` block precedes the first release."""
    lines = text.splitlines()
    if UNRELEASED in lines:
        return text
    first = next((i for i, line in enumerate(lines) if RELEASE_HEADING_RE.match(line)), None)
    if first is None:
        raise CutError(f"{label}: no release heading to insert '{UNRELEASED}' before")
    new_lines = lines[:first] + [UNRELEASED, ""] + lines[first:]
    return "\n".join(new_lines).rstrip("\n") + "\n"


def release_section(text: str, version: str, label: str = CHANGELOG) -> str:
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if RELEASE_HEADING_RE.match(line) and RELEASE_HEADING_RE.match(line).group(1) == version), None)
    if start is None:
        raise CutError(f"{label}: no '## {version} — <date>' section")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[start:end]).rstrip("\n") + "\n"


# ---------------------------------------------------------------- files and commands


def run(argv: Sequence[str], cwd: Path, check: bool = True) -> str:
    # git and gh write UTF-8 whatever the locale, and PYTHONIOENCODING makes a
    # Python child do the same. `text=True` would decode with the locale codec
    # instead (GBK on a Chinese Windows), and there a decode error is raised in
    # subprocess's reader thread and only printed: stdout came back None.
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    proc = subprocess.run(list(argv), cwd=str(cwd), capture_output=True, check=False, env=env)
    if check and proc.returncode != 0:
        stderr, stdout = (out.decode("utf-8", errors="replace").strip() for out in (proc.stderr, proc.stdout))
        raise CutError(f"{' '.join(argv)} failed ({proc.returncode}): {stderr or stdout}")
    try:
        return proc.stdout.decode("utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as exc:
        raise CutError(f"{' '.join(argv)} wrote output that is not UTF-8: {exc}") from None


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text(encoding="utf-8")


def write(root: Path, rel: str, text: str) -> None:
    with open(root / rel, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
