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
from ..model import fsync_directory, open_nofollow



SCHEMA_VERSION = "metacodes-workbuddy-split-mount-v1"
TARGET_PLATFORM = "linux/amd64"
ELF_MACHINE_X86_64 = 62
PROJECT_RULES_TARGET = Path("share/metacodes/workbuddy-w05/project-rules")
PROJECT_KERNEL_TARGET = Path("libexec/metacodes-project-kernel")
PROJECT_ROOT = "/workspace"
MAX_PROJECT_RULE_FILES = 256
MAX_PROJECT_RULE_BYTES = 64 * 1024 * 1024


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
    flags = os.O_RDONLY
    try:
        descriptor = open_nofollow(source, flags)
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


def _project_identity(project_root: str = PROJECT_ROOT) -> str:
    return hashlib.sha256(
        b"metacodes-project-identity-v1\x00" + project_root.encode("utf-8")
    ).hexdigest()


def _copy_project_rules(source: Path, output: Path) -> Tuple[Dict[str, object], list[Path]]:
    if source.is_symlink():
        raise StageError("project-rules source must not be a symlink")
    source = source.resolve(strict=True)
    if not source.is_dir():
        raise StageError("project-rules source must be a real directory")
    rows: list[Tuple[str, Dict[str, object]]] = []
    targets: list[Path] = []
    total = 0
    for candidate in sorted(source.rglob("*")):
        relative = candidate.relative_to(source)
        info = candidate.lstat()
        if candidate.is_symlink():
            raise StageError(f"project-rules source contains a symlink: {relative}")
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise StageError(
                f"project-rules source is not a single-link regular file: {relative}"
            )
        if not relative.parts or ".." in relative.parts:
            raise StageError("project-rules source contains an invalid path")
        if len(rows) >= MAX_PROJECT_RULE_FILES:
            raise StageError("project-rules source exceeds the file-count bound")
        total += info.st_size
        if total > MAX_PROJECT_RULE_BYTES:
            raise StageError("project-rules source exceeds the byte bound")
        target = output / PROJECT_RULES_TARGET / relative
        copied = _copy_regular(candidate, target, 0o644)
        rows.append((relative.as_posix(), copied))
        targets.append(target)
    if not rows:
        raise StageError("project-rules source is empty")

    active_path = output / PROJECT_RULES_TARGET / "active.json"
    try:
        active = json.loads(active_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise StageError("project-rules active pointer is invalid") from exc
    body = active.get("body") if isinstance(active, dict) else None
    if not isinstance(body, dict) or body.get("project_sha256") != _project_identity():
        raise StageError("project-rules template is not bound to /workspace")

    digest = hashlib.sha256()
    for relative, copied in rows:
        name = relative.encode("utf-8")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(int(copied["bytes"]).to_bytes(8, "big"))
        digest.update(bytes.fromhex(str(copied["sha256"])))
    return (
        {
            "schema_version": "metacodes-workbuddy-project-control-v1",
            "project_root": PROJECT_ROOT,
            "project_sha256": _project_identity(),
            "relative_path": PROJECT_RULES_TARGET.as_posix(),
            "files": len(rows),
            "bytes": total,
            "tree_sha256": digest.hexdigest(),
            "active_kernel_sha256": body.get("kernel_sha256"),
        },
        targets,
    )


def _elf_machine(path: Path) -> int | None:
    with path.open("rb") as handle:
        header = handle.read(20)
    if (
        len(header) < 20
        or header[:4] != b"\x7fELF"
        or header[4] != 2  # ELFCLASS64
        or header[5] != 1  # ELFDATA2LSB
        or header[6] != 1  # EV_CURRENT
    ):
        return None
    return int.from_bytes(header[18:20], "little")


def stage(
    *,
    output: Path,
    metacodes: Path,
    tinykg: Path,
    formal_kernel: Path,
    ripgrep: Path | None = None,
    metacodes_commit: str,
    tinykg_commit: str,
    licenses: Iterable[Tuple[str, str, Path]],
    allow_synthetic_fixtures: bool = False,
    project_kernel: Path | None = None,
    project_rules: Path | None = None,
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
    if ripgrep is not None:
        # Grep/Glob are schema-declared tools backed by rg; shipping it beside
        # bin/metacodes satisfies the resolver's next-to-executable probe.
        # 90/90 container dispatches failed with RipgrepNotFound before this.
        binaries["ripgrep"] = ripgrep.resolve()
    if (project_kernel is None) != (project_rules is None):
        raise StageError("project kernel and project-rules template must be staged together")
    license_rows = list(licenses)
    if len(license_rows) != 3 or {row[0] for row in license_rows} != {
        "metacodes",
        "tinykg",
        "lean4",
    }:
        raise StageError("licenses must bind exactly metacodes, tinykg, and lean4")
    if any(not spdx.strip() for _, spdx, _ in license_rows):
        raise StageError("every license requires an explicit SPDX expression or NOASSERTION")
    if not allow_synthetic_fixtures:
        for label, source in binaries.items():
            machine = _elf_machine(source)
            if machine is None:
                raise StageError(
                    f"production {label} is not a Linux ELF64 little-endian artifact"
                )
            if machine != ELF_MACHINE_X86_64:
                raise StageError(
                    f"production {label} ELF machine {machine} does not match "
                    f"{TARGET_PLATFORM} (expected {ELF_MACHINE_X86_64})"
                )

    output.mkdir(parents=True, mode=0o755)
    executable_targets = {
        "metacodes": output / "bin/metacodes",
        "tinykg": output / "bin/tinykg",
        "metacodes-formal-kernel": output / "libexec/metacodes-formal-kernel",
    }
    if "ripgrep" in binaries:
        executable_targets["ripgrep"] = output / "bin/rg"
    executable_meta = {
        name: _copy_regular(source, executable_targets[name], 0o755)
        for name, source in binaries.items()
    }
    if not allow_synthetic_fixtures:
        for label, target in executable_targets.items():
            machine = _elf_machine(target)
            if machine is None:
                raise StageError(
                    f"production {label} is not a Linux ELF64 little-endian artifact"
                )
            if machine != ELF_MACHINE_X86_64:
                raise StageError(
                    f"production {label} ELF machine {machine} does not match "
                    f"{TARGET_PLATFORM} (expected {ELF_MACHINE_X86_64})"
                )
            executable_meta[label]["elf_machine"] = machine

    project_control = None
    project_rule_targets: list[Path] = []
    project_kernel_target: Path | None = None
    if project_kernel is not None and project_rules is not None:
        project_kernel_source = project_kernel.resolve()
        if not allow_synthetic_fixtures:
            machine = _elf_machine(project_kernel_source)
            if machine != ELF_MACHINE_X86_64:
                raise StageError(
                    "production project kernel does not match linux/amd64"
                )
        project_kernel_target = output / PROJECT_KERNEL_TARGET
        kernel_meta = _copy_regular(project_kernel_source, project_kernel_target, 0o755)
        if not allow_synthetic_fixtures:
            kernel_meta["elf_machine"] = ELF_MACHINE_X86_64
        rules_meta, project_rule_targets = _copy_project_rules(project_rules, output)
        if rules_meta["active_kernel_sha256"] != kernel_meta["sha256"]:
            raise StageError("project-rules active pointer does not bind the staged kernel")
        project_control = {
            "schema_version": "metacodes-workbuddy-project-control-v1",
            "kernel": {
                **kernel_meta,
                "relative_path": PROJECT_KERNEL_TARGET.as_posix(),
            },
            "rules": rules_meta,
        }

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
        "target_platform": TARGET_PLATFORM if not allow_synthetic_fixtures else "test-fixture",
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
            "project_control": (
                "runtime-gated-hash-pinned-template"
                if project_control is not None
                else "not-staged"
            ),
        },
    }
    if project_control is not None:
        manifest["project_control"] = project_control
    manifest_path = output / "share/metacodes/artifact-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with manifest_path.open("xb") as handle:
        handle.write(_canonical_json(manifest))
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(manifest_path, 0o644)

    hashed_paths = [
        *executable_targets.values(),
        *([project_kernel_target] if project_kernel_target is not None else []),
        *project_rule_targets,
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
    fsync_directory(output)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metacodes", type=Path, required=True)
    parser.add_argument("--tinykg", type=Path, required=True)
    parser.add_argument("--formal-kernel", type=Path, required=True)
    parser.add_argument("--ripgrep", type=Path)
    parser.add_argument("--project-kernel", type=Path)
    parser.add_argument("--project-rules", type=Path)
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
        ripgrep=args.ripgrep,
            metacodes_commit=args.metacodes_commit,
            tinykg_commit=args.tinykg_commit,
            licenses=(
                ("metacodes", args.metacodes_license_spdx, args.metacodes_license),
                ("tinykg", args.tinykg_license_spdx, args.tinykg_license),
                ("lean4", args.lean_license_spdx, args.lean_license),
            ),
            allow_synthetic_fixtures=args.allow_synthetic_fixtures,
            project_kernel=args.project_kernel,
            project_rules=args.project_rules,
        )
    except (OSError, StageError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
