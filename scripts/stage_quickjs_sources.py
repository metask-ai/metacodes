#!/usr/bin/env python3
"""Validate the vendored QuickJS sources and stage the patched build tree.

Metacodes never downloads QuickJS at build time. The repository keeps the
engine files of the official release archive under `vendor/quickjs/`, byte for
byte, pinned by SHA-256 in `vendor/quickjs/manifest.json`. Local changes live in
`vendor/quickjs/patches/*.patch` and are never committed into the upstream
files. This script verifies the pristine files, applies the patches in
manifest order with no fuzz and no offset, checks every patched file against
its pinned digest, and writes the result into an output directory that the
build compiles.

    python3 scripts/stage_quickjs_sources.py --out DIR
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
from typing import Dict, List, Tuple

PROJECT_ROOT = Path(__file__).resolve().parents[1]
VENDOR_DIR = PROJECT_ROOT / "vendor" / "quickjs"
BUNDLE_SCHEMA = "metacodes.quickjs-source/v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
#: Repository-owned files in the vendor directory besides the upstream files
#: and the patches.
LOCAL_FILES = ("README.md", "manifest.json")


class StageError(RuntimeError):
    """The vendored QuickJS sources do not satisfy their checked-in contract."""


@dataclass(frozen=True)
class PinnedFile:
    path: str
    sha256: str


@dataclass(frozen=True)
class QuickJsSources:
    upstream_release: str
    archive_url: str
    archive_sha256: str
    archive_root: str
    license: str
    files: Tuple[PinnedFile, ...]
    patches: Tuple[PinnedFile, ...]
    patched: Tuple[PinnedFile, ...]

    @staticmethod
    def load(manifest_path: Path) -> "QuickJsSources":
        try:
            value = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise StageError(f"cannot read {manifest_path.name}: {error}") from error
        if not isinstance(value, dict) or value.get("bundle_schema") != BUNDLE_SCHEMA:
            raise StageError(f"manifest schema must be {BUNDLE_SCHEMA}")
        archive = value.get("upstream_archive")
        if not isinstance(archive, dict):
            raise StageError("manifest lacks upstream_archive")
        for key in ("upstream_release", "license"):
            _require_string(value, key)
        for key in ("url", "sha256", "root"):
            _require_string(archive, key)
        _require_sha256(archive["sha256"], "upstream_archive")
        if not archive["url"].startswith("https://"):
            raise StageError("upstream_archive url must be https")
        files = _pinned_list(value, "files")
        patches = _pinned_list(value, "patches")
        patched = _pinned_list(value, "patched")
        names = {item.path for item in files}
        for item in patched:
            if item.path not in names:
                raise StageError(f"patched file {item.path} is not an upstream file")
        for item in patches:
            if PurePosixPath(item.path).parent != PurePosixPath("patches") or not item.path.endswith(".patch"):
                raise StageError(f"patch {item.path} must be patches/*.patch")
        for item in files:
            if "/" in item.path or item.path in LOCAL_FILES:
                raise StageError(f"upstream file {item.path} must be a top-level engine file")
        return QuickJsSources(
            upstream_release=value["upstream_release"],
            archive_url=archive["url"],
            archive_sha256=archive["sha256"],
            archive_root=archive["root"],
            license=value["license"],
            files=files,
            patches=patches,
            patched=patched,
        )


def _require_string(value: dict, key: str) -> None:
    if not isinstance(value.get(key), str) or not value[key]:
        raise StageError(f"manifest lacks a string {key!r}")


def _require_sha256(digest: object, where: str) -> None:
    if not isinstance(digest, str) or not SHA256_RE.match(digest):
        raise StageError(f"{where} has a malformed sha256")


def _pinned_list(value: dict, key: str) -> Tuple[PinnedFile, ...]:
    entries = value.get(key)
    if not isinstance(entries, list):
        raise StageError(f"manifest lacks a {key} list")
    result: List[PinnedFile] = []
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise StageError(f"{key} entry is not an object")
        _require_string(entry, "path")
        path = entry["path"]
        if path.startswith("/") or ".." in PurePosixPath(path).parts or "\\" in path:
            raise StageError(f"{key} path escapes the vendor directory: {path}")
        if path in seen:
            raise StageError(f"{key} lists {path} twice")
        seen.add(path)
        _require_sha256(entry.get("sha256"), f"{key} {path}")
        result.append(PinnedFile(path=path, sha256=entry["sha256"]))
    return tuple(result)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_pinned(vendor_dir: Path, item: PinnedFile) -> bytes:
    path = vendor_dir / item.path
    if path.is_symlink() or not path.is_file():
        raise StageError(f"{item.path} is missing or not a regular file")
    data = path.read_bytes()
    actual = sha256_bytes(data)
    if actual != item.sha256:
        raise StageError(f"{item.path} sha256 drift: expected {item.sha256}, got {actual}")
    return data


def validate_inventory(vendor_dir: Path, sources: QuickJsSources) -> None:
    """Every regular file in the vendor directory is declared, and only those."""
    declared = {item.path for item in sources.files + sources.patches}
    declared.update(LOCAL_FILES)
    present = set()
    for entry in vendor_dir.rglob("*"):
        relative = entry.relative_to(vendor_dir).as_posix()
        if entry.is_symlink():
            raise StageError(f"vendor directory contains a symlink: {relative}")
        if entry.is_dir():
            continue
        present.add(relative)
    extras = sorted(present - declared)
    missing = sorted(declared - present)
    if extras or missing:
        raise StageError(f"inventory drift: undeclared={extras or 'none'} missing={missing or 'none'}")


def parse_patch(text: str) -> List[Tuple[str, List[Tuple[int, List[str], List[str]]]]]:
    """Unified diff -> [(file, [(old_start, old_lines, new_lines)])].

    Text before the first `---` header is the patch description. Line endings
    are kept on each line so that applying is byte exact.
    """
    lines = text.splitlines(keepends=True)
    files: List[Tuple[str, List[Tuple[int, List[str], List[str]]]]] = []
    index = 0
    while index < len(lines) and not lines[index].startswith("--- "):
        index += 1
    if index == len(lines):
        raise StageError("patch has no file header")
    while index < len(lines):
        old_header = lines[index]
        if not old_header.startswith("--- ") or index + 1 >= len(lines) or not lines[index + 1].startswith("+++ "):
            raise StageError(f"malformed patch header at line {index + 1}")
        old_name = old_header[4:].split("\t")[0].strip()
        new_name = lines[index + 1][4:].split("\t")[0].strip()
        if not old_name.startswith("a/") or new_name != "b/" + old_name[2:]:
            raise StageError(f"patch must modify one file in place: {old_name} -> {new_name}")
        index += 2
        hunks: List[Tuple[int, List[str], List[str]]] = []
        while index < len(lines) and lines[index].startswith("@@ "):
            match = HUNK_RE.match(lines[index])
            if not match:
                raise StageError(f"malformed hunk header at line {index + 1}")
            old_start = int(match.group(1))
            old_count = int(match.group(2) or "1")
            new_count = int(match.group(4) or "1")
            index += 1
            old: List[str] = []
            new: List[str] = []
            while len(old) < old_count or len(new) < new_count:
                if index >= len(lines):
                    raise StageError("patch ends inside a hunk")
                line = lines[index]
                tag, body = line[:1], line[1:]
                if tag == " ":
                    old.append(body)
                    new.append(body)
                elif tag == "-":
                    old.append(body)
                elif tag == "+":
                    new.append(body)
                else:
                    raise StageError(f"unexpected patch line {index + 1}: {line!r}")
                index += 1
            if len(old) != old_count or len(new) != new_count:
                raise StageError(f"hunk line counts disagree with its header near line {index}")
            if index < len(lines) and lines[index].startswith("\\"):
                raise StageError("patches must not touch a file's final newline")
            hunks.append((old_start, old, new))
        if not hunks:
            raise StageError(f"patch for {old_name} has no hunks")
        files.append((old_name[2:], hunks))
    return files


def apply_hunks(name: str, data: bytes, hunks: List[Tuple[int, List[str], List[str]]]) -> bytes:
    """Apply hunks exactly where their headers say; any mismatch fails."""
    lines = data.decode("utf-8").splitlines(keepends=True)
    shift = 0
    last_end = 0
    for old_start, old, new in hunks:
        start = old_start - 1 + shift if old else old_start + shift
        if start < last_end:
            raise StageError(f"{name}: hunks overlap or are out of order")
        if lines[start:start + len(old)] != old:
            raise StageError(f"{name}: hunk at line {old_start} does not apply exactly")
        lines[start:start + len(old)] = new
        shift += len(new) - len(old)
        last_end = start + len(new)
    return "".join(lines).encode("utf-8")


def build_tree(vendor_dir: Path, sources: QuickJsSources) -> Dict[str, bytes]:
    """Verify everything and return {path: bytes} of the patched engine tree."""
    validate_inventory(vendor_dir, sources)
    tree = {item.path: read_pinned(vendor_dir, item) for item in sources.files}
    touched = set()
    for patch in sources.patches:
        text = read_pinned(vendor_dir, patch).decode("utf-8")
        for name, hunks in parse_patch(text):
            if name not in tree:
                raise StageError(f"{patch.path} modifies {name}, which is not a pinned upstream file")
            tree[name] = apply_hunks(name, tree[name], hunks)
            touched.add(name)
    expected = {item.path: item.sha256 for item in sources.patched}
    if touched != set(expected):
        raise StageError(
            f"patched set drift: patches touch {sorted(touched) or 'none'}, "
            f"manifest pins {sorted(expected) or 'none'}"
        )
    for name, digest in expected.items():
        actual = sha256_bytes(tree[name])
        if actual != digest:
            raise StageError(f"patched {name} sha256 drift: expected {digest}, got {actual}")
    return tree


def stage(vendor_dir: Path, out_dir: Path) -> QuickJsSources:
    sources = QuickJsSources.load(vendor_dir / "manifest.json")
    tree = build_tree(vendor_dir, sources)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    for name, data in sorted(tree.items()):
        (out_dir / name).write_bytes(data)
    return sources


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, type=Path, help="directory to write the patched engine tree into")
    parser.add_argument("--vendor-dir", type=Path, default=VENDOR_DIR, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        sources = stage(args.vendor_dir, args.out)
    except StageError as error:
        print(f"stage_quickjs_sources: {error}", file=sys.stderr)
        return 1
    print(f"stage_quickjs_sources: ok release={sources.upstream_release} patches={len(sources.patches)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
