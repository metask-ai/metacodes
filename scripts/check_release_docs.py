#!/usr/bin/env python3
"""Check release documents and an optional documents-only installation prefix.

The build and this checker share release/documents.json. Run
`zig build release:docs:check --prefix <empty-directory>` to exercise the
real release file-copy steps without compiling the product or Lean kernels.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath

SCHEMA = "metacodes.release-documents/v1"
MANIFEST = "release/documents.json"


def relative_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (not value or path.is_absolute() or path.as_posix() != value
            or ".." in path.parts or "\\" in value or ":" in value):
        raise ValueError(f"unsafe document path: {value!r}")
    return path


def regular_file(root: Path, relative: str) -> Path:
    path = root
    for part in relative_path(relative).parts:
        path /= part
        if path.is_symlink():
            raise ValueError(f"document path contains a symlink: {relative}")
    if not path.is_file():
        raise ValueError(f"document is not a regular file: {relative}")
    return path


def documents(root: Path) -> list[tuple[str, str]]:
    value = json.loads(regular_file(root, MANIFEST).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema") != SCHEMA:
        raise ValueError("unsupported release documents manifest")
    rows = value.get("files")
    if not isinstance(rows, list) or not rows:
        raise ValueError("release documents files must be a nonempty list")
    zon = regular_file(root, "build.zig.zon").read_text(encoding="utf-8")
    versions = re.findall(r'\.version\s*=\s*"([^"/\\]+)"', zon)
    if len(versions) != 1:
        raise ValueError("build.zig.zon must declare exactly one version")
    found = []
    destinations = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"source", "destination"}:
            raise ValueError("each release document needs source and destination")
        source, destination = row["source"], row["destination"]
        if not isinstance(source, str) or not isinstance(destination, str):
            raise ValueError("release document paths must be strings")
        relative_path(source)
        destination = destination.replace("{version}", versions[0])
        relative_path(destination)
        if "{" in destination or "}" in destination or not destination.startswith(("share/doc/", "share/licenses/")):
            raise ValueError(f"invalid release document destination: {destination}")
        if destination.casefold() in destinations:
            raise ValueError(f"duplicate release document destination: {destination}")
        destinations.add(destination.casefold())
        found.append((source, destination))
    return found


def check(root: Path, prefix: Path | None = None) -> list[str]:
    rows = documents(root)
    expected = set()
    findings = []
    for source, destination in rows:
        payload = regular_file(root, source).read_bytes()
        if not payload.strip():
            findings.append(f"empty release document: {source}")
        if prefix is not None:
            expected.add(destination)
            expected.update(str(parent) for parent in PurePosixPath(destination).parents if str(parent) != ".")
            try:
                installed = regular_file(prefix, destination).read_bytes()
                if installed != payload:
                    findings.append(f"installed document differs from {source}: {destination}")
            except ValueError as exc:
                findings.append(str(exc))
    if prefix is not None:
        if prefix.is_symlink() or not prefix.is_dir():
            findings.append("documents prefix must be a real directory")
        actual = {path.relative_to(prefix).as_posix() for path in prefix.rglob("*")}
        findings.extend(f"unexpected documents entry: {path}" for path in sorted(actual - expected))
        findings.extend(f"missing documents entry: {path}" for path in sorted(expected - actual))
    return findings


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--prefix", type=Path)
    args = parser.parse_args(argv)
    try:
        findings = check(args.root, args.prefix)
    except (OSError, ValueError) as exc:
        findings = [str(exc)]
    if findings:
        print("\n".join(findings), file=sys.stderr)
        return 1
    print("release documents ok" + (" (staged bytes verified)" if args.prefix else " (sources verified)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
