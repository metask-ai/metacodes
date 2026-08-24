#!/usr/bin/env python3
"""Validate and stage one explicitly supplied TinyKG binary.

Metacodes does not build TinyKG from source.  A maintainer supplies a native
binary plus its observed SHA-256.  This program validates that immutable input
before copying it into the Metacodes install graph.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
from typing import Mapping, Sequence


CONTRACT_SCHEMA = "metacodes.tinykg-binary/v1"
RECEIPT_SCHEMA = "metacodes.tinykg-binary-receipt/v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


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


def inspect_binary(
    binary: Path,
    expected_sha256: str,
    contract: TinyKgContract,
) -> BinaryIdentity:
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

    version = _run(binary, ("version",))
    if version.returncode != 0:
        raise StageError(f"TinyKG version probe failed: {version.stdout.strip()}")
    version_line = version.stdout.strip()
    if version_line != f"tinykg {contract.tinykg_version}":
        raise StageError(
            f"TinyKG version mismatch: expected {contract.tinykg_version}, "
            f"observed {version_line or '<empty>'}"
        )
    return BinaryIdentity(binary, observed, version_line)


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


def _atomic_copy(source: Path, destination: Path) -> None:
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
    _atomic_copy(identity.path, output)
    if sha256_file(output) != identity.sha256:
        raise StageError("staged TinyKG bytes changed during copy")
    _atomic_json(
        receipt,
        {
            "binary_sha256": identity.sha256,
            "binary_version": identity.version_line,
            "contract_schema": CONTRACT_SCHEMA,
            "license": contract.license,
            "receipt_schema": RECEIPT_SCHEMA,
            "source_repository": contract.source_repository,
            "storage_format_version": contract.storage_format_version,
            "store_schema_version": contract.store_schema_version,
            "target": target,
        },
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        stage(
            binary=args.binary,
            expected_sha256=args.expected_sha256,
            contract_path=args.contract,
            target=args.target,
            output=args.output,
            receipt=args.receipt,
        )
    except StageError as exc:
        print(f"stage-tinykg: error: {exc}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
