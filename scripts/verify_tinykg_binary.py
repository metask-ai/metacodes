#!/usr/bin/env python3
"""Fail closed unless the selected bundled or explicit TinyKG is attested."""

from __future__ import annotations

import os
from pathlib import Path
import platform
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts.stage_tinykg_binary import (
    StageError,
    TinyKgBundle,
    TinyKgContract,
    inspect_binary,
    validate_bundle_bytes,
    validate_store_contract,
)


def validate_bundle_inventory(manifest_path: Path, bundle: TinyKgBundle) -> None:
    """The bin directory must contain exactly the manifest-declared binaries.

    Per-binary SHA-256 attestation cannot see an EXTRA file dropped next to
    the attested ones; without this inventory an unlisted executable would
    ship in the tree while every gate stays green.
    """

    bin_dir = manifest_path.parent / "bin"
    declared: set[Path] = set()
    for artifact in bundle.artifacts:
        resolved = (manifest_path.parent / artifact.path).resolve()
        if resolved.parent != bin_dir.resolve():
            raise StageError(
                f"manifest artifact escapes the bundle bin directory: {artifact.path}"
            )
        declared.add(resolved)
    present: set[Path] = set()
    for entry in sorted(bin_dir.iterdir()):
        if entry.is_symlink() or not entry.is_file():
            raise StageError(
                f"bundle bin directory contains a non-regular entry: {entry.name}"
            )
        present.add(entry.resolve())
    extras = sorted(p.name for p in present - declared)
    missing = sorted(p.name for p in declared - present)
    if extras or missing:
        raise StageError(
            "bundle inventory drift: "
            f"undeclared={extras or 'none'} missing={missing or 'none'}"
        )


def native_bundle_key() -> str:
    machine = platform.machine().lower()
    arch = {
        "amd64": "x86_64",
        "arm64": "aarch64",
        "x86_64": "x86_64",
    }.get(machine)
    if arch is None:
        raise StageError(f"no bundled TinyKG for native architecture: {machine}")
    if sys.platform == "darwin" and arch in {"aarch64", "x86_64"}:
        return "macos-universal"
    if sys.platform.startswith("linux") and arch in {"aarch64", "x86_64"}:
        return f"linux-{arch}"
    if sys.platform == "win32" and arch == "x86_64":
        return "windows-x86_64"
    raise StageError(f"no bundled TinyKG for native platform: {sys.platform}/{arch}")


def main() -> int:
    path = os.environ.get("METACODES_TEST_TINYKG_BIN")
    sha256 = os.environ.get("METACODES_TEST_TINYKG_SHA256")
    if bool(path) != bool(sha256):
        print(
            "verify-tinykg: error: METACODES_TEST_TINYKG_BIN and "
            "METACODES_TEST_TINYKG_SHA256 must be set together",
            file=os.sys.stderr,
        )
        return 2
    try:
        contract = TinyKgContract.load(PROJECT_ROOT / "deps/tinykg.json")
        manifest_path = PROJECT_ROOT / "vendor/tinykg/manifest.json"
        bundle = TinyKgBundle.load(manifest_path)
        # Repository hygiene holds regardless of an explicit override: the
        # checked-in bundle directory may contain only attested binaries.
        validate_bundle_inventory(manifest_path, bundle)
        if path is not None and sha256 is not None:
            identity = inspect_binary(Path(path), sha256, contract)
            source = "explicit"
        else:
            artifact = bundle.artifact(native_bundle_key())
            binary = (manifest_path.parent / artifact.path).resolve()
            identity = validate_bundle_bytes(binary, artifact, contract)
            identity = inspect_binary(binary, artifact.sha256, contract)
            source = f"bundled:{artifact.key}"
        validate_store_contract(identity, contract)
    except (OSError, StageError) as exc:
        print(f"verify-tinykg: error: {exc}", file=os.sys.stderr)
        return 1
    print(
        f"TinyKG attested: {identity.version_line} sha256={identity.sha256} "
        f"source={source}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
