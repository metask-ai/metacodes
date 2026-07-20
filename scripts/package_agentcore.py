#!/usr/bin/env python3
"""Create one immutable AgentCore SDK archive and its SHA-256 sidecar."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
import unittest
import zipfile


SAFE_COORDINATE = re.compile(r"^[0-9A-Za-z._+-]+$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_bundle(bundle_root: Path) -> tuple[dict, str, str]:
    if not bundle_root.is_dir():
        raise ValueError(f"bundle root is not a directory: {bundle_root}")
    manifest_path = bundle_root / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        schema_version = manifest["schema_version"]
        vendor = manifest["vendor"]
        name = manifest["name"]
        version = manifest["version"]
        target_id = manifest["target"]["id"]
        target_os = manifest["target"]["os"]
        files = manifest["files"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid AgentCore manifest: {error}") from error

    if schema_version != 1 or vendor != "metask" or name != "agentcore":
        raise ValueError("manifest is not metask AgentCore schema 1")

    for label, value in (("version", version), ("target.id", target_id)):
        if not isinstance(value, str) or not SAFE_COORDINATE.fullmatch(value):
            raise ValueError(f"manifest {label} is not archive-name safe")
    if target_os not in ("windows", "linux", "macos"):
        raise ValueError(f"unsupported AgentCore archive OS: {target_os}")
    if not isinstance(files, list):
        raise ValueError("manifest files must be an array")

    expected_paths = {"manifest.json"}
    for entry in files:
        try:
            relative_text = entry["path"]
            expected_hash = entry["sha256"]
        except (KeyError, TypeError) as error:
            raise ValueError("invalid manifest file entry") from error
        if not isinstance(relative_text, str) or not isinstance(expected_hash, str):
            raise ValueError("invalid manifest file entry")
        relative = PurePosixPath(relative_text)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or "\\" in relative_text
            or ":" in relative_text
            or relative_text != relative.as_posix()
        ):
            raise ValueError(f"unsafe manifest path: {relative_text}")
        payload = bundle_root.joinpath(*relative.parts)
        if payload.is_symlink() or not payload.is_file():
            raise ValueError(f"manifest payload is not a regular file: {relative_text}")
        if sha256_file(payload) != expected_hash:
            raise ValueError(f"manifest SHA-256 mismatch: {relative_text}")
        if relative_text in expected_paths:
            raise ValueError(f"duplicate manifest path: {relative_text}")
        expected_paths.add(relative_text)

    actual_paths: set[str] = set()
    for path in bundle_root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"bundle contains a symlink: {path}")
        if path.is_file():
            actual_paths.add(path.relative_to(bundle_root).as_posix())
    if actual_paths != expected_paths:
        missing = sorted(expected_paths - actual_paths)
        extra = sorted(actual_paths - expected_paths)
        raise ValueError(f"bundle tree mismatch: missing={missing}, extra={extra}")
    return manifest, target_os, f"metask-agentcore-{version}-{target_id}"


def write_archive(bundle_root: Path, output_dir: Path) -> tuple[Path, Path]:
    bundle_root = bundle_root.resolve()
    output_dir = output_dir.resolve()
    if output_dir == bundle_root or bundle_root in output_dir.parents:
        raise ValueError("archive output directory must not be inside the bundle root")
    _, target_os, coordinate = load_bundle(bundle_root)
    suffix = ".zip" if target_os == "windows" else ".tar.gz"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / f"{coordinate}{suffix}"
    checksum_path = output_dir / f"{archive_path.name}.sha256"
    if archive_path.exists() or checksum_path.exists():
        raise FileExistsError(f"AgentCore artifact coordinate already exists: {coordinate}")

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{coordinate}.", suffix=".tmp", dir=output_dir)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        if target_os == "windows":
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
                for path in sorted(bundle_root.rglob("*")):
                    if path.is_file():
                        relative = path.relative_to(bundle_root).as_posix()
                        archive.write(path, f"{coordinate}/{relative}")
        else:
            with tarfile.open(temporary, "w:gz", format=tarfile.PAX_FORMAT) as archive:
                archive.add(bundle_root, arcname=coordinate, recursive=True)

        digest = sha256_file(temporary)
        archive_created = False
        checksum_created = False
        try:
            with archive_path.open("xb") as destination, temporary.open("rb") as source:
                archive_created = True
                shutil.copyfileobj(source, destination, 1024 * 1024)
            with checksum_path.open("x", encoding="ascii", newline="\n") as checksum:
                checksum_created = True
                checksum.write(f"{digest}  {archive_path.name}\n")
        except BaseException:
            if archive_created:
                archive_path.unlink(missing_ok=True)
            if checksum_created:
                checksum_path.unlink(missing_ok=True)
            raise
    finally:
        temporary.unlink(missing_ok=True)
    return archive_path, checksum_path


def _fixture(root: Path, target_os: str, target_id: str) -> Path:
    bundle = root / "bundle"
    payload = bundle / "include" / "metask" / "agentcore.h"
    payload.parent.mkdir(parents=True)
    payload.write_text("/* test */\n", encoding="utf-8")
    manifest = {
        "schema_version": 1,
        "vendor": "metask",
        "name": "agentcore",
        "version": "0.1.0-dev+0123456789ab",
        "target": {"id": target_id, "os": target_os},
        "files": [{"path": "include/metask/agentcore.h", "sha256": sha256_file(payload)}],
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return bundle


class ArchiveTests(unittest.TestCase):
    def test_windows_zip_has_coordinate_root_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _fixture(root, "windows", "x86_64-windows-msvc")
            archive, checksum = write_archive(bundle, root / "out")
            self.assertEqual(archive.suffix, ".zip")
            with zipfile.ZipFile(archive) as opened:
                self.assertIn(
                    "metask-agentcore-0.1.0-dev+0123456789ab-x86_64-windows-msvc/manifest.json",
                    opened.namelist(),
                )
            self.assertTrue(checksum.read_text(encoding="ascii").startswith(sha256_file(archive)))
            original_archive = archive.read_bytes()
            original_checksum = checksum.read_bytes()
            with self.assertRaises(FileExistsError):
                write_archive(bundle, root / "out")
            self.assertEqual(archive.read_bytes(), original_archive)
            self.assertEqual(checksum.read_bytes(), original_checksum)

    def test_unix_tar_gz_has_coordinate_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _fixture(root, "macos", "aarch64-macos")
            archive, _ = write_archive(bundle, root / "out")
            self.assertTrue(archive.name.endswith(".tar.gz"))
            with tarfile.open(archive, "r:gz") as opened:
                self.assertIn(
                    "metask-agentcore-0.1.0-dev+0123456789ab-aarch64-macos/manifest.json",
                    opened.getnames(),
                )

    def test_rejects_payload_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _fixture(root, "linux", "x86_64-linux-gnu")
            (bundle / "include" / "metask" / "agentcore.h").write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                write_archive(bundle, root / "out")

    def test_rejects_output_inside_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _fixture(root, "windows", "x86_64-windows-msvc")
            with self.assertRaisesRegex(ValueError, "must not be inside"):
                write_archive(bundle, bundle / "archives")

    def test_rejects_wrong_component_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _fixture(root, "linux", "x86_64-linux-gnu")
            manifest_path = bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["vendor"] = "other"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not metask AgentCore"):
                write_archive(bundle, root / "out")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle_root", nargs="?", type=Path)
    parser.add_argument("output_dir", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveTests)
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
