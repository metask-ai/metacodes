#!/usr/bin/env python3
"""Fail closed unless the vendored QuickJS sources are attested.

Checks `vendor/quickjs/manifest.json`, the SHA-256 of every upstream file and
patch, the directory inventory (an undeclared file fails), that the patches
apply exactly, and that each patched file matches its pinned digest.

With `--archive PATH` it also proves provenance offline against a downloaded
copy of the official release archive: the archive's SHA-256 must equal the
manifest's, and every vendored upstream file must equal its archive member
byte for byte. Nothing is downloaded.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tarfile
from typing import List

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts.stage_quickjs_sources import (  # noqa: E402
    VENDOR_DIR,
    QuickJsSources,
    StageError,
    build_tree,
    read_pinned,
    sha256_bytes,
)


def verify_archive(vendor_dir: Path, sources: QuickJsSources, archive: Path) -> None:
    data = archive.read_bytes()
    actual = sha256_bytes(data)
    if actual != sources.archive_sha256:
        raise StageError(f"archive sha256 is {actual}, manifest pins {sources.archive_sha256}")
    with tarfile.open(archive, mode="r:*") as bundle:
        for item in sources.files:
            member_name = f"{sources.archive_root}/{item.path}"
            try:
                member = bundle.getmember(member_name)
            except KeyError as error:
                raise StageError(f"archive has no {member_name}") from error
            extracted = bundle.extractfile(member)
            if extracted is None:
                raise StageError(f"archive member {member_name} is not a regular file")
            if extracted.read() != read_pinned(vendor_dir, item):
                raise StageError(f"{item.path} differs from the archive's {member_name}")


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--archive", type=Path, help="downloaded official release archive to compare against")
    parser.add_argument("--vendor-dir", type=Path, default=VENDOR_DIR, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        sources = QuickJsSources.load(args.vendor_dir / "manifest.json")
        build_tree(args.vendor_dir, sources)
        if args.archive is not None:
            verify_archive(args.vendor_dir, sources, args.archive)
    except (StageError, OSError, tarfile.TarError) as error:
        print(f"verify_quickjs_sources: {error}", file=sys.stderr)
        return 1
    print(
        f"verify_quickjs_sources: ok release={sources.upstream_release} "
        f"files={len(sources.files)} patches={len(sources.patches)}"
        + (" archive=match" if args.archive is not None else "")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
