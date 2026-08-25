#!/usr/bin/env python3
"""Fail-closed relative-link check for repository Markdown.

Iterates every git-tracked ``*.md`` file, resolves each relative markdown
link ``[text](target)`` against the file's directory, and exits nonzero when a
target does not exist. External URLs, ``mailto:``, and pure anchors are out of
scope. Links inside fenced code blocks are documentation examples, not
navigation, and are skipped. ``vendor/`` mirrors third-party trees whose
relative links are upstream's contract, not ours, and is skipped.

Run from the repository root:  python3 scripts/check_doc_links.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys

# Third-party trees: their Markdown follows upstream, so upstream-relative
# links are not ours to enforce.
SKIP_TOP_DIRS = {"vendor"}

LINK_RE = re.compile(
    r"\[[^\]]*\]\("  # [text](
    r"\s*"
    r"(?:<(?P<angle>[^<>\n]*)>"  # <destination, may contain spaces>
    r"|(?P<plain>[^()\s]+))"  # bare destination
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^()]*\)))?"  # optional link title
    r"\s*\)"
)
FENCE_RE = re.compile(r"^(`{3,}|~{3,})(.*)$")
SCHEME_RE = re.compile(r"^[a-z][a-z0-9+.-]*:")


def iter_markdown(root: str):
    listed = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "--", "*.md"],
        check=True,
        capture_output=True,
    ).stdout
    for rel in listed.decode("utf-8", "replace").split("\0"):
        if not rel or rel.split("/", 1)[0] in SKIP_TOP_DIRS:
            continue
        path = os.path.join(root, rel)
        if os.path.exists(path):  # tracked but locally deleted
            yield path


def strip_fences(text: str) -> str:
    out = []
    open_char = ""
    open_len = 0
    for line in text.splitlines():
        match = FENCE_RE.match(line.strip())
        if match:
            marker, rest = match.group(1), match.group(2)
            if not open_char:
                # A backtick fence's info string may not contain backticks;
                # such a line is an inline code span, not a fence.
                if not (marker[0] == "`" and "`" in rest):
                    open_char, open_len = marker[0], len(marker)
                    continue
            elif (
                marker[0] == open_char
                and len(marker) >= open_len
                and not rest.strip()
            ):
                open_char, open_len = "", 0
                continue
        if not open_char:
            out.append(line)
    # Inline code spans are examples, not navigation.
    return re.sub(r"`[^`\n]*`", "``", "\n".join(out))


def main() -> int:
    root = os.getcwd()
    broken: list[str] = []
    for path in iter_markdown(root):
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = strip_fences(handle.read())
        base = os.path.dirname(path)
        for match in LINK_RE.finditer(text):
            target = match.group("angle")
            if target is None:
                target = match.group("plain")
            target = target.partition("#")[0]
            if not target:
                continue  # pure anchor
            if SCHEME_RE.match(target):
                continue  # http(s)/mailto/other schemes
            resolved = os.path.normpath(os.path.join(base, target))
            if not os.path.exists(resolved):
                broken.append(f"{os.path.relpath(path, root)} -> {target}")
    if broken:
        print("broken relative markdown links:", file=sys.stderr)
        for entry in sorted(broken):
            print(f"  {entry}", file=sys.stderr)
        return 1
    print("doc links ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
