#!/usr/bin/env python3
"""Create one immutable AgentCore SDK archive and its SHA-256 sidecar.

Since #81 the archive core lives in `scripts/release_archive.py`, shared with
the CLI release unit; this entry point keeps the SDK's command line
(`package_agentcore.py <bundle_root> <output_dir>` and `--self-test`) and its
identity (`--kind agentcore`). A stable SDK version still refuses to archive
unless a tag named after the version points at the manifest's source commit —
the same refusal text as before.
"""
from __future__ import annotations

import argparse
import sys
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts import release_archive  # noqa: E402

# Kept as names for the callers and tests that imported them from here.
SAFE_COORDINATE = release_archive.SAFE_COORDINATE
ZIP_EPOCH = release_archive.ZIP_EPOCH
ZIP_COMPRESSION_LEVEL = release_archive.ZIP_COMPRESSION_LEVEL
sha256_file = release_archive.sha256_file
sanitized_tar_info = release_archive.sanitized_tar_info
write_zip_file = release_archive.write_zip_file


def load_bundle(bundle_root: Path) -> tuple[dict, str, str, tuple[str, ...]]:
    bundle = release_archive.load_bundle(bundle_root, "agentcore")
    return bundle.manifest, bundle.target_os, bundle.coordinate, bundle.archive_paths


def write_archive(bundle_root: Path, output_dir: Path) -> tuple[Path, Path]:
    bundle = release_archive.load_bundle(bundle_root.resolve(), "agentcore")
    git_facts = release_archive.collect_git_facts(PROJECT_ROOT, (bundle.version,)) if bundle.channel == "stable" else None
    return release_archive.write_archive(bundle_root, output_dir, "agentcore", git_facts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle_root", nargs="?", type=Path)
    parser.add_argument("output_dir", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(release_archive.ArchiveTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.bundle_root is None or args.output_dir is None:
        parser.error("bundle_root and output_dir are required")
    try:
        archive, checksum = write_archive(args.bundle_root.resolve(), args.output_dir.resolve())
    except (FileExistsError, OSError, ValueError) as error:
        print(f"AgentCore archive: {error}", file=sys.stderr)
        return 1
    print(archive)
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
