#!/usr/bin/env python3
"""Build the manually reviewed TinyKG CLI/daemon bundle on macOS (Python >=3.9).

Normal Metacodes builds never invoke this maintainer tool. --dry-run validates
the source and toolchain, then prints commands and filesystem operations without
exporting sources, compiling, or changing the bundle.
"""

from __future__ import annotations

import argparse
from dataclasses import replace
import io
import json
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
from typing import Optional, Sequence

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts.stage_tinykg_binary import (
    BUNDLE_SCHEMA, COMMIT_RE, StageError, TinyKgBundle, TinyKgContract,
    _atomic_copy, _atomic_json, _atomic_text, inspect_binary, sha256_file,
    validate_bundle_bytes, validate_store_contract,
)
from scripts.verify_tinykg_binary import attest_native

TARGETS = (
    "aarch64-macos", "x86_64-macos", "x86_64-linux-musl",
    "aarch64-linux-musl", "x86_64-windows-gnu",
)
FAMILIES = (
    ("macos-universal", "mach-o-universal", ("aarch64", "x86_64"), ("aarch64-macos", "x86_64-macos")),
    ("linux-x86_64", "elf-static", ("x86_64",), ("x86_64-linux",)),
    ("linux-aarch64", "elf-static", ("aarch64",), ("aarch64-linux",)),
    ("windows-x86_64", "pe", ("x86_64",), ("x86_64-windows",)),
)
ROLES = (("cli", "tinykg"), ("daemon", "tinykgd"))
BUILD_TABLE_BEGIN = "// tinykg-bundle-table:begin"
BUILD_TABLE_END = "// tinykg-bundle-table:end"
SECRET_PATTERNS = (b"/Users/", b"/home/", b"C:\\Users", b"AKIA", b"BEGIN PRIVATE KEY")


class BundleError(RuntimeError):
    """A release precondition or generated artifact failed validation."""


def command(argv: Sequence[str], cwd: Optional[Path] = None) -> str:
    rendered = shlex.join(str(arg) for arg in argv)
    return f"(cd {shlex.quote(str(cwd))} && {rendered})" if cwd else rendered


def run(argv: Sequence[str], *, cwd: Optional[Path] = None, dry_run: bool = False) -> str:
    print("$ " + command(argv, cwd))
    if dry_run:
        return ""
    completed = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=False)
    if completed.returncode:
        raise BundleError(f"command failed ({completed.returncode}): {command(argv, cwd)}\n{completed.stdout}{completed.stderr}")
    return completed.stdout


def verify_source(source: Path, commit: str) -> None:
    if not COMMIT_RE.fullmatch(commit):
        raise BundleError("--commit must be 40 lowercase hexadecimal characters")
    def git(*args: str) -> str:
        return run(("git", "-C", str(source), *args)).strip()
    if git("rev-parse", "--is-inside-work-tree") != "true":
        raise BundleError("--source must be a git work tree")
    if git("rev-parse", "HEAD") != commit:
        raise BundleError("source HEAD does not equal --commit")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise BundleError("source has tracked modifications")


def scan(path: Path) -> None:
    # Raw bytes include every fat Mach-O slice and avoid strings(1) locale rules.
    data = path.read_bytes()
    for marker in SECRET_PATTERNS:
        for encoded in (marker, marker.decode("ascii").encode("utf-16-le")):
            if encoded in data:
                raise BundleError(f"personal or secret-shaped string {marker!r} found in {path.name}")


def render_build_table(artifacts: Sequence) -> str:
    """The build.zig literal, byte-identical to what `zig fmt` produces."""
    lines = ["const tinykg_bundle_table = [_]BundleTableEntry{"]
    for artifact in artifacts:
        rendered = ", ".join('"%s"' % target for target in artifact.targets)
        targets = '&.{%s}' % rendered if len(artifact.targets) == 1 else '&.{ %s }' % rendered
        lines.append(
            '    .{ .key = "%s", .role = "%s", .path = "vendor/tinykg/%s", .sha256 = "%s", .targets = %s },'
            % (artifact.key, artifact.role, artifact.path, artifact.sha256, targets)
        )
    lines.append("};")
    return "\n".join(lines)


def update_build_table(build_zig: Path, artifacts: Sequence) -> None:
    """Rewrite the digest table build.zig compares against the manifest.

    The table is what makes staging a two-file agreement; a bundle whose
    manifest moved while this table did not must fail the next stage rather
    than install silently.
    """
    text = build_zig.read_text(encoding="utf-8")
    if text.count(BUILD_TABLE_BEGIN) != 1 or text.count(BUILD_TABLE_END) != 1:
        raise BundleError("build.zig needs exactly one tinykg-bundle-table marker pair")
    start = text.index(BUILD_TABLE_BEGIN) + len(BUILD_TABLE_BEGIN)
    end = text.index(BUILD_TABLE_END)
    if end < start:
        raise BundleError("the tinykg-bundle-table markers are out of order")
    _atomic_text(build_zig, text[:start] + "\n" + render_build_table(artifacts) + "\n" + text[end:])


def release_root(commit: str) -> Path:
    return Path("/tmp") / f"metacodes-tinykg-release-src-{commit[:8]}"


def export_source(source: Path, commit: str, root: Path, dry_run: bool) -> None:
    print("$ " + command(("rm", "-rf", str(root))))
    print("$ " + command(("mkdir", "-p", str(root))))
    archive_command = ("git", "-C", str(source), "archive", "--format=tar", commit)
    print("$ " + command(archive_command) + " | " + command(("tar", "-xf", "-", "-C", str(root))))
    if dry_run:
        return
    if root.is_symlink():
        raise BundleError("fixed export root must not be a symlink")
    if root.exists():
        shutil.rmtree(root)
    root.mkdir()
    archived = subprocess.run(archive_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if archived.returncode:
        raise BundleError("git archive failed: " + archived.stderr.decode("utf-8", errors="replace"))
    with tarfile.open(fileobj=io.BytesIO(archived.stdout), mode="r:") as archive:
        # Python 3.9 predates tar extraction filters. Fail closed on links and
        # traversal rather than letting an archive escape the disposable root.
        for member in archive.getmembers():
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
                raise BundleError(f"unsafe source archive member: {member.name}")
        archive.extractall(root)


def build(args: argparse.Namespace) -> int:
    source = args.source.resolve()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", args.version):
        raise BundleError("--version must be a semantic version")
    verify_source(source, args.commit)
    if platform.system() != "Darwin" or platform.machine().lower() not in {"arm64", "aarch64", "x86_64"}:
        raise BundleError("bundle maintenance requires an arm64 or x86_64 macOS host")
    project = args.project_root.resolve()
    manifest_path = project / "vendor/tinykg/manifest.json"
    old_bundle = TinyKgBundle.load(manifest_path)
    deps_path = project / "deps/tinykg.json"
    contract = replace(TinyKgContract.load(deps_path), tinykg_version=args.version)
    zon = (source / "build.zig.zon").read_text(encoding="utf-8")
    for field, expected in (("version", args.version), ("minimum_zig_version", old_bundle.zig_version)):
        matched = re.search(r"\." + field + r'\s*=\s*"([^"]+)"', zon)
        if matched is None or matched.group(1) != expected:
            raise BundleError(f"source build.zig.zon {field} does not match {expected}")
    if run((args.zig, "version")).strip() != old_bundle.zig_version:
        raise BundleError("zig version does not match manifest build.zig_version")
    # Resolve a relative --zig before changing cwd to the exported source root.
    zig = shutil.which(args.zig)
    if zig is None:
        raise BundleError("cannot locate the requested Zig executable")
    zig = str(Path(zig).resolve())
    root = release_root(args.commit)
    export_source(source, args.commit, root, args.dry_run)
    candidate = root / ".bundle"
    built = {}
    for triple in TARGETS:
        prefix = root / ".install" / triple
        run((zig, "build", "-Doptimize=ReleaseSafe", "-Dstrip=true", f"-Dtarget={triple}", "--prefix", str(prefix)), cwd=root, dry_run=args.dry_run)
        for role, executable in ROLES:
            path = prefix / "bin" / (executable + (".exe" if "windows" in triple else ""))
            built[(triple, role)] = path
            if not args.dry_run:
                scan(path)
    if not args.dry_run:
        (candidate / "bin").mkdir(parents=True)
    artifacts = []
    for key, fmt, architectures, targets in FAMILIES:
        for role, executable in ROLES:
            destination = candidate / "bin" / f"{executable}-{key}{'.exe' if fmt == 'pe' else ''}"
            if fmt == "mach-o-universal":
                run(("lipo", "-create", str(built[("aarch64-macos", role)]), str(built[("x86_64-macos", role)]), "-output", str(destination)), dry_run=args.dry_run)
            else:
                triple = targets[0] + ("-gnu" if fmt == "pe" else "-musl")
                print("$ " + command(("cp", str(built[(triple, role)]), str(destination))))
                if not args.dry_run:
                    shutil.copy2(built[(triple, role)], destination)
            print(f"# scan {destination} for personal paths and secrets (all slices)")
            if not args.dry_run:
                scan(destination)
                artifacts.append({
                    "key": key if role == "cli" else key + "-daemon",
                    "role": role, "path": "bin/" + destination.name,
                    "format": fmt, "architectures": list(architectures),
                    "targets": list(targets), "sha256": sha256_file(destination),
                })
    native_arch = "aarch64" if platform.machine().lower() in {"arm64", "aarch64"} else "x86_64"
    native_cli = built[(native_arch + "-macos", "cli")]
    native_daemon = built[(native_arch + "-macos", "daemon")]
    if args.dry_run:
        print("$ " + command((str(native_cli), "version")))
        print("$ " + command((str(native_daemon), "--version")))
        print("# fresh temporary store: tinykg init <temp>/probe.kg; tinykg store-info <temp>/probe.kg")
        print("# require storage/schema " + contract.storage_format_version + "/" + contract.store_schema_version)
        print("# validate all eight formats/digests; write deterministic v2 manifest and version contract")
        print("# publish validated artifacts to vendor/tinykg/bin; attest native CLI and daemon")
        print("# regenerate the build.zig tinykg-bundle-table digests")
        return 0
    cli_identity = inspect_binary(native_cli, sha256_file(native_cli), contract)
    validate_store_contract(cli_identity, contract)
    inspect_binary(native_daemon, sha256_file(native_daemon), contract, "daemon")
    generated = {
        "bundle_schema": BUNDLE_SCHEMA, "source_commit": args.commit,
        "build": {"zig_version": old_bundle.zig_version, "optimize": "ReleaseSafe", "strip": True},
        "artifacts": artifacts,
    }
    candidate_manifest = candidate / "manifest.json"
    _atomic_json(candidate_manifest, generated)
    bundle = TinyKgBundle.load(candidate_manifest)
    for artifact in bundle.artifacts:
        validate_bundle_bytes(candidate / artifact.path, artifact, contract)
    attest_native(candidate_manifest, contract)
    # Nothing in the repository is replaced until the complete candidate passed.
    for artifact in bundle.artifacts:
        _atomic_copy(candidate / artifact.path, manifest_path.parent / artifact.path, artifact.sha256)
    _atomic_json(manifest_path, generated)
    deps = json.loads(deps_path.read_text(encoding="utf-8"))
    deps["tinykg_version"] = args.version
    _atomic_json(deps_path, deps)
    update_build_table(project / "build.zig", bundle.artifacts)
    attest_native(manifest_path, contract)
    for artifact in bundle.artifacts:
        print(f"{artifact.key} {artifact.role} {artifact.sha256}")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    args.project_root = PROJECT_ROOT
    try:
        return build(args)
    except (BundleError, StageError, OSError, subprocess.SubprocessError, tarfile.TarError) as exc:
        print(f"build-tinykg-bundle: error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
