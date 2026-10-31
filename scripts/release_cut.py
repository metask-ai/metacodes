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
     -> `## <version> — <date>`, empty `## Unreleased` reinserted), finalize
     AgentCore with its own version (agentcore_release.py: built when its inputs
     changed, reused when not; `--agentcore-level` to raise it), repin the
     implementation fingerprint last;
  5. commit on `release/<version>`, push `--force-with-lease`, `gh pr create`
     with title `release: <version>` and the `release` label.

Reopen (`release_cut.py --reopen [--reopen-level patch|minor]`): the mirror
image after the release PR merged and stage B tagged it, for AgentCore too.

Every external command is an argv list (no shell); the PR body goes through
`--body-file`. Python 3.9, stdlib only. Pure functions are tested in
scripts/tests/test_release_cut.py; the git/gh calls are thin and argv-only.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentcore_contract  # noqa: E402  (same directory, stdlib only)
import agentcore_release  # noqa: E402
from release_common import (  # noqa: E402,F401  (same directory, stdlib only; re-exported for the scripts and tests that use them from here)
    CHANGELOG,
    LEVELS,
    MINOR_TYPES,
    PATCH_TYPES,
    PROTOCOL,
    RELEASE_HEADING_RE,
    ROOT,
    SUBJECT_RE,
    SUBSECTIONS,
    TAG_RE,
    UNRELEASED,
    VERSION_RE,
    VERSION_ZIG,
    ZIG_VERSION_RE,
    ZON,
    ZON_VERSION_RE,
    CutError,
    bump,
    classify_subject,
    derive_level,
    ensure_unreleased,
    fmt,
    parse_version,
    read,
    release_section,
    rewrite_changelog,
    run,
    set_version_text,
    write,
)

# GitHub refuses a longer pull request body ("Body is too long (maximum is
# 65536 characters)"). Sizes are counted in UTF-8 bytes, which never undercount
# GitHub's character count, so a body that fits here fits there.
PR_BODY_LIMIT = 65536


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


def next_dev(version: str, level: str) -> str:
    if level not in ("patch", "minor"):
        raise CutError(f"--reopen-level must be patch or minor, not {level!r}")
    return fmt(bump(parse_version(version)[:3], level)) + "-dev"


# ---------------------------------------------------------------- files


def body_size(text: str) -> int:
    return len(text.encode("utf-8"))


def agentcore_summary(plan: agentcore_release.CutPlan) -> str:
    """The AgentCore half of the release PR, so a reviewer can dispute it too."""
    if plan.kind == "reused":
        what = f"AgentCore **{plan.version}** is reused: {plan.reason}, so this release delivers the artifacts of the main release that built it."
    else:
        what = f"AgentCore **{plan.version}** is built by this release ({plan.reason}; level {plan.level})."
    return f"{what} It implements ABI revision {plan.abi_revision}.\n\n"


def pr_body(version: str, level: str, section: str, drivers: Dict[str, List[str]], unknown: List[str], squashed: Optional[List[str]] = None, limit: int = PR_BODY_LIMIT) -> str:
    """The new changelog section, then the bump derivation. A body over
    GitHub's limit first shows a pointer instead of the section (it is in the
    PR's CHANGELOG.md diff and becomes the release notes); if that is still too
    long, each derivation list keeps its first entries and says how many it
    left out. The level line and the closing instruction always stay."""
    body = _pr_body(level, section, drivers, unknown, squashed, None)
    if body_size(body) <= limit:
        return body
    pointer = section_pointer(version, section)
    lo, hi = 0, max([len(v) for v in drivers.values()] + [len(unknown), len(squashed or [])])
    while lo < hi:  # the most entries per list that still fit
        mid = (lo + hi + 1) // 2
        if body_size(_pr_body(level, pointer, drivers, unknown, squashed, mid)) <= limit:
            lo = mid
        else:
            hi = mid - 1
    body = _pr_body(level, pointer, drivers, unknown, squashed, lo)
    if body_size(body) > limit:
        raise CutError(f"the PR body is {body_size(body):,} bytes even without the changelog section and the derivation lists, over GitHub's {limit:,}")
    return body


def section_pointer(version: str, section: str) -> str:
    """What the PR body shows instead of a changelog section too long for it."""
    lines = section.rstrip("\n").splitlines()
    heading = lines[0] if lines else f"## {version}"
    return (
        f"{heading}\n\n"
        f"This section is {len(lines)} lines ({body_size(section):,} bytes), more than a pull request body holds. "
        f"It is in this PR's `{CHANGELOG}` diff, and `release.yml` turns it into the release notes "
        f"(`scripts/release_notes.py {version}`).\n"
    )


def _pr_body(level: str, section: str, drivers: Dict[str, List[str]], unknown: List[str], squashed: Optional[List[str]], keep: Optional[int]) -> str:
    def listed(subjects: List[str]) -> List[str]:
        shown = subjects if keep is None else subjects[:keep]
        lines = [f"- {s}" for s in shown]
        if len(shown) < len(subjects):
            lines.append(f"- … and {len(subjects) - len(shown)} more")
        return lines

    parts = [section, "", "## Bump derivation", "", f"Level: **{level}**", ""]
    for kind in ("major", "minor", "patch"):
        subjects = drivers.get(kind) or []
        if subjects:
            parts.append(f"{kind}:")
            parts.extend(listed(subjects))
            parts.append("")
    if unknown:
        parts.append("Commits whose subject does not follow `type(scope): text` (contributed nothing to the level; raise it by hand if one of them is a feature or a breaking change):")
        parts.extend(listed(unknown))
        parts.append("")
    if squashed:
        parts.append("Squash/rebase-merged PRs (only the squash subject was classified; their inner commit types are not visible):")
        parts.extend(listed(squashed))
        parts.append("")
    parts.append("Merging this PR is the decision to release; `release-tag.yml` tags the merge commit and starts `release.yml`. Then run `python3 scripts/release_cut.py --reopen`.")
    return "\n".join(parts).rstrip("\n") + "\n"


# ---------------------------------------------------------------- git / gh


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


def agentcore_messages(root: Path, tag: str) -> List[str]:
    """Commits since `tag` that touched what AgentCore is built from."""
    out = run(["git", "log", f"{tag}..HEAD", "--no-merges", "--format=%s%n%b%x00", "--", *agentcore_release.input_paths(root)], root)
    return [m.strip() for m in out.split("\x00") if m.strip()]


def repin_fingerprint(root: Path) -> None:
    run([sys.executable, "scripts/eval/plugin_release_gate.py", "--refresh-implementation-fingerprint"], root)


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
    a different release PR is open (one cut in flight), when this branch
    name already went through a merged PR (a version is released once), or
    when the body is over GitHub's limit (before anything is pushed). Ends on
    `main` whether or not a step failed."""
    files = [ZON, VERSION_ZIG, CHANGELOG, PROTOCOL, *agentcore_contract.GENERATED]
    if body_size(body) > PR_BODY_LIMIT:
        raise CutError(f"the PR body is {body_size(body):,} bytes, over GitHub's {PR_BODY_LIMIT:,}; nothing was pushed")
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
    pushed = False
    try:
        run(["git", "add", "--"] + files, root)
        run(["git", "commit", "-m", title], root)
        # Lease against the remote tip as just fetched (empty = must not exist),
        # not against whatever stale origin/<branch> the clone happened to hold.
        run(["git", "fetch", "--quiet", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}"], root, check=False)
        expected = run(["git", "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}"], root, check=False).strip()
        run(["git", "push", f"--force-with-lease=refs/heads/{branch}:{expected}", "-u", "origin", branch], root)
        pushed = True
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
    except CutError as exc:
        if pushed:
            raise CutError(f"{exc}\n{branch} is already pushed; fix the cause and re-run the same command: it regenerates the branch, pushes it with a lease and opens or updates the PR") from None
        raise
    finally:
        run(["git", "checkout", "main"], root, check=False)


# ---------------------------------------------------------------- commands


def cmd_cut(root: Path, level_arg: str, force: bool, dry_run: bool, agentcore_level: str = "auto") -> int:
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
    plan = agentcore_release.plan_cut(root, agentcore_level, force, lambda since: agentcore_messages(root, since))
    summary = agentcore_summary(plan)
    body = summary + pr_body(version, level, section, drivers, unknown, squashed, PR_BODY_LIMIT - body_size(summary))
    print(f"last tag {tag}, derived level {derived}, cutting {version}")
    print(f"AgentCore: {plan.kind} {plan.version} ({plan.reason}), ABI revision {plan.abi_revision}")
    if squashed:
        print(f"{len(squashed)} first-parent commit(s) are not merge commits (squash/rebase merges); their PR-internal commit types are not visible, only their subjects counted")
    if unknown:
        print(f"{len(unknown)} commit(s) with a non-conventional subject contributed nothing (listed in the PR body)")
    if not body.startswith(summary + section):
        print(f"the changelog section ({body_size(section):,} bytes) is too long for a PR body; the PR points to its {CHANGELOG} diff instead")
    if dry_run:
        print(section)
        print("[dry-run] no files written")
        return 0
    apply_version(root, version)
    write(root, CHANGELOG, new_changelog)
    agentcore_release.apply_cut(root, plan.version, version, date)
    repin_fingerprint(root)
    open_pr(root, f"release/{version}", f"release: {version}", body, "release", dry_run=False)
    print(f"after the PR merges and release-tag.yml has tagged {version}: python3 scripts/release_cut.py --reopen")
    return 0


def cmd_reopen(root: Path, reopen_level: str, dry_run: bool, agentcore_reopen_level: str = "patch") -> int:
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
    agentcore_target = agentcore_release.reopen_target(root, agentcore_reopen_level)
    print(f"reopening development at {target}, AgentCore at {agentcore_target}")
    if dry_run:
        print("[dry-run] no files written")
        return 0
    apply_version(root, target)
    write(root, CHANGELOG, ensure_unreleased(read(root, CHANGELOG)))
    agentcore_release.apply_reopen(root, agentcore_target)
    repin_fingerprint(root)
    body = f"Reopen development after {released}: version files to `{target}`, AgentCore to `{agentcore_target}`, `{UNRELEASED}` restored, fingerprint repinned.\n"
    open_pr(root, f"chore/reopen-{target}", f"chore: reopen {target}", body, None, dry_run=False)
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--level", choices=("auto", "patch", "minor", "major"), default="auto")
    parser.add_argument("--force-level", action="store_true", help="release even without feat/fix/perf commits, or below the derived level")
    parser.add_argument("--reopen", action="store_true", help="stage D: bump to the next -dev after a release was tagged")
    parser.add_argument("--reopen-level", choices=("patch", "minor"), default="patch")
    parser.add_argument("--agentcore-level", choices=("auto", "patch", "minor", "major"), default="auto", help="raise AgentCore's derived level; refused when it is unchanged")
    parser.add_argument("--agentcore-reopen-level", choices=("patch", "minor"), default="patch")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    # Commit subjects and the changelog carry characters such as µ, ✓ and ↔
    # that GBK, the pipe encoding on a Chinese Windows, cannot encode; escape
    # them instead of failing.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    try:
        if args.reopen:
            return cmd_reopen(root, args.reopen_level, args.dry_run, args.agentcore_reopen_level)
        return cmd_cut(root, args.level, args.force_level, args.dry_run, args.agentcore_level)
    except (CutError, OSError) as exc:
        print(f"release_cut: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
