#!/usr/bin/env python3
"""Fail closed unless every vendored ripgrep binary is attested.

Validates `vendor/ripgrep/manifest.json` and each pinned binary (SHA-256 and
binary-format magic), and inventories `vendor/ripgrep/bin/`: an executable not
declared by the manifest fails the gate (per-binary hash attestation cannot
see an extra file dropped next to the attested ones).
"""

from __future__ import annotations

from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts.stage_ripgrep_binary import (
    StageError,
    RipgrepBundle,
    TARGET_CONTRACTS,
    validate_artifact_bytes,
)


def validate_bundle_inventory(bundle_dir: Path, bundle: RipgrepBundle) -> None:
    bin_dir = bundle_dir / "bin"
    declared: set[Path] = set()
    for artifact in bundle.artifacts:
        resolved = (bundle_dir / artifact.path).resolve()
        if resolved.parent != bin_dir.resolve():
            raise StageError(f"manifest artifact escapes the bundle bin directory: {artifact.path}")
        declared.add(resolved)
    present: set[Path] = set()
    for entry in sorted(bin_dir.iterdir()):
        if entry.is_symlink() or not entry.is_file():
            raise StageError(f"bundle bin directory contains a non-regular entry: {entry.name}")
        present.add(entry.resolve())
    extras = sorted(p.name for p in present - declared)
    missing = sorted(p.name for p in declared - present)
    if extras or missing:
        raise StageError(
            "bundle inventory drift: " f"undeclared={extras or 'none'} missing={missing or 'none'}"
        )


def main() -> int:
    bundle_dir = PROJECT_ROOT / "vendor" / "ripgrep"
    try:
        bundle = RipgrepBundle.load(bundle_dir / "manifest.json")
        for artifact in bundle.artifacts:
            validate_artifact_bytes(bundle_dir, artifact)
        validate_bundle_inventory(bundle_dir, bundle)
        for required in ("LICENSE-MIT", "README.md"):
            candidate = bundle_dir / required
            if candidate.is_symlink() or not candidate.is_file():
                raise StageError(f"vendored ripgrep is missing {required}")
        covered = {target for artifact in bundle.artifacts for target in artifact.targets}
        uncovered = sorted(set(TARGET_CONTRACTS) - covered)
        if uncovered:
            print(f"verify_ripgrep_binary: note: no artifact for targets {uncovered}")
    except StageError as error:
        print(f"verify_ripgrep_binary: {error}", file=sys.stderr)
        return 1
    print(
        f"verify_ripgrep_binary: ok release={bundle.upstream_release} "
        f"artifacts={len(bundle.artifacts)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
