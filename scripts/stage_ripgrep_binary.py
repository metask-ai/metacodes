#!/usr/bin/env python3
"""Validate and stage one manifest-pinned vendored ripgrep binary.

Metacodes never builds ripgrep from source and never downloads it at build
time. The repository owns manually reviewed upstream release binaries under
`vendor/ripgrep/bin/`, pinned by SHA-256 in `vendor/ripgrep/manifest.json`.
This script selects the artifact for an explicit target, re-verifies its hash
and binary format, and copies it into a destination directory under the
canonical runtime name (`rg` / `rg.exe`) — used by `zig build agentcore:bundle`
to ship the Glob/Grep execution dependency inside the AgentCore bundle.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import struct
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
BUNDLE_SCHEMA = "metacodes.ripgrep-bundle/v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ARTIFACT_FORMATS = {"mach-o", "elf-static", "pe"}
ARCHITECTURES = {"aarch64", "x86_64"}
TARGET_CONTRACTS = {
    "aarch64-macos": ("mach-o", "aarch64"),
    "x86_64-macos": ("mach-o", "x86_64"),
    "x86_64-linux": ("elf-static", "x86_64"),
    "aarch64-linux": ("elf-static", "aarch64"),
    "x86_64-windows": ("pe", "x86_64"),
    # Upstream publishes no aarch64-windows binary; Windows-on-ARM runs the
    # x86_64 executable through the OS's built-in x64 emulation. The vendor
    # manifest declares this mapping explicitly instead of leaving ARM64
    # Windows bundles without a working rg.
    "aarch64-windows": ("pe", "x86_64"),
}
MACHO_MAGIC_64 = 0xFEEDFACF
MACHO_CPUTYPES = {"aarch64": 0x0100000C, "x86_64": 0x01000007}
ELF_MACHINES = {"aarch64": 183, "x86_64": 62}
PE_MACHINES = {"aarch64": 0xAA64, "x86_64": 0x8664}


class StageError(RuntimeError):
    """The vendored ripgrep bundle cannot satisfy its checked-in contract."""


@dataclass(frozen=True)
class BundleArtifact:
    key: str
    path: str
    sha256: str
    binary_format: str
    architectures: tuple[str, ...]
    targets: tuple[str, ...]


@dataclass(frozen=True)
class RipgrepBundle:
    upstream_release: str
    upstream_revision: str
    source_repository: str
    license: str
    artifacts: tuple[BundleArtifact, ...]

    @classmethod
    def load(cls, path: Path) -> "RipgrepBundle":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise StageError(f"cannot read ripgrep bundle manifest: {exc}") from exc
        if not isinstance(raw, dict) or set(raw) != {
            "artifacts",
            "bundle_schema",
            "license",
            "source_repository",
            "upstream_release",
            "upstream_revision",
        }:
            raise StageError("ripgrep bundle manifest has missing or unknown fields")
        if raw["bundle_schema"] != BUNDLE_SCHEMA:
            raise StageError("unsupported ripgrep bundle schema")
        for field in ("upstream_release", "upstream_revision", "source_repository", "license"):
            if not isinstance(raw[field], str) or not raw[field]:
                raise StageError(f"ripgrep bundle {field} must be a non-empty string")
        if not isinstance(raw["artifacts"], list) or not raw["artifacts"]:
            raise StageError("ripgrep bundle artifacts must be a non-empty array")
        artifacts = tuple(_load_artifact(entry) for entry in raw["artifacts"])
        keys = [artifact.key for artifact in artifacts]
        if len(keys) != len(set(keys)):
            raise StageError("ripgrep bundle artifact keys must be unique")
        targets = [target for artifact in artifacts for target in artifact.targets]
        if len(targets) != len(set(targets)):
            raise StageError("ripgrep bundle artifact targets must be unique")
        return cls(
            upstream_release=raw["upstream_release"],
            upstream_revision=raw["upstream_revision"],
            source_repository=raw["source_repository"],
            license=raw["license"],
            artifacts=artifacts,
        )

    def artifact_for_target(self, target: str) -> BundleArtifact:
        if target not in TARGET_CONTRACTS:
            raise StageError(f"no ripgrep target contract for '{target}'")
        for artifact in self.artifacts:
            if target in artifact.targets:
                return artifact
        raise StageError(f"ripgrep bundle declares no artifact for target '{target}'")


def _load_artifact(entry: object) -> BundleArtifact:
    if not isinstance(entry, dict) or set(entry) != {
        "architectures",
        "format",
        "key",
        "path",
        "sha256",
        "targets",
    }:
        raise StageError("ripgrep bundle artifact has missing or unknown fields")
    if entry["format"] not in ARTIFACT_FORMATS:
        raise StageError(f"unsupported ripgrep artifact format: {entry['format']!r}")
    if not isinstance(entry["sha256"], str) or not SHA256_RE.fullmatch(entry["sha256"]):
        raise StageError("ripgrep artifact sha256 must be 64 lowercase hex characters")
    if not isinstance(entry["key"], str) or not entry["key"]:
        raise StageError("ripgrep artifact key must be a non-empty string")
    path = entry["path"]
    if not isinstance(path, str) or not path.startswith("bin/") or "/" in path[len("bin/") :] or "\\" in path or ".." in path:
        raise StageError("ripgrep artifact path must name a file directly under bin/")
    architectures = entry["architectures"]
    if (
        not isinstance(architectures, list)
        or not architectures
        or not set(architectures) <= ARCHITECTURES
    ):
        raise StageError("ripgrep artifact architectures are invalid")
    targets = entry["targets"]
    if not isinstance(targets, list) or not targets or not all(
        isinstance(target, str) and target in TARGET_CONTRACTS for target in targets
    ):
        raise StageError("ripgrep artifact targets are invalid")
    for target in targets:
        expected_format, expected_arch = TARGET_CONTRACTS[target]
        if entry["format"] != expected_format or expected_arch not in architectures:
            raise StageError(f"ripgrep artifact does not satisfy target contract '{target}'")
    return BundleArtifact(
        key=entry["key"],
        path=path,
        sha256=entry["sha256"],
        binary_format=entry["format"],
        architectures=tuple(architectures),
        targets=tuple(targets),
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_artifact_bytes(bundle_dir: Path, artifact: BundleArtifact) -> Path:
    """Fail closed unless the checked-in file matches its pinned identity."""

    path = bundle_dir / artifact.path
    if path.is_symlink() or not path.is_file():
        raise StageError(f"ripgrep artifact is not a regular file: {artifact.path}")
    observed = sha256_file(path)
    if observed != artifact.sha256:
        raise StageError(
            f"ripgrep artifact hash mismatch for {artifact.path}: "
            f"manifest={artifact.sha256} observed={observed}"
        )
    header = path.read_bytes()[:64]
    _validate_format(artifact, header)
    return path


def _validate_format(artifact: BundleArtifact, header: bytes) -> None:
    if artifact.binary_format == "mach-o":
        if len(header) < 8 or struct.unpack("<I", header[:4])[0] != MACHO_MAGIC_64:
            raise StageError(f"{artifact.path} is not a 64-bit Mach-O binary")
        cputype = struct.unpack("<I", header[4:8])[0]
        expected = {MACHO_CPUTYPES[arch] for arch in artifact.architectures}
        if cputype not in expected:
            raise StageError(f"{artifact.path} Mach-O cputype does not match its manifest architectures")
    elif artifact.binary_format == "elf-static":
        if len(header) < 20 or header[:4] != b"\x7fELF":
            raise StageError(f"{artifact.path} is not an ELF binary")
        machine = struct.unpack("<H", header[18:20])[0]
        expected = {ELF_MACHINES[arch] for arch in artifact.architectures}
        if machine not in expected:
            raise StageError(f"{artifact.path} ELF machine does not match its manifest architectures")
    elif artifact.binary_format == "pe":
        if len(header) < 2 or header[:2] != b"MZ":
            raise StageError(f"{artifact.path} is not a PE binary")
    else:  # pragma: no cover - formats are closed at parse time
        raise StageError(f"unsupported ripgrep artifact format: {artifact.binary_format}")


def stage(
    architecture: str,
    target_os: str,
    dest_dir: Path,
    bundle_dir: Path = PROJECT_ROOT / "vendor" / "ripgrep",
) -> Path:
    target = f"{architecture}-{target_os}"
    bundle = RipgrepBundle.load(bundle_dir / "manifest.json")
    artifact = bundle.artifact_for_target(target)
    source = validate_artifact_bytes(bundle_dir, artifact)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / ("rg.exe" if target_os == "windows" else "rg")
    shutil.copyfile(source, dest)
    dest.chmod(
        stat.S_IRUSR
        | stat.S_IWUSR
        | stat.S_IXUSR
        | stat.S_IRGRP
        | stat.S_IXGRP
        | stat.S_IROTH
        | stat.S_IXOTH
    )
    staged = sha256_file(dest)
    if staged != artifact.sha256:
        raise StageError(f"staged ripgrep copy hash drifted: {staged}")
    print(f"staged ripgrep {bundle.upstream_release} {artifact.key} sha256={staged} -> {dest}")
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("architecture", choices=sorted(ARCHITECTURES))
    parser.add_argument("os", choices=sorted({t.split("-", 1)[1] for t in TARGET_CONTRACTS}))
    parser.add_argument("dest_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        stage(args.architecture, args.os, args.dest_dir)
    except StageError as error:
        print(f"stage_ripgrep_binary: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
