#!/usr/bin/env python3
"""Collect the `.sha256` sidecars of a release's archives into one
`metacodes-<version>-SHA256SUMS` (#81, #47 stage 6).

`release_archive.py` writes `<archive>.sha256` beside every archive; the
release job downloads every platform's archives into one directory and this
script joins the sidecars into the checksum file a user verifies with
`sha256sum -c` (`<hex>  <archive name>`, one per line, sorted by name). Each
sidecar is re-checked against its archive before it is trusted; a sidecar
without its archive, an archive without its sidecar, or a digest that no longer
matches fails the whole file, because a partial SHA256SUMS is worse than none.
Python 3.9, stdlib only; `--self-test` covers the shapes.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import tempfile
import unittest
from pathlib import Path

ARCHIVE_SUFFIXES = (".tar.gz", ".zip")
SIDECAR_LINE = re.compile(r"^([0-9a-f]{64})  (\S+)\n$")
SAFE_VERSION = re.compile(r"^[0-9A-Za-z._+-]+$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect(dist: Path) -> list[tuple[str, str]]:
    """(digest, archive name) for every archive under `dist`, verified against
    its sidecar; raises ValueError on any inconsistency."""
    if not dist.is_dir():
        raise ValueError(f"not a directory: {dist}")
    archives = sorted(p for p in dist.rglob("*") if p.is_file() and p.name.endswith(ARCHIVE_SUFFIXES))
    if not archives:
        raise ValueError(f"no archives under {dist}")
    sidecars = {p for p in dist.rglob("*.sha256") if p.is_file()}
    entries: list[tuple[str, str]] = []
    names: set[str] = set()
    for archive in archives:
        sidecar = archive.with_name(archive.name + ".sha256")
        if sidecar not in sidecars:
            raise ValueError(f"archive without a .sha256 sidecar: {archive.name}")
        sidecars.discard(sidecar)
        match = SIDECAR_LINE.match(sidecar.read_text(encoding="ascii"))
        if match is None or match.group(2) != archive.name:
            raise ValueError(f"malformed sidecar: {sidecar.name}")
        digest = match.group(1)
        if sha256_file(archive) != digest:
            raise ValueError(f"sidecar digest does not match the archive: {archive.name}")
        if archive.name in names:
            raise ValueError(f"two archives share a name: {archive.name}")
        names.add(archive.name)
        entries.append((digest, archive.name))
    if sidecars:
        stray = sorted(p.name for p in sidecars)
        raise ValueError(f"sidecar without an archive: {stray[0]}")
    return sorted(entries, key=lambda entry: entry[1])


def render(entries: list[tuple[str, str]]) -> str:
    return "".join(f"{digest}  {name}\n" for digest, name in entries)


def write_sums(dist: Path, version: str, output_dir: Path) -> Path:
    if not SAFE_VERSION.fullmatch(version):
        raise ValueError(f"version is not file-name safe: {version!r}")
    entries = collect(dist)
    output_dir.mkdir(parents=True, exist_ok=True)
    target = output_dir / f"metacodes-{version}-SHA256SUMS"
    if target.exists():
        raise FileExistsError(f"already exists: {target}")
    with target.open("x", encoding="ascii", newline="\n") as handle:
        handle.write(render(entries))
    return target


# ── self-test ─────────────────────────────────────────────────────────────────


def _archive(dist: Path, name: str, payload: bytes, sidecar_digest: str | None = None) -> None:
    dist.mkdir(parents=True, exist_ok=True)
    (dist / name).write_bytes(payload)
    digest = sidecar_digest or hashlib.sha256(payload).hexdigest()
    (dist / f"{name}.sha256").write_text(f"{digest}  {name}\n", encoding="ascii")


class SumsTests(unittest.TestCase):
    def test_joins_every_platform_sorted_and_verifiable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _archive(root / "dist" / "linux", "metacodes-0.2.0-x86_64-linux-gnu.tar.gz", b"linux")
            _archive(root / "dist" / "windows", "metacodes-0.2.0-x86_64-windows-gnu.zip", b"windows")
            _archive(root / "dist" / "sdk", "metask-agentcore-0.2.0-x86_64-linux-gnu.tar.gz", b"sdk")
            target = write_sums(root / "dist", "0.2.0", root / "out")
            self.assertEqual(target.name, "metacodes-0.2.0-SHA256SUMS")
            lines = target.read_text(encoding="ascii").splitlines()
            self.assertEqual([line.split("  ")[1] for line in lines], [
                "metacodes-0.2.0-x86_64-linux-gnu.tar.gz",
                "metacodes-0.2.0-x86_64-windows-gnu.zip",
                "metask-agentcore-0.2.0-x86_64-linux-gnu.tar.gz",
            ])
            self.assertEqual(lines[0].split("  ")[0], hashlib.sha256(b"linux").hexdigest())
            with self.assertRaises(FileExistsError):
                write_sums(root / "dist", "0.2.0", root / "out")

    def test_refuses_an_inconsistent_dist(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _archive(root / "a", "x.tar.gz", b"x", sidecar_digest="0" * 64)
            with self.assertRaisesRegex(ValueError, "does not match"):
                write_sums(root / "a", "0.2.0", root / "out")
            _archive(root / "b", "y.zip", b"y")
            (root / "b" / "y.zip").unlink()
            with self.assertRaisesRegex(ValueError, "no archives"):
                write_sums(root / "b", "0.2.0", root / "out")
            _archive(root / "c", "z.zip", b"z")
            (root / "c" / "orphan.tar.gz.sha256").write_text(f"{'a' * 64}  orphan.tar.gz\n", encoding="ascii")
            with self.assertRaisesRegex(ValueError, "sidecar without an archive"):
                write_sums(root / "c", "0.2.0", root / "out")
            (root / "d").mkdir()
            (root / "d" / "w.zip").write_bytes(b"w")
            with self.assertRaisesRegex(ValueError, "without a .sha256 sidecar"):
                write_sums(root / "d", "0.2.0", root / "out")
            with self.assertRaisesRegex(ValueError, "not file-name safe"):
                write_sums(root / "a", "0.2.0 beta", root / "out")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dist", nargs="?", type=Path, help="directory holding the archives and their .sha256 sidecars")
    parser.add_argument("version", nargs="?", help="release version; names the SHA256SUMS file")
    parser.add_argument("--output-dir", type=Path, default=None, help="where to write (default: dist)")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SumsTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.dist is None or args.version is None:
        parser.error("dist and version are required")
    try:
        target = write_sums(args.dist.resolve(), args.version, (args.output_dir or args.dist).resolve())
    except (FileExistsError, OSError, ValueError) as error:
        print(f"release sums: {error}", file=sys.stderr)
        return 1
    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
