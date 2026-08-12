"""Crash-conservative local budget journal for paid memory pilots.

This module is deliberately narrow.  It coordinates one machine with an
exclusive OS lock; it is not a distributed ledger, an agent memory store, or a
replacement for TinyKG.  Every provider authorization is durable before the
caller may start a network-capable child process.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import stat
import time
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_CEILING
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Tuple

try:
    import fcntl
except ImportError:  # pragma: no cover - production paid runs reject Windows.
    fcntl = None  # type: ignore[assignment]

from .model import ValidationError, stable_json


JOURNAL_SCHEMA_VERSION = 1
ZERO_HEAD_SHA256 = "0" * 64
MAX_JOURNAL_BYTES = 8 * 1024 * 1024
MICRO_USD_PER_USD = 1_000_000
HEX64 = frozenset("0123456789abcdef")
FaultHook = Callable[[str], None]


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _is_hash(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in HEX64 for character in value)
    )


def _require_hash(value: Any, where: str) -> str:
    if not _is_hash(value):
        _fail(where, "expected lowercase SHA-256 hex")
    return value


def _require_text(value: Any, where: str, *, maximum: int = 1024) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        _fail(where, f"expected non-empty UTF-8 text <= {maximum} bytes")
    return value


def _require_integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def usd_to_microusd(value: float | int | str) -> int:
    if isinstance(value, bool):
        _fail("budget cost", "boolean is not a monetary value")
    try:
        decimal = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise ValidationError(f"budget cost: invalid decimal: {exc}") from exc
    if not decimal.is_finite() or decimal < 0:
        _fail("budget cost", "expected a finite non-negative value")
    scaled = decimal * MICRO_USD_PER_USD
    if scaled != scaled.to_integral_value():
        _fail("budget cost", "requires precision no finer than one micro-USD")
    return int(scaled)


def usd_to_microusd_ceiling(value: float | int | str) -> int:
    """Conservatively account sub-micro prices without ever rounding down."""

    if isinstance(value, bool):
        _fail("budget cost", "boolean is not a monetary value")
    try:
        decimal = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise ValidationError(f"budget cost: invalid decimal: {exc}") from exc
    if not decimal.is_finite() or decimal < 0:
        _fail("budget cost", "expected a finite non-negative value")
    return int((decimal * MICRO_USD_PER_USD).to_integral_value(rounding=ROUND_CEILING))


def microusd_to_usd(value: int) -> float:
    _require_integer(value, "budget microusd")
    return float(Decimal(value) / MICRO_USD_PER_USD)


@dataclass(frozen=True)
class BudgetAuthority:
    manifest_sha256: str
    model_fingerprint: str
    provider_identity: str
    total_cost_microusd: int
    total_metered_tokens: int

    def validate(self) -> None:
        _require_hash(self.manifest_sha256, "budget authority.manifest_sha256")
        _require_hash(self.model_fingerprint, "budget authority.model_fingerprint")
        _require_text(self.provider_identity, "budget authority.provider_identity", maximum=256)
        _require_integer(
            self.total_cost_microusd,
            "budget authority.total_cost_microusd",
            minimum=1,
        )
        _require_integer(
            self.total_metered_tokens,
            "budget authority.total_metered_tokens",
            minimum=1,
        )
        if self.total_cost_microusd > 1000 * MICRO_USD_PER_USD:
            _fail("budget authority.total_cost_microusd", "must not exceed $1000")

    def record(self) -> Mapping[str, Any]:
        self.validate()
        return {
            "manifest_sha256": self.manifest_sha256,
            "model_fingerprint": self.model_fingerprint,
            "provider_identity": self.provider_identity,
            "total_cost_microusd": self.total_cost_microusd,
            "total_metered_tokens": self.total_metered_tokens,
        }


@dataclass(frozen=True)
class BudgetTransaction:
    run_id: str
    manifest_sha256: str
    model_fingerprint: str
    harness_fingerprint: str
    provider_identity: str
    max_cost_microusd: int
    max_metered_tokens: int

    def validate(self) -> None:
        _require_text(self.run_id, "budget transaction.run_id")
        _require_hash(self.manifest_sha256, "budget transaction.manifest_sha256")
        _require_hash(self.model_fingerprint, "budget transaction.model_fingerprint")
        _require_hash(self.harness_fingerprint, "budget transaction.harness_fingerprint")
        _require_text(
            self.provider_identity,
            "budget transaction.provider_identity",
            maximum=256,
        )
        _require_integer(
            self.max_cost_microusd,
            "budget transaction.max_cost_microusd",
            minimum=1,
        )
        _require_integer(
            self.max_metered_tokens,
            "budget transaction.max_metered_tokens",
            minimum=1,
        )

    def record(self) -> Mapping[str, Any]:
        self.validate()
        return {
            "run_id": self.run_id,
            "manifest_sha256": self.manifest_sha256,
            "model_fingerprint": self.model_fingerprint,
            "harness_fingerprint": self.harness_fingerprint,
            "provider_identity": self.provider_identity,
            "max_cost_microusd": self.max_cost_microusd,
            "max_metered_tokens": self.max_metered_tokens,
        }


def _unique_json(payload: bytes, where: str) -> Mapping[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(where, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except ValidationError:
        raise
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"{where}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        _fail(where, "expected a JSON object")
    return value


def _exact_object(value: Any, where: str, keys: tuple[str, ...]) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    expected = frozenset(keys)
    if set(value) != expected:
        missing = sorted(expected - set(value))
        unknown = sorted(set(value) - expected)
        _fail(where, f"field mismatch missing={missing} unknown={unknown}")
    return value


def _validate_authority_record(value: Any, where: str) -> Mapping[str, Any]:
    record = _exact_object(
        value,
        where,
        (
            "manifest_sha256",
            "model_fingerprint",
            "provider_identity",
            "total_cost_microusd",
            "total_metered_tokens",
        ),
    )
    BudgetAuthority(
        manifest_sha256=_require_hash(record["manifest_sha256"], f"{where}.manifest_sha256"),
        model_fingerprint=_require_hash(
            record["model_fingerprint"], f"{where}.model_fingerprint"
        ),
        provider_identity=_require_text(
            record["provider_identity"], f"{where}.provider_identity", maximum=256
        ),
        total_cost_microusd=_require_integer(
            record["total_cost_microusd"], f"{where}.total_cost_microusd", minimum=1
        ),
        total_metered_tokens=_require_integer(
            record["total_metered_tokens"], f"{where}.total_metered_tokens", minimum=1
        ),
    ).validate()
    return record


def _validate_identity_record(value: Any, where: str) -> Mapping[str, Any]:
    record = _exact_object(
        value,
        where,
        (
            "run_id",
            "manifest_sha256",
            "model_fingerprint",
            "harness_fingerprint",
            "provider_identity",
            "max_cost_microusd",
            "max_metered_tokens",
        ),
    )
    BudgetTransaction(
        run_id=_require_text(record["run_id"], f"{where}.run_id"),
        manifest_sha256=_require_hash(
            record["manifest_sha256"], f"{where}.manifest_sha256"
        ),
        model_fingerprint=_require_hash(
            record["model_fingerprint"], f"{where}.model_fingerprint"
        ),
        harness_fingerprint=_require_hash(
            record["harness_fingerprint"], f"{where}.harness_fingerprint"
        ),
        provider_identity=_require_text(
            record["provider_identity"], f"{where}.provider_identity", maximum=256
        ),
        max_cost_microusd=_require_integer(
            record["max_cost_microusd"], f"{where}.max_cost_microusd", minimum=1
        ),
        max_metered_tokens=_require_integer(
            record["max_metered_tokens"], f"{where}.max_metered_tokens", minimum=1
        ),
    ).validate()
    return record


def _initial_document(authority: BudgetAuthority) -> Mapping[str, Any]:
    authority_record = authority.record()
    journal_id = _canonical_sha256(
        {"schema_version": JOURNAL_SCHEMA_VERSION, "authority": authority_record}
    )
    return {
        "schema_version": JOURNAL_SCHEMA_VERSION,
        "journal_id": journal_id,
        "authority": authority_record,
        "revision": 0,
        "head_sha256": ZERO_HEAD_SHA256,
        "events": [],
    }


def _replay_document(document: Mapping[str, Any]) -> Mapping[str, Any]:
    value = _exact_object(
        document,
        "budget journal",
        (
            "schema_version",
            "journal_id",
            "authority",
            "revision",
            "head_sha256",
            "events",
        ),
    )
    if value["schema_version"] != JOURNAL_SCHEMA_VERSION:
        _fail("budget journal.schema_version", "unsupported schema")
    authority = _validate_authority_record(value["authority"], "budget journal.authority")
    expected_journal_id = _canonical_sha256(
        {"schema_version": JOURNAL_SCHEMA_VERSION, "authority": authority}
    )
    if _require_hash(value["journal_id"], "budget journal.journal_id") != expected_journal_id:
        _fail("budget journal.journal_id", "does not bind authority")
    events = value["events"]
    if not isinstance(events, list):
        _fail("budget journal.events", "expected an array")
    revision = _require_integer(value["revision"], "budget journal.revision")
    if revision != len(events):
        _fail("budget journal.revision", "does not equal event count")

    transactions: Dict[str, Dict[str, Any]] = {}
    head = ZERO_HEAD_SHA256
    for index, raw_event in enumerate(events, start=1):
        where = f"budget journal.events[{index - 1}]"
        event = _exact_object(
            raw_event,
            where,
            (
                "revision",
                "previous_head_sha256",
                "action",
                "transaction_id",
                "identity",
                "actual_cost_microusd",
                "actual_metered_tokens",
                "recorded_at_unix_ns",
                "event_sha256",
            ),
        )
        if _require_integer(event["revision"], f"{where}.revision", minimum=1) != index:
            _fail(f"{where}.revision", "is not contiguous")
        if _require_hash(
            event["previous_head_sha256"], f"{where}.previous_head_sha256"
        ) != head:
            _fail(f"{where}.previous_head_sha256", "hash chain is broken")
        event_without_hash = {key: event[key] for key in event if key != "event_sha256"}
        observed_event_hash = _require_hash(event["event_sha256"], f"{where}.event_sha256")
        if observed_event_hash != _canonical_sha256(event_without_hash):
            _fail(f"{where}.event_sha256", "does not bind event")
        head = observed_event_hash
        action = event["action"]
        if action not in {"reserved", "request_authorized", "committed", "aborted_pre_request"}:
            _fail(f"{where}.action", "unsupported transition")
        transaction_id = _require_hash(event["transaction_id"], f"{where}.transaction_id")
        identity = _validate_identity_record(event["identity"], f"{where}.identity")
        _require_integer(event["recorded_at_unix_ns"], f"{where}.recorded_at_unix_ns", minimum=1)
        actual_cost = event["actual_cost_microusd"]
        actual_tokens = event["actual_metered_tokens"]

        current = transactions.get(transaction_id)
        if action == "reserved":
            if current is not None:
                _fail(where, "transaction was reserved more than once")
            if any(
                transaction["identity"]["run_id"] == identity["run_id"]
                and transaction["state"] != "aborted_pre_request"
                for transaction in transactions.values()
            ):
                _fail(where, "run id already has a non-aborted transaction")
            expected_transaction_id = _canonical_sha256(
                {
                    "journal_id": expected_journal_id,
                    "reservation_revision": index,
                    "identity": identity,
                }
            )
            if transaction_id != expected_transaction_id:
                _fail(f"{where}.transaction_id", "does not bind identity and revision")
            if actual_cost is not None or actual_tokens is not None:
                _fail(where, "reservation cannot contain actual usage")
            transactions[transaction_id] = {
                "transaction_id": transaction_id,
                "identity": identity,
                "identity_sha256": _canonical_sha256(identity),
                "state": "reserved",
                "reservation_revision": index,
                "reservation_head_sha256": head,
                "authorization_revision": None,
                "authorization_head_sha256": None,
                "commit_revision": None,
                "commit_head_sha256": None,
                "actual_cost_microusd": None,
                "actual_metered_tokens": None,
            }
        else:
            if current is None:
                _fail(where, "transition refers to an unknown transaction")
            if identity != current["identity"]:
                _fail(where, "transaction identity drift")
            if action == "request_authorized":
                if current["state"] != "reserved":
                    _fail(where, "authorization requires reserved state")
                if actual_cost is not None or actual_tokens is not None:
                    _fail(where, "authorization cannot contain actual usage")
                current["state"] = action
                current["authorization_revision"] = index
                current["authorization_head_sha256"] = head
            elif action == "aborted_pre_request":
                if current["state"] != "reserved":
                    _fail(where, "pre-request abort requires reserved state")
                if actual_cost is not None or actual_tokens is not None:
                    _fail(where, "pre-request abort cannot contain actual usage")
                current["state"] = action
            else:
                if current["state"] != "request_authorized":
                    _fail(where, "commit requires request_authorized state")
                actual_cost = _require_integer(
                    actual_cost, f"{where}.actual_cost_microusd"
                )
                actual_tokens = _require_integer(
                    actual_tokens, f"{where}.actual_metered_tokens"
                )
                if actual_cost > identity["max_cost_microusd"]:
                    _fail(where, "actual cost exceeds transaction maximum")
                if actual_tokens > identity["max_metered_tokens"]:
                    _fail(where, "actual tokens exceed transaction maximum")
                current["state"] = action
                current["commit_revision"] = index
                current["commit_head_sha256"] = head
                current["actual_cost_microusd"] = actual_cost
                current["actual_metered_tokens"] = actual_tokens

        exposure_cost = 0
        exposure_tokens = 0
        for transaction in transactions.values():
            identity_record = transaction["identity"]
            if transaction["state"] == "committed":
                exposure_cost += transaction["actual_cost_microusd"]
                exposure_tokens += transaction["actual_metered_tokens"]
            elif transaction["state"] in {"reserved", "request_authorized"}:
                exposure_cost += identity_record["max_cost_microusd"]
                exposure_tokens += identity_record["max_metered_tokens"]
        if exposure_cost > authority["total_cost_microusd"]:
            _fail(where, "cost exposure exceeds authority")
        if exposure_tokens > authority["total_metered_tokens"]:
            _fail(where, "token exposure exceeds authority")

    if _require_hash(value["head_sha256"], "budget journal.head_sha256") != head:
        _fail("budget journal.head_sha256", "does not match the event chain")
    return {
        "journal_id": expected_journal_id,
        "authority": authority,
        "revision": revision,
        "head_sha256": head,
        "transactions": transactions,
    }


def _transaction_receipt_from_state(
    state: Mapping[str, Any],
    transaction_id: str,
) -> Mapping[str, Any]:
    _require_hash(transaction_id, "budget transaction id")
    current = state["transactions"].get(transaction_id)
    if current is None:
        _fail("budget transaction", "is unknown")
    identity = current["identity"]
    return {
        "journal_id": state["journal_id"],
        "journal_revision": state["revision"],
        "journal_head_sha256": state["head_sha256"],
        "transaction_id": transaction_id,
        "state": current["state"],
        "identity_sha256": current["identity_sha256"],
        "run_id": identity["run_id"],
        "manifest_sha256": identity["manifest_sha256"],
        "model_fingerprint": identity["model_fingerprint"],
        "harness_fingerprint": identity["harness_fingerprint"],
        "provider_identity": identity["provider_identity"],
        "max_cost_microusd": identity["max_cost_microusd"],
        "max_metered_tokens": identity["max_metered_tokens"],
        "reservation_revision": current["reservation_revision"],
        "reservation_head_sha256": current["reservation_head_sha256"],
        "authorization_revision": current["authorization_revision"],
        "authorization_head_sha256": current["authorization_head_sha256"],
        "commit_revision": current["commit_revision"],
        "commit_head_sha256": current["commit_head_sha256"],
        "actual_cost_microusd": current["actual_cost_microusd"],
        "actual_metered_tokens": current["actual_metered_tokens"],
    }


def reopen_checkpoint_transaction(
    payload: bytes,
    transaction_id: str,
) -> Mapping[str, Any]:
    """Validate a durable journal checkpoint and reopen one exact receipt."""

    if not payload or len(payload) > MAX_JOURNAL_BYTES:
        _fail("budget checkpoint", "size is empty or exceeds the safety limit")
    document = _unique_json(payload, "budget checkpoint")
    state = _replay_document(document)
    return _transaction_receipt_from_state(state, transaction_id)


def validate_checkpoint_payload(payload: bytes) -> Mapping[str, Any]:
    """Validate an exported checkpoint and return its replayed public state."""

    return _replay_document(_unique_json(payload, "budget journal checkpoint"))


class BudgetJournal:
    """Exclusive, durable state machine for one local paid experiment."""

    def __init__(
        self,
        path: Path,
        authority: BudgetAuthority,
        *,
        fault_hook: FaultHook | None = None,
    ) -> None:
        self.path = path.expanduser()
        if not self.path.is_absolute():
            self.path = (Path.cwd() / self.path).absolute()
        self.authority = authority
        self.authority.validate()
        self._fault_hook = fault_hook
        self._dir_fd = -1
        self._lock_fd = -1
        self._document: Mapping[str, Any] | None = None
        self._state: Mapping[str, Any] | None = None

    @property
    def lock_path(self) -> Path:
        return self.path.with_name(self.path.name + ".lock")

    @property
    def temporary_path(self) -> Path:
        return self.path.with_name(self.path.name + ".tmp")

    def __enter__(self) -> "BudgetJournal":
        if fcntl is None or os.name == "nt":
            _fail("budget journal lock", "requires POSIX flock")
        parent = self.path.parent.resolve(strict=True)
        parent_info = parent.stat()
        if not stat.S_ISDIR(parent_info.st_mode):
            _fail("budget journal parent", "is not a directory")
        if hasattr(os, "geteuid") and parent_info.st_uid != os.geteuid():
            _fail("budget journal parent", "must be owned by the current user")
        if stat.S_IMODE(parent_info.st_mode) & 0o022:
            _fail("budget journal parent", "must not be group/world writable")
        self.path = parent / self.path.name
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            self._dir_fd = os.open(parent, flags)
            opened_parent_info = os.fstat(self._dir_fd)
            if not stat.S_ISDIR(opened_parent_info.st_mode):
                _fail("budget journal parent", "opened object is not a directory")
            if (
                opened_parent_info.st_dev != parent_info.st_dev
                or opened_parent_info.st_ino != parent_info.st_ino
            ):
                _fail("budget journal parent", "changed while opening")
            if hasattr(os, "geteuid") and opened_parent_info.st_uid != os.geteuid():
                _fail("budget journal parent", "opened directory is not owned by current user")
            if stat.S_IMODE(opened_parent_info.st_mode) & 0o022:
                _fail("budget journal parent", "opened directory is group/world writable")
            self._lock_fd = self._open_lock()
            try:
                fcntl.flock(self._lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise ValidationError("budget journal lock: another local runner holds it") from exc
            self._reject_temporary()
            if self._entry_exists(self.path.name):
                self._document = self._read_document()
            else:
                self._document = _initial_document(self.authority)
                self._persist(self._document)
            self._state = _replay_document(self._document)
            if self._state["authority"] != self.authority.record():
                _fail("budget journal authority", "experiment identity or limits drifted")
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        self.close()

    def close(self) -> None:
        if self._lock_fd >= 0:
            try:
                if fcntl is not None:
                    fcntl.flock(self._lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(self._lock_fd)
                self._lock_fd = -1
        if self._dir_fd >= 0:
            os.close(self._dir_fd)
            self._dir_fd = -1

    def _open_lock(self) -> int:
        name = self.lock_path.name
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            fd = os.open(name, flags, 0o600, dir_fd=self._dir_fd)
        except OSError as exc:
            raise ValidationError(f"budget journal lock: cannot open: {exc}") from exc
        try:
            self._validate_regular_fd(fd, "budget journal lock")
            return fd
        except BaseException:
            os.close(fd)
            raise

    def _validate_regular_fd(self, fd: int, where: str) -> os.stat_result:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            _fail(where, "must be a regular file")
        if info.st_nlink != 1:
            _fail(where, "hard links are forbidden")
        if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
            _fail(where, "must be owned by the current user")
        if stat.S_IMODE(info.st_mode) & 0o077:
            _fail(where, "permissions must be 0600 or stricter")
        return info

    def _entry_exists(self, name: str) -> bool:
        try:
            os.stat(name, dir_fd=self._dir_fd, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False
        except OSError as exc:
            raise ValidationError(f"budget journal: cannot inspect {name!r}: {exc}") from exc

    def _reject_temporary(self) -> None:
        if self._entry_exists(self.temporary_path.name):
            _fail("budget journal", "incomplete temporary file requires manual inspection")

    def _read_document(self) -> Mapping[str, Any]:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            fd = os.open(self.path.name, flags, dir_fd=self._dir_fd)
        except OSError as exc:
            raise ValidationError(f"budget journal: cannot open: {exc}") from exc
        try:
            info = self._validate_regular_fd(fd, "budget journal")
            if info.st_size <= 0 or info.st_size > MAX_JOURNAL_BYTES:
                _fail("budget journal", "size is empty or exceeds the safety limit")
            chunks: list[bytes] = []
            observed = 0
            while True:
                chunk = os.read(fd, min(65536, MAX_JOURNAL_BYTES + 1 - observed))
                if not chunk:
                    break
                chunks.append(chunk)
                observed += len(chunk)
                if observed > MAX_JOURNAL_BYTES:
                    _fail("budget journal", "exceeds the safety limit")
            return _unique_json(b"".join(chunks), "budget journal")
        finally:
            os.close(fd)

    def _reobserve(self) -> None:
        self._reject_temporary()
        current = self._read_document()
        current_state = _replay_document(current)
        if self._state is None or (
            current_state["revision"] != self._state["revision"]
            or current_state["head_sha256"] != self._state["head_sha256"]
            or current_state["journal_id"] != self._state["journal_id"]
        ):
            _fail("budget journal", "revision or head drift while lock is held")
        self._document = current
        self._state = current_state

    def _persist(self, document: Mapping[str, Any]) -> None:
        payload = (stable_json(document) + "\n").encode("utf-8")
        if len(payload) > MAX_JOURNAL_BYTES:
            _fail("budget journal", "serialized journal exceeds the safety limit")
        name = self.temporary_path.name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            fd = os.open(name, flags, 0o600, dir_fd=self._dir_fd)
        except OSError as exc:
            raise ValidationError(f"budget journal: cannot create temporary file: {exc}") from exc
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(fd, payload[offset:])
                if written <= 0:
                    _fail("budget journal", "short write")
                offset += written
            os.fsync(fd)
            self._validate_regular_fd(fd, "budget journal temporary file")
            if self._fault_hook is not None:
                self._fault_hook("after_temporary_fsync")
        finally:
            os.close(fd)
        os.replace(name, self.path.name, src_dir_fd=self._dir_fd, dst_dir_fd=self._dir_fd)
        if self._fault_hook is not None:
            self._fault_hook("after_atomic_replace")
        os.fsync(self._dir_fd)

    def _append(
        self,
        *,
        action: str,
        transaction_id: str,
        identity: Mapping[str, Any],
        actual_cost_microusd: int | None = None,
        actual_metered_tokens: int | None = None,
    ) -> Mapping[str, Any]:
        self._require_open()
        self._reobserve()
        assert self._document is not None
        assert self._state is not None
        revision = int(self._state["revision"]) + 1
        event_without_hash = {
            "revision": revision,
            "previous_head_sha256": self._state["head_sha256"],
            "action": action,
            "transaction_id": transaction_id,
            "identity": identity,
            "actual_cost_microusd": actual_cost_microusd,
            "actual_metered_tokens": actual_metered_tokens,
            "recorded_at_unix_ns": time.time_ns(),
        }
        event = {
            **event_without_hash,
            "event_sha256": _canonical_sha256(event_without_hash),
        }
        updated = {
            **self._document,
            "revision": revision,
            "head_sha256": event["event_sha256"],
            "events": [*self._document["events"], event],
        }
        updated_state = _replay_document(updated)
        self._persist(updated)
        self._document = updated
        self._state = updated_state
        return self.transaction_receipt(transaction_id)

    def _require_open(self) -> None:
        if self._dir_fd < 0 or self._lock_fd < 0 or self._state is None:
            _fail("budget journal", "is not open with an exclusive lock")

    def reserve(self, transaction: BudgetTransaction) -> Mapping[str, Any]:
        self._require_open()
        transaction.validate()
        identity = transaction.record()
        assert self._state is not None
        authority = self._state["authority"]
        for key in ("manifest_sha256", "model_fingerprint", "provider_identity"):
            if identity[key] != authority[key]:
                _fail("budget transaction identity", f"{key} does not match journal authority")
        identity_sha = _canonical_sha256(identity)
        existing_run = [
            item
            for item in self._state["transactions"].values()
            if item["identity"]["run_id"] == identity["run_id"]
            and item["state"] != "aborted_pre_request"
        ]
        if existing_run:
            current = existing_run[-1]
            if current["identity_sha256"] != identity_sha:
                _fail(
                    "budget transaction",
                    "run id is already bound to a different transaction identity; "
                    "use a new explicit run identity instead of retrying",
                )
            if current["state"] == "reserved":
                return self.transaction_receipt(current["transaction_id"])
            if current["state"] == "request_authorized":
                _fail(
                    "budget transaction",
                    "request is already authorized; automatic or implicit retry is forbidden",
                )
            _fail("budget transaction", "run identity is already committed")
        reservation_revision = int(self._state["revision"]) + 1
        transaction_id = _canonical_sha256(
            {
                "journal_id": self._state["journal_id"],
                "reservation_revision": reservation_revision,
                "identity": identity,
            }
        )
        return self._append(
            action="reserved",
            transaction_id=transaction_id,
            identity=identity,
        )

    def authorize_request(
        self,
        transaction_id: str,
        *,
        expected_revision: int,
        expected_head_sha256: str,
    ) -> Mapping[str, Any]:
        current = self._transaction(transaction_id)
        self._require_cas(expected_revision, expected_head_sha256)
        if current["state"] != "reserved":
            if current["state"] == "request_authorized":
                _fail("budget transaction", "authorization already exists; retry is forbidden")
            _fail("budget transaction", "only a reservation may be authorized")
        return self._append(
            action="request_authorized",
            transaction_id=transaction_id,
            identity=current["identity"],
        )

    def commit(
        self,
        transaction_id: str,
        *,
        actual_cost_microusd: int,
        actual_metered_tokens: int,
    ) -> Mapping[str, Any]:
        current = self._transaction(transaction_id)
        actual_cost = _require_integer(actual_cost_microusd, "budget commit.actual_cost_microusd")
        actual_tokens = _require_integer(actual_metered_tokens, "budget commit.actual_metered_tokens")
        if current["state"] == "committed":
            if (
                current["actual_cost_microusd"] == actual_cost
                and current["actual_metered_tokens"] == actual_tokens
            ):
                return self.transaction_receipt(transaction_id)
            _fail("budget transaction", "committed usage may only be replayed identically")
        if current["state"] != "request_authorized":
            _fail("budget transaction", "commit requires request_authorized state")
        return self._append(
            action="committed",
            transaction_id=transaction_id,
            identity=current["identity"],
            actual_cost_microusd=actual_cost,
            actual_metered_tokens=actual_tokens,
        )

    def abort_pre_request(self, transaction_id: str) -> Mapping[str, Any]:
        current = self._transaction(transaction_id)
        if current["state"] == "aborted_pre_request":
            return self.transaction_receipt(transaction_id)
        if current["state"] != "reserved":
            _fail("budget transaction", "authorized or committed requests cannot be aborted")
        return self._append(
            action="aborted_pre_request",
            transaction_id=transaction_id,
            identity=current["identity"],
        )

    def _transaction(self, transaction_id: str) -> Mapping[str, Any]:
        self._require_open()
        _require_hash(transaction_id, "budget transaction id")
        assert self._state is not None
        current = self._state["transactions"].get(transaction_id)
        if current is None:
            _fail("budget transaction", "is unknown")
        return current

    def _require_cas(self, expected_revision: int, expected_head_sha256: str) -> None:
        self._require_open()
        assert self._state is not None
        if (
            expected_revision != self._state["revision"]
            or expected_head_sha256 != self._state["head_sha256"]
        ):
            _fail("budget journal CAS", "revision or head mismatch")

    def transaction_receipt(self, transaction_id: str) -> Mapping[str, Any]:
        self._transaction(transaction_id)
        assert self._state is not None
        return _transaction_receipt_from_state(self._state, transaction_id)

    def transaction_receipts(self) -> Tuple[Mapping[str, Any], ...]:
        """Return every transaction in durable reservation order.

        Callers use this bounded view to detect authorized or committed work
        that has no matching artifact checkpoint.  Returning receipts instead
        of the internal replay table keeps journal mutation encapsulated.
        """

        self._require_open()
        assert self._state is not None
        ordered = sorted(
            self._state["transactions"].values(),
            key=lambda item: int(item["reservation_revision"]),
        )
        return tuple(
            self.transaction_receipt(str(item["transaction_id"]))
            for item in ordered
        )

    def snapshot(self) -> Mapping[str, Any]:
        self._require_open()
        assert self._state is not None
        committed_cost = 0
        committed_tokens = 0
        maximum_cost = 0
        maximum_tokens = 0
        states: Dict[str, int] = {}
        for transaction in self._state["transactions"].values():
            state = transaction["state"]
            states[state] = states.get(state, 0) + 1
            if state == "committed":
                committed_cost += transaction["actual_cost_microusd"]
                committed_tokens += transaction["actual_metered_tokens"]
            elif state in {"reserved", "request_authorized"}:
                maximum_cost += transaction["identity"]["max_cost_microusd"]
                maximum_tokens += transaction["identity"]["max_metered_tokens"]
        return {
            "schema_version": JOURNAL_SCHEMA_VERSION,
            "journal_id": self._state["journal_id"],
            "authority": self._state["authority"],
            "revision": self._state["revision"],
            "head_sha256": self._state["head_sha256"],
            "committed_cost_microusd": committed_cost,
            "committed_metered_tokens": committed_tokens,
            "unsettled_max_cost_microusd": maximum_cost,
            "unsettled_max_metered_tokens": maximum_tokens,
            "exposure_cost_microusd": committed_cost + maximum_cost,
            "exposure_metered_tokens": committed_tokens + maximum_tokens,
            "transaction_states": states,
        }

    def checkpoint_payload(self) -> bytes:
        """Return the current hash-chained document while retaining the lock."""

        self._require_open()
        self._reobserve()
        assert self._document is not None
        return (stable_json(self._document) + "\n").encode("utf-8")
