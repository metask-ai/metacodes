#!/usr/bin/env python3
"""Run exactly one budgeted GLM rule-author feasibility call.

This is mechanism evidence only (`quality_evidence=false`).  The durable budget
journal is authorized before the network-capable child starts.  Any uncertain
post-authorization failure remains charged at the transaction maximum and is
never retried automatically.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import time
from pathlib import Path
from typing import Any, Mapping

from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
)
from scripts.eval.model import ValidationError, stable_json, O_BINARY, mode_violation, open_nofollow


MODEL = "glm-5.2"
PROVIDER_IDENTITY = "napi.metask-ai.com/anthropic-protocol/rule-author"
MAX_COST_MICROUSD = 200_000
MAX_METERED_TOKENS = 33_024
TOTAL_COST_MICROUSD = 1_000_000
TOTAL_METERED_TOKENS = 100_000
MAX_CREDENTIAL_BYTES = 16 * 1024
CHILD_FAILURE_SCHEMA = "metacodes-rule-author-feasibility-failure-v1"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_sha256(value: Any) -> str:
    return sha256_bytes(stable_json(value).encode("utf-8"))


def unique_json(payload: str, where: str) -> Mapping[str, Any]:
    def pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in items:
            if key in result:
                raise ValidationError(f"{where}: duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(payload, object_pairs_hook=pairs)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"{where}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationError(f"{where}: expected object")
    return value


def secure_parent(path: Path) -> Path:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or mode_violation(info.st_mode, 0o077)
        or (hasattr(os, "geteuid") and info.st_uid != os.geteuid())
    ):
        raise ValidationError(f"artifact parent must be a private 0700 directory: {path}")
    return path.resolve(strict=True)


def load_global_api_key() -> bytearray:
    auth_path = Path(
        os.environ.get("METACODES_AUTH_FILE", str(Path.home() / ".metacodes" / "auth.json"))
    ).expanduser()
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        fd = open_nofollow(auth_path, flags)
    except OSError as exc:
        raise ValidationError(f"cannot open global credential file: {exc}") from exc
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or mode_violation(info.st_mode, 0o077)
            or (hasattr(os, "geteuid") and info.st_uid != os.geteuid())
            or info.st_size <= 0
            or info.st_size > 64 * 1024
        ):
            raise ValidationError("global credential file must be a bounded private regular file")
        chunks: list[bytes] = []
        observed = 0
        while True:
            chunk = os.read(fd, min(8192, 64 * 1024 + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > 64 * 1024:
                raise ValidationError("global credential file exceeds 64 KiB")
        payload = b"".join(chunks).decode("utf-8")
    except (OSError, UnicodeError) as exc:
        raise ValidationError(f"cannot read global credential file: {exc}") from exc
    finally:
        os.close(fd)
    document = unique_json(payload, "global credentials")
    key = document.get("api_key")
    if not isinstance(key, str) or not key:
        raise ValidationError(
            "global credential has no api_key usable by the anonymous-FD trial; "
            "OAuth export/refresh is intentionally not implemented here"
        )
    encoded = key.encode("utf-8")
    if len(encoded) > MAX_CREDENTIAL_BYTES:
        raise ValidationError("global credential exceeds the anonymous-FD limit")
    return bytearray(encoded)


def minimal_child_env(credential_fd: int) -> dict[str, str]:
    allowed = (
        "HOME",
        "PATH",
        "TMPDIR",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "CURL_CA_BUNDLE",
    )
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    env["METACODES_API_KEY_FD"] = str(credential_fd)
    return env


def validate_result(value: Mapping[str, Any]) -> None:
    expected = {
        "schema_version",
        "quality_evidence",
        "model",
        "decision",
        "receipt_id",
        "candidate_id",
        "candidate_binding_verified",
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
        "metered_tokens",
        "cost_microusd",
        "provider_elapsed_ns",
    }
    if set(value) != expected:
        raise ValidationError("rule-author result field mismatch")
    if value["schema_version"] != "metacodes-rule-author-feasibility-v1":
        raise ValidationError("rule-author result schema mismatch")
    if value["quality_evidence"] is not False or value["model"] != MODEL:
        raise ValidationError("feasibility result mislabeled")
    decision = value["decision"]
    if decision not in {"abstain", "propose"}:
        raise ValidationError("invalid author decision")
    for name in (
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
        "metered_tokens",
        "cost_microusd",
        "provider_elapsed_ns",
    ):
        if not isinstance(value[name], int) or isinstance(value[name], bool) or value[name] < 0:
            raise ValidationError(f"invalid {name}")
    metered = (
        value["input_tokens"]
        + value["output_tokens"]
        + value["cache_read_input_tokens"]
        + value["cache_creation_input_tokens"]
    )
    if metered != value["metered_tokens"] or metered > MAX_METERED_TOKENS:
        raise ValidationError("metered token accounting mismatch")
    if value["cost_microusd"] > MAX_COST_MICROUSD:
        raise ValidationError("actual author cost exceeds transaction maximum")
    receipt = value["receipt_id"]
    if not isinstance(receipt, str) or len(receipt) != 64:
        raise ValidationError("invalid author receipt id")
    if decision == "propose":
        if (
            not isinstance(value["candidate_id"], str)
            or len(value["candidate_id"]) != 64
            or value["candidate_binding_verified"] is not True
        ):
            raise ValidationError("proposal lacks a verified candidate binding")
    elif value["candidate_id"] is not None or value["candidate_binding_verified"] is not False:
        raise ValidationError("abstention must not create a candidate")


def child_error_code(stderr: str) -> str | None:
    try:
        value = unique_json(stderr, "rule-author child failure")
    except ValidationError:
        return None
    if set(value) != {"schema_version", "error_code"}:
        return None
    code = value.get("error_code")
    if (
        value.get("schema_version") != CHILD_FAILURE_SCHEMA
        or not isinstance(code, str)
        or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,127}", code) is None
    ):
        return None
    return code


def private_write(path: Path, value: Mapping[str, Any]) -> None:
    payload = (stable_json(value) + "\n").encode("utf-8")
    fd = os.open(path, O_BINARY | os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise ValidationError("short artifact write")
            offset += written
        os.fsync(fd)
    finally:
        os.close(fd)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute-paid", action="store_true")
    parser.add_argument(
        "--binary",
        type=Path,
        default=Path("zig-out/bin/rule-author-feasibility"),
    )
    parser.add_argument(
        "--journal",
        type=Path,
        default=Path.home() / ".metacodes" / "eval-budget" / "rule-author-feasibility.json",
    )
    parser.add_argument(
        "--artifact-parent",
        type=Path,
        default=Path.home() / ".metacodes" / "eval-artifacts" / "rule-author",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    binary = args.binary.resolve(strict=True)
    binary_sha256 = sha256_bytes(binary.read_bytes())
    manifest = {
        "schema_version": "metacodes-rule-author-feasibility-manifest-v1",
        "model": MODEL,
        "provider_identity": PROVIDER_IDENTITY,
        "binary_sha256": binary_sha256,
        "max_cost_microusd": MAX_COST_MICROUSD,
        "max_metered_tokens": MAX_METERED_TOKENS,
        "quality_evidence": False,
    }
    manifest_sha256 = canonical_sha256(manifest)
    model_fingerprint = canonical_sha256(
        {"model": MODEL, "protocol": "anthropic", "role": "rule-author"}
    )
    plan = {
        "schema_version": "metacodes-rule-author-feasibility-plan-v1",
        "execute_paid": args.execute_paid,
        "manifest_sha256": manifest_sha256,
        "model": MODEL,
        "max_cost_microusd": MAX_COST_MICROUSD,
        "max_metered_tokens": MAX_METERED_TOKENS,
        "quality_evidence": False,
    }
    if not args.execute_paid:
        print(stable_json(plan))
        return 0

    # Credential and filesystem preflight occur before any reservation.  A
    # failure here is provably pre-request and leaves the journal untouched.
    api_key = load_global_api_key()
    artifact_parent = secure_parent(args.artifact_parent.expanduser())
    journal_parent = secure_parent(args.journal.expanduser().parent)
    journal_path = journal_parent / args.journal.name
    run_id = f"rule-author-{time.time_ns()}"
    run_dir = artifact_parent / run_id
    run_dir.mkdir(mode=0o700)

    authority = BudgetAuthority(
        manifest_sha256=manifest_sha256,
        model_fingerprint=model_fingerprint,
        provider_identity=PROVIDER_IDENTITY,
        total_cost_microusd=TOTAL_COST_MICROUSD,
        total_metered_tokens=TOTAL_METERED_TOKENS,
    )
    transaction = BudgetTransaction(
        run_id=run_id,
        manifest_sha256=manifest_sha256,
        model_fingerprint=model_fingerprint,
        harness_fingerprint=binary_sha256,
        provider_identity=PROVIDER_IDENTITY,
        max_cost_microusd=MAX_COST_MICROUSD,
        max_metered_tokens=MAX_METERED_TOKENS,
    )
    with BudgetJournal(journal_path, authority) as journal:
        reserved = journal.reserve(transaction)
        authorized = journal.authorize_request(
            str(reserved["transaction_id"]),
            expected_revision=int(reserved["journal_revision"]),
            expected_head_sha256=str(reserved["journal_head_sha256"]),
        )
        authorization_sha256 = canonical_sha256(authorized)
        read_fd, write_fd = os.pipe()
        try:
            os.set_inheritable(read_fd, True)
            pipe_buf = os.fpathconf(write_fd, "PC_PIPE_BUF")
            if len(api_key) > pipe_buf:
                raise ValidationError("credential exceeds the atomic anonymous-pipe limit")
            offset = 0
            while offset < len(api_key):
                written = os.write(write_fd, api_key[offset:])
                if written <= 0:
                    raise ValidationError("credential pipe short write")
                offset += written
            os.close(write_fd)
            write_fd = -1
            completed = subprocess.run(
                [str(binary), str(run_dir), authorization_sha256],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=minimal_child_env(read_fd),
                pass_fds=(read_fd,),
                check=False,
                text=True,
                encoding="utf-8",
                timeout=300,
            )
        finally:
            for index in range(len(api_key)):
                api_key[index] = 0
            if write_fd >= 0:
                os.close(write_fd)
            os.close(read_fd)
        if completed.returncode != 0:
            failure = {
                **plan,
                "run_id": run_id,
                "budget_transaction": journal.transaction_receipt(
                    str(reserved["transaction_id"])
                ),
                "child_returncode": completed.returncode,
                "child_error_code": child_error_code(completed.stderr),
                "child_stderr_sha256": sha256_bytes(completed.stderr.encode("utf-8")),
                "uncertain_request_not_retried": True,
            }
            private_write(run_dir / "failure.json", failure)
            raise ValidationError(
                f"rule-author child failed after durable authorization; no retry; artifact={run_dir}"
            )
        result = unique_json(completed.stdout, "rule-author child")
        validate_result(result)
        committed = journal.commit(
            str(reserved["transaction_id"]),
            actual_cost_microusd=int(result["cost_microusd"]),
            actual_metered_tokens=int(result["metered_tokens"]),
        )
        summary = {
            **plan,
            "run_id": run_id,
            "result": result,
            "budget_transaction": committed,
            "authorization_sha256": authorization_sha256,
        }
        private_write(run_dir / "summary.json", summary)
        print(
            stable_json(
                {
                    "artifact": str(run_dir / "summary.json"),
                    "decision": result["decision"],
                    "cost_microusd": result["cost_microusd"],
                    "metered_tokens": result["metered_tokens"],
                    "quality_evidence": False,
                }
            )
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
