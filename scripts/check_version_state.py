#!/usr/bin/env python3
"""Gate: a version without `-dev` is legal only on the commit that carries its
tag, or on a `release/<version>` head (the release PR before it merges).

Closes the reopen window of doc/RELEASE_AUTOMATION_DESIGN.md stage D: between
the release PR merging and the reopen PR merging, `main` carries the bare
released version; any other change merged in that window would ship an
untagged bare version (`release:manifest` fails on it while `--version`
looks stable). Wired into `doc:check`, so `zig build gate:pr` and every PR's
CI run it. Between releases (`X.Y.Z-dev`) it is a no-op.

Head branch detection: `GITHUB_HEAD_REF` (pull_request events check out a
merge commit, so the branch name is only in the environment), else
`git rev-parse --abbrev-ref HEAD`. Python 3.9, stdlib only.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ZON_VERSION_RE = re.compile(r'\.version\s*=\s*"([^"]+)"')


def git(*argv: str, root: Path) -> str:
    proc = subprocess.run(["git", *argv], cwd=str(root), capture_output=True, text=True, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def check(root: Path, head_ref: str) -> str:
    """Empty string = ok, otherwise the finding."""
    text = (root / "build.zig.zon").read_text(encoding="utf-8")
    match = ZON_VERSION_RE.search(text)
    if match is None:
        return "build.zig.zon: no .version declaration"
    version = match.group(1)
    if version.endswith("-dev"):
        return ""
    if git("describe", "--tags", "--exact-match", "HEAD", root=root) == version:
        return ""
    if head_ref == f"release/{version}":
        return ""
    return (
        f"build.zig.zon says {version} (no -dev) but HEAD is not tagged {version} and the head branch "
        f"({head_ref or 'unknown'}) is not release/{version}: a release is mid-flight; merge the reopen PR "
        f"(python3 scripts/release_cut.py --reopen) before merging anything else"
    )


def main() -> int:
    head_ref = os.environ.get("GITHUB_HEAD_REF") or git("rev-parse", "--abbrev-ref", "HEAD", root=ROOT)
    finding = check(ROOT, head_ref)
    if finding:
        print(f"check_version_state: {finding}", file=sys.stderr)
        return 1
    print("version state ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
