#!/usr/bin/env python3
"""Cut a release (stage A) or reopen development (stage D) as a pull request.

Design: doc/RELEASE_AUTOMATION_DESIGN.md. Run by a maintainer on an up-to-date
`main` checkout; the script never runs in CI on purpose (a PR opened with the
repository token gets no `pull_request` workflows).

Cut (`release_cut.py [--level auto|patch|minor|major] [--force-level]`):
  1. refuse unless build.zig.zon carries `-dev` (a release is mid-flight
     otherwise: reopen first) and the tree is clean;
  2. last tag = `git describe --tags --abbrev=0`; level = Conventional-Commit
     types of every non-merge commit since it (unknown types count nothing);
  3. version = max(bump(last tag), dev floor), strictly greater than the tag;
  4. rewrite build.zig.zon, src/version.zig and CHANGELOG.md (`## Unreleased`
     -> `## <version> — <date>`, empty `## Unreleased` reinserted), repin the
     implementation fingerprint last;
  5. commit on `release/<version>`, push `--force-with-lease`, `gh pr create`
     with title `release: <version>` and the `release` label.

Reopen (`release_cut.py --reopen [--reopen-level patch|minor]`): the mirror
image after the release PR merged and stage B tagged it.

Every external command is an argv list (no shell); the PR body goes through
`--body-file`. Python 3.9, stdlib only. Pure functions are tested in
scripts/tests/test_release_cut.py; the git/gh calls are thin and argv-only.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

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


class CutError(Exception):
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


def compute_version(last_tag: str, dev_version: str, level: str) -> str:
    """max(bump(last_tag), floor) and strictly greater than last_tag."""
    if not TAG_RE.match(last_tag):
        raise CutError(f"last tag is not a bare X.Y.Z: {last_tag!r}")
    tag = parse_version(last_tag)[:3]
    major, minor, patch, is_dev = parse_version(dev_version)
    if not is_dev:
        raise CutError(f"{ZON} carries {dev_version!r} without -dev: a release is mid-flight, reopen first")
    floor = (major, minor, patch)
    if level == "none":
        raise CutError("no feat/fix/perf commit since the last tag; pass --force-level patch|minor|major to release anyway")
    candidate = max(bump(tag, level), floor)
    if candidate <= tag:
        raise CutError(f"candidate {fmt(candidate)} is not greater than the last tag {last_tag}; reopen first")
    return fmt(candidate)


def fmt(version: Tuple[int, int, int]) -> str:
    return "%d.%d.%d" % version


def next_dev(version: str, level: str) -> str:
    if level not in ("patch", "minor"):
        raise CutError(f"--reopen-level must be patch or minor, not {level!r}")
    return fmt(bump(parse_version(version)[:3], level)) + "-dev"


# ---------------------------------------------------------------- files


def set_version_text(text: str, pattern: re.Pattern, version: str, label: str) -> str:
    new, count = pattern.subn(lambda m: m.group(1) + version + m.group(3), text)
    if count != 1:
        raise CutError(f"{label}: expected exactly one version declaration, found {count}")
    return new


def rewrite_changelog(text: str, version: str, date: str) -> Tuple[str, str]:
    """Turn `## Unreleased` into `## <version> — <date>` and reinsert an empty
    Unreleased block. Returns (new text, the released section). Fails closed."""
    lines = text.splitlines()
    heads = [i for i, line in enumerate(lines) if line == UNRELEASED]
    if len(heads) != 1:
        raise CutError(f"{CHANGELOG}: expected exactly one '{UNRELEASED}' heading, found {len(heads)}")
    for line in lines:
        m = RELEASE_HEADING_RE.match(line)
        if m and m.group(1) == version:
            raise CutError(f"{CHANGELOG}: '## {version}' already exists")
    start = heads[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    block = lines[start + 1:end]
    for line in block:
        if line.startswith("### ") and line[4:] not in SUBSECTIONS:
            raise CutError(f"{CHANGELOG}: subsection '{line}' is not one of {', '.join(SUBSECTIONS)}")
    if not any(line.startswith("- ") for line in block):
        raise CutError(f"{CHANGELOG}: the '{UNRELEASED}' block has no '- ' entry; a release needs release notes")
    heading = f"## {version} — {date}"
    section = "\n".join([heading] + block).rstrip("\n") + "\n"
    new_lines = lines[:start] + [UNRELEASED, "", heading] + block + lines[end:]
    return "\n".join(new_lines).rstrip("\n") + "\n", section


def ensure_unreleased(text: str) -> str:
    """Reopen: make sure an (empty) `## Unreleased` block precedes the first release."""
    lines = text.splitlines()
    if UNRELEASED in lines:
        return text
    first = next((i for i, line in enumerate(lines) if RELEASE_HEADING_RE.match(line)), None)
    if first is None:
        raise CutError(f"{CHANGELOG}: no release heading to insert '{UNRELEASED}' before")
    new_lines = lines[:first] + [UNRELEASED, ""] + lines[first:]
    return "\n".join(new_lines).rstrip("\n") + "\n"


def release_section(text: str, version: str) -> str:
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if RELEASE_HEADING_RE.match(line) and RELEASE_HEADING_RE.match(line).group(1) == version), None)
    if start is None:
        raise CutError(f"{CHANGELOG}: no '## {version} — <date>' section")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[start:end]).rstrip("\n") + "\n"


def pr_body(version: str, level: str, section: str, drivers: Dict[str, List[str]], unknown: List[str], squashed: Optional[List[str]] = None) -> str:
    parts = [section, "", "## Bump derivation", "", f"Level: **{level}**", ""]
    for kind in ("major", "minor", "patch"):
        subjects = drivers.get(kind) or []
        if subjects:
            parts.append(f"{kind}:")
            parts.extend(f"- {s}" for s in subjects)
            parts.append("")
    if unknown:
        parts.append("Commits whose subject does not follow `type(scope): text` (contributed nothing to the level; raise it by hand if one of them is a feature or a breaking change):")
        parts.extend(f"- {s}" for s in unknown)
        parts.append("")
    if squashed:
        parts.append("Squash/rebase-merged PRs (only the squash subject was classified; their inner commit types are not visible):")
        parts.extend(f"- {s}" for s in squashed)
        parts.append("")
    parts.append("Merging this PR is the decision to release; `release-tag.yml` tags the merge commit and starts `release.yml`. Then run `python3 scripts/release_cut.py --reopen`.")
    return "\n".join(parts).rstrip("\n") + "\n"


# ---------------------------------------------------------------- git / gh


def run(argv: Sequence[str], cwd: Path, check: bool = True) -> str:
    proc = subprocess.run(list(argv), cwd=str(cwd), capture_output=True, text=True, check=False)
    if check and proc.returncode != 0:
        raise CutError(f"{' '.join(argv)} failed ({proc.returncode}): {proc.stderr.strip() or proc.stdout.strip()}")
    return proc.stdout


def require_clean_main(root: Path) -> None:
    """Clean tree, on main, and main == freshly fetched origin/main: the cut
    must classify the commits that are actually on the remote, and the reopen
    must see the tag stage B created."""
    if run(["git", "status", "--porcelain", "--untracked-files=no"], root).strip():
        raise CutError("working tree has modifications; commit or stash them first")
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], root).strip()
    if branch != "main":
        raise CutError(f"run this on main (currently on {branch})")
    run(["git", "fetch", "--quiet", "--tags", "origin", "main"], root)
    head = run(["git", "rev-parse", "HEAD"], root).strip()
    remote = run(["git", "rev-parse", "origin/main"], root).strip()
    if head != remote:
        raise CutError(f"main ({head[:8]}) is not at origin/main ({remote[:8]}); pull --ff-only first")


def last_tag(root: Path) -> str:
    return run(["git", "describe", "--tags", "--abbrev=0", "--match", "[0-9]*.[0-9]*.[0-9]*"], root).strip()


def commit_messages_since(root: Path, tag: str) -> List[str]:
    out = run(["git", "log", f"{tag}..HEAD", "--no-merges", "--format=%s%n%b%x00"], root)
    return [m.strip() for m in out.split("\x00") if m.strip()]


def first_parent_is_conventional(root: Path, tag: str) -> List[str]:
    """Squash/rebase merges leave non-merge commits on the first-parent line;
    merge-commit merges leave only merges there. Returns those subjects. They
    are still counted by `commit_messages_since` (a squash subject carries the
    PR's type), so the cut only reports them: what is lost is the PR-internal
    commit types, which the reviewer can restore by hand via --level."""
    out = run(["git", "log", f"{tag}..HEAD", "--first-parent", "--format=%P%x1f%s"], root)
    offenders = []
    for line in out.splitlines():
        parents, _, subject = line.partition("\x1f")
        if len(parents.split()) < 2 and SUBJECT_RE.match(subject) and not subject.startswith("chore: reopen") and not subject.startswith("release:"):
            offenders.append(subject)
    return offenders


def repin_fingerprint(root: Path) -> None:
    run([sys.executable, "scripts/eval/plugin_release_gate.py", "--refresh-implementation-fingerprint"], root)


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text(encoding="utf-8")


def write(root: Path, rel: str, text: str) -> None:
    with open(root / rel, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def current_versions(root: Path) -> Tuple[str, str]:
    zon = ZON_VERSION_RE.search(read(root, ZON))
    zig = ZIG_VERSION_RE.search(read(root, VERSION_ZIG))
    if zon is None or zig is None:
        raise CutError("could not find the version declarations in build.zig.zon / src/version.zig")
    if zon.group(2) != zig.group(2):
        raise CutError(f"version mirror disagrees: {ZON}={zon.group(2)} {VERSION_ZIG}={zig.group(2)}")
    return zon.group(2), zig.group(2)


def apply_version(root: Path, version: str) -> None:
    write(root, ZON, set_version_text(read(root, ZON), ZON_VERSION_RE, version, ZON))
    write(root, VERSION_ZIG, set_version_text(read(root, VERSION_ZIG), ZIG_VERSION_RE, version, VERSION_ZIG))


def open_release_prs(root: Path) -> List[Tuple[int, str]]:
    """(number, head branch) of every open PR labelled `release`."""
    out = run(["gh", "pr", "list", "--state", "open", "--label", "release", "--json", "number,headRefName", "--jq", ".[] | \"\\(.number) \\(.headRefName)\""], root)
    prs = []
    for line in out.splitlines():
        number, _, head = line.partition(" ")
        if number.isdigit():
            prs.append((int(number), head))
    return prs


def branch_was_merged(root: Path, branch: str) -> bool:
    out = run(["gh", "pr", "list", "--state", "merged", "--head", branch, "--json", "number", "--jq", "length"], root).strip()
    return out.isdigit() and int(out) > 0


def open_pr(root: Path, branch: str, title: str, body: str, label: Optional[str], dry_run: bool) -> None:
    """Commit the generated files on `branch`, push, and create the PR — or
    update the body of the open PR that already has this head. Refuses when
    a different release PR is open (one cut in flight) or when this branch
    name already went through a merged PR (a version is released once)."""
    files = [ZON, VERSION_ZIG, CHANGELOG, PROTOCOL]
    existing = None
    if label == "release":
        for number, head in open_release_prs(root):
            if head == branch:
                existing = number
            else:
                raise CutError(f"release PR #{number} ({head}) is already open; finish or close it before cutting another version")
    if branch_was_merged(root, branch):
        raise CutError(f"branch {branch} already went through a merged PR; a version is released once")
    if dry_run:
        action = f"update PR #{existing}" if existing else f"open PR {title!r}"
        print(f"[dry-run] would commit {files} on {branch}, push --force-with-lease, and {action}")
        return
    run(["git", "checkout", "-B", branch], root)
    run(["git", "add", "--"] + files, root)
    run(["git", "commit", "-m", title], root)
    # Lease against the remote tip as just fetched (empty = must not exist),
    # not against whatever stale origin/<branch> the clone happened to hold.
    run(["git", "fetch", "--quiet", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}"], root, check=False)
    expected = run(["git", "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}"], root, check=False).strip()
    run(["git", "push", f"--force-with-lease=refs/heads/{branch}:{expected}", "-u", "origin", branch], root)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(body)
        body_path = handle.name
    if existing:
        run(["gh", "pr", "edit", str(existing), "--title", title, "--body-file", body_path], root)
        print(f"updated PR #{existing}")
    else:
        argv = ["gh", "pr", "create", "--base", "main", "--head", branch, "--title", title, "--body-file", body_path]
        if label:
            argv += ["--label", label]
        print(run(argv, root).strip())
    run(["git", "checkout", "main"], root)


# ---------------------------------------------------------------- commands


def cmd_cut(root: Path, level_arg: str, force: bool, dry_run: bool) -> int:
    require_clean_main(root)
    dev_version, _ = current_versions(root)
    tag = last_tag(root)
    squashed = first_parent_is_conventional(root, tag)
    messages = commit_messages_since(root, tag)
    derived, unknown = derive_level(messages)
    level = derived if level_arg == "auto" else level_arg
    if derived == "none" and level_arg == "auto" and not force:
        raise CutError("no feat/fix/perf commit since %s; pass --level patch|minor|major --force-level to release anyway" % tag)
    if level_arg != "auto" and not force and LEVELS.index(level_arg) < LEVELS.index(derived):
        raise CutError(f"--level {level_arg} is below the derived level {derived}; add --force-level to override")
    version = compute_version(tag, dev_version, level)
    drivers: Dict[str, List[str]] = {}
    for message in messages:
        subject = message.splitlines()[0]
        kind, commit_level = classify_subject(subject)
        if "BREAKING CHANGE:" in message:
            commit_level = "major"
        if commit_level != "none":
            drivers.setdefault(commit_level, []).append(subject)
    date = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d")
    new_changelog, section = rewrite_changelog(read(root, CHANGELOG), version, date)
    print(f"last tag {tag}, derived level {derived}, cutting {version}")
    if squashed:
        print(f"{len(squashed)} first-parent commit(s) are not merge commits (squash/rebase merges); their PR-internal commit types are not visible, only their subjects counted")
    if unknown:
        print(f"{len(unknown)} commit(s) with a non-conventional subject contributed nothing (listed in the PR body)")
    if dry_run:
        print(section)
        print(f"[dry-run] no files written")
        return 0
    apply_version(root, version)
    write(root, CHANGELOG, new_changelog)
    repin_fingerprint(root)
    open_pr(root, f"release/{version}", f"release: {version}", pr_body(version, level, section, drivers, unknown, squashed), "release", dry_run=False)
    print(f"after the PR merges and release-tag.yml has tagged {version}: python3 scripts/release_cut.py --reopen")
    return 0


def cmd_reopen(root: Path, reopen_level: str, dry_run: bool) -> int:
    require_clean_main(root)
    released, _ = current_versions(root)
    if released.endswith("-dev"):
        raise CutError(f"{ZON} already carries {released}; nothing to reopen")
    # The tag must exist on the remote (stage B creates it there) and point at
    # a commit main already contains: a local tag with the right name is not
    # evidence, and a remote tag elsewhere means a different release happened.
    remote = run(["git", "ls-remote", "--tags", "origin", f"{released}^{{}}", released], root)
    shas = [line.split()[0] for line in remote.splitlines() if line.strip()]
    if not shas:
        raise CutError(f"tag {released} does not exist on origin yet; let release-tag.yml tag the merge commit first")
    peeled = shas[0]
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", peeled, "HEAD"], cwd=str(root), capture_output=True)
    if ancestor.returncode != 0:
        raise CutError(f"tag {released} on origin points at {peeled[:8]}, which is not on this main")
    target = next_dev(released, reopen_level)
    print(f"reopening development at {target}")
    if dry_run:
        print("[dry-run] no files written")
        return 0
    apply_version(root, target)
    write(root, CHANGELOG, ensure_unreleased(read(root, CHANGELOG)))
    repin_fingerprint(root)
    body = f"Reopen development after {released}: version files to `{target}`, `{UNRELEASED}` restored, fingerprint repinned.\n"
    open_pr(root, f"chore/reopen-{target}", f"chore: reopen {target}", body, None, dry_run=False)
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--level", choices=("auto", "patch", "minor", "major"), default="auto")
    parser.add_argument("--force-level", action="store_true", help="release even without feat/fix/perf commits, or below the derived level")
    parser.add_argument("--reopen", action="store_true", help="stage D: bump to the next -dev after a release was tagged")
    parser.add_argument("--reopen-level", choices=("patch", "minor"), default="patch")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    try:
        if args.reopen:
            return cmd_reopen(root, args.reopen_level, args.dry_run)
        return cmd_cut(root, args.level, args.force_level, args.dry_run)
    except CutError as exc:
        print(f"release_cut: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
