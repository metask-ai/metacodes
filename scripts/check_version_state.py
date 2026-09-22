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
`git rev-parse --abbrev-ref HEAD`. In CI the release-PR exception also needs
RELEASE_PR_TITLE == `release: <version>` and `release` in RELEASE_PR_LABELS
(ci.yml passes both from the event payload); the merge-subject exception is
honoured only on push runs. Tags: `actions/checkout` with `fetch-depth: 0`
fetches every branch and tag, so no fetch is needed here.

`--rehearse` (CI only): on a release PR head or on main's run of the release
merge commit, tag HEAD locally so `release:verify` / `release:archive` can run
the stable channel on the candidate before the real tag exists (design §3 C).
Python 3.9, stdlib only.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, Optional

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
    if rehearsable(root, version, head_ref):
        return ""
    return (
        f"build.zig.zon says {version} (no -dev) but HEAD is not tagged {version} and the head branch "
        f"({head_ref or 'unknown'}) is not release/{version}: a release is mid-flight; merge the reopen PR "
        f"(python3 scripts/release_cut.py --reopen) before merging anything else"
    )


def rehearsable(root: Path, version: str, head_ref: str, env: Optional[Dict[str, str]] = None) -> bool:
    """The two legitimate untagged bare-version states: the release PR itself
    and main's own run on its merge commit, which release-tag.yml is tagging
    concurrently. In CI the release PR is recognised by trusted event
    metadata, not by its branch name alone: ci.yml passes the PR title and
    labels (RELEASE_PR_TITLE / RELEASE_PR_LABELS) and the gate requires
    `release: <version>` plus the `release` label — the same facts
    release-tag.yml checks before tagging, so a branch merely named
    `release/<version>` cannot pass. Outside CI (no GITHUB_ACTIONS) the branch
    name is enough: that is the maintainer's own checkout."""
    env = os.environ if env is None else env
    if head_ref == f"release/{version}":
        if env.get("GITHUB_ACTIONS") != "true":
            return True
        labels = [l.strip() for l in env.get("RELEASE_PR_LABELS", "").split(",") if l.strip()]
        return env.get("RELEASE_PR_TITLE", "") == f"release: {version}" and "release" in labels
    if env.get("GITHUB_ACTIONS") == "true" and env.get("GITHUB_EVENT_NAME") not in ("push", None):
        return False  # only main's push run may rely on the merge subject
    subject = git("log", "-1", "--format=%s", "HEAD", root=root)
    return re.match(r"^Merge pull request #\d+ from \S+/release/" + re.escape(version) + r"$", subject) is not None


def rehearse(root: Path, head_ref: str) -> str:
    """`--rehearse`: in a rehearsable state, create the release tag *locally*
    (never pushed) so the existing release chain (`release:manifest` stable
    channel: clean tree + `git describe --exact-match`) can run on the
    candidate exactly as it will on the tag. Returns what was done."""
    match = ZON_VERSION_RE.search((root / "build.zig.zon").read_text(encoding="utf-8"))
    version = match.group(1) if match else ""
    if not version or version.endswith("-dev"):
        return "no rehearsal needed (development version)"
    if git("describe", "--tags", "--exact-match", "HEAD", root=root) == version:
        return f"HEAD already carries tag {version}"
    if not rehearsable(root, version, head_ref):
        return ""
    proc = subprocess.run(["git", "tag", version, "HEAD"], cwd=str(root), capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        return ""
    return f"rehearsal: tagged HEAD as {version} locally (not pushed)"


def main() -> int:
    head_ref = os.environ.get("GITHUB_HEAD_REF") or git("rev-parse", "--abbrev-ref", "HEAD", root=ROOT)
    finding = check(ROOT, head_ref)
    if finding:
        print(f"check_version_state: {finding}", file=sys.stderr)
        return 1
    if "--rehearse" in sys.argv[1:]:
        done = rehearse(ROOT, head_ref)
        if not done:
            print("check_version_state: cannot rehearse this state", file=sys.stderr)
            return 1
        print(done)
    print("version state ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
