#!/usr/bin/env python3
"""Safely materialize a sparse, immutable Git snapshot for one scored E2E task."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tarfile
from pathlib import Path, PurePosixPath


MAX_FILES = 2_048
MAX_TOTAL_BYTES = 64 * 1024 * 1024


def _safe_relative(value: str, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError(f"{label} must be a safe repository-relative path")
    components = value.split("/")
    path = PurePosixPath(value)
    if (
        any(component in {"", ".", ".."} for component in components)
        or path.is_absolute()
        or path.as_posix() != value
    ):
        raise ValueError(f"{label} must be a safe repository-relative path")
    return path


def _safe_prefix(value: str) -> PurePosixPath:
    if value == ".":
        return PurePosixPath(".")
    return _safe_relative(value, "repository_snapshot prefix")


def materialize(repo_root: Path, workspace: Path, snapshot: dict) -> None:
    if set(snapshot) != {"revision", "prefix", "paths"}:
        raise ValueError("repository_snapshot must contain exactly revision, prefix, and paths")
    revision = snapshot["revision"]
    if not isinstance(revision, str) or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("repository_snapshot revision must be a full lowercase commit id")
    prefix = _safe_prefix(snapshot["prefix"])
    paths = snapshot["paths"]
    if not isinstance(paths, list) or not paths or len(paths) > 64:
        raise ValueError("repository_snapshot paths must contain 1-64 entries")
    archive_paths = []
    for item in paths:
        relative = _safe_relative(item, "repository_snapshot path")
        archive_paths.append(str(relative if prefix == PurePosixPath(".") else prefix / relative))

    git_root = Path(
        subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--show-toplevel"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
        ).stdout.strip()
    ).resolve()
    verified = subprocess.run(
        ["git", "-C", str(git_root), "rev-parse", "--verify", f"{revision}^{{commit}}"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=20,
    ).stdout.strip()
    if verified != revision:
        raise ValueError(f"repository_snapshot revision resolved to unexpected commit {verified}")

    workspace.mkdir(parents=True, exist_ok=True)
    if any(workspace.iterdir()):
        raise ValueError("repository snapshot workspace must be empty before materialization")
    process = subprocess.Popen(
        ["git", "-C", str(git_root), "archive", "--format=tar", revision, "--", *archive_paths],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    file_count = 0
    total_bytes = 0
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for member in archive:
                source = PurePosixPath(member.name)
                try:
                    relative = source.relative_to(prefix)
                except ValueError as exc:
                    # `git archive` emits a directory entry for every ancestor
                    # of a deep pathspec (`tests/`, `tests/e2e/`, ...). Those
                    # carry no bytes and sit above the prefix by construction;
                    # only a *file* or an unrelated directory outside the
                    # prefix is an escape.
                    if member.isdir() and (source == prefix or source in prefix.parents):
                        continue
                    raise ValueError(f"archive member escaped snapshot prefix: {member.name}") from exc
                if not relative.parts or ".." in relative.parts:
                    continue
                target = workspace.joinpath(*relative.parts)
                resolved_parent = target.parent.resolve()
                resolved_parent.relative_to(workspace.resolve())
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise ValueError(f"snapshot archive contains non-regular member: {member.name}")
                file_count += 1
                total_bytes += member.size
                if file_count > MAX_FILES or total_bytes > MAX_TOTAL_BYTES:
                    raise ValueError("repository snapshot exceeds file or byte limit")
                target.parent.mkdir(parents=True, exist_ok=True)
                source_file = archive.extractfile(member)
                if source_file is None:
                    raise ValueError(f"cannot read archive member: {member.name}")
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                fd = os.open(target, flags, 0o755 if member.mode & 0o111 else 0o644)
                try:
                    remaining = member.size
                    while remaining:
                        chunk = source_file.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise ValueError(f"short archive member: {member.name}")
                        offset = 0
                        while offset < len(chunk):
                            written = os.write(fd, chunk[offset:])
                            if written <= 0:
                                raise OSError("short snapshot write")
                            offset += written
                        remaining -= len(chunk)
                finally:
                    os.close(fd)
    finally:
        process.stdout.close()
    stderr = process.stderr.read() if process.stderr is not None else b""
    if process.stderr is not None:
        process.stderr.close()
    returncode = process.wait(timeout=20)
    if returncode != 0:
        raise RuntimeError(
            f"git archive exited {returncode}: {stderr.decode('utf-8', 'replace')[-1000:]}"
        )
    if file_count == 0:
        raise ValueError("repository snapshot produced no regular files")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--workspace", required=True)
    args = parser.parse_args()
    suite = json.loads(Path(args.suite).read_text(encoding="utf-8"))
    task = next((item for item in suite.get("tasks", []) if item.get("id") == args.task), None)
    if task is None:
        return 0
    snapshot = task.get("environment", {}).get("repository_snapshot")
    if snapshot is None:
        return 0
    materialize(Path(args.repo_root).resolve(), Path(args.workspace).resolve(), snapshot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
