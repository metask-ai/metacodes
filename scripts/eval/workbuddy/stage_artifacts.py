"""Stage a reproducible WorkBuddy split-mount build context.

The command refuses to mutate an existing stage.  Production candidates must
be Linux ELF executables; standard-library tests may opt into synthetic fixture
executables, which are permanently labelled ``quality_evidence=false``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
from pathlib import Path
from typing import Dict, Iterable, Tuple

from . import WORKBUDDY_PINNED_COMMIT


SCHEMA_VERSION = "metacodes-workbuddy-split-mount-v1"


class StageError(ValueError):
    pass


def _canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _copy_regular(source: Path, target: Path, mode: int) -> Dict[str, object]:
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(source, flags)
    except OSError as exc:
        raise StageError(f"cannot open artifact source {source}: {exc}") from exc
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise StageError(f"artifact source is not a regular file: {source}")
        if info.st_size <= 0:
            raise StageError(f"artifact source is empty: {source}")
    except Exception:
        os.close(descriptor)
        raise
    with os.fdopen(descriptor, "rb") as reader, target.open("xb") as writer:
        shutil.copyfileobj(reader, writer, length=1024 * 1024)
        writer.flush()
        os.fsync(writer.fileno())
        after = os.fstat(reader.fileno())
        if (
            after.st_size != info.st_size
            or after.st_mtime_ns != info.st_mtime_ns
            or after.st_ctime_ns != info.st_ctime_ns
        ):
            raise StageError(f"artifact source changed while staging: {source}")
    os.chmod(target, mode)
    return {
        "bytes": info.st_size,
        "sha256": _sha256(target),
        "mode": format(mode, "04o"),
    }


def _is_elf(path: Path) -> bool:
    with path.open("rb") as handle:
        return handle.read(4) == b"\x7fELF"


def stage(
    *,
    output: Path,
    metacodes: Path,
    tinykg: Path,
    formal_kernel: Path,
    metacodes_commit: str,
    tinykg_commit: str,
    licenses: Iterable[Tuple[str, str, Path]],
    allow_synthetic_fixtures: bool = False,
) -> Dict[str, object]:
    if output.exists():
        raise StageError(f"refusing to overwrite existing stage: {output}")
    if not all(
        re.fullmatch(r"[0-9a-f]{40}", commit)
        for commit in (metacodes_commit, tinykg_commit)
    ):
        raise StageError("source commits must be lowercase 40-hex git object ids")
    binaries = {
        "metacodes": metacodes.resolve(),
        "tinykg": tinykg.resolve(),
        "metacodes-formal-kernel": formal_kernel.resolve(),
    }
    license_rows = list(licenses)
    if len(license_rows) != 3 or {row[0] for row in license_rows} != {
        "metacodes",
        "tinykg",
        "lean4",
    }:
        raise StageError("licenses must bind exactly metacodes, tinykg, and lean4")
    if any(not spdx.strip() for _, spdx, _ in license_rows):
        raise StageError("every license requires an explicit SPDX expression or NOASSERTION")

    output.mkdir(parents=True, mode=0o755)
    executable_targets = {
        "metacodes": output / "bin/metacodes",
        "tinykg": output / "bin/tinykg",
        "metacodes-formal-kernel": output / "libexec/metacodes-formal-kernel",
    }
    executable_meta = {
        name: _copy_regular(source, executable_targets[name], 0o755)
        for name, source in binaries.items()
    }
    if not allow_synthetic_fixtures:
        for label, target in executable_targets.items():
            if not _is_elf(target):
                raise StageError(f"production {label} is not a Linux ELF artifact")

    license_meta: Dict[str, object] = {}
    for component, spdx, source in sorted(license_rows):
        target = output / f"share/licenses/{component}/LICENSE"
        copied = _copy_regular(source.resolve(), target, 0o644)
        copied.update({"spdx": spdx, "path": target.relative_to(output).as_posix()})
        license_meta[component] = copied

    manifest = {
        "schema_version": SCHEMA_VERSION,
        "quality_evidence": False,
        "synthetic_fixture": bool(allow_synthetic_fixtures),
        "target": "linux-container" if not allow_synthetic_fixtures else "test-fixture",
        "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
        "sources": {
            "metacodes_commit": metacodes_commit,
            "tinykg_commit": tinykg_commit,
        },
        "executables": executable_meta,
        "licenses": license_meta,
        "runtime_contract": {
            "provider": "local-proxy-only",
            "credential_delivery": "anonymous-fd-route-token",
            "tinykg": "fresh-local-store-only",
            "formal_kernel": "path-and-sha256-pinned",
        },
    }
    manifest_path = output / "share/metacodes/artifact-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with manifest_path.open("xb") as handle:
        handle.write(_canonical_json(manifest))
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(manifest_path, 0o644)

    hashed_paths = [
        *executable_targets.values(),
        manifest_path,
        *(output / str(row["path"]) for row in license_meta.values()),
    ]
    checksums = "".join(
        f"{_sha256(path)}  {path.relative_to(output).as_posix()}\n"
        for path in sorted(hashed_paths, key=lambda item: item.relative_to(output).as_posix())
    )
    sums_path = output / "share/metacodes/SHA256SUMS"
    with sums_path.open("x", encoding="ascii", newline="\n") as handle:
        handle.write(checksums)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(sums_path, 0o644)
    directory_fd = os.open(output, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metacodes", type=Path, required=True)
    parser.add_argument("--tinykg", type=Path, required=True)
    parser.add_argument("--formal-kernel", type=Path, required=True)
    parser.add_argument("--metacodes-commit", required=True)
    parser.add_argument("--tinykg-commit", required=True)
    parser.add_argument("--metacodes-license", type=Path, required=True)
    parser.add_argument("--metacodes-license-spdx", required=True)
    parser.add_argument("--tinykg-license", type=Path, required=True)
    parser.add_argument("--tinykg-license-spdx", default="Apache-2.0")
    parser.add_argument("--lean-license", type=Path, required=True)
    parser.add_argument("--lean-license-spdx", default="Apache-2.0")
    parser.add_argument("--allow-synthetic-fixtures", action="store_true")
    args = parser.parse_args(argv)
    try:
        stage(
            output=args.output,
            metacodes=args.metacodes,
            tinykg=args.tinykg,
            formal_kernel=args.formal_kernel,
            metacodes_commit=args.metacodes_commit,
            tinykg_commit=args.tinykg_commit,
            licenses=(
                ("metacodes", args.metacodes_license_spdx, args.metacodes_license),
                ("tinykg", args.tinykg_license_spdx, args.tinykg_license),
                ("lean4", args.lean_license_spdx, args.lean_license),
            ),
            allow_synthetic_fixtures=args.allow_synthetic_fixtures,
        )
    except (OSError, StageError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
