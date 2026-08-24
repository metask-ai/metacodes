#!/usr/bin/env python3
"""Validate and stage one explicit or repository-bundled TinyKG binary.

Metacodes never builds TinyKG from source. An operator may supply an absolute
binary plus its observed SHA-256, while normal builds select a checked-in native
artifact from the manually maintained cross-platform bundle.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import tempfile
from typing import Mapping, Sequence


CONTRACT_SCHEMA = "metacodes.tinykg-binary/v1"
BUNDLE_SCHEMA = "metacodes.tinykg-bundle/v1"
RECEIPT_SCHEMA = "metacodes.tinykg-binary-receipt/v2"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
ARTIFACT_FORMATS = {"elf-static", "mach-o-universal", "pe"}
ARCHITECTURES = {"aarch64", "x86_64"}
TARGET_CONTRACTS = {
    "aarch64-linux": ("elf-static", "aarch64"),
    "x86_64-linux": ("elf-static", "x86_64"),
    "aarch64-macos": ("mach-o-universal", "aarch64"),
    "x86_64-macos": ("mach-o-universal", "x86_64"),
    "x86_64-windows": ("pe", "x86_64"),
}


class StageError(RuntimeError):
    """The supplied binary cannot satisfy the checked-in TinyKG contract."""


@dataclass(frozen=True)
class TinyKgContract:
    tinykg_version: str
    storage_format_version: str
    store_schema_version: str
    source_repository: str
    license: str

    @classmethod
    def load(cls, path: Path) -> "TinyKgContract":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise StageError(f"cannot read TinyKG contract: {exc}") from exc
        if not isinstance(raw, dict):
            raise StageError("TinyKG contract must be a JSON object")
        expected = {
            "contract_schema",
            "license",
            "source_repository",
            "storage_format_version",
            "store_schema_version",
            "tinykg_version",
        }
        if set(raw) != expected:
            raise StageError("TinyKG contract has missing or unknown fields")
        if raw["contract_schema"] != CONTRACT_SCHEMA:
            raise StageError("unsupported TinyKG contract schema")
        values = {key: raw[key] for key in expected - {"contract_schema"}}
        if not all(isinstance(value, str) and value for value in values.values()):
            raise StageError("TinyKG contract string fields must be non-empty")
        return cls(
            tinykg_version=raw["tinykg_version"],
            storage_format_version=raw["storage_format_version"],
            store_schema_version=raw["store_schema_version"],
            source_repository=raw["source_repository"],
            license=raw["license"],
        )


@dataclass(frozen=True)
class BundleArtifact:
    key: str
    path: str
    sha256: str
    binary_format: str
    architectures: tuple[str, ...]
    targets: tuple[str, ...]


@dataclass(frozen=True)
class TinyKgBundle:
    source_commit: str
    zig_version: str
    optimize: str
    strip: bool
    artifacts: tuple[BundleArtifact, ...]

    @classmethod
    def load(cls, path: Path) -> "TinyKgBundle":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise StageError(f"cannot read TinyKG bundle manifest: {exc}") from exc
        if not isinstance(raw, dict) or set(raw) != {
            "artifacts",
            "build",
            "bundle_schema",
            "source_commit",
        }:
            raise StageError("TinyKG bundle manifest has missing or unknown fields")
        if raw["bundle_schema"] != BUNDLE_SCHEMA:
            raise StageError("unsupported TinyKG bundle schema")
        if not isinstance(raw["source_commit"], str) or not COMMIT_RE.fullmatch(
            raw["source_commit"]
        ):
            raise StageError("TinyKG source commit must be 40 lowercase hex characters")
        build = raw["build"]
        if not isinstance(build, dict) or set(build) != {
            "optimize",
            "strip",
            "zig_version",
        }:
            raise StageError("TinyKG bundle build contract has missing or unknown fields")
        if (
            not isinstance(build["zig_version"], str)
            or not build["zig_version"]
            or build["optimize"] != "ReleaseSafe"
            or build["strip"] is not True
        ):
            raise StageError("TinyKG bundle must be a stripped ReleaseSafe build")
        artifacts_raw = raw["artifacts"]
        if not isinstance(artifacts_raw, list) or not artifacts_raw:
            raise StageError("TinyKG bundle must declare at least one artifact")
        artifacts: list[BundleArtifact] = []
        keys: set[str] = set()
        paths: set[str] = set()
        targets: set[str] = set()
        for value in artifacts_raw:
            if not isinstance(value, dict) or set(value) != {
                "architectures",
                "format",
                "key",
                "path",
                "sha256",
                "targets",
            }:
                raise StageError("TinyKG bundle artifact has missing or unknown fields")
            key = value["key"]
            relative = value["path"]
            digest = value["sha256"]
            binary_format = value["format"]
            architectures = value["architectures"]
            artifact_targets = value["targets"]
            if not isinstance(key, str) or not key or key in keys:
                raise StageError("TinyKG bundle artifact keys must be unique")
            if (
                not isinstance(relative, str)
                or not relative
                or "\\" in relative
                or ":" in relative
                or relative == "."
                or Path(relative).is_absolute()
                or PurePosixPath(relative).as_posix() != relative
                or ".." in PurePosixPath(relative).parts
                or relative in paths
            ):
                raise StageError(
                    "TinyKG bundle artifact paths must be unique portable POSIX paths"
                )
            if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
                raise StageError("TinyKG bundle artifact SHA-256 is invalid")
            if binary_format not in ARTIFACT_FORMATS:
                raise StageError("TinyKG bundle artifact format is unsupported")
            if (
                not isinstance(architectures, list)
                or not architectures
                or len(set(architectures)) != len(architectures)
                or any(arch not in ARCHITECTURES for arch in architectures)
            ):
                raise StageError("TinyKG bundle architectures are invalid")
            if (
                not isinstance(artifact_targets, list)
                or not artifact_targets
                or len(set(artifact_targets)) != len(artifact_targets)
                or any(target not in TARGET_CONTRACTS for target in artifact_targets)
                or any(target in targets for target in artifact_targets)
            ):
                raise StageError("TinyKG bundle targets must be supported and unique")
            target_contracts = [TARGET_CONTRACTS[target] for target in artifact_targets]
            if any(format_name != binary_format for format_name, _ in target_contracts):
                raise StageError("TinyKG bundle target and executable format disagree")
            if {arch for _, arch in target_contracts} != set(architectures):
                raise StageError("TinyKG bundle target and architecture declarations disagree")
            keys.add(key)
            paths.add(relative)
            targets.update(artifact_targets)
            artifacts.append(
                BundleArtifact(
                    key=key,
                    path=relative,
                    sha256=digest,
                    binary_format=binary_format,
                    architectures=tuple(architectures),
                    targets=tuple(artifact_targets),
                )
            )
        return cls(
            source_commit=raw["source_commit"],
            zig_version=build["zig_version"],
            optimize=build["optimize"],
            strip=build["strip"],
            artifacts=tuple(artifacts),
        )

    def artifact(self, key: str) -> BundleArtifact:
        matches = [artifact for artifact in self.artifacts if artifact.key == key]
        if len(matches) != 1:
            raise StageError(f"TinyKG bundle key is not declared exactly once: {key}")
        return matches[0]


@dataclass(frozen=True)
class BinaryIdentity:
    path: Path
    sha256: str
    version_line: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _run(binary: Path, arguments: Sequence[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [str(binary), *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StageError(f"TinyKG probe failed: {exc}") from exc


def _validate_regular_binary(binary: Path, expected_sha256: str) -> None:
    if not binary.is_absolute():
        raise StageError("TinyKG binary path must be absolute")
    try:
        info = binary.lstat()
    except OSError as exc:
        raise StageError(f"cannot stat TinyKG binary: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise StageError("TinyKG binary must be a regular non-symlink file")
    if os.name != "nt" and not os.access(binary, os.X_OK):
        raise StageError("TinyKG binary is not executable")
    if not SHA256_RE.fullmatch(expected_sha256):
        raise StageError("expected TinyKG SHA-256 must be 64 lowercase hex characters")
    observed = sha256_file(binary)
    if observed != expected_sha256:
        raise StageError(
            f"TinyKG SHA-256 mismatch: expected {expected_sha256}, observed {observed}"
        )


def inspect_binary(
    binary: Path,
    expected_sha256: str,
    contract: TinyKgContract,
) -> BinaryIdentity:
    _validate_regular_binary(binary, expected_sha256)
    version = _run(binary, ("version",))
    if version.returncode != 0:
        raise StageError(f"TinyKG version probe failed: {version.stdout.strip()}")
    version_line = version.stdout.strip()
    if version_line != f"tinykg {contract.tinykg_version}":
        raise StageError(
            f"TinyKG version mismatch: expected {contract.tinykg_version}, "
            f"observed {version_line or '<empty>'}"
        )
    return BinaryIdentity(binary, expected_sha256, version_line)


def _validate_elf(data: bytes, architectures: tuple[str, ...]) -> None:
    if (
        len(data) < 64
        or data[:7] != b"\x7fELF\x02\x01\x01"
        or struct.unpack("<H", data[16:18])[0] != 2
        or struct.unpack("<I", data[20:24])[0] != 1
        or struct.unpack("<H", data[52:54])[0] != 64
    ):
        raise StageError("TinyKG bundle expected a 64-bit little-endian ELF binary")
    expected_machine = {"x86_64": 62, "aarch64": 183}
    if len(architectures) != 1 or struct.unpack("<H", data[18:20])[0] != expected_machine[
        architectures[0]
    ]:
        raise StageError("TinyKG ELF architecture does not match its manifest")
    program_offset = struct.unpack("<Q", data[32:40])[0]
    entry_size = struct.unpack("<H", data[54:56])[0]
    entry_count = struct.unpack("<H", data[56:58])[0]
    if (
        entry_size != 56
        or entry_count == 0
        or program_offset + entry_size * entry_count > len(data)
    ):
        raise StageError("TinyKG ELF program-header table is invalid")
    saw_load = False
    for index in range(entry_count):
        offset = program_offset + index * entry_size
        program_type = struct.unpack("<I", data[offset : offset + 4])[0]
        file_offset = struct.unpack("<Q", data[offset + 8 : offset + 16])[0]
        file_size = struct.unpack("<Q", data[offset + 32 : offset + 40])[0]
        if file_offset + file_size > len(data):
            raise StageError("TinyKG ELF program segment exceeds the file")
        saw_load = saw_load or program_type == 1
        if program_type in {2, 3}:
            raise StageError(
                "TinyKG Linux bundle must be static and contain no PT_DYNAMIC/PT_INTERP"
            )
    if not saw_load:
        raise StageError("TinyKG Linux bundle contains no loadable program segment")


def _validate_mach_o_universal(
    data: bytes,
    architectures: tuple[str, ...],
) -> tuple[tuple[int, int], ...]:
    if len(data) < 48 or data[:4] != b"\xca\xfe\xba\xbe":
        raise StageError("TinyKG bundle expected a universal Mach-O binary")
    count = struct.unpack(">I", data[4:8])[0]
    if count == 0 or 8 + count * 20 > len(data):
        raise StageError("TinyKG universal Mach-O header is invalid")
    cpu_names = {0x01000007: "x86_64", 0x0100000C: "aarch64"}
    observed: set[str] = set()
    slices: list[tuple[int, int]] = []
    for index in range(count):
        entry = 8 + index * 20
        cpu = struct.unpack(">I", data[entry : entry + 4])[0]
        slice_offset, slice_size = struct.unpack(">II", data[entry + 8 : entry + 16])
        alignment = struct.unpack(">I", data[entry + 16 : entry + 20])[0]
        if (
            cpu not in cpu_names
            or slice_size < 32
            or slice_offset + slice_size > len(data)
            or alignment > 30
            or slice_offset % (1 << alignment) != 0
        ):
            raise StageError("TinyKG universal Mach-O slice is invalid")
        if data[slice_offset : slice_offset + 4] != b"\xcf\xfa\xed\xfe":
            raise StageError("TinyKG universal Mach-O slice is not a 64-bit Mach-O")
        if struct.unpack("<I", data[slice_offset + 4 : slice_offset + 8])[0] != cpu:
            raise StageError("TinyKG universal Mach-O slice CPU disagrees with its fat table")
        if struct.unpack("<I", data[slice_offset + 12 : slice_offset + 16])[0] != 2:
            raise StageError("TinyKG universal Mach-O slice is not an executable")
        command_count = struct.unpack(
            "<I", data[slice_offset + 16 : slice_offset + 20]
        )[0]
        command_bytes = struct.unpack(
            "<I", data[slice_offset + 20 : slice_offset + 24]
        )[0]
        command_start = slice_offset + 32
        command_end = command_start + command_bytes
        if command_count == 0 or command_end > slice_offset + slice_size:
            raise StageError("TinyKG universal Mach-O load-command table is invalid")
        cursor = command_start
        macos_build = False
        for _ in range(command_count):
            if cursor + 8 > command_end:
                raise StageError("TinyKG universal Mach-O load command is truncated")
            command, command_size = struct.unpack("<II", data[cursor : cursor + 8])
            if command_size < 8 or command_size % 8 != 0 or cursor + command_size > command_end:
                raise StageError("TinyKG universal Mach-O load command is invalid")
            if command == 0x32:
                if command_size < 24 or struct.unpack(
                    "<I", data[cursor + 8 : cursor + 12]
                )[0] != 1:
                    raise StageError("TinyKG universal Mach-O build target is not macOS")
                macos_build = True
            cursor += command_size
        if cursor != command_end or not macos_build:
            raise StageError("TinyKG universal Mach-O lacks a canonical macOS build command")
        observed.add(cpu_names[cpu])
        slices.append((slice_offset, slice_offset + slice_size))
    slices.sort()
    if any(left[1] > right[0] for left, right in zip(slices, slices[1:])):
        raise StageError("TinyKG universal Mach-O slices overlap")
    if observed != set(architectures) or count != len(architectures):
        raise StageError("TinyKG universal Mach-O architectures do not match its manifest")
    return tuple(slices)


def _validate_pe(data: bytes, architectures: tuple[str, ...]) -> None:
    if len(data) < 256 or data[:2] != b"MZ" or architectures != ("x86_64",):
        raise StageError("TinyKG bundle expected an x86_64 Windows PE binary")
    pe_offset = struct.unpack("<I", data[0x3C:0x40])[0]
    if pe_offset + 26 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise StageError("TinyKG Windows PE signature is invalid")
    if struct.unpack("<H", data[pe_offset + 4 : pe_offset + 6])[0] != 0x8664:
        raise StageError("TinyKG Windows PE architecture is not x86_64")
    section_count = struct.unpack("<H", data[pe_offset + 6 : pe_offset + 8])[0]
    optional_size = struct.unpack("<H", data[pe_offset + 20 : pe_offset + 22])[0]
    characteristics = struct.unpack("<H", data[pe_offset + 22 : pe_offset + 24])[0]
    if (
        section_count == 0
        or characteristics & 0x0002 == 0
        or optional_size < 2
        or pe_offset + 24 + optional_size + section_count * 40 > len(data)
    ):
        raise StageError("TinyKG Windows PE optional header is invalid")
    if struct.unpack("<H", data[pe_offset + 24 : pe_offset + 26])[0] != 0x20B:
        raise StageError("TinyKG Windows binary is not PE32+")
    if optional_size < 70 or struct.unpack(
        "<H", data[pe_offset + 92 : pe_offset + 94]
    )[0] != 3:
        raise StageError("TinyKG Windows binary is not a console executable")


def validate_bundle_bytes(
    binary: Path,
    artifact: BundleArtifact,
    contract: TinyKgContract,
) -> BinaryIdentity:
    _validate_regular_binary(binary, artifact.sha256)
    try:
        data = binary.read_bytes()
    except OSError as exc:
        raise StageError(f"cannot read TinyKG bundle binary: {exc}") from exc
    mach_slices: tuple[tuple[int, int], ...] = ()
    if artifact.binary_format == "elf-static":
        _validate_elf(data, artifact.architectures)
    elif artifact.binary_format == "mach-o-universal":
        mach_slices = _validate_mach_o_universal(data, artifact.architectures)
    elif artifact.binary_format == "pe":
        _validate_pe(data, artifact.architectures)
    else:  # TinyKgBundle.load makes this state unrepresentable.
        raise AssertionError(artifact.binary_format)
    version_line = f"tinykg {contract.tinykg_version}"
    version_marker = version_line.encode("utf-8")
    if mach_slices and any(
        version_marker not in data[start:end] for start, end in mach_slices
    ):
        raise StageError(f"TinyKG version marker is missing from a Mach-O slice: {version_line}")
    if not mach_slices and version_marker not in data:
        raise StageError(f"TinyKG version marker is missing: {version_line}")
    return BinaryIdentity(binary, artifact.sha256, version_line)


def _parse_store_info(output: str) -> Mapping[str, str]:
    parsed: dict[str, str] = {}
    for line in output.splitlines():
        key, separator, value = line.partition("=")
        if separator and key and key not in parsed:
            parsed[key] = value
    return parsed


def validate_store_contract(identity: BinaryIdentity, contract: TinyKgContract) -> None:
    with tempfile.TemporaryDirectory(prefix="metacodes-tinykg-contract-") as directory:
        store = Path(directory) / "probe.kg"
        initialized = _run(identity.path, ("init", str(store)))
        if initialized.returncode != 0:
            raise StageError(f"TinyKG init probe failed: {initialized.stdout.strip()}")
        inspected = _run(identity.path, ("store-info", str(store)))
        if inspected.returncode != 0:
            raise StageError(
                f"TinyKG store-info probe failed: {inspected.stdout.strip()}"
            )
        fields = _parse_store_info(inspected.stdout)
        observed = (
            fields.get("storage_format_version"),
            fields.get("schema_version"),
        )
        expected = (
            contract.storage_format_version,
            contract.store_schema_version,
        )
        if observed != expected:
            raise StageError(
                "TinyKG store contract mismatch: "
                f"expected storage/schema {expected[0]}/{expected[1]}, "
                f"observed {observed[0] or '<missing>'}/{observed[1] or '<missing>'}"
            )


def _atomic_copy(source: Path, destination: Path, expected_sha256: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as target, source.open("rb") as origin:
            shutil.copyfileobj(origin, target, length=1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
        if os.name != "nt":
            temporary.chmod(source.stat().st_mode & 0o777)
        observed = sha256_file(temporary)
        if observed != expected_sha256:
            raise StageError(
                "TinyKG source changed while staging: "
                f"expected {expected_sha256}, observed {observed}"
            )
        os.replace(temporary, destination)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_json(destination: Path, value: Mapping[str, object]) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(value, indent=2, sort_keys=True) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.", dir=destination.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _publish(
    identity: BinaryIdentity,
    contract: TinyKgContract,
    target: str,
    output: Path,
    receipt: Path,
    distribution: str,
    bundle_key: str | None = None,
    source_commit: str | None = None,
) -> None:
    _atomic_copy(identity.path, output, identity.sha256)
    value: dict[str, object] = {
        "binary_sha256": identity.sha256,
        "binary_version": identity.version_line,
        "contract_schema": CONTRACT_SCHEMA,
        "distribution": distribution,
        "license": contract.license,
        "receipt_schema": RECEIPT_SCHEMA,
        "source_repository": contract.source_repository,
        "storage_format_version": contract.storage_format_version,
        "store_schema_version": contract.store_schema_version,
        "target": target,
    }
    if distribution == "bundled":
        if bundle_key is None or source_commit is None:
            raise AssertionError("bundled provenance requires key and source commit")
        value["bundle_key"] = bundle_key
        value["source_commit"] = source_commit
    _atomic_json(receipt, value)


def stage(
    binary: Path,
    expected_sha256: str,
    contract_path: Path,
    target: str,
    output: Path,
    receipt: Path,
) -> None:
    if not target:
        raise StageError("target triple must be non-empty")
    contract = TinyKgContract.load(contract_path)
    identity = inspect_binary(binary, expected_sha256, contract)
    validate_store_contract(identity, contract)
    _publish(identity, contract, target, output, receipt, "explicit")


def stage_bundled(
    binary: Path,
    manifest_path: Path,
    bundle_key: str,
    expected_sha256: str,
    target_family: str,
    runtime_probe: bool,
    contract_path: Path,
    target: str,
    output: Path,
    receipt: Path,
) -> None:
    if not target or not target_family:
        raise StageError("target triple and family must be non-empty")
    contract = TinyKgContract.load(contract_path)
    bundle = TinyKgBundle.load(manifest_path)
    artifact = bundle.artifact(bundle_key)
    if artifact.sha256 != expected_sha256:
        raise StageError("TinyKG build selection digest does not match its manifest")
    expected = (manifest_path.parent / artifact.path).resolve()
    if binary.resolve() != expected:
        raise StageError("TinyKG bundle binary path does not match its manifest")
    if target_family not in artifact.targets:
        raise StageError(
            f"TinyKG bundle {bundle_key} does not support target {target_family}"
        )
    identity = validate_bundle_bytes(binary, artifact, contract)
    if runtime_probe:
        probed = inspect_binary(binary, artifact.sha256, contract)
        validate_store_contract(probed, contract)
        identity = probed
    _publish(
        identity,
        contract,
        target,
        output,
        receipt,
        "bundled",
        bundle_key=bundle_key,
        source_commit=bundle.source_commit,
    )


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    explicit = modes.add_parser("explicit", help="stage an operator-supplied binary")
    explicit.add_argument("--binary", type=Path, required=True)
    explicit.add_argument("--expected-sha256", required=True)
    _add_common_arguments(explicit)
    bundled = modes.add_parser("bundled", help="stage a checked-in bundle artifact")
    bundled.add_argument("--binary", type=Path, required=True)
    bundled.add_argument("--manifest", type=Path, required=True)
    bundled.add_argument("--bundle-key", required=True)
    bundled.add_argument("--expected-sha256", required=True)
    bundled.add_argument("--target-family", required=True)
    bundled.add_argument("--runtime-probe", action="store_true")
    _add_common_arguments(bundled)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.mode == "explicit":
            stage(
                binary=args.binary,
                expected_sha256=args.expected_sha256,
                contract_path=args.contract,
                target=args.target,
                output=args.output,
                receipt=args.receipt,
            )
        else:
            stage_bundled(
                binary=args.binary,
                manifest_path=args.manifest,
                bundle_key=args.bundle_key,
                expected_sha256=args.expected_sha256,
                target_family=args.target_family,
                runtime_probe=args.runtime_probe,
                contract_path=args.contract,
                target=args.target,
                output=args.output,
                receipt=args.receipt,
            )
    except (OSError, StageError) as exc:
        print(f"stage-tinykg: error: {exc}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
