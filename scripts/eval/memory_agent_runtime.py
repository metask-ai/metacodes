"""Execute frozen memory schedules through the real metacodes agent runtime.

This is deliberately a host-side runner, not a replay synthesizer.  Every row
starts the native ``metacodes`` binary, supplies execution metadata over an
inherited read-only fd, captures native events through an anonymous fd, and
records the provider cassette.  TinyKG arms use a hash-pinned binary and a
fresh store below the owned run directory; the TinyKG skill harness is never
imported or executed.

The built-in provider is a deterministic *lifecycle smoke*.  It drives the real
Markdown Write/Read and TinyKG KgRemember/KgRecall/KgContext tools, including a
fresh-process procedural online-to-offline handoff, and then returns a fixed
negative answer.  It proves execution and durability boundaries at zero paid
cost, but is intentionally not memory-quality evidence.
"""

from __future__ import annotations

import hashlib
import http.server
import json
import math
import os
import platform
import re
import signal
import socketserver
import stat
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, MutableMapping, Sequence, Tuple

from .e2e_adapter import (
    NATIVE_EVENT_SCHEMA_VERSION,
    _native_trace_metrics,
    finalize_evaluation_fd,
)
from .memory_benchmark import PROTOCOL_ID, file_sha256, is_online_memory_case
from .memory_budget_journal import (
    BudgetJournal,
    BudgetTransaction,
    MAX_USER_AUTHORITY_USD,
    validate_checkpoint_payload,
    usd_to_microusd,
    usd_to_microusd_ceiling,
)
from .memory_procedural_adapter import (
    evaluate_workspace,
    validate_validator_bundle,
)
from .memory_query_plan import (
    QUERY_PLAN_INVALID_PREFIX,
    SIDECAR_NAME as QUERY_PLAN_SIDECAR_NAME,
    build_query_plan_trace,
    quality_scoreable_with_pre_search_rejections,
    project_query_variants,
)
from .memory_replay import (
    PRODUCTION_EXECUTION_MODE,
    PRODUCTION_MODEL_ID,
    PRODUCTION_MODEL_PROVIDER,
    PRODUCTION_PRICING_PROVENANCE,
    PRODUCTION_PROVIDER_ID,
    PRODUCTION_ALLOWED_PROVIDER_TOOLS,
    PRODUCTION_DISALLOWED_PROVIDER_TOOLS,
    PRODUCTION_AUTO_COMPACT_POLICY,
    PRODUCTION_CHILD_PATH,
    PRODUCTION_FORCE_COMPACT_AT,
    PRODUCTION_FILESYSTEM_ISOLATION,
    PRODUCTION_RUNNER_SOURCE_MODULES,
    PRODUCTION_SANDBOX_BACKEND,
    PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION,
    PRODUCTION_TOOL_NETWORK_ISOLATION,
    OBSERVATION_SCHEMA_VERSION,
    RUNNER_SOURCE_MODULES,
    _artifact_tree_digest,
    _cassette_memory_activity,
    _cassette_memory_exposure,
    _cassette_scoped_recall_injections,
    _cassette_treatment_activation,
    _cassette_context_cache,
    _summarize_context_cache,
    _validate_production_provider_tool_schema,
    _native_pricing_provenance,
    _path_is_within,
    _production_harness_fingerprint,
    load_manifest,
    replay_observations,
    validate_runtime_artifacts,
    validate_runtime_receipt,
)
from .memory_tinykg_local import (
    LocalTinyKg,
    _batch_bytes,
    _store_info,
    _tree_digest,
    build_case_batch,
)
from .model import ValidationError, stable_json


RUNTIME_RECEIPT_SCHEMA_VERSION = 3
PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION = 9
RUNTIME_METADATA_SCHEMA_VERSION = NATIVE_EVENT_SCHEMA_VERSION
SCRIPTED_PROVIDER_ID = "metacodes-memory-scripted-lifecycle-v3"
SCRIPTED_LIFECYCLE_MODE = "native-agent-loop-scripted-lifecycle-smoke"
PRODUCTION_MODEL_FINGERPRINT = hashlib.sha256(
    stable_json(
        {
            "endpoint": "https://napi.metask-ai.com/v1/messages",
            "model": PRODUCTION_MODEL_ID,
            "protocol": "anthropic-messages-sse",
            "provider": PRODUCTION_MODEL_PROVIDER,
        }
    ).encode("utf-8")
).hexdigest()
PRODUCTION_CREDENTIAL_MAX_BYTES = 4096
PRODUCTION_SANDBOX_EXEC = Path("/usr/bin/sandbox-exec")
PRODUCTION_SYSTEM_READ_ROOTS = (
    Path("/System"),
    Path("/usr"),
    Path("/bin"),
    Path("/sbin"),
    Path("/Library/Apple"),
    Path("/Library/Developer/CommandLineTools"),
    Path("/Library/Preferences"),
    Path("/Library/Keychains"),
    Path("/etc"),
    Path("/var/db"),
    Path("/var/run"),
    Path("/var/select"),
    Path("/private/etc"),
    Path("/private/var/db"),
    Path("/private/var/run"),
    Path("/private/var/select"),
    Path("/dev"),
)
ARM_TO_RUNTIME = {
    "no_memory": "codex_style",
    "codex_style": "codex_style",
    "markdown_memory": "claude_style",
    "claude_style": "claude_style",
    "tinykg_lexical": "tinykg",
    "tinykg": "tinykg",
}
SAFE_STOP_REASONS = frozenset({"end_turn", "max_turns", "tool_loop", "budget"})
HEX64 = re.compile(r"^[0-9a-f]{64}$")
BudgetFaultHook = Callable[[str, Mapping[str, Any]], None]
ROLLOUT_RESUME_CHECKPOINT_SCHEMA = "metacodes-memory-rollout-resume-v1"
ROLLOUT_RESUME_CHECKPOINT_NAME = "rollout-resume-checkpoint.json"
ROLLOUT_RESUME_CHECKPOINT_TEMP_NAME = ".rollout-resume-checkpoint.json.tmp"
MAX_ROLLOUT_RESUME_FILE_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class ProductionRuntimeConfig:
    """Host-only authority and fixed caps for one paid production schedule.

    The API key is deliberately excluded from repr/equality-facing receipts.
    Receipts bind only the public provider/model identity and the budget caps.
    """

    api_key: str = field(repr=False, compare=False)
    allow_paid_rollouts: bool = False
    max_total_cost_usd: float = 0.0
    max_total_metered_tokens: int = 0
    max_rollout_cost_usd: float = 0.0
    max_rollout_metered_tokens: int = 0
    max_output_tokens: int = 4096
    ripgrep_binary: Path | None = None
    ripgrep_binary_sha256: str | None = None

    def validate(self, rollout_count: int) -> None:
        if not self.allow_paid_rollouts:
            _fail("production memory runtime", "requires explicit paid-rollout authority")
        if not isinstance(self.api_key, str) or not self.api_key.strip():
            _fail("production memory runtime", "API credential is unavailable")
        if len(self.api_key.encode("utf-8")) > PRODUCTION_CREDENTIAL_MAX_BYTES:
            _fail("production memory runtime", "API credential exceeds inherited FD limit")
        if not isinstance(rollout_count, int) or isinstance(rollout_count, bool) or rollout_count <= 0:
            _fail("production memory runtime", "rollout count must be positive")
        for name, value in (
            ("max_total_cost_usd", self.max_total_cost_usd),
            ("max_rollout_cost_usd", self.max_rollout_cost_usd),
        ):
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(float(value))
                or float(value) <= 0
            ):
                _fail(f"production memory runtime.{name}", "expected a finite number > 0")
        for name, value in (
            ("max_total_metered_tokens", self.max_total_metered_tokens),
            ("max_rollout_metered_tokens", self.max_rollout_metered_tokens),
            ("max_output_tokens", self.max_output_tokens),
        ):
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                _fail(f"production memory runtime.{name}", "expected an integer > 0")
        if self.max_total_cost_usd > MAX_USER_AUTHORITY_USD:
            _fail(
                "production memory runtime.max_total_cost_usd",
                f"must not exceed ${MAX_USER_AUTHORITY_USD}",
            )
        if self.max_rollout_cost_usd > self.max_total_cost_usd:
            _fail("production memory runtime", "rollout cost cap exceeds total cost cap")
        if self.max_rollout_metered_tokens > self.max_total_metered_tokens:
            _fail("production memory runtime", "rollout token cap exceeds total token cap")
        if self.ripgrep_binary is None or self.ripgrep_binary_sha256 is None:
            _fail("production memory runtime", "requires a pinned ripgrep binary")
        if not HEX64.fullmatch(self.ripgrep_binary_sha256):
            _fail("production memory runtime.ripgrep_binary_sha256", "expected SHA-256")
        _assert_executable_identity(
            self.ripgrep_binary,
            self.ripgrep_binary_sha256,
            "production ripgrep binary",
        )
        # Strict inequality preserves one fail-closed unit of headroom: reaching
        # either hard cap is a terminal budget event, not a successful schedule.
        if self.max_rollout_cost_usd * rollout_count >= self.max_total_cost_usd:
            _fail(
                "production memory runtime",
                "total cost cap does not strictly cover every fixed rollout cap",
            )
        if self.max_rollout_metered_tokens * rollout_count >= self.max_total_metered_tokens:
            _fail(
                "production memory runtime",
                "total token cap does not strictly cover every fixed rollout cap",
            )

    def public_budget(self) -> Mapping[str, Any]:
        return {
            "max_total_cost_usd": float(self.max_total_cost_usd),
            "max_total_metered_tokens": self.max_total_metered_tokens,
            "max_rollout_cost_usd": float(self.max_rollout_cost_usd),
            "max_rollout_metered_tokens": self.max_rollout_metered_tokens,
            "max_output_tokens": self.max_output_tokens,
        }


@dataclass(frozen=True)
class ProductionSandbox:
    profile_path: Path
    profile_sha256: str

    def command(self, command: Sequence[str]) -> List[str]:
        return [str(PRODUCTION_SANDBOX_EXEC), "-f", str(self.profile_path), *command]


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _hash_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _hash_text(value: str) -> str:
    return _hash_bytes(value.encode("utf-8"))


def _verify_scoped_recall_activation(
    native: Mapping[str, Any],
    cassette: Path,
    prompt: str,
    *,
    tinykg_enabled: bool,
    where: str,
) -> Mapping[str, Any] | None:
    raw_receipts = native.get("scoped_recalls")
    if not isinstance(raw_receipts, list):
        _fail(where, "native trace omitted scoped recall evidence collection")
    injections = _cassette_scoped_recall_injections(cassette, where)
    if not tinykg_enabled:
        if raw_receipts or injections:
            _fail(where, "non-TinyKG arm exposed scoped recall evidence")
        return None
    if len(raw_receipts) != 1:
        _fail(where, f"expected one native scoped recall receipt, observed {len(raw_receipts)}")
    receipt = raw_receipts[0]
    if not isinstance(receipt, dict):
        _fail(where, "scoped recall receipt is not an object")
    if receipt.get("query_sha256") != _hash_bytes(prompt.encode("utf-8")[:400]):
        _fail(where, "scoped recall query does not bind the rollout prompt")
    status = receipt.get("status")
    if status == "injected":
        if len(injections) != 1:
            _fail(where, f"native injection requires one provider block, observed {len(injections)}")
        payload = injections[0]
        injected_count = receipt.get("injected_count")
        if (
            receipt.get("injected_bytes") != len(payload)
            or receipt.get("injection_sha256") != _hash_bytes(payload)
            or not isinstance(injected_count, int)
            or isinstance(injected_count, bool)
            or injected_count < 1
        ):
            _fail(where, "native scoped recall commitment does not match provider bytes")
    elif injections:
        _fail(where, "provider received a scoped recall block without an injected receipt")
    return dict(receipt)


def _host_recall_covers_missing_explicit_recall(
    scoped_recall: Mapping[str, Any] | None,
    query_plan_trace: Mapping[str, Any],
) -> bool:
    """A completed host lookup makes a duplicate model KgRecall optional.

    `no_hits` is still an observed, successful lookup result.  It is the
    expected online state before the first episode is consolidated; treating
    it as a query-plan failure erases the real deterministic validator outcome
    and makes the consolidation receipt unverifiable.  `search_error` remains
    invalid and therefore cannot launder an unavailable TinyKG treatment.
    """

    return bool(
        scoped_recall is not None
        and scoped_recall.get("status") in {"injected", "no_hits"}
        and query_plan_trace.get("invalid_reasons")
        == ["TinyKG backend executed no KgRecall"]
    )


def _query_plan_evaluator_invalid_reason(
    scoped_recall: Mapping[str, Any] | None,
    query_plan_trace: Mapping[str, Any],
) -> str | None:
    """Return a treatment-invalid reason without erasing safe recovery.

    The query-plan trace remains the protocol-health authority.  This function
    answers the narrower quality-evaluation question: did the run retain a
    host-verified evidence path after any pre-search rejection?  Keeping this
    decision in one function makes the production runner and its L2 test share
    the same boundary.
    """

    if query_plan_trace["status"] != "invalid":
        return None
    if _host_recall_covers_missing_explicit_recall(scoped_recall, query_plan_trace):
        return None
    if quality_scoreable_with_pre_search_rejections(query_plan_trace):
        return None
    return QUERY_PLAN_INVALID_PREFIX + "; ".join(
        str(reason) for reason in query_plan_trace["invalid_reasons"]
    )


def _safe_component(value: str) -> str:
    # Artifact paths are visible to the model through cwd, memory instructions,
    # and METACODES_KG_STORE. Never leak arm labels such as "tinykg" or
    # "no_memory" into those paths; treatment identity belongs only in the
    # host-owned schedule/receipt.
    return f"run-{_hash_text(value)[:20]}"


def _inside(child: Path, parent: Path, where: str) -> Path:
    resolved_child = child.expanduser().resolve()
    resolved_parent = parent.expanduser().resolve()
    try:
        resolved_child.relative_to(resolved_parent)
    except ValueError as exc:
        raise ValidationError(f"{where}: path escapes the owned run directory") from exc
    return resolved_child


def _write_new(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        raise ValidationError(f"cannot create fresh runtime artifact {path}: {exc}") from exc
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    finally:
        os.close(fd)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _private_regular_payload(path: Path, where: str) -> bytes:
    """Read and validate identity through one no-follow descriptor."""

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise ValidationError(f"{where}: cannot open private file: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            _fail(where, "expected a regular file")
        if info.st_nlink != 1:
            _fail(where, "hard links are forbidden")
        if os.name != "nt" and stat.S_IMODE(info.st_mode) & 0o077:
            _fail(where, "permissions must be 0600 or stricter")
        if info.st_size <= 0 or info.st_size > MAX_ROLLOUT_RESUME_FILE_BYTES:
            _fail(where, "file is empty or exceeds the resume safety limit")
        chunks: List[bytes] = []
        observed = 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, MAX_ROLLOUT_RESUME_FILE_BYTES + 1 - observed))
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
            observed += len(chunk)
            if observed > MAX_ROLLOUT_RESUME_FILE_BYTES:
                _fail(where, "file exceeds the resume safety limit")
    except OSError as exc:
        raise ValidationError(f"{where}: cannot read private file: {exc}") from exc
    finally:
        os.close(fd)


def _replace_private_file(path: Path, payload: bytes) -> None:
    """Durably replace one private file, leaving a detectable temp on failure."""

    temporary = path.with_name(ROLLOUT_RESUME_CHECKPOINT_TEMP_NAME)
    if temporary.exists() or temporary.is_symlink():
        _fail("rollout resume checkpoint", "incomplete temporary file requires inspection")
    if path.exists() or path.is_symlink():
        _private_regular_payload(path, "rollout resume checkpoint")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = -1
    try:
        fd = os.open(temporary, flags, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            _fail("rollout resume checkpoint temporary file", "identity changed")
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)


def _write_failed_validation_checkpoint(
    run_dir: Path,
    *,
    observations_payload: bytes,
    receipt: Mapping[str, Any],
    error: BaseException,
    budget_journal_receipt: Mapping[str, Any] | None,
) -> Mapping[str, Any]:
    failed_observations = run_dir / "failed-validation-observations.jsonl"
    failed_receipt = run_dir / "failed-validation-runtime-candidate.json"
    failure_identity = {
        "schema_version": "metacodes-memory-runtime-validation-failure-v1",
        "status": "invalid",
        "classification": "post-run-runtime-receipt-validation",
        "error_type": type(error).__name__,
        "error_sha256": hashlib.sha256(str(error).encode("utf-8")).hexdigest(),
    }
    failed_receipt_payload = (
        stable_json(
            {
                **failure_identity,
                # Deliberately wrapped: this file cannot masquerade as a
                # canonical runtime receipt after a future validator change,
                # but the paid candidate remains recoverable.
                "candidate_runtime_receipt": receipt,
            }
        )
        + "\n"
    ).encode("utf-8")
    _write_new(failed_observations, observations_payload)
    _write_new(failed_receipt, failed_receipt_payload)
    diagnostic = {
        **failure_identity,
        "observations_file": failed_observations.name,
        "observations_sha256": _hash_bytes(observations_payload),
        "runtime_candidate_file": failed_receipt.name,
        "runtime_candidate_sha256": _hash_bytes(failed_receipt_payload),
        "budget_journal_revision": (
            budget_journal_receipt["revision"]
            if budget_journal_receipt is not None
            else None
        ),
        "budget_journal_head_sha256": (
            budget_journal_receipt["head_sha256"]
            if budget_journal_receipt is not None
            else None
        ),
    }
    _write_new(
        run_dir / "failed-validation-diagnostic.json",
        (stable_json(diagnostic) + "\n").encode("utf-8"),
    )
    return diagnostic


def _child_failure_diagnostic(
    *,
    run_id: str,
    returncode: int,
    stdout: str,
    stderr: str,
    budget_transaction: Mapping[str, Any] | None,
) -> Mapping[str, Any]:
    signal_number = -returncode if returncode < 0 else None
    signal_name = None
    if signal_number is not None:
        try:
            signal_name = signal.Signals(signal_number).name
        except ValueError:
            signal_name = f"SIGNAL_{signal_number}"
    stdout_bytes = stdout.encode("utf-8")
    stderr_bytes = stderr.encode("utf-8")
    return {
        "schema_version": 1,
        "run_id": run_id,
        "returncode": returncode,
        "exit_code": returncode if returncode >= 0 else None,
        "signal": signal_number,
        "signal_name": signal_name,
        "stdout_bytes": len(stdout_bytes),
        "stdout_sha256": _hash_bytes(stdout_bytes),
        "stderr_bytes": len(stderr_bytes),
        "stderr_sha256": _hash_bytes(stderr_bytes),
        # This is evidence of authorization exposure, never a commit receipt.
        "budget_transaction": budget_transaction,
    }


def _child_failure_message(returncode: int) -> str:
    if returncode >= 0:
        return f"process exited {returncode}"
    signal_number = -returncode
    try:
        name = signal.Signals(signal_number).name
    except ValueError:
        name = f"signal {signal_number}"
    return f"process terminated by {name} ({signal_number})"


def _read_regular_file(path: Path, where: str) -> bytes:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise ValidationError(f"{where}: cannot open regular file: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            _fail(where, "expected a regular file")
        chunks: List[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    except OSError as exc:
        raise ValidationError(f"{where}: cannot read regular file: {exc}") from exc
    finally:
        os.close(fd)


def _assert_tinykg_read_transients_clean(store: Path, where: str) -> None:
    """Reject leaked or attacker-shaped TinyKG read coordination state."""

    spelled_store = store.expanduser().absolute()
    store_info = spelled_store.lstat()
    if stat.S_ISLNK(store_info.st_mode) or not stat.S_ISDIR(store_info.st_mode):
        _fail(where, "store must be a real directory")
    resolved_store = spelled_store.resolve(strict=True)
    lock_path = resolved_store / ".tinykg-cli.lock"
    try:
        lock_path.lstat()
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise ValidationError(f"{where}: cannot inspect TinyKG CLI lock: {exc}") from exc
    else:
        _fail(where, "TinyKG CLI lock was not released")
    lease_dir = resolved_store / ".tinykg_leases"
    try:
        lease_info = lease_dir.lstat()
    except OSError as exc:
        raise ValidationError(f"{where}: TinyKG lease directory is unavailable: {exc}") from exc
    if stat.S_ISLNK(lease_info.st_mode) or not stat.S_ISDIR(lease_info.st_mode):
        _fail(where, "TinyKG lease path must be a real directory")
    try:
        leaked = sorted(entry.name for entry in lease_dir.iterdir())
    except OSError as exc:
        raise ValidationError(f"{where}: cannot inspect TinyKG leases: {exc}") from exc
    if leaked:
        _fail(where, f"TinyKG read lease was not released: {leaked[:3]}")


def _prepare_tinykg_read_transients(store: Path) -> None:
    """Materialize stable empty read coordination state before store hashing."""

    spelled_store = store.expanduser().absolute()
    store_info = spelled_store.lstat()
    if stat.S_ISLNK(store_info.st_mode) or not stat.S_ISDIR(store_info.st_mode):
        _fail("TinyKG read transients", "store must be a real directory")
    resolved_store = spelled_store.resolve(strict=True)
    lease_dir = resolved_store / ".tinykg_leases"
    try:
        lease_dir.mkdir(mode=0o700)
    except FileExistsError:
        pass
    except OSError as exc:
        raise ValidationError(
            f"TinyKG read transients: cannot create lease directory: {exc}"
        ) from exc
    _assert_tinykg_read_transients_clean(resolved_store, "TinyKG read transients")


def _secret_encodings(secret: str) -> Tuple[bytes, ...]:
    """Representations that may appear in raw or JSON-encoded artifacts."""

    raw = secret.encode("utf-8")
    escaped = json.dumps(secret, ensure_ascii=False)[1:-1].encode("utf-8")
    return tuple(dict.fromkeys((raw, escaped)))


def _assert_production_secret_absent(
    artifact_root: Path,
    secret: str,
    *,
    pending_payloads: Sequence[Tuple[str, bytes]] = (),
) -> None:
    """Fail closed if a production credential reached any durable artifact.

    The scan runs before observations/receipt publication and covers the whole
    owned run tree, not only the artifacts currently named by the receipt. This
    catches stdout/stderr, cassette, transcript, workspace, Markdown memory,
    TinyKG bytes, and unexpected files created by a model tool call.
    """

    if not isinstance(secret, str) or not secret:
        _fail("production secret scan", "credential is unavailable")
    needles = _secret_encodings(secret)

    def check(label: str, payload: bytes) -> None:
        if any(needle and needle in payload for needle in needles):
            _fail("production secret scan", f"credential leaked into {label}")

    try:
        root_info = artifact_root.lstat()
        if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
            _fail("production secret scan", "artifact root must be a real directory")
        for path in sorted(artifact_root.rglob("*")):
            relative = path.relative_to(artifact_root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                _fail("production secret scan", f"symlink is forbidden: {relative!r}")
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                _fail("production secret scan", f"non-regular artifact: {relative!r}")
            if info.st_nlink != 1:
                _fail("production secret scan", f"hard-linked artifact: {relative!r}")
            check(relative, _read_regular_file(path, f"production secret scan {relative!r}"))
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError(f"production secret scan: cannot re-observe artifacts: {exc}") from exc
    for label, payload in pending_payloads:
        check(label, payload)


def _load_json_payload(payload: bytes, label: str) -> Mapping[str, Any]:
    def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(label, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(payload.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except ValidationError:
        raise
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot parse {label}: {exc}") from exc
    if not isinstance(value, dict):
        _fail(label, "expected an object")
    return value


def _load_json(path: Path, label: str) -> Mapping[str, Any]:
    return _load_json_payload(_read_regular_file(path, label), label)


def _xxhash64(data: bytes, seed: int = 0) -> int:
    """Small dependency-free XXH64 implementation matching Zig XxHash64."""

    mask = (1 << 64) - 1
    p1, p2 = 11400714785074694791, 14029467366897019727
    p3, p4, p5 = 1609587929392839161, 9650029242287828579, 2870177450012600261

    def rotl(value: int, bits: int) -> int:
        return ((value << bits) | (value >> (64 - bits))) & mask

    def lane(value: int, word: int) -> int:
        value = (value + word * p2) & mask
        value = rotl(value, 31)
        return (value * p1) & mask

    length = len(data)
    offset = 0
    if length >= 32:
        v1 = (seed + p1 + p2) & mask
        v2 = (seed + p2) & mask
        v3 = seed & mask
        v4 = (seed - p1) & mask
        limit = length - 32
        while offset <= limit:
            v1 = lane(v1, int.from_bytes(data[offset : offset + 8], "little"))
            v2 = lane(v2, int.from_bytes(data[offset + 8 : offset + 16], "little"))
            v3 = lane(v3, int.from_bytes(data[offset + 16 : offset + 24], "little"))
            v4 = lane(v4, int.from_bytes(data[offset + 24 : offset + 32], "little"))
            offset += 32
        value = (rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18)) & mask
        for item in (v1, v2, v3, v4):
            mixed = lane(0, item)
            value ^= mixed
            value = (value * p1 + p4) & mask
    else:
        value = (seed + p5) & mask
    value = (value + length) & mask
    while offset + 8 <= length:
        mixed = lane(0, int.from_bytes(data[offset : offset + 8], "little"))
        value ^= mixed
        value = (rotl(value, 27) * p1 + p4) & mask
        offset += 8
    if offset + 4 <= length:
        value ^= (int.from_bytes(data[offset : offset + 4], "little") * p1) & mask
        value &= mask
        value = (rotl(value, 23) * p2 + p3) & mask
        offset += 4
    while offset < length:
        value ^= (data[offset] * p5) & mask
        value &= mask
        value = (rotl(value, 11) * p1) & mask
        offset += 1
    value ^= value >> 33
    value = (value * p2) & mask
    value ^= value >> 29
    value = (value * p3) & mask
    value ^= value >> 32
    return value & mask


def _project_domain(project_root: Path) -> str:
    resolved = str(project_root.resolve())
    return f"{project_root.name or 'root'}-{_xxhash64(resolved.encode('utf-8')):016x}"[: len(project_root.name or 'root') + 9]


def _memory_dir(home: Path, workspace: Path) -> Path:
    """Mirror the product memdir derived from the actual process cwd."""

    cwd_hash = f"{_xxhash64(str(workspace.resolve()).encode('utf-8')):016x}"
    return home / ".metacodes" / "projects" / cwd_hash / "memory"


def _copy_memory_tree(source: Path, target: Path) -> None:
    """Copy a small durable-memory tree without following links or overwriting.

    The source may ultimately contain model-authored files, so a normal
    ``copytree`` is too permissive: a symlink must never escape the owned run
    directory or become a different artifact on replay.
    """

    if not source.is_dir() or source.is_symlink():
        _fail("markdown memory state", "source must be a real directory")
    source_root = source.resolve()
    target_root = target.resolve(strict=False)
    if source_root == target_root or source_root in target_root.parents or target_root in source_root.parents:
        _fail("markdown memory state", "source and target must not overlap")
    if target.exists() and (target.is_symlink() or not target.is_dir()):
        _fail("markdown memory state", "target must be a real directory")
    target.mkdir(parents=True, exist_ok=True)
    if any(target.iterdir()):
        _fail("markdown memory state", "target must be empty")
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            _fail("markdown memory state", f"symlink is forbidden: {relative.as_posix()!r}")
        destination = target / relative
        if stat.S_ISDIR(info.st_mode):
            destination.mkdir()
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink != 1:
                _fail(
                    "markdown memory state",
                    f"hard-linked file is forbidden: {relative.as_posix()!r}",
                )
            _write_new(
                destination,
                _read_regular_file(path, f"markdown memory state {relative.as_posix()!r}"),
            )
        else:
            _fail("markdown memory state", f"unsupported entry: {relative.as_posix()!r}")


def _public_memory_document(public_case: Mapping[str, Any]) -> str:
    payload = stable_json(public_case)
    marker = f"public-memory-sha256:{_hash_text(payload)}"
    return (
        "---\n"
        "name: benchmark-public-memory\n"
        "description: Public benchmark context; contains no hidden gold labels.\n"
        "metadata:\n  type: project\n"
        "---\n\n"
        f"# Public benchmark memory\n\n{marker}\n\n"
        f"```json\n{payload}\n```\n"
    )


def _seed_public_markdown_memory(
    memory_dir: Path,
    public_case: Mapping[str, Any],
) -> Tuple[Path, str]:
    memory_dir.mkdir(parents=True, exist_ok=True)
    document = _public_memory_document(public_case)
    marker = f"public-memory-sha256:{_hash_text(stable_json(public_case))}"
    corpus = memory_dir / "benchmark-public-memory.md"
    index = memory_dir / "MEMORY.md"
    _write_new(corpus, document.encode("utf-8"))
    _write_new(
        index,
        b"- [Benchmark public memory](benchmark-public-memory.md) -- public corpus for this case\n",
    )
    return corpus, marker


def _agent_batch(
    batch: bytes,
    logical_ids: Mapping[int, str],
    root_node_id: int,
    domain: str,
) -> Tuple[bytes, Dict[int, str], int, Mapping[str, int]]:
    """Add the exact project-containment root used by KgClient recall."""

    records = [json.loads(line) for line in batch.decode("utf-8").splitlines() if line]
    if not records or records[0] != {"version": 1}:
        _fail("memory agent TinyKG batch", "invalid version header")
    nodes: List[Mapping[str, Any]] = []
    edges: List[Mapping[str, Any]] = []
    for record in records[1:]:
        shifted = dict(record)
        if shifted.get("op") == "node":
            shifted["id"] = int(shifted["id"]) + 1
            nodes.append(shifted)
        elif shifted.get("op") == "edge":
            shifted["id"] = int(shifted["id"]) + 1
            shifted["src"] = int(shifted["src"]) + 1
            shifted["dst"] = int(shifted["dst"]) + 1
            edges.append(shifted)
        else:
            _fail("memory agent TinyKG batch", "unsupported record")
    project = {"op": "node", "id": 1, "kind": "project", "name": domain}
    next_edge = max((int(edge["id"]) for edge in edges), default=0) + 1
    containment: List[Mapping[str, Any]] = []
    for node in nodes:
        containment.append(
            {"op": "edge", "id": next_edge, "src": 1, "rel": "contain", "dst": node["id"]}
        )
        next_edge += 1
    shifted_logical = {node_id + 1: value for node_id, value in logical_ids.items()}
    counts = {
        "nodes": 1 + len(nodes),
        "edges": len(edges) + len(containment),
        "abstraction_nodes": sum(node.get("kind") == "concept" for node in nodes),
    }
    return _batch_bytes([project, *nodes], [*edges, *containment]), shifted_logical, root_node_id + 1, counts


def _empty_project_batch(domain: str) -> bytes:
    return _batch_bytes(
        [{"op": "node", "id": 1, "kind": "project", "name": domain}],
        [],
    )


def _text_sse(text: str, request_id: int) -> bytes:
    events = [
        {
            "type": "message_start",
            "message": {
                "id": f"smoke-{request_id}",
                "role": "assistant",
                "model": SCRIPTED_PROVIDER_ID,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            },
        },
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""},
        },
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": text},
        },
        {"type": "content_block_stop", "index": 0},
        {
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 1},
        },
        {"type": "message_stop"},
    ]
    return "".join(
        f"data: {json.dumps(event, ensure_ascii=False, separators=(',', ':'))}\n\n"
        for event in events
    ).encode("utf-8")


def _tool_sse(tools: Sequence[Tuple[str, str, Mapping[str, Any]]], request_id: int) -> bytes:
    events: List[Mapping[str, Any]] = [
        {
            "type": "message_start",
            "message": {
                "id": f"smoke-{request_id}",
                "role": "assistant",
                "model": SCRIPTED_PROVIDER_ID,
                "usage": {"input_tokens": 1, "output_tokens": 1},
            },
        }
    ]
    for index, (tool_id, name, tool_input) in enumerate(tools):
        raw_input = stable_json(tool_input)
        events.extend(
            [
                {
                    "type": "content_block_start",
                    "index": index,
                    "content_block": {
                        "type": "tool_use",
                        "id": tool_id,
                        "name": name,
                        "input": {},
                    },
                },
                {
                    "type": "content_block_delta",
                    "index": index,
                    "delta": {
                        "type": "input_json_delta",
                        "partial_json": raw_input,
                    },
                },
                {"type": "content_block_stop", "index": index},
            ]
        )
    events.extend(
        [
            {
                "type": "message_delta",
                "delta": {"stop_reason": "tool_use"},
                "usage": {"output_tokens": max(1, len(tools))},
            },
            {"type": "message_stop"},
        ]
    )
    return "".join(
        f"data: {json.dumps(event, ensure_ascii=False, separators=(',', ':'))}\n\n"
        for event in events
    ).encode("utf-8")


def _tool_results(body: Mapping[str, Any]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    messages = body.get("messages")
    if not isinstance(messages, list):
        return result
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_result":
                continue
            tool_id = item.get("tool_use_id")
            value = item.get("content")
            if isinstance(tool_id, str) and isinstance(value, str):
                result[tool_id] = value
    return result


class _ScriptedPlanner:
    def __init__(
        self,
        prompt: str,
        runtime_arm: str,
        benchmark: str,
        split: str,
        *,
        memory_file: Path | None,
        memory_index: Path | None,
        memory_marker: str | None,
    ) -> None:
        self.prompt = prompt
        self.runtime_arm = runtime_arm
        self.benchmark = benchmark
        self.split = split
        self.memory_file = memory_file
        self.memory_index = memory_index
        self.memory_marker = memory_marker
        self.memory_verified = False
        if runtime_arm == "tinykg":
            self.stage = "kg_remember" if benchmark == "procedural_transfer" and split == "online" else "kg_recall"
        elif runtime_arm == "claude_style":
            self.stage = "markdown_write" if benchmark == "procedural_transfer" and split == "online" else "markdown_read"
        else:
            self.stage = "final"

    def response(self, body: Mapping[str, Any], request_id: int) -> bytes:
        results = _tool_results(body)
        if self.stage == "markdown_write":
            if self.memory_file is None or self.memory_index is None or self.memory_marker is None:
                raise ValueError("markdown online phase is missing its durable memory paths")
            self.stage = "final"
            memory_text = (
                "---\nname: benchmark-procedural-pattern\n"
                "description: Procedure learned during the online member of a frozen intent family.\n"
                "metadata:\n  type: project\n---\n\n"
                f"{self.memory_marker}\n"
            )
            return _tool_sse(
                [
                    (
                        "markdown-memory-1",
                        "Write",
                        {"file_path": str(self.memory_file), "content": memory_text},
                    ),
                    (
                        "markdown-index-1",
                        "Write",
                        {
                            "file_path": str(self.memory_index),
                            "content": "- [Procedural pattern](benchmark-procedural-pattern.md) -- frozen online intent-family lesson\n",
                        },
                    ),
                ],
                request_id,
            )
        if self.stage == "markdown_read":
            if self.memory_file is None or self.memory_marker is None:
                raise ValueError("markdown read phase is missing its durable memory artifact")
            self.stage = "markdown_verify"
            return _tool_sse(
                [("markdown-read-1", "Read", {"file_path": str(self.memory_file)})],
                request_id,
            )
        if self.stage == "markdown_verify":
            raw = results.get("markdown-read-1", "")
            if self.memory_marker not in raw:
                raise ValueError("fresh-process Markdown read did not expose the expected marker")
            self.memory_verified = True
            self.stage = "final"
        if self.stage == "kg_remember":
            if self.memory_marker is None:
                raise ValueError("TinyKG online phase is missing its durable marker")
            self.stage = "kg_recall"
            return _tool_sse(
                [
                    (
                        "kg-remember-1",
                        "KgRemember",
                        {"text": self.memory_marker, "kind": "observation", "scope": "project"},
                    )
                ],
                request_id,
            )
        if self.stage == "kg_recall":
            query_source = self.memory_marker if self.memory_marker is not None else self.prompt
            query = " ".join(query_source.split())
            if len(query.encode("utf-8")) > 400:
                query = query.encode("utf-8")[:400].decode("utf-8", errors="ignore").rstrip()
            if not query:
                raise ValueError("TinyKG scripted recall has no compact lexical query")
            self.stage = "kg_context"
            intent = {
                "procedural_transfer": "procedure_reuse",
                "multihop_retrieval": "causal",
                "episodic_recall": "temporal",
            }.get(self.benchmark, "fact_lookup")
            return _tool_sse(
                [
                    (
                        "kg-recall-1",
                        "KgRecall",
                        {
                            "query": query,
                            "lexical_plan": {
                                "schema_version": "lexical-query-plan-v1",
                                "intent": intent,
                                "stage": "seed",
                                "variants": [{"kind": "exact", "text": query}],
                                "variant_index": 0,
                                "seen_node_ids": [],
                            },
                        },
                    )
                ],
                request_id,
            )
        if self.stage == "kg_context":
            raw = results.get("kg-recall-1", "")
            node_id = None
            try:
                parsed = json.loads(raw)
                hits = parsed.get("hits") if isinstance(parsed, dict) else None
                if isinstance(hits, list) and hits and isinstance(hits[0], dict):
                    node_id = hits[0].get("node_id")
            except json.JSONDecodeError:
                pass
            if isinstance(node_id, int) and not isinstance(node_id, bool):
                self.stage = "kg_verify"
                return _tool_sse(
                    [("kg-context-1", "KgContext", {"node_id": node_id, "limit": 12})],
                    request_id,
                )
            self.stage = "final"
        if self.stage == "kg_verify":
            raw = results.get("kg-context-1", "")
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ValueError("KgContext did not return JSON") from exc
            if not isinstance(parsed, dict) or parsed.get("kg_unavailable") is True:
                raise ValueError("KgContext did not return an available bounded packet")
            if self.memory_marker is not None and self.memory_marker not in raw:
                raise ValueError("KgContext did not expose the expected durable marker")
            self.memory_verified = True
            self.stage = "final"
        return _text_sse("runtime-smoke", request_id)


class ScriptedMemoryProvider:
    """Loopback-only deterministic Anthropic SSE provider for native L2."""

    def __init__(
        self,
        prompt: str,
        runtime_arm: str,
        benchmark: str,
        split: str,
        *,
        memory_file: Path | None,
        memory_index: Path | None,
        memory_marker: str | None,
    ) -> None:
        self.planner = _ScriptedPlanner(
            prompt,
            runtime_arm,
            benchmark,
            split,
            memory_file=memory_file,
            memory_index=memory_index,
            memory_marker=memory_marker,
        )
        self.requests: List[Mapping[str, Any]] = []
        self._server: socketserver.TCPServer | None = None
        self._thread: threading.Thread | None = None
        self.port: int | None = None

    def __enter__(self) -> "ScriptedMemoryProvider":
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
                try:
                    length = int(self.headers.get("content-length", "0"))
                    if length < 0 or length > 16 * 1024 * 1024:
                        raise ValueError("request exceeds scripted-provider cap")
                    raw = self.rfile.read(length)
                    body = json.loads(raw)
                    if not isinstance(body, dict):
                        raise ValueError("request must be an object")
                    outer.requests.append(body)
                    response = outer.planner.response(body, len(outer.requests))
                except (UnicodeError, json.JSONDecodeError, ValueError):
                    self.send_response(400)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                try:
                    self.wfile.write(response)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

        socketserver.TCPServer.allow_reuse_address = True
        self._server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        self.port = int(self._server.server_address[1])
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="memory-scripted-provider",
            daemon=True,
        )
        self._thread.start()
        return self

    @property
    def url(self) -> str:
        if self.port is None:
            raise RuntimeError("scripted provider has not started")
        return f"http://127.0.0.1:{self.port}/v1/messages"

    def __exit__(self, *_args: Any) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)


def _public_procedural_cases(source: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    result: Dict[str, Mapping[str, Any]] = {}
    families = source.get("families")
    if not isinstance(families, list):
        return result
    for family in families:
        if not isinstance(family, dict) or not isinstance(family.get("cases"), list):
            continue
        for case in family["cases"]:
            if isinstance(case, dict) and isinstance(case.get("id"), str):
                result[case["id"]] = {
                    **case,
                    "_family_id": family.get("id"),
                    "_procedure_evidence_id": family.get("procedure_evidence_id"),
                }
    return result


def _materialize_workspace(case: Mapping[str, Any], workspace: Path) -> Dict[str, str]:
    raw_workspace = case.get("workspace")
    files = raw_workspace.get("files") if isinstance(raw_workspace, dict) else None
    if not isinstance(files, list) or not files:
        _fail("procedural public workspace", "missing files")
    baseline: Dict[str, str] = {}
    for index, item in enumerate(files):
        if not isinstance(item, dict):
            _fail("procedural public workspace", f"files[{index}] is not an object")
        relative = item.get("path")
        content = item.get("content")
        expected = item.get("sha256")
        if not isinstance(relative, str) or not isinstance(content, str) or not isinstance(expected, str):
            _fail("procedural public workspace", f"files[{index}] is incomplete")
        target = (workspace / relative).resolve()
        _inside(target, workspace, "procedural workspace file")
        if _hash_text(content) != expected:
            _fail("procedural public workspace", f"files[{index}] content hash mismatch")
        _write_new(target, content.encode("utf-8"))
        baseline[relative] = content
    return baseline


def _read_workspace(workspace: Path, baseline: Mapping[str, str]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for relative in baseline:
        target = _inside(workspace / relative, workspace, "procedural workspace result")
        try:
            info = target.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_size > 16 * 1024 * 1024:
                _fail("procedural workspace result", f"invalid file {relative!r}")
            result[relative] = target.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as exc:
            raise ValidationError(f"cannot read procedural result {relative!r}: {exc}") from exc
    return result


def _parse_result(stdout: str) -> Mapping[str, Any]:
    rows: List[Mapping[str, Any]] = []
    for line in stdout.splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"native metacodes stdout is not NDJSON: {exc}") from exc
        if isinstance(value, dict) and value.get("type") == "result":
            rows.append(value)
    if len(rows) != 1:
        _fail("native metacodes stdout", f"expected exactly one result row, observed {len(rows)}")
    result = rows[0]
    legacy_fields = {
        "type",
        "stop_reason",
        "turns",
        "tool_calls",
        "input_tokens",
        "output_tokens",
        "cost_usd",
        "text",
    }
    cache_fields = {"cache_read_input_tokens", "cache_creation_input_tokens"}
    observed_fields = set(result)
    if observed_fields == legacy_fields:
        # Historical receipts predate public cache telemetry. Preserve replay
        # compatibility without accepting a partially upgraded schema.
        result = dict(result)
        result.update({key: 0 for key in cache_fields})
    elif observed_fields != legacy_fields | cache_fields:
        expected = legacy_fields | cache_fields
        _fail(
            "native metacodes result",
            f"unexpected fields: {sorted(observed_fields ^ expected)}",
        )
    if not isinstance(result["stop_reason"], str) or not result["stop_reason"]:
        _fail("native metacodes result.stop_reason", "expected non-empty string")
    for key in (
        "turns",
        "tool_calls",
        "input_tokens",
        "output_tokens",
        "cache_read_input_tokens",
        "cache_creation_input_tokens",
    ):
        value = result[key]
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            _fail(f"native metacodes result.{key}", "expected non-negative integer")
    cost = result["cost_usd"]
    if (
        not isinstance(cost, (int, float))
        or isinstance(cost, bool)
        or not math.isfinite(float(cost))
        or float(cost) < 0
    ):
        _fail("native metacodes result.cost_usd", "expected finite non-negative number")
    if not isinstance(result["text"], str):
        _fail("native metacodes result.text", "expected string")
    return result


def _estimated_costs_match(metric_cost: float, result_cost: float) -> bool:
    """Compare independent runtime totals at the journal's micro-USD precision."""

    if (
        not math.isfinite(metric_cost)
        or not math.isfinite(result_cost)
        or metric_cost < 0
        or result_cost < 0
    ):
        return False
    # Native usage events retain sub-micro-USD components while the public
    # result is rendered to six decimal places.  The durable ledger accounts
    # in whole micro-USD, so a difference within one ledger unit is equivalent;
    # the more precise event total remains authoritative for charging.
    return usd_to_microusd_ceiling(abs(metric_cost - result_cost)) <= 1


def _cassette_tool_data(
    cassette: Path,
    logical_ids: Mapping[int, str],
    fallback_query: str,
    *,
    memory_dir: Path | None = None,
) -> Mapping[str, Any]:
    query_variants: List[Mapping[str, str]] = []
    normalized_queries: set[str] = set()

    def append_query_variant(text: str) -> None:
        # A failed/denied KgRecall still belongs in the audit trace, but its
        # model-supplied lexical plan can repeat the same text under both the
        # exact and semantic slots.  Keep the first occurrence so an invalid
        # recall remains a row-level invalid outcome instead of poisoning the
        # whole post-run observation join.
        normalized = " ".join(text.casefold().split())
        if not normalized or normalized in normalized_queries:
            return
        normalized_queries.add(normalized)
        query_variants.append(
            {"kind": "exact" if not query_variants else "semantic", "text": text}
        )

    retrieved: List[str] = []
    verified: List[str] = []
    graph_truncated = False
    exposed_bytes = 0
    remembered_node_ids: List[int] = []
    seen_tools: set[str] = set()
    for request_path in sorted(cassette.glob("req-*.json")):
        body = _load_json(request_path, "provider request cassette")
        messages = body.get("messages")
        if not isinstance(messages, list):
            continue
        known_uses: Dict[str, Tuple[str, Mapping[str, Any]]] = {}
        results: Dict[str, str] = {}
        for message in messages:
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "text" and isinstance(item.get("text"), str):
                    raw_text = item["text"]
                    for match in re.finditer(r"\bnode_id=([0-9]+)\b", raw_text):
                        logical = logical_ids.get(int(match.group(1)))
                        if logical is not None and logical not in retrieved:
                            retrieved.append(logical)
                if item.get("type") == "tool_use":
                    tool_id, name, tool_input = item.get("id"), item.get("name"), item.get("input")
                    if isinstance(tool_id, str) and isinstance(name, str) and isinstance(tool_input, dict):
                        known_uses[tool_id] = (name, tool_input)
                elif item.get("type") == "tool_result":
                    tool_id, value = item.get("tool_use_id"), item.get("content")
                    if isinstance(tool_id, str) and isinstance(value, str):
                        results[tool_id] = value
        for tool_id, (name, tool_input) in known_uses.items():
            if tool_id in seen_tools or tool_id not in results:
                continue
            seen_tools.add(tool_id)
            raw_result = results[tool_id]
            exposed_bytes += len(raw_result.encode("utf-8"))
            if name == "KgRecall":
                query = tool_input.get("query")
                if isinstance(query, str):
                    append_query_variant(query)
                try:
                    parsed = json.loads(raw_result)
                except json.JSONDecodeError:
                    continue
                hits = parsed.get("hits") if isinstance(parsed, dict) else None
                if isinstance(hits, list):
                    for hit in hits:
                        node_id = hit.get("node_id") if isinstance(hit, dict) else None
                        logical = logical_ids.get(node_id) if isinstance(node_id, int) else None
                        if logical is not None and logical not in retrieved:
                            retrieved.append(logical)
            elif name == "KgContext":
                node_id = tool_input.get("node_id")
                logical = logical_ids.get(node_id) if isinstance(node_id, int) else None
                if logical is not None and logical not in verified:
                    verified.append(logical)
                try:
                    parsed = json.loads(raw_result)
                    if isinstance(parsed, dict):
                        graph_truncated = graph_truncated or bool(
                            parsed.get("graph_truncated")
                            or (isinstance(parsed.get("summary"), dict) and parsed["summary"].get("truncated"))
                        )
                except json.JSONDecodeError:
                    pass
            elif name == "KgRemember":
                try:
                    parsed = json.loads(raw_result)
                    remembered = parsed.get("remembered") if isinstance(parsed, dict) else None
                    node_id = remembered.get("node_id") if isinstance(remembered, dict) else None
                    if isinstance(node_id, int) and not isinstance(node_id, bool):
                        remembered_node_ids.append(node_id)
                except json.JSONDecodeError:
                    pass
            elif name in {"Read", "Grep"} and (
                _path_is_within(tool_input.get("file_path"), memory_dir)
                or _path_is_within(tool_input.get("path"), memory_dir)
            ):
                if not query_variants:
                    observed_query = tool_input.get("pattern") if name == "Grep" else fallback_query
                    append_query_variant(
                        observed_query if isinstance(observed_query, str) else fallback_query
                    )
    if retrieved and not query_variants:
        # Host-scoped recall uses the original task prompt when it injects
        # evidence before the model can issue KgRecall.  The query is still
        # the protocol's one exact seed; "automatic" describes who issued it,
        # not a third query kind (the result schema only permits exact/semantic).
        append_query_variant(fallback_query)
    return {
        "query_variants": query_variants,
        "retrieved": retrieved,
        "verified": verified,
        "graph_truncated": graph_truncated,
        "exposed_bytes": exposed_bytes,
        "remembered_node_ids": remembered_node_ids,
    }


def _runtime_metadata(
    *,
    manifest: Mapping[str, Any],
    case: Mapping[str, Any],
    schedule: Mapping[str, Any],
    events_path: Path,
    run_id: str,
    model_provider: str,
    harness_fingerprint: str,
    environment_fingerprint: str,
    allowed_tools: Sequence[str] | None = None,
    max_metered_tokens: int | None = None,
    max_cost_usd: float | None = None,
) -> Mapping[str, Any]:
    if (max_metered_tokens is None) != (max_cost_usd is None):
        _fail("memory runtime metadata", "token and cost caps must be supplied together")
    metadata: Dict[str, Any] = {
        "schema_version": RUNTIME_METADATA_SCHEMA_VERSION,
        "events_path": str(events_path),
        "run_id": run_id,
        "trial": schedule["trial"],
        "suite_id": manifest["manifest_id"],
        "task_id": case["id"],
        "task_fingerprint": _canonical_sha256(case),
        "model_provider": model_provider,
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_config_id": f"memory:{schedule['arm']}",
        "harness_revision": manifest["execution"]["harness_revision"],
        "harness_fingerprint": harness_fingerprint,
        "permission_mode": "bypass_permissions",
        "environment_fingerprint": environment_fingerprint,
        "grader_fingerprint": case["grader"]["fingerprint"],
    }
    if max_metered_tokens is not None:
        metadata["max_metered_tokens"] = max_metered_tokens
        metadata["max_cost_usd"] = float(max_cost_usd)
    if allowed_tools is not None:
        metadata["allowed_tools"] = list(allowed_tools)
    return metadata


def _sanitized_environment(base: Mapping[str, str]) -> Dict[str, str]:
    forbidden_exact = {
        "HOME",
        "TMPDIR",
        "TMP",
        "TEMP",
        "METACODES_KG_BIN",
        "METACODES_KG_DOMAIN",
        "METACODES_KG_STORE",
        "METACODES_KG_TRANSPORT",
        "METACODES_KG_CONFIG",
        "METACODES_KG_URL",
        "METACODES_KG_API_KEY",
        "METACODES_KG_EXPECTED_BUILD_ID",
        "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
        "METACODES_LONG_HORIZON_ARM",
        "METACODES_BASE_URL",
        "METACODES_RECORD_DIR",
        "METACODES_EVAL_METADATA_FD",
        "METACODES_EVAL_FD",
        "METACODES_LOG",
        "METACODES_LOG_FILE",
        "METACODES_AUTH_FILE",
        "METACODES_API_KEY_FD",
        "METACODES_PROVIDER",
        "METACODES_AUTH_PRECEDENCE",
        "METACODES_NO_AUTO_RECALL",
        "METACODES_RECALL_FLOOR",
        "METASK_API_KEY",
    }
    return {
        key: value
        for key, value in base.items()
        if not key.startswith("TINYKG_") and key not in forbidden_exact
    }


def _production_environment(_base: Mapping[str, str]) -> Dict[str, str]:
    """Build the minimal inherited environment for a paid model-controlled run.

    A credential-name blacklist is insufficient here: Bash could inspect an
    unrelated AWS/GitHub/SSH secret inherited from the operator. Production
    receives only a deterministic system search path; HOME, temp, locale,
    evaluation FDs, and treatment settings are added explicitly by the caller.
    """

    return {"PATH": PRODUCTION_CHILD_PATH}


def _sbpl_string(value: str) -> str:
    if any(character in value for character in ("\x00", "\n", "\r")):
        _fail("production sandbox path", "contains a forbidden control character")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _production_sandbox_profile(
    *,
    read_write_roots: Sequence[Path],
    read_only_files: Sequence[Path],
    sealed_files: Sequence[Path],
    sealed_roots: Sequence[Path] = (),
    transient_write_roots: Sequence[Path] = (),
) -> str:
    """Build a whole-child Seatbelt profile with a filesystem default deny.

    ``allow default`` deliberately preserves the provider's HTTPS stack and the
    normal process primitives used by Bash. File reads/writes are then denied
    from ``/`` and only the current rollout is restored. ``process-info*`` is
    denied independently so a tool cannot recover the Python parent's command
    line or environment through ``ps``/pid inspection.
    """

    if platform.system() != "Darwin" or not PRODUCTION_SANDBOX_EXEC.is_file():
        _fail(
            "production sandbox",
            "macOS sandbox-exec is required for a paid production rollout",
        )

    roots: List[Path] = []
    for raw in read_write_roots:
        path = raw.expanduser().resolve()
        try:
            info = path.lstat()
        except OSError as exc:
            raise ValidationError(f"production sandbox root is unavailable: {exc}") from exc
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            _fail("production sandbox root", "must be a real directory")
        if path not in roots:
            roots.append(path)
    roots.sort(key=lambda item: (len(item.parts), str(item)))
    minimal_roots: List[Path] = []
    for root in roots:
        if any(_path_is_within(str(root), parent) for parent in minimal_roots):
            continue
        minimal_roots.append(root)
    if not minimal_roots:
        _fail("production sandbox", "has no current-rollout roots")

    # Seatbelt matches the spelling used by the syscall. Keep both macOS's
    # public symlink spelling (/var, /etc) and the resolved /private target;
    # resolving everything would block xcode-select before a script starts.
    system_roots = sorted(
        {
            candidate
            for path in PRODUCTION_SYSTEM_READ_ROOTS
            if path.exists() and path.is_dir()
            for candidate in (path.absolute(), path.resolve())
        },
        key=str,
    )
    readonly: List[Path] = []
    for raw in read_only_files:
        # dyld opens Homebrew dependencies through their install-name spelling
        # (for example /opt/homebrew/opt/gmp/...), while the integrity check is
        # necessarily over the resolved Cellar file.  Seatbelt matches the
        # spelling used by the syscall, so preserve both identities.  Callers
        # must still hash/reopen these files before and after the child run.
        spelled = raw.expanduser().absolute()
        path = spelled.resolve()
        if not path.is_file():
            _fail("production sandbox read-only file", "is unavailable")
        for candidate in (spelled, path):
            if candidate not in readonly:
                readonly.append(candidate)
        # A literal grant for the final file is insufficient when an install
        # name traverses a symlinked directory: dyld must read the link itself
        # before it can open the resolved Cellar object.  Grant only those
        # symlink path components, never their directory contents.
        component = spelled
        symlink_spellings: List[Path] = []
        while component != component.parent:
            candidates = (component, component.parent.resolve(strict=False) / component.name)
            for link_candidate in candidates:
                try:
                    component_info = link_candidate.lstat()
                except OSError:
                    continue
                if stat.S_ISLNK(component_info.st_mode):
                    if link_candidate not in readonly:
                        readonly.append(link_candidate)
                    if link_candidate not in symlink_spellings:
                        symlink_spellings.append(link_candidate)
            component = component.parent
        # dyld realpath resolution reads the exact directory containing an
        # intermediate dylib symlink.  A literal directory grant permits that
        # lookup/list operation but does not grant data reads for its children.
        for link in symlink_spellings:
            if link.parent not in readonly:
                readonly.append(link.parent)
    sealed = sorted({path.expanduser().resolve(strict=False) for path in sealed_files}, key=str)
    for path in sealed:
        if not any(_path_is_within(str(path), root) for root in minimal_roots):
            _fail("production sandbox sealed file", "is outside the writable rollout roots")
    sealed_directories: List[Path] = []
    for raw in sealed_roots:
        spelled = raw.expanduser().absolute()
        try:
            info = spelled.lstat()
        except OSError as exc:
            raise ValidationError(f"production sandbox sealed root is unavailable: {exc}") from exc
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            _fail("production sandbox sealed root", "must be a real directory")
        path = spelled.resolve(strict=True)
        if not any(_path_is_within(str(path), root) for root in minimal_roots):
            _fail("production sandbox sealed root", "is outside the writable rollout roots")
        if path not in sealed_directories:
            sealed_directories.append(path)
    sealed_directories.sort(key=str)
    transient_directories: List[Path] = []
    for raw in transient_write_roots:
        spelled = raw.expanduser().absolute()
        if spelled.name not in {".tinykg-cli.lock", ".tinykg_leases"}:
            _fail(
                "production sandbox transient write root",
                "only TinyKG CLI lock and process-lease paths are supported",
            )
        try:
            transient_info = spelled.lstat()
        except FileNotFoundError:
            if spelled.name != ".tinykg-cli.lock":
                _fail(
                    "production sandbox transient write root",
                    "TinyKG process-lease directory must be pre-created",
                )
        except OSError as exc:
            raise ValidationError(
                f"production sandbox transient write root is unavailable: {exc}"
            ) from exc
        else:
            if spelled.name == ".tinykg-cli.lock":
                _fail("production sandbox transient write root", "CLI lock must not already exist")
            if stat.S_ISLNK(transient_info.st_mode) or not stat.S_ISDIR(
                transient_info.st_mode
            ):
                _fail(
                    "production sandbox transient write root",
                    "TinyKG process-lease path must be a real directory",
                )
            try:
                if any(spelled.iterdir()):
                    _fail(
                        "production sandbox transient write root",
                        "TinyKG process-lease directory must be empty",
                    )
            except OSError as exc:
                raise ValidationError(
                    f"production sandbox transient write root is unavailable: {exc}"
                ) from exc
        parent = spelled.parent
        try:
            parent_info = parent.lstat()
        except OSError as exc:
            raise ValidationError(
                f"production sandbox transient write parent is unavailable: {exc}"
            ) from exc
        if stat.S_ISLNK(parent_info.st_mode) or not stat.S_ISDIR(parent_info.st_mode):
            _fail("production sandbox transient write root", "parent must be a real directory")
        path = parent.resolve(strict=True) / spelled.name
        if not any(_path_is_within(str(path), root) for root in sealed_directories):
            _fail(
                "production sandbox transient write root",
                "must be inside a sealed read-only root",
            )
        if path not in transient_directories:
            transient_directories.append(path)
    transient_directories.sort(key=str)

    # Seatbelt's subpath filter does not grant metadata access to ancestors.
    # Shell startup calls getcwd(), which must stat every parent of the current
    # workspace; macOS launch shims likewise resolve /var and /etc symlinks.
    # Grant metadata only (not contents) on those path components.
    ancestor_metadata: set[Path] = set()
    for path in (*system_roots, *minimal_roots, *readonly):
        current = path.parent
        while current != current.parent:
            ancestor_metadata.add(current)
            current = current.parent

    lines = [
        "(version 1)",
        "(allow default)",
        # Shells need process metadata about themselves. Deny only cross-process
        # inspection so ps cannot recover the Python parent's argv/environment.
        "(deny process-info* (target others))",
        '(deny file-read* (subpath "/"))',
        '(deny file-write* (subpath "/"))',
        "(allow file-read*",
        '  (literal "/")',
    ]
    lines.extend(f"  (subpath {_sbpl_string(str(path))})" for path in system_roots)
    lines.extend(f"  (subpath {_sbpl_string(str(path))})" for path in minimal_roots)
    lines.extend(f"  (literal {_sbpl_string(str(path))})" for path in sorted(readonly, key=str))
    lines.extend(
        [
            ")",
            "(allow file-read-metadata",
            *[
                f"  (literal {_sbpl_string(str(path))})"
                for path in sorted(ancestor_metadata, key=str)
            ],
            ")",
            "(allow file-write*",
            *[f"  (subpath {_sbpl_string(str(path))})" for path in minimal_roots],
            '  (literal "/dev/null")',
            '  (literal "/dev/zero")',
            '  (literal "/dev/stdout")',
            '  (literal "/dev/stderr")',
            '  (literal "/dev/random")',
            '  (literal "/dev/urandom")',
            '  (regex #"^/dev/fd/")',
            ")",
        ]
    )
    if sealed or sealed_directories:
        lines.append("(deny file-write*")
        lines.extend(f"  (literal {_sbpl_string(str(path))})" for path in sealed)
        lines.extend(
            f"  (subpath {_sbpl_string(str(path))})" for path in sealed_directories
        )
        lines.append(")")
    if transient_directories:
        lines.append("(allow file-write*")
        lines.extend(
            f"  (subpath {_sbpl_string(str(path))})" for path in transient_directories
        )
        lines.append(")")
    return "\n".join(lines) + "\n"


def _materialize_production_sandbox(
    *,
    profile_path: Path,
    evidence_path: Path,
    artifact_dir: Path,
    workspace: Path,
    store: Path | None,
    metacodes: Path,
    tinykg: Path | None,
    ripgrep: Path,
    additional_read_only_files: Sequence[Path] = (),
    read_only_roots: Sequence[Path] = (),
    tinykg_read_only_store: Path | None = None,
) -> ProductionSandbox:
    roots = [artifact_dir, workspace]
    if store is not None:
        roots.append(store)
    profile = _production_sandbox_profile(
        read_write_roots=roots,
        read_only_files=(
            (metacodes, ripgrep, *additional_read_only_files)
            if tinykg is None
            else (metacodes, tinykg, ripgrep, *additional_read_only_files)
        ),
        sealed_files=(profile_path, evidence_path, ripgrep),
        sealed_roots=read_only_roots,
        transient_write_roots=(
            (
                tinykg_read_only_store / ".tinykg-cli.lock",
                tinykg_read_only_store / ".tinykg_leases",
            )
            if tinykg_read_only_store is not None
            else ()
        ),
    )
    _write_new(profile_path, profile.encode("utf-8"))
    return ProductionSandbox(
        profile_path=profile_path,
        profile_sha256=file_sha256(profile_path),
    )


def _run_production_tinykg_read_probe(
    sandbox: ProductionSandbox,
    *,
    tinykg_binary: Path,
    store: Path,
    query: str,
    writable_root: Path,
) -> Mapping[str, Any]:
    binary = tinykg_binary.expanduser().resolve(strict=True)
    resolved_store = store.expanduser().resolve(strict=True)
    store_info = resolved_store.lstat()
    if stat.S_ISLNK(store_info.st_mode) or not stat.S_ISDIR(store_info.st_mode):
        _fail("production TinyKG read probe", "store must be a real directory")
    compact_query = " ".join(query.split())
    if not compact_query or len(compact_query.encode("utf-8")) > 400:
        _fail("production TinyKG read probe", "query must contain 1-400 UTF-8 bytes")
    _assert_tinykg_read_transients_clean(resolved_store, "production TinyKG read probe")
    normalized_before = _tree_digest(resolved_store, normalize_store_manifest=True)
    raw_before = _tree_digest(resolved_store)

    def run(action: str, *arguments: str) -> str:
        try:
            completed = subprocess.run(
                sandbox.command([str(binary), action, str(resolved_store), *arguments]),
                cwd=writable_root,
                env={"PATH": PRODUCTION_CHILD_PATH, "LC_ALL": "C", "LANG": "C"},
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValidationError(
                f"production TinyKG read probe {action} failed to execute: {exc}"
            ) from exc
        if completed.returncode != 0:
            diagnostic = completed.stderr.strip().replace("\n", " ")[-512:]
            _fail(
                f"production TinyKG read probe {action}",
                f"exited {completed.returncode}: {diagnostic}",
            )
        _assert_tinykg_read_transients_clean(
            resolved_store, f"production TinyKG read probe {action}"
        )
        return completed.stdout

    info_output = run("store-info")
    parsed_info = _store_info(info_output)
    _assert_tinykg_read_transients_clean(resolved_store, "production TinyKG read probe")
    if (
        parsed_info.get("storage_format_version") != "2"
        or parsed_info.get("schema_version") != "3"
        or parsed_info.get("text_current") != "1"
        or parsed_info.get("text_stale") != "0"
    ):
        _fail("production TinyKG read probe", "store is not current and recall-ready")
    recall_output = run(
        "search",
        compact_query,
        "--profile",
        "agent-memory",
        "--limit",
        "1",
        "--format",
        "json",
    )
    try:
        recall = json.loads(recall_output)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"production TinyKG read probe returned invalid JSON: {exc}") from exc
    hits = recall.get("hits") if isinstance(recall, dict) else None
    if (
        not isinstance(recall, dict)
        or recall.get("schema_version") != "tinykg-agent-retrieval-v1"
        or not isinstance(hits, list)
        or not hits
    ):
        _fail("production TinyKG read probe", "recall returned no bounded evidence")
    if (
        _tree_digest(resolved_store, normalize_store_manifest=True) != normalized_before
        or _tree_digest(resolved_store) != raw_before
    ):
        _fail("production TinyKG read probe", "read-only commands changed store bytes")
    return {
        "tinykg_read_probe_performed": True,
        "tinykg_store_info_sha256": _hash_bytes(info_output.encode("utf-8")),
        "tinykg_recall_sha256": _hash_bytes(recall_output.encode("utf-8")),
        "tinykg_lock_path_clean": True,
        "tinykg_store_unchanged": True,
    }


def _run_production_sandbox_probe(
    sandbox: ProductionSandbox,
    *,
    host_read_path: Path,
    sibling_read_path: Path,
    writable_root: Path,
    evidence_path: Path,
    read_only_probes: Sequence[Tuple[Path, Path]] = (),
    tinykg_read_probe: Tuple[Path, Path, str] | None = None,
) -> Mapping[str, Any]:
    """Run a zero-network controlled negative before exposing the API key."""

    host = host_read_path.expanduser().resolve()
    sibling = sibling_read_path.expanduser().resolve()
    for path, label in ((host, "host"), (sibling, "sibling")):
        if not path.is_file() or not os.access(path, os.R_OK):
            _fail(f"production sandbox {label} sentinel", "must be host-readable")
    allowed = writable_root.expanduser().resolve() / "sandbox-positive-probe.txt"
    validated_read_only: List[Tuple[Path, Path, Path, Path, str]] = []
    seen_read_only_roots: set[Path] = set()
    for raw_root, raw_file in read_only_probes:
        spelled_root = raw_root.expanduser().absolute()
        spelled_file = raw_file.expanduser().absolute()
        try:
            root_info = spelled_root.lstat()
            file_info = spelled_file.lstat()
        except OSError as exc:
            raise ValidationError(f"production sandbox read-only probe is unavailable: {exc}") from exc
        if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
            _fail("production sandbox read-only probe", "root must be a real directory")
        if (
            stat.S_ISLNK(file_info.st_mode)
            or not stat.S_ISREG(file_info.st_mode)
            or file_info.st_nlink != 1
        ):
            _fail("production sandbox read-only probe", "sentinel must be a single-link regular file")
        root = spelled_root.resolve(strict=True)
        read_only = spelled_file.resolve(strict=True)
        try:
            read_only.relative_to(root)
        except ValueError:
            _fail("production sandbox read-only probe", "sentinel must be inside its root")
        if root in seen_read_only_roots:
            _fail("production sandbox read-only probe", "roots must be unique")
        seen_read_only_roots.add(root)
        read_only_created = root / ".metacodes-seatbelt-write-probe"
        read_only_moved = root.with_name(root.name + ".metacodes-seatbelt-move-probe")
        if read_only_created.exists() or read_only_moved.exists():
            _fail("production sandbox read-only probe", "mutation sentinel already exists")
        validated_read_only.append(
            (root, read_only, read_only_created, read_only_moved, file_sha256(read_only))
        )
    token = _hash_text(
        stable_json(
            {
                "profile": sandbox.profile_sha256,
                "host": str(host),
                "sibling": str(sibling),
                "read_only": [
                    {"root": str(root), "sentinel": str(read_only)}
                    for root, read_only, _created, _moved, _sha256 in validated_read_only
                ],
            }
        )
    )
    script = """
if /usr/bin/head -c 1 "$1" >/dev/null 2>&1; then exit 11; fi
if /usr/bin/head -c 1 "$2" >/dev/null 2>&1; then exit 12; fi
if /bin/ps -p "$PPID" -o command= >/dev/null 2>&1; then exit 13; fi
/bin/echo "$3" > "$4" || exit 14
test "$(/bin/cat "$4")" = "$3" || exit 15
""".strip()
    try:
        completed = subprocess.run(
            sandbox.command(
                [
                    "/bin/sh",
                    "-c",
                    script,
                    "production-sandbox-probe",
                    str(host),
                    str(sibling),
                    token,
                    str(allowed),
                ]
            ),
            cwd=writable_root,
            env={"PATH": PRODUCTION_CHILD_PATH, "LC_ALL": "C", "LANG": "C"},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
        if completed.returncode != 0:
            diagnostic = completed.stderr.strip().replace("\n", " ")[:512]
            _fail(
                "production sandbox controlled negative",
                f"probe exited {completed.returncode}: {diagnostic}",
            )
        if _read_regular_file(allowed, "production sandbox positive probe").strip() != token.encode():
            _fail("production sandbox controlled negative", "writable-root round trip failed")
        read_only_script = """
/usr/bin/head -c 1 "$1" >/dev/null 2>&1 || exit 16
if /bin/echo changed 2>/dev/null > "$1"; then exit 17; fi
if /bin/echo changed 2>/dev/null > "$2"; then exit 18; fi
if /bin/chmod 700 "$3" 2>/dev/null; then exit 19; fi
if /bin/mv "$3" "$4" 2>/dev/null; then exit 20; fi
""".strip()
        for root, read_only, read_only_created, read_only_moved, read_only_sha256 in validated_read_only:
            completed = subprocess.run(
                sandbox.command(
                    [
                        "/bin/sh",
                        "-c",
                        read_only_script,
                        "production-sandbox-read-only-probe",
                        str(read_only),
                        str(read_only_created),
                        str(root),
                        str(read_only_moved),
                    ]
                ),
                cwd=writable_root,
                env={"PATH": PRODUCTION_CHILD_PATH, "LC_ALL": "C", "LANG": "C"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
                check=False,
            )
            if completed.returncode != 0:
                diagnostic = completed.stderr.strip().replace("\n", " ")[:512]
                _fail(
                    "production sandbox controlled negative",
                    f"read-only probe exited {completed.returncode}: {diagnostic}",
                )
            if (
                file_sha256(read_only) != read_only_sha256
                or read_only_created.exists()
                or read_only_moved.exists()
            ):
                _fail("production sandbox controlled negative", "read-only memory changed")
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ValidationError(f"production sandbox controlled negative failed: {exc}") from exc
    finally:
        try:
            allowed.unlink()
        except FileNotFoundError:
            pass

    tinykg_evidence: Mapping[str, Any] = {
        "tinykg_read_probe_performed": False,
        "tinykg_store_info_sha256": None,
        "tinykg_recall_sha256": None,
        "tinykg_lock_path_clean": None,
        "tinykg_store_unchanged": None,
    }
    if tinykg_read_probe is not None:
        tinykg_binary, tinykg_store, tinykg_query = tinykg_read_probe
        tinykg_evidence = _run_production_tinykg_read_probe(
            sandbox,
            tinykg_binary=tinykg_binary,
            store=tinykg_store,
            query=tinykg_query,
            writable_root=writable_root,
        )

    evidence = {
        "schema_version": PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION,
        "backend": PRODUCTION_SANDBOX_BACKEND,
        "profile_sha256": sandbox.profile_sha256,
        "host_path_sha256": _hash_text(str(host)),
        "host_content_sha256": file_sha256(host),
        "sibling_path_sha256": _hash_text(str(sibling)),
        "sibling_content_sha256": file_sha256(sibling),
        "host_read_denied": True,
        "sibling_read_denied": True,
        "process_info_denied": True,
        "workspace_read_write_allowed": True,
        "read_only_roots_enforced": True,
        "read_only_root_count": len(validated_read_only),
        "read_only_roots_sha256": _canonical_sha256(
            [str(root) for root, _file, _created, _moved, _sha256 in validated_read_only]
        ),
        **tinykg_evidence,
    }
    _write_new(
        evidence_path,
        (stable_json(evidence) + "\n").encode("utf-8"),
    )
    return evidence


def _assert_production_sandbox_identity(sandbox: ProductionSandbox, evidence_path: Path) -> None:
    if file_sha256(sandbox.profile_path) != sandbox.profile_sha256:
        _fail("production sandbox profile", "changed during the rollout")
    evidence = _load_json(evidence_path, "production sandbox evidence")
    if evidence.get("backend") != PRODUCTION_SANDBOX_BACKEND:
        _fail("production sandbox evidence", "backend drift")
    if evidence.get("profile_sha256") != sandbox.profile_sha256:
        _fail("production sandbox evidence", "profile identity drift")


def _assert_executable_identity(path: Path, expected_sha256: str, where: str) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        _fail(where, "is no longer executable")
    if file_sha256(path) != expected_sha256:
        _fail(where, "changed during the frozen schedule")


def _materialize_pinned_ripgrep(
    source: Path,
    expected_sha256: str,
    sealed_home: Path,
) -> Path:
    _assert_executable_identity(source, expected_sha256, "production ripgrep binary")
    target = sealed_home / ".metacodes" / "toolchain" / "rg"
    _write_new(target, _read_regular_file(source, "production ripgrep binary"))
    target.chmod(0o500)
    _assert_executable_identity(target, expected_sha256, "sealed production ripgrep binary")
    _assert_executable_identity(source, expected_sha256, "production ripgrep binary")
    return target


def _validate_production_manifest(
    manifest: Mapping[str, Any],
    production: ProductionRuntimeConfig,
) -> None:
    execution = manifest.get("execution")
    if not isinstance(execution, dict):
        _fail("production memory manifest", "missing execution contract")
    if execution.get("model_id") != PRODUCTION_MODEL_ID:
        _fail(
            "production memory manifest.model_id",
            f"must be exactly {PRODUCTION_MODEL_ID!r}",
        )
    if execution.get("model_fingerprint") != PRODUCTION_MODEL_FINGERPRINT:
        _fail(
            "production memory manifest.model_fingerprint",
            "does not bind the production provider/model endpoint",
        )
    production.validate(len(manifest.get("schedule", ())))


def _require_production_budget(
    production: ProductionRuntimeConfig,
    rollout_receipts: Sequence[Mapping[str, Any]],
    remaining_rollouts: int,
) -> None:
    observed_cost = sum(
        float(item["estimated_cost_usd"]) for item in rollout_receipts
    )
    observed_tokens = sum(
        int(item["metered_tokens"]) for item in rollout_receipts
    )
    remaining_cost = float(production.max_total_cost_usd) - observed_cost
    remaining_tokens = production.max_total_metered_tokens - observed_tokens
    required_cost = float(production.max_rollout_cost_usd) * remaining_rollouts
    required_tokens = production.max_rollout_metered_tokens * remaining_rollouts
    if (
        not math.isfinite(observed_cost)
        or observed_cost < 0
        or observed_tokens < 0
        or remaining_cost <= required_cost
        or remaining_tokens <= required_tokens
    ):
        _fail(
            "production memory runtime budget",
            "remaining schedule is not budget-feasible before provider request",
        )


def _build_runtime_receipt(
    *,
    manifest: Mapping[str, Any],
    source_sha: str,
    runner_sources: Sequence[Mapping[str, str]],
    observations: Sequence[Mapping[str, Any]],
    rollout_receipts: Sequence[Mapping[str, Any]],
    metacodes_sha: str,
    tinykg_sha: str,
    production: ProductionRuntimeConfig | None,
    production_ripgrep: Path | None,
    artifact_relative: Callable[[Path, str], str],
    budget_journal_receipt: Mapping[str, Any] | None,
) -> Mapping[str, Any]:
    receipt: Dict[str, Any] = {
        "protocol_id": PROTOCOL_ID,
        "manifest_sha256": _canonical_sha256(manifest),
        "observations_sha256": _canonical_sha256(list(observations)),
        "dataset_sha256": source_sha,
        "adapter_id": manifest["dataset"]["adapter_id"],
        "adapter_revision": manifest["dataset"]["adapter_revision"],
        "model_id": manifest["execution"]["model_id"],
        "model_fingerprint": manifest["execution"]["model_fingerprint"],
        "harness_revision": manifest["execution"]["harness_revision"],
        "runner_sources": list(runner_sources),
        "arms": list(manifest["execution"]["arms"]),
        "graders": [
            {"case_id": case["id"], "fingerprint": case["grader"]["fingerprint"]}
            for case in manifest["cases"]
        ],
        "quality_evidence": False,
        "metacodes_binary_sha256": metacodes_sha,
        "tinykg_binary_sha256": tinykg_sha,
        "estimated_cost_usd": sum(
            float(rollout["estimated_cost_usd"]) for rollout in rollout_receipts
        ),
        "rollouts": list(rollout_receipts),
    }
    if production is not None:
        if production_ripgrep is None or budget_journal_receipt is None:
            _fail("production runtime receipt", "missing toolchain or budget checkpoint")
        receipt.update(
            {
                "schema_version": PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
                "execution_mode": PRODUCTION_EXECUTION_MODE,
                "provider_id": PRODUCTION_PROVIDER_ID,
                "model_provider": PRODUCTION_MODEL_PROVIDER,
                "disallowed_provider_tools": list(PRODUCTION_DISALLOWED_PROVIDER_TOOLS),
                "allowed_provider_tools": list(PRODUCTION_ALLOWED_PROVIDER_TOOLS),
                "ripgrep_binary_sha256": production.ripgrep_binary_sha256,
                "ripgrep_snapshot_path": artifact_relative(
                    production_ripgrep,
                    "frozen production ripgrep binary",
                ),
                "budget": production.public_budget(),
                "provider_requests": sum(
                    int(rollout["provider_requests"]) for rollout in rollout_receipts
                ),
                "tool_network_isolation": PRODUCTION_TOOL_NETWORK_ISOLATION,
                "filesystem_isolation": PRODUCTION_FILESYSTEM_ISOLATION,
                "auto_compact_policy": PRODUCTION_AUTO_COMPACT_POLICY,
                "provider_billed_cost_usd": None,
                "metered_tokens": sum(
                    int(rollout["metered_tokens"]) for rollout in rollout_receipts
                ),
                "pricing_provenance": PRODUCTION_PRICING_PROVENANCE,
                "budget_journal": budget_journal_receipt,
                "context_cache_summary": _summarize_context_cache(rollout_receipts),
                "unconditional_memory_claim_eligible": False,
            }
        )
    else:
        receipt.update(
            {
                "schema_version": RUNTIME_RECEIPT_SCHEMA_VERSION,
                "execution_mode": SCRIPTED_LIFECYCLE_MODE,
                "external_network_calls": 0,
                "paid_cost_usd": 0.0,
            }
        )
    return receipt


def validate_memory_agent_resume(
    *,
    run_dir: Path,
    manifest: Mapping[str, Any],
    source_sha: str,
    metacodes_sha: str,
    tinykg_sha: str,
    ripgrep_sha: str,
    budget_journal: BudgetJournal,
) -> Mapping[str, Any]:
    """Validate an explicit paid-run resume before credential access or network.

    Only a fully checked contiguous prefix may resume.  Any journal transition
    after the checkpoint, including a commit that lost its artifact checkpoint,
    is an unrecoverable ambiguity and therefore fails closed.
    """

    root = run_dir.expanduser().resolve()
    try:
        root_info = run_dir.expanduser().lstat()
    except OSError as exc:
        raise ValidationError(f"paid-run resume directory: cannot inspect: {exc}") from exc
    if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        _fail("paid-run resume directory", "must be an existing real directory")
    for forbidden in (
        root / ROLLOUT_RESUME_CHECKPOINT_TEMP_NAME,
        root / "observations.jsonl",
        root / "runtime-receipt.json",
    ):
        if forbidden.exists() or forbidden.is_symlink():
            _fail(
                "paid-run resume",
                f"ambiguous or already-published artifact {forbidden.name!r}",
            )
    checkpoint_path = root / ROLLOUT_RESUME_CHECKPOINT_NAME
    checkpoint = _load_json_payload(
        _private_regular_payload(checkpoint_path, "rollout resume checkpoint"),
        "rollout resume checkpoint",
    )
    expected_fields = {
        "schema_version",
        "status",
        "manifest_sha256",
        "dataset_sha256",
        "metacodes_binary_sha256",
        "tinykg_binary_sha256",
        "ripgrep_binary_sha256",
        "runner_sources_sha256",
        "completed_sequences",
        "observations",
        "candidate_runtime_receipt",
        "budget_checkpoints",
    }
    if set(checkpoint) != expected_fields:
        _fail("rollout resume checkpoint", "field set drift")
    if (
        checkpoint["schema_version"] != ROLLOUT_RESUME_CHECKPOINT_SCHEMA
        or checkpoint["status"] != "partial"
    ):
        _fail("rollout resume checkpoint", "unsupported schema or status")
    identity = {
        "manifest_sha256": _canonical_sha256(manifest),
        "dataset_sha256": source_sha,
        "metacodes_binary_sha256": metacodes_sha,
        "tinykg_binary_sha256": tinykg_sha,
        "ripgrep_binary_sha256": ripgrep_sha,
    }
    for key, expected in identity.items():
        if checkpoint.get(key) != expected:
            _fail(f"rollout resume checkpoint.{key}", "identity drift")

    observations = checkpoint["observations"]
    receipt = checkpoint["candidate_runtime_receipt"]
    completed = checkpoint["completed_sequences"]
    if not isinstance(observations, list) or not isinstance(receipt, dict):
        _fail("rollout resume checkpoint", "observations or receipt is malformed")
    if not isinstance(completed, list) or any(
        not isinstance(value, int) or isinstance(value, bool) for value in completed
    ):
        _fail("rollout resume checkpoint.completed_sequences", "expected integer array")
    if not completed or completed != list(range(len(completed))):
        _fail("rollout resume checkpoint.completed_sequences", "must be a non-empty prefix")
    if len(completed) > len(manifest["schedule"]) or len(observations) != len(completed):
        _fail("rollout resume checkpoint", "completed prefix length drift")
    rollouts = receipt.get("rollouts")
    if not isinstance(rollouts, list) or len(rollouts) != len(completed):
        _fail("rollout resume checkpoint.candidate_runtime_receipt", "rollout count drift")
    if receipt.get("schema_version") != PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION:
        _fail("rollout resume checkpoint.candidate_runtime_receipt", "not production v9")
    if receipt.get("quality_evidence") is not False:
        _fail("rollout resume checkpoint.candidate_runtime_receipt", "quality flag drift")
    for key, expected in identity.items():
        receipt_key = "dataset_sha256" if key == "dataset_sha256" else key
        if receipt.get(receipt_key) != expected:
            _fail(f"rollout resume checkpoint.candidate_runtime_receipt.{receipt_key}", "identity drift")
    runner_sources = receipt.get("runner_sources")
    if (
        not isinstance(runner_sources, list)
        or checkpoint["runner_sources_sha256"] != _canonical_sha256(runner_sources)
    ):
        _fail("rollout resume checkpoint.runner_sources_sha256", "source bundle drift")
    expected_modules = list(PRODUCTION_RUNNER_SOURCE_MODULES)
    if [item.get("module") for item in runner_sources if isinstance(item, dict)] != expected_modules:
        _fail("rollout resume checkpoint.runner_sources", "module set or order drift")
    runtime_source_root = Path(__file__).resolve().parent
    for index, source_record in enumerate(runner_sources):
        if not isinstance(source_record, dict) or set(source_record) != {"module", "path", "sha256"}:
            _fail(f"rollout resume checkpoint.runner_sources[{index}]", "malformed record")
        module = str(source_record["module"])
        current_sha = file_sha256(runtime_source_root / f"{module}.py")
        if source_record["sha256"] != current_sha:
            _fail(
                f"rollout resume checkpoint.runner_sources[{index}]",
                "current runner source changed since checkpoint",
            )
    if receipt.get("observations_sha256") != _canonical_sha256(observations):
        _fail("rollout resume checkpoint.observations", "receipt hash drift")
    expected_rollout_dirs: set[str] = set()
    for sequence in completed:
        schedule = manifest["schedule"][sequence]
        if schedule.get("sequence") != sequence:
            _fail("rollout resume checkpoint", "manifest schedule is not contiguous")
        case = manifest["cases"][next(
            index
            for index, item in enumerate(manifest["cases"])
            if item["id"] == schedule["case_id"]
        )]
        observation = observations[sequence]
        rollout = rollouts[sequence]
        if not isinstance(observation, dict) or not isinstance(rollout, dict):
            _fail(f"rollout resume checkpoint sequence {sequence}", "malformed row")
        for key, expected in (
            ("case_id", schedule["case_id"]),
            ("trial", schedule["trial"]),
            ("arm", schedule["arm"]),
        ):
            if observation.get(key) != expected or rollout.get(key) != expected:
                _fail(f"rollout resume checkpoint sequence {sequence}", f"{key} drift")
        if rollout.get("sequence") != sequence:
            _fail(f"rollout resume checkpoint sequence {sequence}", "sequence drift")
        if rollout.get("task_fingerprint") != _canonical_sha256(case):
            _fail(f"rollout resume checkpoint sequence {sequence}", "task identity drift")
        if rollout.get("observation_sha256") != _canonical_sha256(observation):
            _fail(f"rollout resume checkpoint sequence {sequence}", "observation hash drift")
        component = _safe_component(
            f"{sequence}:{schedule['case_id']}:{schedule['trial']}:{schedule['arm']}"
        )
        expected_rollout_dirs.add(f"{sequence:05d}-{component}")
    rollout_root = root / "rollouts"
    observed_rollout_dirs = (
        {path.name for path in rollout_root.iterdir() if path.is_dir() and not path.is_symlink()}
        if rollout_root.is_dir() and not rollout_root.is_symlink()
        else set()
    )
    if observed_rollout_dirs != expected_rollout_dirs:
        _fail("paid-run resume rollouts", "contains missing or uncheckpointed directories")

    budget_history = checkpoint["budget_checkpoints"]
    if not isinstance(budget_history, list) or len(budget_history) != len(completed):
        _fail("rollout resume checkpoint.budget_checkpoints", "history length drift")
    seen_budget_paths: set[str] = set()
    last_budget_payload = b""
    last_budget_state: Mapping[str, Any] | None = None
    for index, raw_entry in enumerate(budget_history):
        if not isinstance(raw_entry, dict) or set(raw_entry) != {
            "path",
            "sha256",
            "revision",
            "head_sha256",
        }:
            _fail(f"rollout resume checkpoint.budget_checkpoints[{index}]", "malformed entry")
        relative = raw_entry["path"]
        if (
            not isinstance(relative, str)
            or not re.fullmatch(r"rollout-budget-checkpoint-r[0-9]+\.json", relative)
            or relative in seen_budget_paths
        ):
            _fail(f"rollout resume checkpoint.budget_checkpoints[{index}].path", "invalid path")
        seen_budget_paths.add(relative)
        payload = _private_regular_payload(root / relative, f"rollout budget checkpoint {index}")
        if _hash_bytes(payload) != raw_entry["sha256"]:
            _fail(f"rollout resume checkpoint.budget_checkpoints[{index}]", "byte hash drift")
        state = validate_checkpoint_payload(payload)
        if state["revision"] != raw_entry["revision"] or state["head_sha256"] != raw_entry["head_sha256"]:
            _fail(f"rollout resume checkpoint.budget_checkpoints[{index}]", "state drift")
        states = [transaction["state"] for transaction in state["transactions"].values()]
        if states.count("committed") != index + 1 or any(value != "committed" for value in states):
            _fail(f"rollout resume checkpoint.budget_checkpoints[{index}]", "transaction prefix drift")
        last_budget_payload = payload
        last_budget_state = state
    assert last_budget_state is not None
    live_budget_payload = budget_journal.checkpoint_payload()
    live_budget_state = validate_checkpoint_payload(live_budget_payload)
    if (
        _hash_bytes(live_budget_payload) != _hash_bytes(last_budget_payload)
        or live_budget_state["revision"] != last_budget_state["revision"]
        or live_budget_state["head_sha256"] != last_budget_state["head_sha256"]
    ):
        _fail(
            "paid-run resume budget",
            "journal advanced beyond the artifact checkpoint; replay is forbidden",
        )
    if len(live_budget_state["transactions"]) != len(completed):
        _fail("paid-run resume budget", "committed transaction count drift")
    journal_receipt = receipt.get("budget_journal")
    if not isinstance(journal_receipt, dict):
        _fail("rollout resume checkpoint.candidate_runtime_receipt", "budget receipt missing")
    if (
        journal_receipt.get("checkpoint_path") != budget_history[-1]["path"]
        or journal_receipt.get("checkpoint_sha256") != budget_history[-1]["sha256"]
        or journal_receipt.get("revision") != last_budget_state["revision"]
        or journal_receipt.get("head_sha256") != last_budget_state["head_sha256"]
    ):
        _fail("rollout resume checkpoint.candidate_runtime_receipt", "budget binding drift")
    validate_runtime_receipt(
        receipt,
        manifest,
        observations,
        source_sha,
        "rollout resume checkpoint receipt",
    )
    validate_runtime_artifacts(receipt, root, "rollout resume checkpoint artifacts")
    return checkpoint


def run_memory_agent_schedule(
    *,
    metacodes_binary: Path,
    expected_metacodes_sha256: str,
    tinykg_binary: Path,
    expected_tinykg_sha256: str,
    source_path: Path,
    manifest_path: Path,
    run_dir: Path,
    observations_path: Path,
    runtime_receipt_path: Path,
    validator_bundle_path: Path | None = None,
    timeout_seconds: int = 45,
    production: ProductionRuntimeConfig | None = None,
    budget_journal: BudgetJournal | None = None,
    budget_fault_hook: BudgetFaultHook | None = None,
    resume_paid_run: bool = False,
) -> Tuple[List[Mapping[str, Any]], Mapping[str, Any]]:
    """Run one complete frozen schedule through scripted or production provider.

    The default remains the v3 zero-cost lifecycle smoke. Passing ``production``
    selects the stricter v9 contract and requires an exclusively locked,
    persistent authorization journal before any provider-capable subprocess.
    """

    metacodes = metacodes_binary.expanduser().resolve()
    tinykg = tinykg_binary.expanduser().resolve()
    if not metacodes.is_file() or not os.access(metacodes, os.X_OK):
        _fail("metacodes runtime binary", "not executable")
    if not tinykg.is_file() or not os.access(tinykg, os.X_OK):
        _fail("TinyKG runtime binary", "not executable")
    metacodes_sha = file_sha256(metacodes)
    tinykg_sha = file_sha256(tinykg)
    if not HEX64.fullmatch(expected_metacodes_sha256) or metacodes_sha != expected_metacodes_sha256:
        _fail("metacodes runtime binary", "SHA-256 mismatch")
    if not HEX64.fullmatch(expected_tinykg_sha256) or tinykg_sha != expected_tinykg_sha256:
        _fail("TinyKG runtime binary", "SHA-256 mismatch")

    manifest = load_manifest(manifest_path)
    # Parse and hash the same opened bytes. Separate path reads leave a TOCTOU
    # gap where the executed public source and the receipt identity can refer
    # to different file versions.
    source_payload = _read_regular_file(source_path, "memory adapter source")
    source = _load_json_payload(source_payload, "memory adapter source")
    source_sha = _hash_bytes(source_payload)
    if source_sha != manifest["dataset"]["source_sha256"]:
        _fail("memory adapter source", "SHA-256 does not match manifest")
    if source.get("adapter_id") != manifest["dataset"]["adapter_id"]:
        _fail("memory adapter source", "adapter id does not match manifest")
    if source.get("adapter_revision") != manifest["dataset"]["adapter_revision"]:
        _fail("memory adapter source", "adapter revision does not match manifest")
    production_mode = production is not None
    if production is not None:
        if os.name == "nt":
            _fail(
                "production memory runtime",
                "inherited credential FD transport is not implemented on Windows",
            )
        _validate_production_manifest(manifest, production)
        if budget_journal is None:
            _fail("production memory runtime", "requires an open persistent budget journal")
        budget_snapshot = budget_journal.snapshot()
        if (
            budget_snapshot["authority"]["manifest_sha256"] != _canonical_sha256(manifest)
            or budget_snapshot["authority"]["model_fingerprint"]
            != manifest["execution"]["model_fingerprint"]
            or budget_snapshot["authority"]["provider_identity"] != PRODUCTION_PROVIDER_ID
            or budget_snapshot["authority"]["total_cost_microusd"]
            != usd_to_microusd(production.max_total_cost_usd)
            or budget_snapshot["authority"]["total_metered_tokens"]
            != production.max_total_metered_tokens
        ):
            _fail("production memory runtime", "budget journal authority drift")
    elif budget_journal is not None or budget_fault_hook is not None:
        _fail("memory agent runtime", "budget journal is only valid in production mode")
    if resume_paid_run and production is None:
        _fail("memory agent runtime", "resume is only supported for paid production runs")

    procedural_cases = _public_procedural_cases(source)
    public_cases = {
        item["id"]: item
        for item in source.get("cases", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    public_cases.update(procedural_cases)
    validators: Dict[str, Mapping[str, Any]] = {}
    if manifest["dataset"]["adapter_id"] == "coding-intent-families":
        if validator_bundle_path is None:
            _fail("procedural memory runtime", "validator bundle is required")
        bundle = _load_json(validator_bundle_path, "procedural validator bundle")
        validate_validator_bundle(bundle, source)
        validators = {item["case_id"]: item for item in bundle["cases"]}
    elif validator_bundle_path is not None:
        _fail("memory agent runtime", "validator bundle is only valid for procedural adapter")

    resolved_run = run_dir.expanduser().resolve()
    observations_output = _inside(observations_path, resolved_run, "memory observations output")
    receipt_output = _inside(runtime_receipt_path, resolved_run, "memory runtime receipt output")
    if observations_output == receipt_output:
        _fail("memory agent runtime", "observation and receipt outputs must be distinct")
    resume_checkpoint: Mapping[str, Any] | None = None
    if resume_paid_run:
        assert production is not None
        assert production.ripgrep_binary_sha256 is not None
        assert budget_journal is not None
        resume_checkpoint = validate_memory_agent_resume(
            run_dir=run_dir,
            manifest=manifest,
            source_sha=source_sha,
            metacodes_sha=metacodes_sha,
            tinykg_sha=tinykg_sha,
            ripgrep_sha=production.ripgrep_binary_sha256,
            budget_journal=budget_journal,
        )
    else:
        if resolved_run.exists():
            _fail("memory agent run directory", "must not already exist")
        resolved_run.mkdir(parents=True)
    production_ripgrep: Path | None = None
    if production is not None:
        assert production.ripgrep_binary is not None
        assert production.ripgrep_binary_sha256 is not None
        if resume_checkpoint is not None:
            production_ripgrep = resolved_run / str(
                resume_checkpoint["candidate_runtime_receipt"]["ripgrep_snapshot_path"]
            )
            _assert_executable_identity(
                production_ripgrep,
                production.ripgrep_binary_sha256,
                "resumed production ripgrep binary",
            )
        else:
            production_ripgrep = _materialize_pinned_ripgrep(
                production.ripgrep_binary,
                production.ripgrep_binary_sha256,
                resolved_run / "production-toolchain",
            )
    runtime_source_root = Path(__file__).resolve().parent
    runner_sources: List[Mapping[str, str]] = []
    runner_source_modules = (
        PRODUCTION_RUNNER_SOURCE_MODULES if production_mode else RUNNER_SOURCE_MODULES
    )
    if resume_checkpoint is not None:
        runner_sources = list(
            resume_checkpoint["candidate_runtime_receipt"]["runner_sources"]
        )
    else:
        for module in runner_source_modules:
            runtime_source = runtime_source_root / f"{module}.py"
            target = resolved_run / "runner-sources" / f"{module}.py"
            _write_new(target, _read_regular_file(runtime_source, f"runtime source {module}"))
            runner_sources.append(
                {
                    "module": module,
                    "path": target.relative_to(resolved_run).as_posix(),
                    "sha256": file_sha256(target),
                }
            )
    runner_sources_sha = _canonical_sha256(runner_sources)

    def artifact_relative(path: Path, label: str) -> str:
        return _inside(path, resolved_run, label).relative_to(resolved_run).as_posix()

    local = LocalTinyKg(
        tinykg,
        expected_sha256=expected_tinykg_sha256,
        run_dir=resolved_run / "local-tinykg",
        timeout_seconds=timeout_seconds,
        resume=resume_checkpoint is not None,
    )
    cases = {case["id"]: case for case in manifest["cases"]}
    arms = {arm["id"]: arm for arm in manifest["execution"]["arms"]}
    for arm_id in arms:
        if arm_id not in ARM_TO_RUNTIME:
            _fail("memory agent runtime", f"unsupported arm {arm_id!r}")

    observations: List[Mapping[str, Any]] = (
        list(resume_checkpoint["observations"]) if resume_checkpoint is not None else []
    )
    rollout_receipts: List[Mapping[str, Any]] = (
        list(resume_checkpoint["candidate_runtime_receipt"]["rollouts"])
        if resume_checkpoint is not None
        else []
    )
    budget_checkpoint_history: List[Mapping[str, Any]] = (
        list(resume_checkpoint["budget_checkpoints"])
        if resume_checkpoint is not None
        else []
    )
    procedural_stores: MutableMapping[Tuple[str, int, str], Mapping[str, Any]] = {}

    if resume_checkpoint is not None:
        for sequence, prior_rollout in enumerate(rollout_receipts):
            schedule = manifest["schedule"][sequence]
            case = cases[schedule["case_id"]]
            if case["benchmark"] != "procedural_transfer":
                continue
            store_relative = prior_rollout["artifact_paths"].get("store")
            if store_relative is None:
                continue
            store_path = _inside(
                resolved_run / str(store_relative),
                local.store_root,
                "resumed procedural TinyKG store",
            )
            public_case = public_cases.get(case["id"])
            procedure_id = (
                public_case.get("_procedure_evidence_id")
                if isinstance(public_case, dict)
                else None
            )
            logical_ids: Dict[int, str] = {}
            consolidation = prior_rollout.get("consolidation")
            if isinstance(consolidation, dict) and isinstance(procedure_id, str):
                projection_ids = consolidation.get("tinykg_projection_node_ids")
                if isinstance(projection_ids, list):
                    for node_id in projection_ids:
                        if not isinstance(node_id, int) or isinstance(node_id, bool):
                            _fail("paid-run resume", "invalid consolidation projection id")
                        logical_ids[node_id] = procedure_id
            family_key = (
                str(case.get("family_id") or case["id"]),
                int(schedule["trial"]),
                str(schedule["arm"]),
            )
            procedural_stores[family_key] = {
                "store": str(store_path),
                "logical_ids": logical_ids,
                "abstraction_nodes": int(
                    observations[sequence]["memory"]["abstraction_nodes"]
                ),
            }

    for expected_sequence, schedule in enumerate(manifest["schedule"]):
        if expected_sequence < len(observations):
            continue
        if production_mode:
            _assert_executable_identity(
                metacodes,
                expected_metacodes_sha256,
                "production metacodes binary",
            )
            _assert_executable_identity(
                tinykg,
                expected_tinykg_sha256,
                "production TinyKG binary",
            )
            assert production is not None
            assert production.ripgrep_binary_sha256 is not None
            assert production_ripgrep is not None
            _assert_executable_identity(
                production_ripgrep,
                production.ripgrep_binary_sha256,
                "frozen production ripgrep binary",
            )
        if schedule["sequence"] != expected_sequence:
            _fail("memory schedule", "sequence is not contiguous")
        case = cases[schedule["case_id"]]
        arm_id = schedule["arm"]
        runtime_arm = ARM_TO_RUNTIME[arm_id]
        tinykg_enabled = runtime_arm == "tinykg"
        component = _safe_component(
            f"{expected_sequence}:{case['id']}:{schedule['trial']}:{arm_id}"
        )
        artifact_dir = resolved_run / "rollouts" / f"{expected_sequence:05d}-{component}"
        artifact_dir.mkdir(parents=True)
        if case["benchmark"] == "procedural_transfer":
            project_root = (
                resolved_run
                / "procedural-projects"
                / _safe_component(
                    f"{case.get('family_id')}:{schedule['trial']}:{arm_id}"
                )
            )
            workspace = project_root / "workspaces" / component
        else:
            project_root = artifact_dir / "project"
            workspace = project_root / "workspace"
        workspace.mkdir(parents=True)
        # Keep repository discovery inside the current rollout. A shared
        # family-level .git sentinel would force the sandbox to expose parent
        # directories containing sibling online/offline workspaces.
        (workspace / ".git").mkdir(exist_ok=True)
        sealed_home = artifact_dir / "sealed-home"
        child_tmp = artifact_dir / "tmp"
        cassette = artifact_dir / "cassette"
        for directory in (sealed_home, child_tmp, cassette):
            directory.mkdir()
        pinned_ripgrep: Path | None = None
        if production is not None:
            assert production.ripgrep_binary_sha256 is not None
            assert production_ripgrep is not None
            pinned_ripgrep = _materialize_pinned_ripgrep(
                production_ripgrep,
                production.ripgrep_binary_sha256,
                sealed_home,
            )

        baseline: Dict[str, str] = {}
        public_case = public_cases.get(case["id"])
        if public_case is None:
            _fail("memory agent runtime", f"public source is missing case {case['id']!r}")
        if case["id"] in procedural_cases:
            baseline = _materialize_workspace(public_case, workspace)

        split = str(case["split"])
        online_memory = is_online_memory_case(case)
        read_only_memory = not online_memory
        memory_backend = {
            "codex_style": "none",
            "claude_style": "markdown",
            "tinykg": "tinykg_integrated" if production_mode else "tinykg",
        }[runtime_arm]
        memory_dir: Path | None = None
        memory_file: Path | None = None
        memory_index: Path | None = None
        memory_marker: str | None = None
        markdown_state: Path | None = None
        memory_state_before = "none"
        memory_state_after = "none"
        markdown_revision_before: str | None = None
        markdown_revision_after: str | None = None
        markdown_files_before = 0
        markdown_files_after = 0
        if case["benchmark"] == "procedural_transfer":
            procedure_id = public_case.get("_procedure_evidence_id")
            if not isinstance(procedure_id, str) or not procedure_id:
                _fail("procedural memory runtime", "public source is missing procedure evidence id")
            memory_marker = (
                f"procedure-memory:{procedure_id}: preserve the intent-family pattern across "
                "registry, protocol manifest, documentation, and contract surfaces"
            )
        if runtime_arm == "claude_style" or (runtime_arm == "tinykg" and production_mode):
            memory_dir = _memory_dir(sealed_home, workspace)
            memory_dir.mkdir(parents=True)
            memory_index = memory_dir / "MEMORY.md"
            if case["benchmark"] == "procedural_transfer":
                markdown_state = project_root / (
                    "durable-integrated-markdown-state"
                    if runtime_arm == "tinykg"
                    else "durable-markdown-state"
                )
                if markdown_state.exists():
                    _copy_memory_tree(markdown_state, memory_dir)
                elif split != "online":
                    _fail("procedural memory runtime", "offline phase has no online Markdown state")
                if runtime_arm == "claude_style":
                    memory_file = memory_dir / "benchmark-procedural-pattern.md"
            elif runtime_arm == "claude_style":
                memory_file, memory_marker = _seed_public_markdown_memory(
                    memory_dir,
                    public_case,
                )
            elif read_only_memory and not memory_index.exists():
                # Integrated TinyKG still exposes the product's Markdown
                # channel. Give the read-only sandbox a stable empty index to
                # seal and probe; do not let the child create governance state.
                _write_new(memory_index, b"")
            markdown_revision_before = _artifact_tree_digest(
                memory_dir,
                "markdown memory before rollout",
            )
            markdown_files_before = sum(1 for path in memory_dir.rglob("*") if path.is_file())
            if production_mode:
                if runtime_arm == "claude_style":
                    memory_state_before = _canonical_sha256(
                        {"markdown": markdown_revision_before, "tinykg": None}
                    )
            else:
                memory_state_before = markdown_revision_before

        store: Path | None = None
        logical_ids: Dict[int, str] = {}
        graph_revision_before = "none"
        graph_revision_after = "none"
        raw_store_digest_before = "none"
        raw_store_digest_after = "none"
        store_nodes = 0
        store_nodes_before = 0
        store_edges = 0
        store_text_stale = False
        abstraction_nodes = 0
        if tinykg_enabled:
            domain = _project_domain(project_root)
            family_key = (
                str(case.get("family_id") or case["id"]),
                int(schedule["trial"]),
                arm_id,
            )
            if case["benchmark"] == "procedural_transfer" and family_key in procedural_stores:
                prior = procedural_stores[family_key]
                store = Path(str(prior["store"]))
                logical_ids = dict(prior["logical_ids"])
                abstraction_nodes = int(prior["abstraction_nodes"])
            else:
                store = local.store_root / f"{_safe_component(':'.join(map(str, family_key)))}.kg"
                local.command("init", store, ())
                batch_path = local.batch_root / f"{_safe_component(':'.join(map(str, family_key)))}.jsonl"
                if case["benchmark"] == "procedural_transfer":
                    batch = _empty_project_batch(domain)
                    counts = {"nodes": 1, "edges": 0, "abstraction_nodes": 0}
                else:
                    raw_batch, raw_logical, root_id, _query_case = build_case_batch(
                        source,
                        manifest,
                        case["id"],
                    )
                    batch, logical_ids, _root_id, counts = _agent_batch(
                        raw_batch,
                        raw_logical,
                        root_id,
                        domain,
                    )
                _write_new(batch_path, batch)
                local.command("apply", store, (str(batch_path),))
                # Text search is a derived TinyKG catalog.  A freshly applied
                # store is intentionally stale until the host publishes that
                # catalog, so make publication part of store preparation --
                # before the first digest, read-only sandbox probe, budget
                # authorization, or provider request.  Reused procedural
                # stores are published by the online consolidation boundary
                # and must never be repaired implicitly by an offline reader.
                local.command("rebuild-text", store, ())
                abstraction_nodes = counts["abstraction_nodes"]
                if case["benchmark"] == "procedural_transfer":
                    procedural_stores[family_key] = {
                        "store": str(store),
                        "logical_ids": logical_ids,
                        "abstraction_nodes": abstraction_nodes,
                    }
            _prepare_tinykg_read_transients(store)
            graph_revision_before = _tree_digest(store, normalize_store_manifest=True)
            raw_store_digest_before = _tree_digest(store)
            info = _store_info(local.command("store-info", store, ()))
            store_nodes, store_edges = int(info["nodes"]), int(info["edges"])
            store_nodes_before = store_nodes
            if info.get("text_stale") not in {"0", "1"}:
                _fail(f"native memory rollout {case['id']}", "invalid TinyKG text_stale state")
            store_text_stale = info["text_stale"] == "1"
            if production_mode:
                assert markdown_revision_before is not None
                memory_state_before = _canonical_sha256(
                    {"markdown": markdown_revision_before, "tinykg": graph_revision_before}
                )
            else:
                memory_state_before = graph_revision_before

        memory_index_before = (
            _read_regular_file(memory_index, "pre-rollout MEMORY.md")
            if memory_index is not None and memory_index.exists()
            else b""
        )

        sandbox: ProductionSandbox | None = None
        sandbox_evidence: Mapping[str, Any] | None = None
        sandbox_profile_path: Path | None = None
        sandbox_evidence_path: Path | None = None
        if production_mode:
            assert pinned_ripgrep is not None
            sandbox_profile_path = artifact_dir / "production-seatbelt.sb"
            sandbox_evidence_path = artifact_dir / "production-seatbelt-probe.json"
            sibling_sentinel = (
                resolved_run / "isolation-sentinels" / f"{component}.sentinel"
            )
            _write_new(
                sibling_sentinel,
                f"forbidden-sibling:{_hash_text(component)}\n".encode("utf-8"),
            )
            offline_read_only_probes: List[Tuple[Path, Path]] = []
            if read_only_memory:
                if memory_dir is not None and memory_index is not None:
                    offline_read_only_probes.append((memory_dir, memory_index))
                if store is not None:
                    offline_read_only_probes.append(
                        (store, store / ".tinykg" / "store-manifest.json")
                    )
            sandbox = _materialize_production_sandbox(
                profile_path=sandbox_profile_path,
                evidence_path=sandbox_evidence_path,
                artifact_dir=artifact_dir,
                workspace=workspace,
                store=store,
                metacodes=metacodes,
                tinykg=tinykg if tinykg_enabled else None,
                ripgrep=pinned_ripgrep,
                read_only_roots=tuple(root for root, _file in offline_read_only_probes),
                tinykg_read_only_store=(
                    store if read_only_memory and store is not None else None
                ),
            )
            tinykg_probe_query_bytes = (
                "execution episode"
                if case["benchmark"] == "procedural_transfer"
                else " ".join(str(case["prompt"]).split())
            ).encode("utf-8")[:400]
            tinykg_probe_query = tinykg_probe_query_bytes.decode(
                "utf-8", errors="ignore"
            ).rstrip()
            _assert_executable_identity(
                tinykg,
                expected_tinykg_sha256,
                "production TinyKG binary before sandbox probe",
            )
            sandbox_evidence = _run_production_sandbox_probe(
                sandbox,
                host_read_path=source_path,
                sibling_read_path=sibling_sentinel,
                writable_root=child_tmp,
                evidence_path=sandbox_evidence_path,
                read_only_probes=tuple(offline_read_only_probes),
                tinykg_read_probe=(
                    (tinykg, store, tinykg_probe_query)
                    if read_only_memory and store is not None
                    else None
                ),
            )
            _assert_executable_identity(
                tinykg,
                expected_tinykg_sha256,
                "production TinyKG binary after sandbox probe",
            )

        events = artifact_dir / "native-events.jsonl"
        metadata_path = artifact_dir / "runtime-metadata.json"
        stdout_path = artifact_dir / "stdout.ndjson"
        stderr_path = artifact_dir / "stderr.log"
        run_id = f"{manifest['manifest_id']}:{expected_sequence}:{case['id']}:{schedule['trial']}:{arm_id}"
        harness_fingerprint = (
            _production_harness_fingerprint(
                metacodes_binary_sha256=metacodes_sha,
                tinykg_binary_sha256=tinykg_sha if tinykg_enabled else None,
                harness_revision=manifest["execution"]["harness_revision"],
                arm=arms[arm_id],
                runtime_arm=runtime_arm,
                runtime_budget=production.public_budget(),
                runner_sources=runner_sources,
                allowed_provider_tools=PRODUCTION_ALLOWED_PROVIDER_TOOLS,
                ripgrep_binary_sha256=production.ripgrep_binary_sha256,
            )
            if production is not None
            else _canonical_sha256(
                {
                    "metacodes_binary_sha256": metacodes_sha,
                    "harness_revision": manifest["execution"]["harness_revision"],
                    "arm": arms[arm_id],
                    "runtime_arm": runtime_arm,
                    "provider": SCRIPTED_PROVIDER_ID,
                    "runtime_budget": None,
                    "disallowed_provider_tools": None,
                    "runner_sources_sha256": runner_sources_sha,
                }
            )
        )
        environment_claim = {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "source_sha256": source_sha,
            "tinykg_binary_sha256": tinykg_sha if tinykg_enabled else None,
            "project_domain": _project_domain(project_root),
            "child_path": PRODUCTION_CHILD_PATH,
            "auto_compact_policy": PRODUCTION_AUTO_COMPACT_POLICY,
        }
        if production_mode:
            assert sandbox is not None
            assert production is not None
            assert production.ripgrep_binary_sha256 is not None
            environment_claim.update(
                {
                    "sandbox_backend": PRODUCTION_SANDBOX_BACKEND,
                    "sandbox_profile_sha256": sandbox.profile_sha256,
                    "ripgrep_binary_sha256": production.ripgrep_binary_sha256,
                }
            )
        environment_fingerprint = _canonical_sha256(environment_claim)
        metadata = _runtime_metadata(
            manifest=manifest,
            case=case,
            schedule=schedule,
            events_path=events,
            run_id=run_id,
            model_provider=(PRODUCTION_MODEL_PROVIDER if production_mode else "scripted-local"),
            harness_fingerprint=harness_fingerprint,
            environment_fingerprint=environment_fingerprint,
            allowed_tools=(PRODUCTION_ALLOWED_PROVIDER_TOOLS if production_mode else None),
            max_metered_tokens=(
                production.max_rollout_metered_tokens if production is not None else None
            ),
            max_cost_usd=(
                production.max_rollout_cost_usd if production is not None else None
            ),
        )
        _write_new(
            metadata_path,
            (json.dumps(metadata, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8"),
        )
        metadata_fd = os.open(metadata_path, os.O_RDONLY)
        metadata_path.unlink()
        # Keep the inherited event vnode inside the current artifact allowlist;
        # a process-global temp directory would punch an unnecessary write hole.
        events_file = tempfile.TemporaryFile(dir=artifact_dir)
        started = time.monotonic_ns()
        provider_memory_verified = False
        treatment_activation: Mapping[str, Any] | None = None
        budget_transaction_receipt: Mapping[str, Any] | None = None
        budget_transaction_id: str | None = None
        budget_request_authorized = False
        env = (
            _production_environment(os.environ)
            if production_mode
            else _sanitized_environment(os.environ)
        )
        env.update(
            {
                "HOME": str(sealed_home),
                "TMPDIR": str(child_tmp),
                "TMP": str(child_tmp),
                "TEMP": str(child_tmp),
                "LC_ALL": "C",
                "LANG": "C",
                "METACODES_NO_PROBE": "1",
                "METACODES_PROVIDER": "anthropic",
                "METACODES_LONG_HORIZON_ARM": runtime_arm,
                "METACODES_RECORD_DIR": str(cassette),
                "METACODES_EVAL_METADATA_FD": str(metadata_fd),
                "METACODES_EVAL_FD": str(events_file.fileno()),
            }
        )
        if tinykg_enabled and store is not None:
            # Rule 8 owns this fresh Store for exactly one local rollout. The
            # explicit mode is therefore part of the benchmark isolation
            # contract, not a production fallback from tinykgd.
            env["METACODES_KG_TRANSPORT"] = "cli-exclusive"
            env["METACODES_KG_BIN"] = str(tinykg)
            env["METACODES_KG_DOMAIN"] = _project_domain(project_root)
            env["METACODES_KG_STORE"] = str(store)
        if production_mode:
            env["METACODES_FORCE_COMPACT_AT"] = PRODUCTION_FORCE_COMPACT_AT
            assert pinned_ripgrep is not None
            env["RG_BIN"] = str(pinned_ripgrep)
        common_args = [
            str(metacodes),
            "--model",
            manifest["execution"]["model_id"],
            "--permission",
            "bypassPermissions",
            "--no-theme",
            "--record",
            str(cassette),
            "-p",
            case["prompt"],
            "--json",
        ]
        try:
            if production is not None:
                assert budget_journal is not None
                _require_production_budget(
                    production,
                    rollout_receipts,
                    len(manifest["schedule"]) - expected_sequence,
                )
                reserved = budget_journal.reserve(
                    BudgetTransaction(
                        run_id=run_id,
                        manifest_sha256=_canonical_sha256(manifest),
                        model_fingerprint=manifest["execution"]["model_fingerprint"],
                        harness_fingerprint=harness_fingerprint,
                        provider_identity=PRODUCTION_PROVIDER_ID,
                        max_cost_microusd=usd_to_microusd(
                            production.max_rollout_cost_usd
                        ),
                        max_metered_tokens=production.max_rollout_metered_tokens,
                    )
                )
                budget_transaction_id = str(reserved["transaction_id"])
                assert sandbox is not None
                assert sandbox_evidence_path is not None
                _assert_production_sandbox_identity(sandbox, sandbox_evidence_path)
                credential_read_fd, credential_write_fd = os.pipe()
                try:
                    credential = production.api_key.encode("utf-8")
                    pipe_buf = os.fpathconf(credential_write_fd, "PC_PIPE_BUF")
                    if len(credential) > min(PRODUCTION_CREDENTIAL_MAX_BYTES, pipe_buf):
                        _fail("production credential", "exceeds inherited FD limit")
                    written = os.write(credential_write_fd, credential)
                    if written != len(credential):
                        _fail("production credential", "short write to inherited FD")
                    os.close(credential_write_fd)
                    credential_write_fd = -1
                    env["METACODES_API_KEY_FD"] = str(credential_read_fd)
                    budget_transaction_receipt = budget_journal.authorize_request(
                        budget_transaction_id,
                        expected_revision=int(reserved["journal_revision"]),
                        expected_head_sha256=str(reserved["journal_head_sha256"]),
                    )
                    budget_request_authorized = True
                    if budget_fault_hook is not None:
                        budget_fault_hook(
                            "after_request_authorized",
                            budget_transaction_receipt,
                        )
                    completed = subprocess.run(
                        sandbox.command(
                            [
                                *common_args[:3],
                                "--max-tokens",
                                str(production.max_output_tokens),
                                "--disallowedTools",
                                ",".join(PRODUCTION_DISALLOWED_PROVIDER_TOOLS),
                                *common_args[3:],
                            ]
                        ),
                        cwd=workspace,
                        env=env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=timeout_seconds,
                        check=False,
                        pass_fds=(
                            metadata_fd,
                            events_file.fileno(),
                            credential_read_fd,
                        ),
                    )
                    if budget_fault_hook is not None:
                        budget_fault_hook(
                            "after_provider_return_before_commit",
                            budget_transaction_receipt,
                        )
                finally:
                    if credential_write_fd >= 0:
                        os.close(credential_write_fd)
                    os.close(credential_read_fd)
                provider_request_count = len(list(cassette.glob("req-*.json")))
                treatment_activation = _cassette_treatment_activation(
                    cassette,
                    runtime_arm,
                    PRODUCTION_MODEL_ID,
                )
            else:
                with ScriptedMemoryProvider(
                    case["prompt"],
                    runtime_arm,
                    case["benchmark"],
                    split,
                    memory_file=memory_file,
                    memory_index=memory_index,
                    memory_marker=memory_marker,
                ) as provider:
                    completed = subprocess.run(
                        [
                            str(metacodes),
                            "--api-key",
                            "scripted-local-no-secret",
                            "--base-url",
                            provider.url,
                            *common_args[1:],
                        ],
                        cwd=workspace,
                        env=env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=timeout_seconds,
                        check=False,
                        pass_fds=(metadata_fd, events_file.fileno()),
                    )
                    provider_request_count = len(provider.requests)
                    provider_memory_verified = provider.planner.memory_verified
        except (OSError, subprocess.TimeoutExpired) as exc:
            events_file.close()
            if (
                production is not None
                and budget_transaction_id is not None
                and not budget_request_authorized
            ):
                assert budget_journal is not None
                budget_journal.abort_pre_request(budget_transaction_id)
            if production is not None:
                _assert_production_secret_absent(resolved_run, production.api_key)
            raise ValidationError(f"native memory rollout {run_id} failed to execute: {exc}") from exc
        except BaseException:
            events_file.close()
            if (
                production is not None
                and budget_transaction_id is not None
                and not budget_request_authorized
            ):
                assert budget_journal is not None
                budget_journal.abort_pre_request(budget_transaction_id)
            if production is not None:
                _assert_production_secret_absent(resolved_run, production.api_key)
            raise
        finally:
            os.close(metadata_fd)
        elapsed_ms = (time.monotonic_ns() - started) / 1_000_000.0
        # Persist the direct child evidence before parsing NDJSON or finalizing
        # native events.  A signal exit commonly leaves no result row; checking
        # `_parse_result` first erased the only actionable diagnosis.
        _write_new(stdout_path, completed.stdout.encode("utf-8"))
        _write_new(stderr_path, completed.stderr.encode("utf-8"))
        if completed.returncode != 0:
            diagnostic = _child_failure_diagnostic(
                run_id=run_id,
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
                budget_transaction=budget_transaction_receipt,
            )
            _write_new(
                artifact_dir / "child-process-failure.json",
                (stable_json(diagnostic) + "\n").encode("utf-8"),
            )
        try:
            finalize_evaluation_fd(events_file.fileno(), events)
        finally:
            events_file.close()
            # Event finalization itself can fail. The child has already
            # terminated, so scan every durable artifact before propagating
            # that failure instead of leaving an unchecked partial run.
            if production is not None:
                _assert_production_secret_absent(resolved_run, production.api_key)
        if production is not None:
            _assert_executable_identity(
                metacodes,
                expected_metacodes_sha256,
                "production metacodes binary",
            )
            _assert_executable_identity(
                tinykg,
                expected_tinykg_sha256,
                "production TinyKG binary",
            )
            assert production.ripgrep_binary_sha256 is not None
            assert production_ripgrep is not None
            assert pinned_ripgrep is not None
            _assert_executable_identity(
                production_ripgrep,
                production.ripgrep_binary_sha256,
                "frozen production ripgrep binary",
            )
            _assert_executable_identity(
                pinned_ripgrep,
                production.ripgrep_binary_sha256,
                "sealed production ripgrep binary",
            )
            assert sandbox is not None
            assert sandbox_evidence_path is not None
            _assert_production_sandbox_identity(sandbox, sandbox_evidence_path)
            # Stop the schedule at the first contaminated rollout rather than
            # spending the remaining budget and discovering the leak only when
            # publishing the final receipt.
            _assert_production_secret_absent(resolved_run, production.api_key)
        if completed.returncode != 0:
            _fail(
                f"native memory rollout {run_id}",
                _child_failure_message(completed.returncode),
            )
        result = _parse_result(completed.stdout)
        native, native_error = _native_trace_metrics(events)
        if native_error is not None or native is None:
            _fail(f"native memory rollout {run_id}", native_error or "invalid events")
        metrics = native["metrics"]
        scoped_recall_activation = _verify_scoped_recall_activation(
            native,
            cassette,
            str(case["prompt"]),
            tinykg_enabled=tinykg_enabled,
            where=f"native memory rollout {run_id} scoped recall",
        )
        if result["stop_reason"] not in SAFE_STOP_REASONS:
            _fail(f"native memory rollout {run_id}", f"unsafe stop {result['stop_reason']!r}")
        if not native["complete"] or native["starts"] != 1 or native["finishes"] != 1:
            _fail(f"native memory rollout {run_id}", "native lifecycle is incomplete")
        if native["dropped_events_total"] != 0:
            _fail(f"native memory rollout {run_id}", "native events were dropped")
        native_metadata = native["metadata"]
        for key in (
            "run_id",
            "task_id",
            "task_fingerprint",
            "model_fingerprint",
            "harness_fingerprint",
            "environment_fingerprint",
            "grader_fingerprint",
        ):
            if native_metadata.get(key) != metadata[key]:
                _fail(f"native memory rollout {run_id}", f"metadata drift in {key}")
        if native_metadata.get("runtime_model_id") != manifest["execution"]["model_id"]:
            _fail(f"native memory rollout {run_id}", "runtime model id drift")
        if native_metadata.get("runtime_model_provider") != "anthropic":
            _fail(f"native memory rollout {run_id}", "runtime model provider drift")
        if native_metadata.get("runtime_permission_mode") != "bypass_permissions":
            _fail(f"native memory rollout {run_id}", "runtime permission drift")
        if production is not None and (
            native_metadata.get("model_provider") != PRODUCTION_MODEL_PROVIDER
            or native_metadata.get("max_metered_tokens")
            != production.max_rollout_metered_tokens
            or native_metadata.get("max_cost_usd") != production.max_rollout_cost_usd
        ):
            _fail(f"native memory rollout {run_id}", "production identity or budget drift")
        if metrics["model_request_count"] != provider_request_count or provider_request_count < 1:
            _fail(f"native memory rollout {run_id}", "provider/native request count mismatch")
        compact_event_count = int(metrics["compact_request_count"])
        if production is not None and compact_event_count != 0:
            _fail(
                f"native memory rollout {run_id}",
                "production pilot requires an uncompacted trace",
            )
        metric_cost = float(metrics["cost_usd"])
        result_cost = float(result["cost_usd"])
        if not _estimated_costs_match(metric_cost, result_cost):
            _fail(f"native memory rollout {run_id}", "runtime emitted an invalid estimated cost")
        metered_tokens = sum(
            int(metrics[key])
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            )
        )
        pricing_provenance = _native_pricing_provenance(
            events,
            f"native memory rollout {run_id} pricing",
        )
        if production is not None:
            if metered_tokens <= 0:
                _fail(f"native memory rollout {run_id}", "production usage is empty")
            if (
                metered_tokens > production.max_rollout_metered_tokens
                or metric_cost > production.max_rollout_cost_usd
            ):
                _fail(f"native memory rollout {run_id}", "production budget exceeded")
            if pricing_provenance != PRODUCTION_PRICING_PROVENANCE:
                _fail(f"native memory rollout {run_id}", "production pricing provenance drift")
            assert budget_journal is not None
            assert budget_transaction_id is not None
            budget_transaction_receipt = budget_journal.commit(
                budget_transaction_id,
                actual_cost_microusd=usd_to_microusd_ceiling(metric_cost),
                actual_metered_tokens=metered_tokens,
            )

        deterministic_success: bool | None = None
        candidate: Mapping[str, str] | None = None
        if case["benchmark"] == "procedural_transfer":
            validator_entry = validators.get(case["id"])
            if validator_entry is not None:
                candidate = _read_workspace(workspace, baseline)
                deterministic_success, _failures = evaluate_workspace(
                    baseline,
                    candidate,
                    validator_entry["validator"],
                )

        consolidation_receipt: Mapping[str, Any] | None = None
        if production_mode and online_memory and memory_backend != "none":
            from .memory_consolidation import commit_execution_episode

            if memory_dir is None or memory_index is None or candidate is None:
                _fail(
                    f"native memory rollout {run_id}",
                    "online consolidation requires durable memory and validator output",
                )
            consolidation_receipt = commit_execution_episode(
                local=local,
                memory_dir=memory_dir,
                memory_index=memory_index,
                store=store if tinykg_enabled else None,
                prompt=str(case["prompt"]),
                stop_reason=str(result["stop_reason"]),
                deterministic_success=deterministic_success,
                baseline=baseline,
                candidate=candidate,
                source_events_sha256=file_sha256(events),
            )
            if tinykg_enabled:
                procedure_id = public_case.get("_procedure_evidence_id")
                projection_nodes = consolidation_receipt.get(
                    "tinykg_projection_node_ids"
                )
                if not isinstance(procedure_id, str) or not isinstance(
                    projection_nodes, list
                ):
                    _fail(
                        f"native memory rollout {run_id}",
                        "TinyKG consolidation omitted logical projection provenance",
                    )
                for node_id in projection_nodes:
                    if not isinstance(node_id, int) or isinstance(node_id, bool):
                        _fail(
                            f"native memory rollout {run_id}",
                            "TinyKG consolidation returned an invalid projection id",
                        )
                    logical_ids[node_id] = procedure_id
                procedural_stores[family_key]["logical_ids"] = logical_ids

        tool_data = _cassette_tool_data(
            cassette,
            logical_ids,
            case["prompt"],
            memory_dir=memory_dir,
        )
        cassette_activity = _cassette_memory_activity(
            cassette,
            f"native memory rollout {run_id} cassette",
            memory_root=memory_dir,
        )
        context_cache_contract: Mapping[str, Any] | None = None
        if production is not None:
            _validate_production_provider_tool_schema(
                cassette,
                f"native memory rollout {run_id} cassette",
                PRODUCTION_ALLOWED_PROVIDER_TOOLS,
            )
            context_cache_contract = _cassette_context_cache(
                cassette,
                PRODUCTION_MODEL_ID,
                f"native memory rollout {run_id} context/cache",
            )
        if cassette_activity["provider_requests"] != provider_request_count:
            _fail(f"native memory rollout {run_id}", "raw provider request count drift")
        if (
            production is not None
            and cassette_activity["uncontained_forbidden_provider_tool_attempts"] != 0
        ):
            _fail(
                f"native memory rollout {run_id}",
                "forbidden provider tool was not safely denied",
            )
        if (
            tinykg_enabled
            and case["benchmark"] == "procedural_transfer"
            and tool_data["remembered_node_ids"]
        ):
            procedure_id = public_case.get("_procedure_evidence_id")
            assert isinstance(procedure_id, str)
            for node_id in tool_data["remembered_node_ids"]:
                logical_ids[int(node_id)] = procedure_id
            procedural_stores[family_key] = {
                "store": str(store),
                "logical_ids": logical_ids,
                "abstraction_nodes": abstraction_nodes,
            }
            tool_data = _cassette_tool_data(
                cassette,
                logical_ids,
                case["prompt"],
                memory_dir=memory_dir,
            )
        query_plan_trace = build_query_plan_trace(
            cassette,
            run_id=run_id,
            arm=arm_id,
            memory_backend=memory_backend,
            where=f"native memory rollout {run_id} query plan",
        )
        _write_new(
            cassette / QUERY_PLAN_SIDECAR_NAME,
            (stable_json(query_plan_trace) + "\n").encode("utf-8"),
        )
        query_variants = tool_data["query_variants"]
        host_recall_injected = bool(
            scoped_recall_activation is not None
            and scoped_recall_activation.get("status") == "injected"
        )
        governed_variants = project_query_variants(query_plan_trace)
        if governed_variants:
            query_variants = governed_variants
        if host_recall_injected and not any(
            variant["kind"] == "exact" for variant in query_variants
        ):
            prompt_bytes = str(case["prompt"]).encode("utf-8")[:400]
            query_variants = [
                {"kind": "exact", "text": prompt_bytes.decode("utf-8", errors="ignore")},
                *query_variants[:4],
            ]
        retrieved = tool_data["retrieved"]
        verified = tool_data["verified"]
        graph_truncated = bool(tool_data["graph_truncated"])
        exposure = (
            _cassette_memory_exposure(
                cassette,
                f"native memory rollout {run_id} exposure",
                memory_root=memory_dir,
                expected_memory_index=memory_index_before,
                count_graph_context=tinykg_enabled,
            )
            if production_mode
            else {
                "auto_injected_bytes": 0,
                "tool_result_bytes": int(tool_data["exposed_bytes"]),
                "total_bytes": int(tool_data["exposed_bytes"]),
            }
        )
        exposed_bytes = int(exposure["total_bytes"])
        context_cache: Mapping[str, Any] | None = None
        if production_mode:
            assert context_cache_contract is not None
            context_cache = {
                **context_cache_contract,
                "input_tokens": int(metrics["input_tokens"]),
                "output_tokens": int(metrics["output_tokens"]),
                "cache_read_tokens": int(metrics["cache_read_tokens"]),
                "cache_write_tokens": int(metrics["cache_write_tokens"]),
                "cache_break_count": int(metrics.get("cache_break_count", 0)),
                "compact_request_count": int(metrics["compact_request_count"]),
                "auto_compact_event_count": int(
                    metrics.get("auto_compact_event_count", 0)
                ),
                "context_projection_count": int(
                    metrics.get("context_projection_count", 0)
                ),
                "context_projected_bytes": int(
                    metrics.get("context_projected_bytes", 0)
                ),
                "memory_exposed_tokens": (exposed_bytes + 3) // 4,
                "original_context_preserved": (
                    int(metrics.get("auto_compact_event_count", 0)) == 0
                    and int(metrics.get("context_projection_count", 0)) == 0
                ),
            }
        remembered_node_ids = [int(node_id) for node_id in tool_data["remembered_node_ids"]]
        if memory_backend == "tinykg":
            memory_reads = int(cassette_activity["tinykg_reads"])
            memory_writes = int(cassette_activity["tinykg_writes"])
            foreign_memory_events = int(
                cassette_activity["markdown_reads"] + cassette_activity["markdown_writes"]
            )
        elif memory_backend == "markdown":
            memory_reads = int(cassette_activity["markdown_reads"])
            memory_writes = int(cassette_activity["markdown_writes"])
            foreign_memory_events = int(
                cassette_activity["tinykg_reads"] + cassette_activity["tinykg_writes"]
            )
        elif memory_backend == "tinykg_integrated":
            memory_reads = int(
                cassette_activity["tinykg_reads"] + cassette_activity["markdown_reads"]
            )
            memory_writes = int(
                cassette_activity["tinykg_writes"] + cassette_activity["markdown_writes"]
            )
            foreign_memory_events = 0
        else:
            memory_reads = 0
            memory_writes = 0
            foreign_memory_events = sum(
                int(cassette_activity[key])
                for key in (
                    "tinykg_reads",
                    "tinykg_writes",
                    "markdown_reads",
                    "markdown_writes",
                )
            )
        if foreign_memory_events != 0:
            _fail(f"native memory rollout {run_id}", "cross-backend memory activity")
        if production_mode:
            if int(metrics["tool_calls"]) < memory_reads + memory_writes:
                _fail(f"native memory rollout {run_id}", "memory activity exceeds native tools")
        else:
            if int(metrics["tool_calls"]) != memory_reads + memory_writes:
                _fail(f"native memory rollout {run_id}", "scripted lifecycle reached an undeclared tool")
            if int(metrics["model_tool_errors"] + metrics["harness_tool_errors"]) != 0:
                _fail(f"native memory rollout {run_id}", "scripted lifecycle contains a tool failure")
        if len([item for item in query_variants if item["kind"] == "semantic"]) > 4:
            _fail(f"native memory rollout {run_id}", "semantic query cap exceeded")
        if memory_dir is not None:
            markdown_revision_after = _artifact_tree_digest(
                memory_dir,
                "markdown memory after rollout",
            )
            markdown_files_after = sum(1 for path in memory_dir.rglob("*") if path.is_file())
        if tinykg_enabled:
            assert store is not None
            _assert_tinykg_read_transients_clean(
                store, f"native memory rollout {run_id}"
            )
            graph_revision_after = _tree_digest(store, normalize_store_manifest=True)
            raw_store_digest_after = _tree_digest(store)
            info_after = _store_info(local.command("store-info", store, ()))
            _assert_tinykg_read_transients_clean(
                store, f"native memory rollout {run_id} post-observation"
            )
            store_nodes, store_edges = int(info_after["nodes"]), int(info_after["edges"])
            if info_after.get("text_stale") not in {"0", "1"}:
                _fail(f"native memory rollout {case['id']}", "invalid TinyKG text_stale state")
            store_text_stale = info_after["text_stale"] == "1"
            if production_mode:
                assert markdown_revision_after is not None
                memory_state_after = _canonical_sha256(
                    {"markdown": markdown_revision_after, "tinykg": graph_revision_after}
                )
            else:
                memory_state_after = graph_revision_after
            if online_memory:
                if production_mode:
                    assert markdown_state is not None
                    if markdown_state.exists():
                        _fail("procedural integrated runtime", "online state already exists")
                    assert memory_dir is not None
                    _copy_memory_tree(memory_dir, markdown_state)
                else:
                    if memory_writes < 1 or graph_revision_after == graph_revision_before:
                        _fail(f"native memory rollout {run_id}", "online TinyKG phase did not commit memory")
                    if raw_store_digest_after == raw_store_digest_before:
                        _fail(f"native memory rollout {run_id}", "online TinyKG bytes did not change")
                    if len(set(remembered_node_ids)) != 1:
                        _fail(f"native memory rollout {run_id}", "online TinyKG insert was not observable")
            else:
                if graph_revision_after != graph_revision_before:
                    _fail(f"native memory rollout {run_id}", "read-only memory rollout changed TinyKG store")
                if raw_store_digest_after != raw_store_digest_before:
                    _fail(
                        f"native memory rollout {run_id}",
                        "read-only memory rollout changed raw TinyKG store bytes",
                    )
                if production_mode:
                    if memory_writes != 0 or markdown_revision_after != markdown_revision_before:
                        _fail(f"native memory rollout {run_id}", "read-only integrated memory changed")
                elif memory_reads < 1 or not query_variants or not provider_memory_verified:
                    _fail(f"native memory rollout {run_id}", "TinyKG arm did not call KgRecall")
        elif runtime_arm == "claude_style":
            assert memory_dir is not None
            assert markdown_revision_after is not None
            memory_state_after = (
                _canonical_sha256({"markdown": markdown_revision_after, "tinykg": None})
                if production_mode
                else markdown_revision_after
            )
            if online_memory:
                if not production_mode and (
                    memory_writes < 1 or memory_state_after == memory_state_before
                ):
                    _fail(f"native memory rollout {run_id}", "online Markdown phase did not persist memory")
                assert markdown_state is not None
                if markdown_state.exists():
                    _fail("procedural Markdown runtime", "online state already exists")
                _copy_memory_tree(memory_dir, markdown_state)
            else:
                if memory_writes != 0 or memory_state_after != memory_state_before:
                    _fail(f"native memory rollout {run_id}", "read-only Markdown phase changed memory")
                if (
                    not production_mode
                    and (memory_reads < 1 or not query_variants or not provider_memory_verified)
                ):
                    _fail(f"native memory rollout {run_id}", "Markdown arm did not read durable memory")
        elif query_variants or memory_reads != 0 or memory_writes != 0:
            _fail(f"native memory rollout {run_id}", "no-memory control reached memory tools")

        inserted_nodes = 0
        if online_memory and memory_backend == "markdown":
            inserted_nodes = (
                max(0, markdown_files_after - markdown_files_before)
                if production_mode
                else 1
            )
        elif online_memory and memory_backend in {"tinykg", "tinykg_integrated"}:
            inserted_nodes = (
                max(0, store_nodes - store_nodes_before)
                if production_mode
                else len(set(remembered_node_ids))
            )

        retrieval_enabled = (
            bool(query_variants) or host_recall_injected
            if production_mode
            else memory_reads > 0 or host_recall_injected
        )
        if memory_backend == "none":
            active_memory = 0
            provenance_links = 0
        elif memory_backend == "markdown":
            assert memory_dir is not None
            active_memory = sum(1 for path in memory_dir.rglob("*") if path.is_file())
            provenance_links = 1 if active_memory >= 2 else 0
        else:
            active_memory = store_nodes
            provenance_links = store_edges

        evaluator_invalid: str | None = None
        evaluator_invalid = _query_plan_evaluator_invalid_reason(
            scoped_recall_activation,
            query_plan_trace,
        )
        if case["benchmark"] == "procedural_transfer":
            validator_entry = validators.get(case["id"])
            if validator_entry is None:
                evaluator_invalid = evaluator_invalid or "validator bundle missing case"
        if production_mode and read_only_memory and memory_backend == "markdown":
            if int(exposure["auto_injected_bytes"]) <= 0 and int(
                exposure["tool_result_bytes"]
            ) <= 0:
                evaluator_invalid = (
                    evaluator_invalid
                    or "Markdown backend exposed no durable memory"
                )
        if production_mode and read_only_memory and tinykg_enabled:
            explicit_recall = bool(
                memory_reads > 0 and query_variants and int(exposure["tool_result_bytes"]) > 0
            )
            if not host_recall_injected and not explicit_recall:
                evaluator_invalid = (
                    evaluator_invalid
                    or "TinyKG backend exposed no verified host or explicit recall"
                )

        observation: Mapping[str, Any] = {
            "schema_version": OBSERVATION_SCHEMA_VERSION,
            "protocol_id": PROTOCOL_ID,
            "case_id": case["id"],
            "trial": schedule["trial"],
            "arm": arm_id,
            "execution": {"status": "completed", "invalid_reason": None},
            "workspace": {"deterministic_success": deterministic_success},
            "evaluator": {
                "status": "invalid" if evaluator_invalid else "ready",
                "invalid_reason": evaluator_invalid,
                "deterministic_success": deterministic_success if not evaluator_invalid else None,
            },
            "prediction": str(result["text"]),
            "retrieval": {
                "enabled": retrieval_enabled,
                "k": (8 if tinykg_enabled else 1) if retrieval_enabled else 0,
                "hop_count": 1 if (provider_memory_verified or verified) else 0,
                "query_variants": query_variants,
                "retrieved_evidence_ids": retrieved,
                "verified_evidence_ids": verified,
                "graph_truncated": graph_truncated,
            },
            "memory": {
                "write_mode": (
                    "disabled"
                    if memory_backend == "none"
                    else "online" if online_memory else "read_only"
                ),
                "exposed_tokens": (exposed_bytes + 3) // 4,
                "internal_tokens": 0,
                "inserted_nodes": inserted_nodes,
                "active_nodes": active_memory,
                "provenance_links": provenance_links,
                "abstraction_nodes": abstraction_nodes if tinykg_enabled else 0,
                "abstraction_nodes_with_provenance": abstraction_nodes if tinykg_enabled else 0,
                "candidate_fanout": float(len(retrieved) if tinykg_enabled else memory_reads),
            },
            "graph": {
                "revision": graph_revision_after if tinykg_enabled else memory_state_after,
                "text_stale": store_text_stale,
                "retrieval_excluded_nodes": 0,
                "contradiction_edges": 0,
            },
            "governance": {
                "stale_candidates": 0,
                "stale_rejected": 0,
                "contradictory_candidates": 0,
                "contradictory_rejected": 0,
                "retrieval_excluded_returned": 0,
                "provenance_missing_returned": 0,
                # Historical field name; semantically covers every read-only
                # lifecycle, including QA's frozen ``test`` split.
                "offline_write_events": memory_writes if read_only_memory else 0,
            },
            "cost": {
                "cost_usd": metric_cost if production_mode else 0.0,
                "wall_time_ms": float(metrics["wall_time_ms"]),
            },
            "trajectory": {
                "model_requests": int(metrics["model_request_count"]),
                "tool_calls": int(metrics["tool_calls"]),
                "tool_errors": int(metrics["model_tool_errors"] + metrics["harness_tool_errors"]),
                "turns": int(metrics["turns"]),
            },
        }
        observations.append(observation)
        rollout_receipt: Dict[str, Any] = {
                "sequence": expected_sequence,
                "case_id": case["id"],
                "trial": schedule["trial"],
                "arm": arm_id,
                "run_id": run_id,
                "task_fingerprint": _canonical_sha256(case),
                "metacodes_binary_sha256": metacodes_sha,
                "tinykg_binary_sha256": tinykg_sha if tinykg_enabled else None,
                "native_events_sha256": file_sha256(events),
                "result_sha256": file_sha256(stdout_path),
                "stderr_sha256": file_sha256(stderr_path),
                "cassette_sha256": _artifact_tree_digest(cassette),
                "transcript_sha256": _artifact_tree_digest(sealed_home),
                "workspace_sha256": _artifact_tree_digest(workspace),
                "artifact_paths": {
                    "native_events": artifact_relative(events, "native events artifact"),
                    "result": artifact_relative(stdout_path, "native result artifact"),
                    "stderr": artifact_relative(stderr_path, "native stderr artifact"),
                    "cassette": artifact_relative(cassette, "provider cassette artifact"),
                    "transcript": artifact_relative(sealed_home, "transcript artifact"),
                    "workspace": artifact_relative(workspace, "workspace artifact"),
                    "store": artifact_relative(store, "TinyKG store artifact")
                    if store is not None
                    else None,
                    "memory_state": artifact_relative(memory_dir, "Markdown memory artifact")
                    if memory_dir is not None
                    else None,
                },
                "store_revision_before": graph_revision_before,
                "store_revision_after": graph_revision_after,
                "raw_store_digest_before": raw_store_digest_before,
                "raw_store_digest_after": raw_store_digest_after,
                "memory_backend": memory_backend,
                "memory_phase": split,
                "memory_state_before": memory_state_before,
                "memory_state_after": memory_state_after,
                "memory_read_events": memory_reads,
                "memory_write_events": memory_writes,
                "stop_reason": result["stop_reason"],
                "provider_requests": provider_request_count,
                "estimated_cost_usd": float(metrics["cost_usd"]),
                "observation_sha256": _canonical_sha256(observation),
                "host_elapsed_ms": elapsed_ms,
        }
        if production_mode:
            assert treatment_activation is not None
            assert budget_transaction_receipt is not None
            assert sandbox is not None
            assert sandbox_profile_path is not None
            assert sandbox_evidence_path is not None
            assert sandbox_evidence is not None
            rollout_receipt.update(
                {
                    "harness_fingerprint": harness_fingerprint,
                    "environment": environment_claim,
                    "environment_fingerprint": environment_fingerprint,
                    "memory_components_before": {
                        "markdown": markdown_revision_before,
                        "tinykg": graph_revision_before if tinykg_enabled else None,
                    },
                    "memory_components_after": {
                        "markdown": markdown_revision_after,
                        "tinykg": graph_revision_after if tinykg_enabled else None,
                    },
                    "provider_mode": "production-network",
                    "tool_network_isolation": PRODUCTION_TOOL_NETWORK_ISOLATION,
                    "filesystem_isolation": PRODUCTION_FILESYSTEM_ISOLATION,
                    "provider_billed_cost_usd": None,
                    "metered_tokens": metered_tokens,
                    "pricing_provenance": pricing_provenance,
                    "compact_event_count": compact_event_count,
                    "memory_auto_injected_bytes": int(exposure["auto_injected_bytes"]),
                    "memory_tool_result_bytes": int(exposure["tool_result_bytes"]),
                    "context_cache": context_cache,
                    "treatment_activation": treatment_activation,
                    "scoped_recall": scoped_recall_activation,
                    "consolidation": consolidation_receipt,
                    "budget_transaction": budget_transaction_receipt,
                    "sandbox": {
                        "backend": PRODUCTION_SANDBOX_BACKEND,
                        "profile_path": artifact_relative(
                            sandbox_profile_path,
                            "production sandbox profile",
                        ),
                        "profile_sha256": sandbox.profile_sha256,
                        "probe_path": artifact_relative(
                            sandbox_evidence_path,
                            "production sandbox probe",
                        ),
                        "probe_sha256": file_sha256(sandbox_evidence_path),
                    },
                }
            )
        else:
            rollout_receipt.update(
                {
                    "provider_mode": "scripted-local",
                    "external_network_calls": 0,
                    "paid_cost_usd": 0.0,
                }
            )
        rollout_receipts.append(rollout_receipt)

        if production is not None:
            assert budget_journal is not None
            budget_checkpoint_payload = budget_journal.checkpoint_payload()
            budget_state = validate_checkpoint_payload(budget_checkpoint_payload)
            budget_checkpoint_path = resolved_run / (
                f"rollout-budget-checkpoint-r{int(budget_state['revision']):08d}.json"
            )
            _write_new(budget_checkpoint_path, budget_checkpoint_payload)
            budget_checkpoint_entry = {
                "path": budget_checkpoint_path.relative_to(resolved_run).as_posix(),
                "sha256": _hash_bytes(budget_checkpoint_payload),
                "revision": int(budget_state["revision"]),
                "head_sha256": str(budget_state["head_sha256"]),
            }
            budget_checkpoint_history.append(budget_checkpoint_entry)
            budget_snapshot = budget_journal.snapshot()
            if (
                budget_snapshot["unsettled_max_cost_microusd"] != 0
                or budget_snapshot["unsettled_max_metered_tokens"] != 0
            ):
                _fail("production memory runtime", "checkpoint has unsettled budget exposure")
            budget_journal_receipt = {
                **budget_snapshot,
                "checkpoint_path": budget_checkpoint_entry["path"],
                "checkpoint_sha256": budget_checkpoint_entry["sha256"],
            }
            candidate_receipt = _build_runtime_receipt(
                manifest=manifest,
                source_sha=source_sha,
                runner_sources=runner_sources,
                observations=observations,
                rollout_receipts=rollout_receipts,
                metacodes_sha=metacodes_sha,
                tinykg_sha=tinykg_sha,
                production=production,
                production_ripgrep=production_ripgrep,
                artifact_relative=artifact_relative,
                budget_journal_receipt=budget_journal_receipt,
            )
            validate_runtime_receipt(
                candidate_receipt,
                manifest,
                observations,
                source_sha,
                f"rollout resume receipt {expected_sequence}",
            )
            # Validate the just-finished line before it becomes resumable.  A
            # full historical validation is done once on resume/finalization;
            # keeping this check O(1) avoids quadratic hashing across 144 rows.
            latest_only_receipt = _build_runtime_receipt(
                manifest=manifest,
                source_sha=source_sha,
                runner_sources=runner_sources,
                observations=observations[-1:],
                rollout_receipts=rollout_receipts[-1:],
                metacodes_sha=metacodes_sha,
                tinykg_sha=tinykg_sha,
                production=production,
                production_ripgrep=production_ripgrep,
                artifact_relative=artifact_relative,
                budget_journal_receipt=budget_journal_receipt,
            )
            validate_runtime_artifacts(
                latest_only_receipt,
                resolved_run,
                f"rollout resume line {expected_sequence}",
            )
            resume_document = {
                "schema_version": ROLLOUT_RESUME_CHECKPOINT_SCHEMA,
                "status": "partial",
                "manifest_sha256": _canonical_sha256(manifest),
                "dataset_sha256": source_sha,
                "metacodes_binary_sha256": metacodes_sha,
                "tinykg_binary_sha256": tinykg_sha,
                "ripgrep_binary_sha256": production.ripgrep_binary_sha256,
                "runner_sources_sha256": runner_sources_sha,
                "completed_sequences": list(range(len(observations))),
                "observations": observations,
                "candidate_runtime_receipt": candidate_receipt,
                "budget_checkpoints": budget_checkpoint_history,
            }
            resume_payload = (stable_json(resume_document) + "\n").encode("utf-8")
            _assert_production_secret_absent(
                resolved_run,
                production.api_key,
                pending_payloads=(("pending rollout resume checkpoint", resume_payload),),
            )
            _replace_private_file(
                resolved_run / ROLLOUT_RESUME_CHECKPOINT_NAME,
                resume_payload,
            )
            if budget_fault_hook is not None:
                budget_fault_hook("after_rollout_resume_checkpoint", resume_document)

    budget_journal_receipt: Mapping[str, Any] | None = None
    if production is not None:
        assert budget_journal is not None
        final_budget = budget_journal.snapshot()
        if (
            final_budget["unsettled_max_cost_microusd"] != 0
            or final_budget["unsettled_max_metered_tokens"] != 0
        ):
            _fail("production memory runtime", "successful schedule has unsettled budget exposure")
        if not budget_checkpoint_history:
            _fail("production memory runtime", "missing rollout budget checkpoint")
        final_budget_checkpoint = budget_checkpoint_history[-1]
        budget_journal_receipt = {
            **final_budget,
            "checkpoint_path": final_budget_checkpoint["path"],
            "checkpoint_sha256": final_budget_checkpoint["sha256"],
        }
    receipt = _build_runtime_receipt(
        manifest=manifest,
        source_sha=source_sha,
        runner_sources=runner_sources,
        observations=observations,
        rollout_receipts=rollout_receipts,
        metacodes_sha=metacodes_sha,
        tinykg_sha=tinykg_sha,
        production=production,
        production_ripgrep=production_ripgrep,
        artifact_relative=artifact_relative,
        budget_journal_receipt=budget_journal_receipt,
    )
    observations_payload = b"".join(
        (stable_json(row) + "\n").encode("utf-8") for row in observations
    )
    receipt_payload = (stable_json(receipt) + "\n").encode("utf-8")
    if production is not None:
        _assert_production_secret_absent(
            resolved_run,
            production.api_key,
            pending_payloads=(
                ("pending observations", observations_payload),
                ("pending runtime receipt", receipt_payload),
            ),
        )
    # Join before canonical publication: a malformed observation must not
    # leave runtime-receipt.json looking complete.  A paid run has already
    # incurred irreversible provider cost, though, so preserve an explicitly
    # invalid candidate checkpoint before re-raising.  This closes the
    # evidence-loss window without making the candidate promotable.
    try:
        replay_observations(
            manifest,
            observations,
            dataset_source=source_path,
            runtime_receipt=receipt,
            runtime_artifact_root=resolved_run,
        )
    except ValidationError as exc:
        if production is not None:
            _write_failed_validation_checkpoint(
                resolved_run,
                observations_payload=observations_payload,
                receipt=receipt,
                error=exc,
                budget_journal_receipt=budget_journal_receipt,
            )
        raise
    _write_new(
        observations_output,
        observations_payload,
    )
    _write_new(
        receipt_output,
        receipt_payload,
    )
    return observations, receipt
