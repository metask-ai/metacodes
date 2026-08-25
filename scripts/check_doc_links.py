#!/usr/bin/env python3
"""Fail-closed relative-link check for repository Markdown.

Walks every tracked-directory ``*.md`` file, resolves each relative markdown
link ``[text](target)`` against the file's directory, and exits nonzero when a
target does not exist. External URLs, ``mailto:``, and pure anchors are out of
scope. Links inside fenced code blocks are documentation examples, not
navigation, and are skipped.

Run from the repository root:  python3 scripts/check_doc_links.py
"""
from __future__ import annotations

import os
import re
import sys

SKIP_DIRS = {
    ".git",
    ".zig-cache",
    "zig-out",
    ".lake",
    ".claude",
    "node_modules",
}

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)#\s]+)(#[^)\s]*)?\)")
FENCE_RE = re.compile(r"^(```|~~~)")


def iter_markdown(root: str):
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            if name.endswith(".md"):
                yield os.path.join(dirpath, name)


def strip_fences(text: str) -> str:
    out = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line.strip()):
            in_fence = not in_fence
            continue
        if not in_fence:
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
            target = match.group(1)
            if re.match(r"^[a-z][a-z0-9+.-]*:", target):
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
