#!/usr/bin/env python3
"""Create one immutable release archive and its SHA-256 sidecar (#81).

The archive core `package_agentcore.py` grew for the AgentCore SDK — sanitized
tar members, epoch-dated zip entries, the manifest whitelist as the only source
of members, a `.sha256` sidecar — serves both release units; `--kind` picks the
manifest identity:

  agentcore  `metask-agentcore-<version>-<target-id>` from the SDK bundle manifest
  cli        `metacodes-<version>-<target-id>`        from the CLI release manifest
             (release/manifest.schema.json)

Channels gate what may be archived (#47 Q1/Q3): a pre-release version
(`X.Y.Z-<pre>+<commit12>`) archives from any commit; a stable version requires a
clean source tree and a tag — for the CLI the bare `X.Y.Z` tag on HEAD, for the
SDK a tag named after the version pointing at `manifest.source.commit`. A
stable archive that fails the gate raises the same error the SDK packager
always raised, so nothing downstream learns a new message.

Two runs over the same bundle produce byte-identical archives: no timestamps,
owners or host names enter the members. Python 3.9, stdlib only; `--self-test`
covers both kinds, the gate, and reproducibility.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

SAFE_COORDINATE = re.compile(r"^[0-9A-Za-z._+-]+$")
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_COMPRESSION_LEVEL = 9
KINDS = ("agentcore", "cli")
STABLE_SDK_DISABLED = "stable AgentCore archives are disabled until the release process is established"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitized_tar_info(info: tarfile.TarInfo) -> tarfile.TarInfo:
    """Remove build-host identity and timestamps from a tar member."""
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


def write_zip_file(archive: zipfile.ZipFile, source: Path, archive_name: str) -> None:
    """Write a regular file without copying its host timestamp into the zip."""
    info = zipfile.ZipInfo(archive_name, date_time=ZIP_EPOCH)
    archive.writestr(
        info,
        source.read_bytes(),
        compress_type=zipfile.ZIP_DEFLATED,
        compresslevel=ZIP_COMPRESSION_LEVEL,
    )


@dataclass(frozen=True)
class GitFacts:
    """What the channel gate asks of the repository; tests build it directly."""

    head_tag: str | None
    tag_commits: dict[str, str] = field(default_factory=dict)


def collect_git_facts(repo_root: Path, tags: tuple[str, ...]) -> GitFacts:
    def git(*argv: str) -> str | None:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), *argv],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if completed.returncode != 0:
            return None
        return completed.stdout.strip() or None

    tag_commits = {}
    for tag in tags:
        commit = git("rev-list", "-n", "1", tag)
        if commit is not None:
            tag_commits[tag] = commit
    return GitFacts(head_tag=git("describe", "--tags", "--exact-match", "HEAD"), tag_commits=tag_commits)


@dataclass(frozen=True)
class Bundle:
    manifest: dict
    kind: str
    version: str
    channel: str
    target_os: str
    coordinate: str
    archive_paths: tuple[str, ...]


def load_bundle(bundle_root: Path, kind: str) -> Bundle:
    if kind not in KINDS:
        raise ValueError(f"unknown archive kind: {kind}")
    if not bundle_root.is_dir():
        raise ValueError(f"bundle root is not a directory: {bundle_root}")
    manifest_path = bundle_root / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("manifest.json is not a regular file")
    label = "AgentCore" if kind == "agentcore" else "metacodes CLI"
    expected_name = "agentcore" if kind == "agentcore" else "metacodes-cli"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        schema_version = manifest["schema_version"]
        vendor = manifest["vendor"]
        name = manifest["name"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid {kind} manifest: {error}") from error
    # Identity before shape: a manifest of the other unit is refused by name,
    # not by whichever field it happens to lack.
    if schema_version != 1 or vendor != "metask" or name != expected_name:
        raise ValueError(f"manifest is not metask {label} schema 1")
    try:
        target_id = manifest["target"]["id"]
        target_os = manifest["target"]["os"]
        files = manifest["files"]
        if kind == "agentcore":
            version = manifest["version"]
            channel = "pre" if "-" in version.partition("+")[0] else "stable"
            coordinate_prefix = "metask-agentcore"
        else:
            version = manifest["release"]["version"]
            channel = manifest["release"]["channel"]
            coordinate_prefix = "metacodes"
    except (KeyError, TypeError) as error:
        raise ValueError(f"invalid {kind} manifest: {error}") from error

    if channel not in ("stable", "pre"):
        raise ValueError(f"manifest channel is not stable or pre: {channel!r}")
    for field_name, value in (("version", version), ("target.id", target_id)):
        if not isinstance(value, str) or not SAFE_COORDINATE.fullmatch(value):
            raise ValueError(f"manifest {field_name} is not archive-name safe")
    if target_os not in ("windows", "linux", "macos"):
        raise ValueError(f"unsupported archive OS: {target_os}")
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
        payload = bundle_root
        for part in relative.parts:
            payload /= part
            if payload.is_symlink():
                raise ValueError(f"manifest payload traverses a symlink: {relative_text}")
        if not payload.is_file():
            raise ValueError(f"manifest payload is not a regular file: {relative_text}")
        if sha256_file(payload) != expected_hash:
            raise ValueError(f"manifest SHA-256 mismatch: {relative_text}")
        if relative_text in expected_paths:
            raise ValueError(f"duplicate manifest path: {relative_text}")
        expected_paths.add(relative_text)

    return Bundle(
        manifest=manifest,
        kind=kind,
        version=version,
        channel=channel,
        target_os=target_os,
        coordinate=f"{coordinate_prefix}-{version}-{target_id}",
        archive_paths=tuple(sorted(expected_paths)),
    )


def enforce_channel(bundle: Bundle, git_facts: GitFacts | None) -> None:
    """A pre-release archives from any commit; a stable one only from a clean,
    tagged tree. The SDK's historical refusal text is kept verbatim."""
    if bundle.channel == "pre":
        return
    source = bundle.manifest.get("source") or {}
    dirty = source.get("dirty")
    commit = source.get("commit")
    if bundle.kind == "agentcore":
        tag_commit = None if git_facts is None else git_facts.tag_commits.get(bundle.version)
        if dirty is not False or not isinstance(commit, str) or tag_commit != commit:
            raise ValueError(STABLE_SDK_DISABLED)
        return
    head_tag = None if git_facts is None else git_facts.head_tag
    if dirty is not False or head_tag != bundle.version:
        raise ValueError(
            f"stable metacodes archives require a clean source tree tagged {bundle.version} "
            f"(tree dirty={dirty!r}, HEAD tag={head_tag!r})"
        )


def write_archive(bundle_root: Path, output_dir: Path, kind: str, git_facts: GitFacts | None) -> tuple[Path, Path]:
    bundle_root = bundle_root.resolve()
    output_dir = output_dir.resolve()
    if output_dir == bundle_root or bundle_root in output_dir.parents:
        raise ValueError("archive output directory must not be inside the bundle root")
    bundle = load_bundle(bundle_root, kind)
    enforce_channel(bundle, git_facts)
    suffix = ".zip" if bundle.target_os == "windows" else ".tar.gz"
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / f"{bundle.coordinate}{suffix}"
    checksum_path = output_dir / f"{archive_path.name}.sha256"

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{bundle.coordinate}.", suffix=".tmp", dir=output_dir)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        if bundle.target_os == "windows":
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=ZIP_COMPRESSION_LEVEL) as archive:
                for relative in bundle.archive_paths:
                    path = bundle_root.joinpath(*PurePosixPath(relative).parts)
                    write_zip_file(archive, path, f"{bundle.coordinate}/{relative}")
        else:
            # A gzip header carries a file name and an mtime; `tarfile`'s "w:gz"
            # would write the temporary's name and the current time, and two
            # runs would differ. Fixed empty name, epoch mtime.
            with temporary.open("wb") as raw, gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=ZIP_COMPRESSION_LEVEL
            ) as compressed, tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for relative in bundle.archive_paths:
                    path = bundle_root.joinpath(*PurePosixPath(relative).parts)
                    archive.add(path, arcname=f"{bundle.coordinate}/{relative}", recursive=False, filter=sanitized_tar_info)

        digest = sha256_file(temporary)
        if archive_path.exists() or checksum_path.exists():
            # Immutable, not merely write-once: the build graph re-runs this
            # step (release:sums depends on it), so an existing archive is
            # accepted when it is byte-identical to what would be written now
            # — a reproducibility check for free — and never replaced.
            expected_sidecar = f"{digest}  {archive_path.name}\n"
            if (
                archive_path.is_file()
                and checksum_path.is_file()
                and sha256_file(archive_path) == digest
                and checksum_path.read_text(encoding="ascii") == expected_sidecar
            ):
                return archive_path, checksum_path
            raise FileExistsError(f"archive coordinate already exists with different bytes: {bundle.coordinate}")
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


# ── self-test ─────────────────────────────────────────────────────────────────

COMMIT = "0123456789abcdef0123456789abcdef01234567"


def _sdk_fixture(root: Path, target_os: str, target_id: str, version: str = "0.1.0-dev+0123456789ab") -> Path:
    bundle = root / "sdk-bundle"
    payload = bundle / "include" / "metask" / "agentcore.h"
    payload.parent.mkdir(parents=True)
    payload.write_text("/* test */\n", encoding="utf-8")
    manifest = {
        "schema_version": 1,
        "vendor": "metask",
        "name": "agentcore",
        "version": version,
        "source": {"commit": COMMIT, "dirty": False},
        "target": {"id": target_id, "os": target_os},
        "files": [{"path": "include/metask/agentcore.h", "sha256": sha256_file(payload)}],
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return bundle


def _cli_fixture(root: Path, target_os: str, target_id: str, version: str, channel: str, dirty: bool = False) -> Path:
    bundle = root / "cli-bundle"
    executable = bundle / "bin" / ("metacodes.exe" if target_os == "windows" else "metacodes")
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"metacodes")
    manifest = {
        "schema_version": 1,
        "vendor": "metask",
        "name": "metacodes-cli",
        "release": {"version": version, "channel": channel, "tag": version if channel == "stable" else None},
        "source": {"commit": COMMIT, "dirty": dirty},
        "target": {"id": target_id, "os": target_os},
        "files": [{"path": f"bin/{executable.name}", "sha256": sha256_file(executable)}],
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return bundle


class ArchiveTests(unittest.TestCase):
    def test_sdk_windows_zip_has_coordinate_root_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "windows", "x86_64-windows-msvc")
            stale = bundle / "sdk" / "old-agentcore.zig"
            stale.parent.mkdir()
            stale.write_text("// ignored local residue\n", encoding="utf-8")
            archive, checksum = write_archive(bundle, root / "out", "agentcore", None)
            self.assertEqual(archive.suffix, ".zip")
            with zipfile.ZipFile(archive) as opened:
                self.assertIn("metask-agentcore-0.1.0-dev+0123456789ab-x86_64-windows-msvc/manifest.json", opened.namelist())
                self.assertTrue(all(info.date_time == ZIP_EPOCH for info in opened.infolist()))
                self.assertFalse(any(name.endswith("sdk/old-agentcore.zig") for name in opened.namelist()))
            self.assertTrue(checksum.read_text(encoding="ascii").startswith(sha256_file(archive)))
            # Re-running over the unchanged bundle is a no-op that proves the
            # bytes reproduce; a changed bundle may not replace the archive.
            self.assertEqual(write_archive(bundle, root / "out", "agentcore", None), (archive, checksum))
            payload = bundle / "include" / "metask" / "agentcore.h"
            payload.write_text("/* changed */\n", encoding="utf-8")
            manifest_path = bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["files"][0]["sha256"] = sha256_file(payload)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(FileExistsError, "different bytes"):
                write_archive(bundle, root / "out", "agentcore", None)

    def test_cli_tar_gz_is_reproducible_and_named_after_the_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _cli_fixture(root, "linux", "x86_64-linux-gnu", "0.2.0-dev+0123456789ab", "pre")
            first, _ = write_archive(bundle, root / "one", "cli", None)
            second, _ = write_archive(bundle, root / "two", "cli", None)
            self.assertEqual(first.name, "metacodes-0.2.0-dev+0123456789ab-x86_64-linux-gnu.tar.gz")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as opened:
                self.assertIn("metacodes-0.2.0-dev+0123456789ab-x86_64-linux-gnu/bin/metacodes", opened.getnames())
                for member in opened.getmembers():
                    self.assertEqual((member.uid, member.gid, member.uname, member.gname, member.mtime), (0, 0, "", "", 0))

    def test_stable_cli_requires_clean_tree_and_head_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _cli_fixture(root, "macos", "aarch64-macos", "0.2.0", "stable")
            with self.assertRaisesRegex(ValueError, "require a clean source tree tagged 0.2.0"):
                write_archive(bundle, root / "out", "cli", GitFacts(head_tag=None))
            with self.assertRaisesRegex(ValueError, "tagged 0.2.0"):
                write_archive(bundle, root / "out", "cli", GitFacts(head_tag="0.1.0"))
            archive, _ = write_archive(bundle, root / "out", "cli", GitFacts(head_tag="0.2.0"))
            self.assertEqual(archive.name, "metacodes-0.2.0-aarch64-macos.tar.gz")
            dirty = _cli_fixture(root / "dirty", "macos", "aarch64-macos", "0.2.0", "stable", dirty=True)
            with self.assertRaisesRegex(ValueError, "dirty=True"):
                write_archive(dirty, root / "out-dirty", "cli", GitFacts(head_tag="0.2.0"))

    def test_stable_sdk_keeps_the_historical_refusal_unless_tagged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu", version="0.1.0")
            with self.assertRaisesRegex(ValueError, re.escape(STABLE_SDK_DISABLED)):
                write_archive(bundle, root / "out", "agentcore", None)
            with self.assertRaisesRegex(ValueError, re.escape(STABLE_SDK_DISABLED)):
                write_archive(bundle, root / "out", "agentcore", GitFacts(head_tag=None, tag_commits={"0.1.0": "f" * 40}))
            archive, _ = write_archive(bundle, root / "out", "agentcore", GitFacts(head_tag=None, tag_commits={"0.1.0": COMMIT}))
            self.assertEqual(archive.name, "metask-agentcore-0.1.0-x86_64-linux-gnu.tar.gz")

    def test_rejects_payload_hash_mismatch_and_wrong_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu")
            (bundle / "include" / "metask" / "agentcore.h").write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                write_archive(bundle, root / "out", "agentcore", None)
            cli = _cli_fixture(root, "linux", "x86_64-linux-gnu", "0.2.0-dev+0123456789ab", "pre")
            with self.assertRaisesRegex(ValueError, "not metask AgentCore"):
                write_archive(cli, root / "out", "agentcore", None)
            with self.assertRaisesRegex(ValueError, "must not be inside"):
                write_archive(cli, cli / "archives", "cli", None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bundle_root", nargs="?", type=Path)
    parser.add_argument("output_dir", nargs="?", type=Path)
    parser.add_argument("--kind", choices=KINDS, default="cli")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1], help="repository the channel gate asks git about")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.bundle_root is None or args.output_dir is None:
        parser.error("bundle_root and output_dir are required")
    try:
        bundle = load_bundle(args.bundle_root.resolve(), args.kind)
        git_facts = collect_git_facts(args.repo_root, (bundle.version,)) if bundle.channel == "stable" else None
        archive, checksum = write_archive(args.bundle_root.resolve(), args.output_dir.resolve(), args.kind, git_facts)
    except (FileExistsError, OSError, ValueError) as error:
        print(f"release archive: {error}", file=sys.stderr)
        return 1
    print(archive)
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
