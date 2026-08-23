"""Normalize the existing shell E2E artifacts into trace-aware rollouts."""

from __future__ import annotations

import hashlib
import json
import math
import os
import platform
import re
import stat
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from .model import SCHEMA_VERSION, ValidationError, stable_json


# Evaluator semantics and native event wire compatibility are separate
# identities. A scoring-rule change must move the grader fingerprint without
# forcing a byte-compatible native emitter to rev its wire schema.
EVALUATION_CONTRACT_VERSION = 4
NATIVE_EVENT_SCHEMA_VERSION = 3
MAX_NATIVE_EVENT_BYTES = 64 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
MAX_VALIDATOR_OUTPUT_BYTES = 1024 * 1024


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
USAGE_RE = re.compile(
    r"usage in=(\d+) out=(\d+) cache_r=(\d+) cache_w=(\d+)"
)
MODEL_RE = re.compile(r"metacodes starting; model=([^\s]+)")
SESSION_TIMEOUT_RE = re.compile(r"单段超时:\s*(\d+)s")
TURN_RE = re.compile(r"turn\s+(\d+)/(\d+)\s+starting")
TOOL_START_RE = re.compile(r"tool\.exec start(?:\(par\))? name=([A-Za-z0-9_]+)")
TOOL_DONE_RE = re.compile(
    r"tool\.exec done(?:\(par\))? name=([A-Za-z0-9_]+).*?duration_ms=(\d+)"
)
TOOL_FAIL_RE = re.compile(
    r"tool\.exec FAILED(?:\(par\))? name=([A-Za-z0-9_]+) "
    r"err=([^\s,]+).*?duration_ms=(\d+)"
)
HEADER_LATENCY_RE = re.compile(r"header_latency_ms=(\d+)")
PERMISSION_DENY_RE = re.compile(r"tool=([A-Za-z0-9_]+) decision=deny")
COST_RE = re.compile(r"(?:estimated_)?cost_usd=\$?([0-9]+(?:\.[0-9]+)?)")
HARNESS_ERROR_RE = re.compile(
    r"panic|unreachable|StreamTooLong|RequestFailed|ApiError|Unauthorized|"
    r"RateLimited|ServerError",
    re.IGNORECASE,
)
NETWORK_ERROR_RE = re.compile(
    r"RequestFailed|ApiError|Unauthorized|RateLimited|ServerError", re.IGNORECASE
)
RETRY_RE = re.compile(r"\bretry(?:ing| attempt)?\b", re.IGNORECASE)
MODEL_ARGUMENT_ERROR_PREFIXES = ("Missing", "Invalid", "Empty")
LEGACY_MODEL_TOOL_ERROR_CODES = {
    "NotRead",
    "StaleFile",
    "UnknownTool",
    "NoToolMatch",
    "FileNotFound",
    "MultipleMatches",
    "StringNotFound",
    "ContextNotFound",
    "OldLinesNotFound",
    "NoOpEdit",
}


def _is_policy_failure_code(value: Any) -> bool:
    canonical = re.sub(r"[^a-z0-9]", "", str(value or "").lower())
    return canonical in {
        "permissiondenied",
        "pretooluseblocked",
        "toolpolicydenied",
    }


def _is_model_tool_failure(error_code: Any, error_category: Any = None) -> bool:
    """Classify model-correctable tool failures without blaming the harness.

    Native events expose ``error_category`` when available; debug-log fallback
    and old error names remain useful for unscored legacy imports.
    """
    if str(error_category or "").lower() == "user_error":
        return True
    code = str(error_code or "")
    return code.startswith(MODEL_ARGUMENT_ERROR_PREFIXES) or code in LEGACY_MODEL_TOOL_ERROR_CODES


def _fingerprint(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()[:16]


def _validator_hashes(task: Dict[str, Any], repo_root: Path) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for check in task["success"]["checks"]:
        if check.get("type") != "validator":
            continue
        path = (repo_root / check["validator"]).resolve()
        try:
            relative = path.relative_to(repo_root.resolve()).as_posix()
            if path.is_symlink() or not path.is_file():
                raise OSError("validator is not a regular file")
            payload = path.read_bytes()
        except (OSError, ValueError) as exc:
            raise ValidationError(f"cannot fingerprint validator {path}: {exc}") from exc
        result[relative] = hashlib.sha256(payload).hexdigest()
    return dict(sorted(result.items()))


def _grader_fingerprint(task: Dict[str, Any], repo_root: Path) -> str:
    payload = {
        "evaluation_contract_version": EVALUATION_CONTRACT_VERSION,
        "grader": task["grader"],
        "checks": task["success"]["checks"],
    }
    validator_sha256 = _validator_hashes(task, repo_root)
    if validator_sha256:
        payload["validator_sha256"] = validator_sha256
    return _fingerprint(payload)


def _execution_input_hashes(task: Dict[str, Any], repo_root: Path) -> Dict[str, str]:
    """Hash every checked-in input that can alter a scored episode."""
    scenario = repo_root / task["scenario"]
    paths = [scenario]
    companion = scenario.with_suffix(".conf")
    if companion.is_file():
        paths.append(companion)
    for fixture in task.get("environment", {}).get("fixtures", []):
        paths.append(repo_root / fixture)
    for check in task["success"]["checks"]:
        if check.get("type") == "validator":
            paths.append(repo_root / check["validator"])
    result: Dict[str, str] = {}
    for path in paths:
        try:
            relative = path.resolve().relative_to(repo_root.resolve()).as_posix()
            payload = path.read_bytes()
        except (OSError, ValueError) as exc:
            raise ValidationError(f"cannot fingerprint execution input {path}: {exc}") from exc
        result[relative] = hashlib.sha256(payload).hexdigest()
    snapshot = task.get("environment", {}).get("repository_snapshot")
    if snapshot is not None:
        revision = snapshot["revision"]
        prefix = snapshot["prefix"].strip("/")
        archive_paths = [f"{prefix}/{item.strip('/')}" for item in snapshot["paths"]]
        try:
            git_root = subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "--show-toplevel"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
            ).stdout.strip()
            verified = subprocess.run(
                [
                    "git",
                    "-C",
                    git_root,
                    "rev-parse",
                    "--verify",
                    f"{revision}^{{commit}}",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
            ).stdout.strip()
            listing = subprocess.run(
                [
                    "git",
                    "-C",
                    git_root,
                    "ls-tree",
                    "-r",
                    "--full-tree",
                    revision,
                    "--",
                    *archive_paths,
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=20,
            ).stdout
        except (OSError, subprocess.SubprocessError) as exc:
            raise ValidationError(f"cannot fingerprint repository snapshot: {exc}") from exc
        if verified != revision or not listing:
            raise ValidationError("repository snapshot revision or sparse paths are unavailable")
        for line in listing.splitlines():
            if line.startswith(b"120000 ") or b" commit " in line:
                raise ValidationError("repository snapshot may contain regular files only")
        result[f"git:{revision}:{prefix}"] = hashlib.sha256(listing).hexdigest()
    return dict(sorted(result.items()))


def _canonical_permission_mode(value: str) -> str:
    aliases = {
        "bypassPermissions": "bypass_permissions",
        "dontAsk": "dont_ask",
        "acceptEdits": "accept_edits",
        "prompt": "default",
        "bypass": "bypass_permissions",
    }
    return aliases.get(value, value)


def prepare_runtime_metadata(
    suite: Dict[str, Any],
    repo_root: Path,
    task_id: str,
    *,
    output: Path,
    events_path: str,
    run_id: str,
    trial: int,
    model_provider: str,
    model_id: str,
    harness_config_id: str,
    harness_revision: str,
    permission_mode: str,
    binary_path: Path,
    max_metered_tokens: Optional[int] = None,
    max_cost_usd: Optional[float] = None,
) -> Optional[Dict[str, Any]]:
    """Freeze comparison-critical identities before the child process starts.

    Tasks outside the checked-in evaluation suite are intentionally skipped:
    the shell E2E runner has broader exploratory coverage than the scored suite.
    """
    task = next((item for item in suite["tasks"] if item["id"] == task_id), None)
    if task is None:
        return None
    identity = comparison_fingerprints(
        task,
        repo_root,
        model_provider=model_provider,
        model_id=model_id,
        harness_config_id=harness_config_id,
        harness_revision=harness_revision,
        permission_mode=permission_mode,
        binary_path=binary_path,
    )
    permission_mode = identity["permission_mode"]
    if (max_metered_tokens is None) != (max_cost_usd is None):
        raise ValidationError("runtime budget requires both token and cost caps")
    if max_metered_tokens is not None and (
        not isinstance(max_metered_tokens, int)
        or isinstance(max_metered_tokens, bool)
        or max_metered_tokens <= 0
    ):
        raise ValidationError("runtime max_metered_tokens must be an integer > 0")
    if max_cost_usd is not None and (
        not isinstance(max_cost_usd, (int, float))
        or isinstance(max_cost_usd, bool)
        or not math.isfinite(float(max_cost_usd))
        or float(max_cost_usd) <= 0
    ):
        raise ValidationError("runtime max_cost_usd must be finite and > 0")
    metadata = {
        "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
        "events_path": events_path,
        "run_id": run_id,
        "trial": trial,
        "suite_id": suite["suite_id"],
        "task_id": task_id,
        "task_fingerprint": identity["task_fingerprint"],
        "model_provider": model_provider,
        "model_id": model_id,
        "model_fingerprint": identity["model_fingerprint"],
        "harness_config_id": harness_config_id,
        "harness_revision": harness_revision,
        "harness_fingerprint": identity["harness_fingerprint"],
        "permission_mode": permission_mode,
        "environment_fingerprint": identity["environment_fingerprint"],
        "grader_fingerprint": identity["grader_fingerprint"],
    }
    if max_metered_tokens is not None:
        metadata["max_metered_tokens"] = max_metered_tokens
    if max_cost_usd is not None:
        metadata["max_cost_usd"] = float(max_cost_usd)
    allowed_tools = task["tools"].get("allowed")
    if allowed_tools is not None:
        metadata["allowed_tools"] = list(allowed_tools)
    _write_new_private_file(
        output,
        (json.dumps(metadata, ensure_ascii=False, sort_keys=True) + "\n").encode(
            "utf-8"
        ),
    )
    return metadata


def _write_new_private_file(path: Path, payload: bytes) -> None:
    """Create a private artifact without following or replacing a path.

    Evaluation inputs and outputs are control-plane data. Silently truncating an
    existing path would let a stale file or symlink redirect the evidence stream.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write to evaluation artifact")
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


def finalize_evaluation_fd(fd: int, output: Path) -> None:
    """Materialize an anonymous runner-owned event stream after the agent exits."""
    if isinstance(fd, bool) or fd < 0:
        raise ValidationError("evaluation fd must be a non-negative integer")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValidationError("evaluation fd is not a regular file")
        if info.st_size > MAX_NATIVE_EVENT_BYTES:
            raise ValidationError("evaluation event artifact exceeds 64 MiB")
        os.lseek(fd, 0, os.SEEK_SET)
        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, MAX_NATIVE_EVENT_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_NATIVE_EVENT_BYTES:
                raise ValidationError("evaluation event artifact exceeds 64 MiB")
            chunks.append(chunk)
    except OSError as exc:
        raise ValidationError(f"cannot finalize evaluation fd: {exc}") from exc
    if total != info.st_size:
        raise ValidationError(
            f"evaluation event artifact changed while finalizing: stat={info.st_size} read={total}"
        )
    _write_new_private_file(output, b"".join(chunks))


def comparison_fingerprints(
    task: Dict[str, Any],
    repo_root: Path,
    *,
    model_provider: str,
    model_id: str,
    harness_config_id: str,
    harness_revision: str,
    permission_mode: str,
    binary_path: Path,
) -> Dict[str, str]:
    """Compute the exact identities frozen by ``prepare_runtime_metadata``.

    The paired runner uses the same function to reject stale checkpoints before
    deciding that an expensive rollout can be skipped.
    """
    canonical_permission = _canonical_permission_mode(permission_mode)
    expected_permission = _canonical_permission_mode(
        task["constraints"]["permission_mode"]
    )
    if canonical_permission != expected_permission:
        raise ValidationError(
            f"{task['id']}: runtime permission {canonical_permission!r} does not match "
            f"grounded suite permission {expected_permission!r}"
        )
    execution_inputs = _execution_input_hashes(task, repo_root)
    binary_bytes = binary_path.read_bytes()
    return {
        "permission_mode": canonical_permission,
        "task_fingerprint": _fingerprint(
            {
                "task": task,
                "execution_inputs": execution_inputs,
            }
        ),
        "grader_fingerprint": _grader_fingerprint(task, repo_root),
        "model_fingerprint": _fingerprint(
            {"provider": model_provider, "id": model_id}
        ),
        "harness_fingerprint": _fingerprint(
            {
                "config_id": harness_config_id,
                "revision": harness_revision,
                "binary_sha256": hashlib.sha256(binary_bytes).hexdigest(),
                "permission_mode": canonical_permission,
                "tool_profile": task["tools"]["profile"],
            }
        ),
        "environment_fingerprint": _fingerprint(
            {
                "environment": task["environment"],
                "execution_inputs": execution_inputs,
                "platform": platform.platform(),
                "python": platform.python_version(),
            }
        ),
    }


def grounding_fingerprints(task: Dict[str, Any], repo_root: Path) -> Dict[str, str]:
    """Return suite identities that do not depend on a candidate binary.

    Release gates recompute these values from the checked-in suite so a
    rollout cannot silently substitute different task inputs, grader rules,
    or an execution environment captured on another host.
    """
    execution_inputs = _execution_input_hashes(task, repo_root)
    return {
        "task_fingerprint": _fingerprint(
            {"task": task, "execution_inputs": execution_inputs}
        ),
        "grader_fingerprint": _grader_fingerprint(task, repo_root),
        "environment_fingerprint": _fingerprint(
            {
                "environment": task["environment"],
                "execution_inputs": execution_inputs,
                "platform": platform.platform(),
                "python": platform.python_version(),
            }
        ),
        "permission_mode": _canonical_permission_mode(
            task["constraints"]["permission_mode"]
        ),
    }


def _read(path: Path) -> Tuple[Optional[str], Optional[str]]:
    try:
        return path.read_text(encoding="utf-8", errors="replace"), None
    except OSError as exc:
        return None, str(exc)


def _read_regular_text_capped(
    path: Path, max_bytes: int
) -> Tuple[Optional[str], Optional[str]]:
    """Race-resistant bounded read for control-plane artifacts."""
    try:
        before = path.lstat()
    except FileNotFoundError:
        return None, None
    except OSError as exc:
        return None, str(exc)
    if stat.S_ISLNK(before.st_mode):
        return None, "artifact path is a forbidden symlink"
    if not stat.S_ISREG(before.st_mode):
        return None, "artifact path is not a regular file"
    if before.st_size > max_bytes:
        return None, f"artifact exceeds {max_bytes} byte limit"

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        return None, str(exc)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode):
            return None, "opened artifact is not a regular file"
        if opened.st_size > max_bytes:
            return None, f"artifact exceeds {max_bytes} byte limit"
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            return None, "artifact changed while opening"
        chunks: List[bytes] = []
        total = 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                return None, f"artifact exceeds {max_bytes} byte limit"
            chunks.append(chunk)
        if total != opened.st_size:
            return None, "artifact changed while reading"
        try:
            return b"".join(chunks).decode("utf-8"), None
        except UnicodeDecodeError as exc:
            return None, f"artifact is not valid UTF-8: {exc}"
    except OSError as exc:
        return None, str(exc)
    finally:
        os.close(fd)


def _assistant_text(path: Path) -> Tuple[Optional[str], Optional[str]]:
    text, read_error = _read(path)
    if read_error is not None:
        return None, read_error
    assistant_blocks: List[str] = []
    try:
        for line_no, line in enumerate((text or "").splitlines(), 1):
            if not line.strip():
                continue
            message = json.loads(line)
            if not isinstance(message, dict):
                raise ValueError(f"line {line_no}: expected object")
            if message.get("role") != "assistant":
                continue
            blocks = message.get("blocks")
            if not isinstance(blocks, list):
                raise ValueError(f"line {line_no}: assistant blocks must be a list")
            for block in blocks:
                if (
                    isinstance(block, dict)
                    and block.get("type") == "text"
                    and isinstance(block.get("text"), str)
                ):
                    assistant_blocks.append(block["text"])
    except (json.JSONDecodeError, ValueError) as exc:
        return None, f"malformed transcript: {exc}"
    return "\n".join(assistant_blocks), None


def _workspace_target(workspace: Path, relative: str) -> Tuple[Optional[Path], Optional[str]]:
    """Resolve a grader path without accepting traversal or symlink tricks."""
    requested = Path(relative)
    if not relative or requested.is_absolute() or ".." in requested.parts:
        return None, f"unsafe workspace-relative path: {relative!r}"
    try:
        root = workspace.resolve(strict=True)
    except OSError as exc:
        return None, f"cannot resolve workspace: {exc}"
    target = root.joinpath(*requested.parts)
    current = root
    try:
        for part in requested.parts:
            current = current / part
            try:
                current.lstat()
            except FileNotFoundError:
                break
            if current.is_symlink():
                return None, f"grader path contains forbidden symlink: {relative!r}"
    except OSError as exc:
        return None, f"cannot inspect grader path {relative!r}: {exc}"
    try:
        target.relative_to(root)
    except ValueError:
        return None, f"grader path escapes workspace: {relative!r}"
    return target, None


def _report_exit_code(report: str, task_id: str) -> Optional[int]:
    section_re = re.compile(
        rf"^##\s+场景:\s+{re.escape(task_id)}\s*$([\s\S]*?)(?=^##\s+场景:|^##\s+摘要|\Z)",
        re.MULTILINE,
    )
    match = section_re.search(report)
    if match:
        code = re.search(r"session\s+退出码:\s+`(-?\d+)`", match.group(1))
        if code:
            return int(code.group(1))
    row = re.search(
        rf"^\|\s*{re.escape(task_id)}\s*\|\s*(-?\d+)\s*\|", report, re.MULTILINE
    )
    return int(row.group(1)) if row else None


def _report_timeout_seconds(report: str) -> Optional[int]:
    match = SESSION_TIMEOUT_RE.search(report)
    if match is None:
        return None
    value = int(match.group(1))
    return value if value > 0 else None


def _trace_metrics(debug_log: str) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    clean = ANSI_RE.sub("", debug_log)
    lines = clean.splitlines()
    usage_text = "\n".join(
        line for line in lines if "[INFO agent" in line and "usage in=" in line
    )
    diagnostic_text = "\n".join(
        line
        for line in lines
        if "[WARN " in line
        or "[ERROR " in line
        or re.search(r"panic|unreachable", line, re.IGNORECASE)
    )
    usages = [tuple(map(int, match.groups())) for match in USAGE_RE.finditer(usage_text)]
    tool_starts = TOOL_START_RE.findall(clean)
    tool_done = [(name, int(duration)) for name, duration in TOOL_DONE_RE.findall(clean)]
    failures = [
        (name, error, int(duration))
        for name, error, duration in TOOL_FAIL_RE.findall(clean)
    ]
    model_failures = [item for item in failures if _is_model_tool_failure(item[1])]
    policy_failures = [item for item in failures if _is_policy_failure_code(item[1])]
    harness_failures = [
        item
        for item in failures
        if item not in model_failures and item not in policy_failures
    ]
    turns = [int(value) for value, _limit in TURN_RE.findall(clean)]
    costs = [float(value) for value in COST_RE.findall("\n".join(line for line in lines if "[INFO " in line))]
    permission_denials = len(PERMISSION_DENY_RE.findall(clean))
    harness_errors = len(HARNESS_ERROR_RE.findall(diagnostic_text))
    network_errors = len(NETWORK_ERROR_RE.findall(diagnostic_text))

    metrics: Dict[str, Any] = {
        "input_tokens": sum(item[0] for item in usages),
        "output_tokens": sum(item[1] for item in usages),
        "cache_read_tokens": sum(item[2] for item in usages),
        "cache_write_tokens": sum(item[3] for item in usages),
        "cost_usd": sum(costs) if costs else None,
        "wall_time_ms": None,
        "model_header_latency_ms": sum(
            int(value) for value in HEADER_LATENCY_RE.findall(clean)
        ),
        "model_request_time_ms": None,
        "model_request_count": None,
        "model_request_outcomes": None,
        "compact_request_count": None,
        "compact_request_time_ms": None,
        "compact_request_outcomes": None,
        "tool_time_ms": sum(duration for _name, duration in tool_done)
        + sum(duration for _name, _error, duration in failures),
        "tool_stage_time_ms": None,
        "harness_time_ms": None,
        "turns": len(turns),
        "tool_calls": len(tool_starts),
        "tool_successes": len(tool_done),
        "model_tool_errors": len(model_failures),
        "model_tool_error_distribution": {
            f"{name}:{error}": sum(
                1 for other_name, other_error, _duration in model_failures
                if other_name == name and other_error == error
            )
            for name, error, _duration in sorted(set(model_failures))
        },
        "harness_tool_errors": len(harness_failures),
        "harness_errors": harness_errors,
        "network_errors": network_errors,
        "permission_denials": permission_denials,
        "policy_violations": None,
        "retries": len(RETRY_RE.findall(diagnostic_text)),
        "tool_distribution": {
            name: tool_starts.count(name) for name in sorted(set(tool_starts))
        },
    }
    trace_failures = [
        {"tool": name, "error": error, "duration_ms": duration}
        for name, error, duration in failures
    ]
    return metrics, trace_failures


def _count_policy_violations(
    tool_starts: List[Dict[str, Any]], policies: List[Dict[str, Any]]
) -> int:
    """Count tool attempts without a decision for the same trace and id."""
    decisions_by_attempt: Dict[Tuple[str, str], int] = {}
    for item in policies:
        key = (str(item.get("trace_id", "unknown")), str(item.get("id", "")))
        decisions_by_attempt[key] = decisions_by_attempt.get(key, 0) + 1
    return sum(
        # tool_started is the model-attempt lifecycle and includes denied
        # slots. A deny is enforcement, not a violation. Pair by exact
        # trace/id so duplicate decisions for one Write cannot conceal a
        # missing decision for another Write in the same run.
        1
        for item in tool_starts
        if decisions_by_attempt.get(
            (str(item.get("trace_id", "unknown")), str(item.get("id", ""))), 0
        )
        == 0
    )


def _run_validator_capped(
    command: List[str],
    *,
    cwd: Path,
    env: Dict[str, str],
    timeout_seconds: int,
) -> Tuple[int, int, str, bool, bool]:
    """Drain validator output without allowing an unbounded pipe allocation."""
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert process.stdout is not None
    tail = bytearray()
    state: Dict[str, Any] = {"bytes": 0, "overflow": False, "error": None}

    def drain() -> None:
        try:
            while True:
                chunk = process.stdout.read(64 * 1024)
                if not chunk:
                    return
                state["bytes"] += len(chunk)
                tail.extend(chunk)
                if len(tail) > 4000:
                    del tail[:-4000]
                if state["bytes"] > MAX_VALIDATOR_OUTPUT_BYTES:
                    state["overflow"] = True
                    try:
                        process.kill()
                    except OSError:
                        pass
                    return
        except OSError as exc:
            state["error"] = exc
        finally:
            process.stdout.close()

    reader = threading.Thread(target=drain, name="eval-validator-output", daemon=True)
    reader.start()
    timed_out = False
    try:
        returncode = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        returncode = process.wait()
    reader.join(timeout=2)
    if reader.is_alive():
        process.stdout.close()
        reader.join(timeout=1)
    if reader.is_alive():
        raise OSError("validator output pipe did not close after process exit")
    if state["error"] is not None and not timed_out and not state["overflow"]:
        raise OSError(f"cannot read validator output: {state['error']}")
    combined = bytes(tail).decode("utf-8", "replace").strip()
    return (
        returncode,
        int(state["bytes"]),
        combined,
        bool(state["overflow"]),
        timed_out,
    )


def _evaluate_check(
    check: Dict[str, Any],
    workspace: Path,
    log_text: str,
    debug_log_text: str = "",
    *,
    repo_root: Optional[Path] = None,
) -> Dict[str, Any]:
    kind = check["type"]
    description = check.get("description") or kind
    target: Optional[Path] = None
    target_text: Optional[str] = None
    read_error: Optional[str] = None
    passed = False
    detail = ""
    if kind == "validator":
        if repo_root is None:
            read_error = "validator check requires an explicit repository root"
        else:
            validator = (repo_root / check["validator"]).resolve()
            try:
                validator.relative_to(repo_root.resolve())
                if validator.is_symlink() or not validator.is_file():
                    raise OSError("validator is not a regular file")
                returncode, output_bytes, combined, overflow, timed_out = (
                    _run_validator_capped(
                        [
                            sys.executable,
                            "-I",
                            str(validator),
                            str(workspace.resolve()),
                        ],
                        cwd=workspace,
                        env={
                            "PATH": os.environ.get("PATH", ""),
                            "LANG": "C.UTF-8",
                            "LC_ALL": "C.UTF-8",
                        },
                        timeout_seconds=check.get("timeout_seconds", 30),
                    )
                )
                if timed_out:
                    read_error = f"validator exceeded {check.get('timeout_seconds', 30)}s"
                elif overflow:
                    read_error = (
                        f"validator output exceeds {MAX_VALIDATOR_OUTPUT_BYTES} byte limit"
                    )
                else:
                    passed = returncode == 0
                detail = (
                    f"{check['validator']} exited {returncode} "
                    f"output_bytes={output_bytes}: {combined}"
                )
            except (OSError, ValueError) as exc:
                read_error = f"cannot execute validator: {exc}"
    elif kind not in {
        "log_contains",
        "log_not_contains",
        "debug_log_contains",
        "debug_log_not_contains",
        "debug_tool_input_contains",
        "debug_tool_input_not_contains",
        "assistant_contains",
    }:
        target, read_error = _workspace_target(workspace, check["path"])
        if target is not None and kind not in {"file_exists", "file_absent"}:
            try:
                file_stat = os.stat(target, follow_symlinks=False)
                if not stat.S_ISREG(file_stat.st_mode):
                    read_error = f"grader path is not a regular file: {check['path']!r}"
                elif file_stat.st_size > 16 * 1024 * 1024:
                    read_error = f"grader file exceeds 16 MiB limit: {check['path']!r}"
                else:
                    target_text, read_error = _read(target)
            except FileNotFoundError:
                # A missing product artifact is a deterministic negative
                # outcome, not a grader malfunction.  Keep target_text=None
                # so contains/contains_any/min_lines/not_contains all fail
                # closed while the evaluator remains ready.
                target_text = None
                read_error = None
            except OSError as exc:
                read_error = str(exc)
    elif kind == "assistant_contains":
        target, read_error = _workspace_target(workspace, "transcript.jsonl")
        if target is not None and read_error is None:
            try:
                file_stat = os.stat(target, follow_symlinks=False)
                if not stat.S_ISREG(file_stat.st_mode):
                    read_error = "grader transcript is not a regular file"
                elif file_stat.st_size > 16 * 1024 * 1024:
                    read_error = "grader transcript exceeds 16 MiB limit"
                else:
                    target_text, read_error = _assistant_text(target)
            except OSError as exc:
                read_error = str(exc)

    if kind == "validator":
        pass
    elif kind == "file_exists":
        passed = bool(target and read_error is None and target.is_file())
        detail = f"{check['path']} {'exists' if passed else 'is missing'}"
    elif kind == "file_absent":
        # lexists semantics: a dangling symlink is still an artifact. Symlinks
        # are rejected above, so they also make the evaluator invalid.
        passed = bool(
            target
            and read_error is None
            and not os.path.lexists(os.fspath(target))
        )
        detail = f"{check['path']} {'is absent' if passed else 'unexpectedly exists'}"
    elif kind in {"contains", "not_contains"}:
        needle = check["text"]
        contains = target_text is not None and needle in target_text
        passed = contains if kind == "contains" else target_text is not None and not contains
        detail = f"{check['path']} {'contains' if contains else 'does not contain'} {needle!r}"
    elif kind in {"contains_casefold", "not_contains_casefold"}:
        needle = check["text"]
        contains = (
            target_text is not None
            and needle.casefold() in target_text.casefold()
        )
        passed = (
            contains
            if kind == "contains_casefold"
            else target_text is not None and not contains
        )
        detail = (
            f"{check['path']} "
            f"{'contains' if contains else 'does not contain'} {needle!r} (casefold)"
        )
    elif kind == "contains_any":
        haystack = target_text.lower() if target_text is not None else ""
        matched = [needle for needle in check["texts"] if needle.lower() in haystack]
        passed = target_text is not None and bool(matched)
        detail = f"{check['path']} matched_any={matched!r} candidates={check['texts']!r}"
    elif kind == "min_lines":
        count = len(target_text.splitlines()) if target_text is not None else 0
        passed = target_text is not None and count >= check["minimum"]
        detail = f"{check['path']} has {count} lines; minimum={check['minimum']}"
    elif kind in {"log_contains", "log_not_contains"}:
        contains = check["text"] in log_text
        passed = contains if kind == "log_contains" else not contains
        detail = f"log {'contains' if contains else 'does not contain'} {check['text']!r}"
    elif kind in {"debug_log_contains", "debug_log_not_contains"}:
        contains = check["text"] in debug_log_text
        passed = contains if kind == "debug_log_contains" else not contains
        detail = f"debug log {'contains' if contains else 'does not contain'} {check['text']!r}"
    elif kind in {"debug_tool_input_contains", "debug_tool_input_not_contains"}:
        inputs = _debug_tool_inputs(debug_log_text, check["tool"])
        contains = any(check["text"] in item for item in inputs)
        passed = contains if kind == "debug_tool_input_contains" else not contains
        detail = (
            f"{check['tool']} inputs {'contain' if contains else 'do not contain'} "
            f"{check['text']!r} across {len(inputs)} call(s)"
        )
    elif kind == "assistant_contains":
        contains = target_text is not None and check["text"] in target_text
        passed = contains
        detail = (
            f"assistant transcript {'contains' if contains else 'does not contain'} "
            f"{check['text']!r}"
        )
    return {
        "type": kind,
        "description": description,
        "passed": passed,
        "detail": detail,
        "evaluator_error": read_error,
    }


def _debug_tool_inputs(debug_log: str, tool_name: str) -> List[str]:
    """Extract complete model-supplied JSON inputs for one tool from debug logs.

    The stream logger emits a `tool_use complete ... name=X` line followed by
    `tool_use input_json=...`. Large JSON strings may continue on physical
    lines, so collect until the next structured log prefix. This intentionally
    ignores model thinking/text deltas: a retrieval contract concerns the
    query actually sent to the tool, not vocabulary the model considered and
    rejected in hidden reasoning.
    """
    clean = ANSI_RE.sub("", debug_log)
    complete_re = re.compile(
        r"tool_use complete id=\S+ name=([A-Za-z0-9_]+) input_bytes=\d+"
    )
    log_prefix_re = re.compile(r"^\[(?:DEBUG|INFO|WARN|ERROR)\b")
    marker = "tool_use input_json="
    pending_tool: Optional[str] = None
    collecting_tool: Optional[str] = None
    payload: List[str] = []
    collected: List[Tuple[str, str]] = []

    def flush() -> None:
        nonlocal collecting_tool, payload
        if collecting_tool is not None:
            collected.append((collecting_tool, "\n".join(payload)))
        collecting_tool = None
        payload = []

    for line in clean.splitlines():
        match = complete_re.search(line)
        if match:
            flush()
            pending_tool = match.group(1)
            continue
        marker_pos = line.find(marker)
        if marker_pos >= 0 and pending_tool is not None:
            flush()
            collecting_tool = pending_tool
            pending_tool = None
            payload = [line[marker_pos + len(marker) :]]
            continue
        if collecting_tool is not None:
            if log_prefix_re.match(line):
                flush()
            else:
                payload.append(line)
    flush()
    return [value for name, value in collected if name == tool_name]


def _trajectory_judgement(
    constraints: Dict[str, Any], metrics: Dict[str, Any]
) -> Dict[str, Any]:
    if not constraints:
        return {"status": "unscored", "checks": []}
    metric_names = {
        "max_turns": "turns",
        "max_tool_calls": "tool_calls",
        "max_model_tool_errors": "model_tool_errors",
        "max_harness_tool_errors": "harness_tool_errors",
        "max_permission_denials": "permission_denials",
        "min_permission_denials": "permission_denials",
    }
    checks = []
    for constraint, limit in constraints.items():
        if constraint in {"required_tools", "forbidden_tools"}:
            observed = set(metrics["tool_distribution"])
            expected = set(limit)
            if constraint == "required_tools":
                passed = expected <= observed
                detail = f"missing={sorted(expected - observed)}"
            else:
                passed = not (expected & observed)
                detail = f"observed_forbidden={sorted(expected & observed)}"
            checks.append(
                {
                    "constraint": constraint,
                    "expected": sorted(expected),
                    "observed": sorted(observed),
                    "detail": detail,
                    "passed": passed,
                }
            )
            continue
        if constraint == "min_tool_counts":
            observed = metrics.get("tool_distribution") or {}
            missing = {
                tool_name: {"minimum": minimum, "observed": int(observed.get(tool_name, 0))}
                for tool_name, minimum in limit.items()
                if int(observed.get(tool_name, 0)) < minimum
            }
            checks.append(
                {
                    "constraint": constraint,
                    "expected": dict(sorted(limit.items())),
                    "observed": {
                        tool_name: int(observed.get(tool_name, 0))
                        for tool_name in sorted(limit)
                    },
                    "detail": f"below_minimum={missing}",
                    "passed": not missing,
                }
            )
            continue
        metric = metric_names[constraint]
        actual = metrics.get(metric)
        if constraint.startswith("min_"):
            passed = actual is not None and actual >= limit
        else:
            passed = actual is not None and actual <= limit
        checks.append(
            {
                "constraint": constraint,
                "metric": metric,
                "limit": limit,
                "actual": actual,
                "passed": passed,
            }
        )
    return {
        "status": "pass" if all(item["passed"] for item in checks) else "fail",
        "checks": checks,
    }


def _attribution(
    execution_status: str,
    exit_code: Optional[int],
    metrics: Dict[str, Any],
    outcome_status: str,
    failed_checks: int,
    evaluator_status: str,
) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    if metrics["model_tool_errors"]:
        result.append(
            {
                "source": "model",
                "code": "invalid_tool_arguments",
                "count": metrics["model_tool_errors"],
                "confidence": 0.9,
            }
        )
    if metrics["harness_tool_errors"]:
        result.append(
            {
                "source": "T",
                "code": "tool_execution_failure",
                "count": metrics["harness_tool_errors"],
                "confidence": 0.7,
            }
        )
    if metrics["network_errors"]:
        result.append(
            {
                "source": "E",
                "code": "provider_or_network_failure",
                "count": metrics["network_errors"],
                "confidence": 0.7,
            }
        )
    non_network_harness_errors = metrics["harness_errors"] - metrics["network_errors"]
    if non_network_harness_errors > 0:
        result.append(
            {
                "source": "L",
                "code": "harness_runtime_failure",
                "count": non_network_harness_errors,
                "confidence": 0.6,
            }
        )
    if exit_code == 124:
        result.append(
            {
                "source": "model" if execution_status == "completed" else "L",
                "code": "rollout_timeout",
                "count": 1,
                "confidence": 0.9 if execution_status == "completed" else 0.6,
            }
        )
    if evaluator_status == "invalid":
        result.append(
            {
                "source": "grader",
                "code": "evaluator_not_ready",
                "count": 1,
                "confidence": 1.0,
            }
        )
    if outcome_status == "fail" and failed_checks:
        result.append(
            {
                "source": "unattributed",
                "code": "outcome_check_failed",
                "count": failed_checks,
                "confidence": 0.2,
            }
        )
    if execution_status == "invalid" and not result:
        result.append(
            {
                "source": "unattributed",
                "code": "invalid_execution",
                "count": 1,
                "confidence": 0.2,
            }
        )
    return result


def _native_trace_metrics(path: Path) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    text, artifact_error = _read_regular_text_capped(path, MAX_NATIVE_EVENT_BYTES)
    if artifact_error is not None or text is None:
        return None, artifact_error
    if text and not text.endswith("\n"):
        return None, "native event artifact ends with a partial line"
    events: List[Tuple[str, Dict[str, Any], int, str]] = []
    event_elapsed_ns: List[int] = []
    try:
        for line_no, line in enumerate(text.splitlines(), 1):
            if not line.strip():
                continue
            envelope = json.loads(line)
            if envelope.get("schema_version") != NATIVE_EVENT_SCHEMA_VERSION:
                raise ValueError(f"line {line_no}: unsupported schema_version")
            tagged = envelope.get("event")
            if not isinstance(tagged, dict) or len(tagged) != 1:
                raise ValueError(f"line {line_no}: malformed event union")
            kind, payload = next(iter(tagged.items()))
            known_kinds = {
                "run_started",
                "scoped_recall",
                "turn_started",
                "turn_finished",
                "model_request_finished",
                "compact_request_finished",
                "tool_stage_finished",
                "tool_started",
                "tool_finished",
                "usage",
                "policy_decision",
                "retry",
                "breaker_tripped",
                "cache_break",
                "continuation",
                "auto_compact",
                "context_projection",
                "run_finished",
            }
            if kind not in known_kinds:
                raise ValueError(
                    f"line {line_no}: unknown native event kind {kind!r}"
                )
            if not isinstance(payload, dict):
                raise ValueError(f"line {line_no}: malformed {kind} payload")
            sequence = envelope.get("sequence")
            session_id = envelope.get("session_id")
            if not isinstance(sequence, int) or sequence < 0:
                raise ValueError(f"line {line_no}: invalid sequence")
            if not isinstance(session_id, str) or not session_id:
                raise ValueError(f"line {line_no}: invalid session_id")
            monotonic_elapsed_ns = envelope.get("monotonic_elapsed_ns")
            if (
                not isinstance(monotonic_elapsed_ns, int)
                or isinstance(monotonic_elapsed_ns, bool)
                or monotonic_elapsed_ns < 0
            ):
                raise ValueError(f"line {line_no}: invalid monotonic_elapsed_ns")
            events.append((kind, payload, sequence, session_id))
            event_elapsed_ns.append(monotonic_elapsed_ns)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        return None, str(exc)
    if not events:
        return None, "native event artifact is empty"

    starts = [payload for kind, payload, _seq, _session in events if kind == "run_started"]
    finishes = [payload for kind, payload, _seq, _session in events if kind == "run_finished"]
    if not starts:
        return None, "native event artifact has no run_started"
    metadata = starts[0].get("metadata")
    if not isinstance(metadata, dict):
        return None, "run_started has no metadata"
    required_metadata_strings = {
        "run_id",
        "suite_id",
        "task_id",
        "task_fingerprint",
        "model_provider",
        "model_id",
        "model_fingerprint",
        "harness_config_id",
        "harness_revision",
        "harness_fingerprint",
        "permission_mode",
        "environment_fingerprint",
        "grader_fingerprint",
    }
    missing_metadata = sorted(
        key
        for key in required_metadata_strings
        if not isinstance(metadata.get(key), str) or not metadata.get(key)
    )
    if missing_metadata:
        return None, f"run_started metadata is incomplete: {missing_metadata}"
    if (
        not isinstance(metadata.get("trial"), int)
        or isinstance(metadata.get("trial"), bool)
        or metadata["trial"] < 0
    ):
        return None, "run_started metadata has invalid trial"
    max_metered_tokens = metadata.get("max_metered_tokens")
    max_cost_usd = metadata.get("max_cost_usd")
    if (max_metered_tokens is None) != (max_cost_usd is None):
        return None, "run_started metadata has incomplete runtime budget"
    if max_metered_tokens is not None and (
        not isinstance(max_metered_tokens, int)
        or isinstance(max_metered_tokens, bool)
        or max_metered_tokens <= 0
        or not isinstance(max_cost_usd, (int, float))
        or isinstance(max_cost_usd, bool)
        or not math.isfinite(float(max_cost_usd))
        or float(max_cost_usd) <= 0
    ):
        return None, "run_started metadata has invalid runtime budget"
    identity_keys = {
        "run_id",
        "trial",
        "suite_id",
        "task_id",
        "task_fingerprint",
        "model_provider",
        "model_id",
        "model_fingerprint",
        "runtime_model_provider",
        "runtime_model_id",
        "harness_config_id",
        "harness_revision",
        "harness_fingerprint",
        "permission_mode",
        "runtime_permission_mode",
        "environment_fingerprint",
        "grader_fingerprint",
        "max_metered_tokens",
        "max_cost_usd",
    }
    for start in starts[1:]:
        other = start.get("metadata", {})
        if any(other.get(key) != metadata.get(key) for key in identity_keys):
            return None, "execution metadata changed between invocations"

    trace_events: Dict[str, List[Tuple[str, Dict[str, Any], int, str]]] = {}
    for event in events:
        kind, payload, _sequence, _session = event
        trace_id = payload.get("trace_id")
        if not isinstance(trace_id, str) or not trace_id:
            return None, f"{kind} has no trace_id"
        trace_events.setdefault(trace_id, []).append(event)
        integer_fields = {
            "turn_started": ("depth", "turn"),
            "turn_finished": ("depth", "turn", "tool_calls"),
            "model_request_finished": ("depth", "turn", "attempt", "elapsed_ms"),
            "compact_request_finished": ("depth", "turn", "elapsed_ms"),
            "tool_stage_finished": ("depth", "turn", "tool_calls", "elapsed_ms"),
            "tool_started": ("input_bytes",),
            "tool_finished": ("elapsed_ms", "result_bytes"),
            "usage": (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            ),
            "policy_decision": ("depth",),
            "retry": ("attempt", "max", "delay_ms"),
            "breaker_tripped": ("depth", "same_err_count"),
            "cache_break": ("depth", "cache_read", "cache_creation"),
            "continuation": ("depth", "n", "max"),
            "auto_compact": ("dropped", "kept", "before_tokens", "after_tokens"),
            "context_projection": (
                "changed_items",
                "bytes_before",
                "bytes_after",
                "active_messages",
            ),
            "run_finished": ("depth", "turns", "tool_calls", "wall_time_ms", "dropped_events"),
            "scoped_recall": (
                "result_count",
                "injected_count",
                "injected_bytes",
            ),
        }.get(kind, ())
        for field in integer_fields:
            value = payload.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                return None, f"{kind} has invalid {field}"
        if kind == "usage":
            cost = payload.get("estimated_cost_usd")
            if (
                not isinstance(cost, (int, float))
                or isinstance(cost, bool)
                or cost < 0
            ):
                return None, "usage has invalid estimated_cost_usd"
        if kind == "scoped_recall":
            if payload.get("schema_version") != "metacodes-scoped-recall-v1":
                return None, "scoped_recall has unsupported schema_version"
            status = payload.get("status")
            if status not in {
                "injected",
                "disabled",
                "kg_not_ready",
                "no_user_text",
                "query_too_short",
                "search_error",
                "no_hits",
                "below_floor",
            }:
                return None, "scoped_recall has invalid status"
            for field in ("query_sha256", "injection_sha256"):
                digest = payload.get(field)
                if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                    return None, f"scoped_recall has invalid {field}"
            injected = status == "injected"
            if injected != (
                payload.get("injected_count", 0) > 0
                and payload.get("injected_bytes", 0) > 0
                and payload.get("injection_sha256") != "0" * 64
            ):
                return None, "scoped_recall injection fields contradict status"
        if kind == "tool_finished" and not isinstance(payload.get("is_error"), bool):
            return None, "tool_finished has invalid is_error"
        if kind == "policy_decision":
            if not isinstance(payload.get("allowed"), bool):
                return None, "policy_decision has invalid allowed"
            if not isinstance(payload.get("id"), str) or not payload.get("id"):
                return None, "policy_decision has invalid id"
        if kind in {"model_request_finished", "compact_request_finished"} and not isinstance(
            payload.get("outcome"), str
        ):
            return None, f"{kind} has invalid outcome"
        if kind == "compact_request_finished" and (
            not isinstance(payload.get("cause"), str) or not payload.get("cause")
        ):
            return None, "compact_request_finished has invalid cause"
        if kind == "context_projection":
            projection_kind = payload.get("kind")
            if projection_kind not in {
                "large_tool_result_truncation",
                "stale_tool_result_microcompact",
            }:
                return None, "context_projection has invalid kind"
            if (
                payload.get("changed_items", 0) < 1
                or payload.get("bytes_after", 0) >= payload.get("bytes_before", 0)
                or not isinstance(payload.get("cause"), str)
                or not payload.get("cause")
            ):
                return None, "context_projection does not describe a real reduction"
        if kind == "run_finished" and (
            not isinstance(payload.get("stop_reason"), str)
            or not payload.get("stop_reason")
        ):
            return None, "run_finished has invalid stop_reason"
    if len(trace_events) != len(starts):
        return None, "native event artifact has orphan or duplicate run traces"
    invocations = [start.get("metadata", {}).get("invocation") for start in starts]
    if any(
        not isinstance(value, int) or isinstance(value, bool) or value < 0
        for value in invocations
    ):
        return None, "run_started has invalid invocation identity"
    if len(set(invocations)) != len(invocations):
        return None, "native event artifact has duplicate invocation identity"

    structural_errors: List[str] = []
    stop_reasons: List[str] = []
    dropped_events_total = 0
    dropped_events_max = 0
    incomplete_trace_ids: set[str] = set()
    incomplete_model_turn_ids: set[str] = set()
    last_trace_id = str(events[-1][1].get("trace_id", ""))
    for trace_id, trace in trace_events.items():
        sequences = [event[2] for event in trace]
        if sequences != list(range(len(sequences))):
            structural_errors.append(f"trace {trace_id}: non-contiguous sequence")
        sessions = {event[3] for event in trace}
        if len(sessions) != 1:
            structural_errors.append(f"trace {trace_id}: session_id changed")
        trace_starts = [payload for kind, payload, _seq, _session in trace if kind == "run_started"]
        trace_finishes = [payload for kind, payload, _seq, _session in trace if kind == "run_finished"]
        if len(trace_starts) != 1:
            structural_errors.append(
                f"trace {trace_id}: expected one run_started"
            )
            continue
        incomplete = len(trace_finishes) == 0 and trace_id == last_trace_id
        if incomplete:
            incomplete_trace_ids.add(trace_id)
        elif len(trace_finishes) != 1:
            structural_errors.append(
                f"trace {trace_id}: expected one run_finished"
            )
            continue
        if trace[0][0] != "run_started" or (not incomplete and trace[-1][0] != "run_finished"):
            structural_errors.append(
                f"trace {trace_id}: run lifecycle does not bound the trace"
            )
        reason = (
            "incomplete"
            if incomplete
            else str(trace_finishes[0].get("stop_reason", "unknown"))
        )
        stop_reasons.append(reason)
        if not incomplete:
            dropped = trace_finishes[0].get("dropped_events")
            if not isinstance(dropped, int) or dropped < 0:
                structural_errors.append(f"trace {trace_id}: invalid dropped_events")
            else:
                dropped_events_total += dropped
                dropped_events_max = max(dropped_events_max, dropped)

        started_tools: Dict[Tuple[str, str], Tuple[str, int]] = {}
        finished_tools: Dict[
            Tuple[str, str], Tuple[str, int, Dict[str, Any]]
        ] = {}
        for kind, payload, sequence, _session in trace:
            if kind not in {"tool_started", "tool_finished"}:
                continue
            tool_id, name = payload.get("id"), payload.get("name")
            if not isinstance(tool_id, str) or not tool_id or not isinstance(name, str):
                structural_errors.append(f"trace {trace_id}: malformed {kind}")
                continue
            key = (trace_id, tool_id)
            target = started_tools if kind == "tool_started" else finished_tools
            if key in target:
                structural_errors.append(f"trace {trace_id}: duplicate {kind} id={tool_id}")
            if kind == "tool_started":
                started_tools[key] = (name, sequence)
            else:
                finished_tools[key] = (name, sequence, payload)
        if not incomplete and set(started_tools) != set(finished_tools):
            structural_errors.append(f"trace {trace_id}: unpaired tool lifecycle")
        if (
            incomplete
            and trace[-1][0] in {"turn_started", "usage"}
            and set(started_tools) == set(finished_tools)
        ):
            incomplete_model_turn_ids.add(trace_id)
        for key in set(started_tools) & set(finished_tools):
            started_name, started_sequence = started_tools[key]
            finished_name, finished_sequence, _finished_payload = finished_tools[key]
            if started_name != finished_name:
                structural_errors.append(f"trace {trace_id}: tool name changed id={key[1]}")
            if started_sequence >= finished_sequence:
                structural_errors.append(f"trace {trace_id}: tool finished before start id={key[1]}")
        policies_by_attempt: Dict[
            Tuple[str, str], List[Tuple[Dict[str, Any], int]]
        ] = {}
        for kind, payload, sequence, _session in trace:
            if kind != "policy_decision":
                continue
            policy_id = payload.get("id")
            key = (trace_id, policy_id)
            policies_by_attempt.setdefault(key, []).append((payload, sequence))
            started = started_tools.get(key)
            if started is None:
                structural_errors.append(
                    f"trace {trace_id}: policy decision has no tool attempt id={policy_id}"
                )
                continue
            if payload.get("tool") != started[0]:
                structural_errors.append(
                    f"trace {trace_id}: policy tool name changed id={policy_id}"
                )
        for key, attempt_policies in policies_by_attempt.items():
            finished = finished_tools.get(key)
            if finished is None:
                continue
            _name, finished_sequence, finished_payload = finished
            if any(sequence >= finished_sequence for _policy, sequence in attempt_policies):
                structural_errors.append(
                    f"trace {trace_id}: policy decision recorded after tool result id={key[1]}"
                )
            if any(not policy.get("allowed") for policy, _sequence in attempt_policies):
                if not finished_payload.get("is_error") or not _is_policy_failure_code(
                    finished_payload.get("error_code")
                ):
                    structural_errors.append(
                        f"trace {trace_id}: denied tool did not finish as policy failure id={key[1]}"
                    )

    if structural_errors:
        return None, "; ".join(structural_errors)

    usage = [payload for kind, payload, _seq, _session in events if kind == "usage"]
    model_requests = [
        payload for kind, payload, _seq, _session in events if kind == "model_request_finished"
    ]
    compact_requests = [
        payload
        for kind, payload, _seq, _session in events
        if kind == "compact_request_finished"
    ]
    all_model_requests = model_requests + compact_requests
    tool_stages = [
        payload for kind, payload, _seq, _session in events if kind == "tool_stage_finished"
    ]
    tool_starts = [payload for kind, payload, _seq, _session in events if kind == "tool_started"]
    tool_finishes = [payload for kind, payload, _seq, _session in events if kind == "tool_finished"]
    policies = [payload for kind, payload, _seq, _session in events if kind == "policy_decision"]
    scoped_recalls = [
        payload for kind, payload, _seq, _session in events if kind == "scoped_recall"
    ]
    context_projections = [
        payload for kind, payload, _seq, _session in events if kind == "context_projection"
    ]
    cache_breaks = [
        payload for kind, payload, _seq, _session in events if kind == "cache_break"
    ]
    auto_compacts = [
        payload for kind, payload, _seq, _session in events if kind == "auto_compact"
    ]
    if len(scoped_recalls) > len(starts):
        return None, "native trace has more scoped recall receipts than invocations"
    failures = [item for item in tool_finishes if item.get("is_error")]
    model_failures = [
        item
        for item in failures
        if _is_model_tool_failure(item.get("error_code"), item.get("error_category"))
    ]
    policy_failures = [
        item for item in failures if _is_policy_failure_code(item.get("error_code"))
    ]
    harness_failures = [
        item for item in failures if item not in model_failures and item not in policy_failures
    ]
    tool_names = [str(item.get("name", "unknown")) for item in tool_starts]
    starts_by_tool = {
        name: tool_names.count(name) for name in sorted(set(tool_names))
    }
    policy_violations = _count_policy_violations(tool_starts, policies)
    model_request_outcomes = {
        outcome: sum(
            1
            for item in all_model_requests
            if str(item.get("outcome", "unknown")) == outcome
        )
        for outcome in sorted(
            {str(item.get("outcome", "unknown")) for item in all_model_requests}
        )
    }
    failed_model_requests = sum(
        count for outcome, count in model_request_outcomes.items() if outcome != "success"
    )
    network_errors = sum(
        count
        for outcome, count in model_request_outcomes.items()
        if outcome in {"api_error", "stream_error"}
    )
    complete = not incomplete_trace_ids
    partial_wall_time_ms = sum(
        max(
            (
                elapsed_ns
                for event, elapsed_ns in zip(events, event_elapsed_ns)
                if event[1].get("trace_id") == trace_id
            ),
            default=0,
        )
        // 1_000_000
        for trace_id in incomplete_trace_ids
    )
    wall_time_ms = (
        sum(int(item.get("wall_time_ms", 0)) for item in finishes)
        + partial_wall_time_ms
    )
    model_request_time_ms = (
        sum(int(item.get("elapsed_ms", 0)) for item in all_model_requests)
        if all_model_requests
        else None
    )
    compact_request_outcomes = {
        outcome: sum(
            1
            for item in compact_requests
            if str(item.get("outcome", "unknown")) == outcome
        )
        for outcome in sorted(
            {str(item.get("outcome", "unknown")) for item in compact_requests}
        )
    }
    total_tool_calls = sum(int(item.get("tool_calls", 0)) for item in finishes)
    tool_stage_time_ms = (
        sum(int(item.get("elapsed_ms", 0)) for item in tool_stages)
        if tool_stages
        else 0
        if total_tool_calls == 0
        else None
    )
    harness_time_ms = None
    if model_request_time_ms is not None and tool_stage_time_ms is not None:
        attributed_ms = model_request_time_ms + tool_stage_time_ms
        if attributed_ms > wall_time_ms:
            return None, (
                "native latency spans exceed run wall time: "
                f"model+tool={attributed_ms} wall={wall_time_ms}"
            )
        harness_time_ms = wall_time_ms - attributed_ms
    tool_time_ms = sum(int(item.get("elapsed_ms", 0)) for item in tool_finishes)
    tool_parallelism_factor = (
        tool_time_ms / tool_stage_time_ms
        if tool_stage_time_ms is not None and tool_stage_time_ms > 0
        else 0.0
        if total_tool_calls == 0
        else None
    )
    metrics: Dict[str, Any] = {
        "input_tokens": sum(int(item.get("input_tokens", 0)) for item in usage),
        "output_tokens": sum(int(item.get("output_tokens", 0)) for item in usage),
        "cache_read_tokens": sum(int(item.get("cache_read_tokens", 0)) for item in usage),
        "cache_write_tokens": sum(int(item.get("cache_write_tokens", 0)) for item in usage),
        "cost_usd": sum(float(item.get("estimated_cost_usd", 0.0)) for item in usage),
        "wall_time_ms": wall_time_ms,
        "model_header_latency_ms": None,
        "model_request_time_ms": model_request_time_ms,
        "model_request_count": len(all_model_requests) if all_model_requests else None,
        "model_request_outcomes": model_request_outcomes if all_model_requests else None,
        "compact_request_count": len(compact_requests),
        "compact_request_time_ms": sum(
            int(item.get("elapsed_ms", 0)) for item in compact_requests
        ),
        "compact_request_outcomes": compact_request_outcomes,
        "cache_break_count": len(cache_breaks),
        "auto_compact_event_count": len(auto_compacts),
        "context_projection_count": len(context_projections),
        "context_projected_bytes": sum(
            int(item["bytes_before"]) - int(item["bytes_after"])
            for item in context_projections
        ),
        "tool_time_ms": tool_time_ms,
        "tool_stage_time_ms": tool_stage_time_ms,
        "tool_parallelism_factor": tool_parallelism_factor,
        "harness_time_ms": harness_time_ms,
        "turns": sum(
            1
            for kind, _payload, _seq, _session in events
            if kind == "turn_started"
        ),
        "tool_calls": len(tool_starts),
        "tool_successes": sum(1 for item in tool_finishes if not item.get("is_error")),
        "model_tool_errors": len(model_failures),
        "model_tool_error_distribution": {
            f"{item.get('name', 'unknown')}:{item.get('error_code') or 'UnknownToolError'}": sum(
                1
                for other in model_failures
                if other.get("name") == item.get("name")
                and other.get("error_code") == item.get("error_code")
            )
            for item in model_failures
        },
        "harness_tool_errors": len(harness_failures),
        "harness_errors": failed_model_requests,
        "network_errors": network_errors,
        "permission_denials": sum(1 for item in policies if not item.get("allowed")),
        "policy_violations": policy_violations,
        "policy_decisions": len(policies),
        "retries": sum(1 for kind, _payload, _seq, _session in events if kind == "retry"),
        "tool_distribution": starts_by_tool,
        "scoped_recall_count": len(scoped_recalls),
        "scoped_recall_injected_count": sum(
            int(item.get("injected_count", 0)) for item in scoped_recalls
        ),
        "scoped_recall_injected_bytes": sum(
            int(item.get("injected_bytes", 0)) for item in scoped_recalls
        ),
    }
    return {
        "metadata": metadata,
        "metrics": metrics,
        "complete": complete,
        "incomplete_model_turn": bool(incomplete_trace_ids)
        and incomplete_model_turn_ids == incomplete_trace_ids,
        "starts": len(starts),
        "finishes": len(finishes),
        "stop_reasons": stop_reasons,
        "dropped_events_total": dropped_events_total,
        "dropped_events_max": dropped_events_max,
        "failed_model_requests": failed_model_requests,
        "tool_failures": [
            {
                "tool": item.get("name", "unknown"),
                "error": item.get("error_code") or "UnknownToolError",
                "duration_ms": item.get("elapsed_ms", 0),
            }
            for item in failures
        ],
        "scoped_recalls": scoped_recalls,
    }, None


def import_run(
    suite: Dict[str, Any],
    repo_root: Path,
    run_dir: Path,
    config: Optional[Dict[str, Any]] = None,
) -> List[Dict[str, Any]]:
    report_path = run_dir / "REPORT.md"
    report, report_error = _read(report_path)
    report = report or ""
    results: List[Dict[str, Any]] = []

    for task in suite["tasks"]:
        task_id = task["id"]
        workspace = run_dir / task_id
        log_path = run_dir / f"{task_id}.log"
        debug_path = run_dir / f"{task_id}.debug.log"
        log_text, log_error = _read(log_path)
        debug_text, debug_error = _read(debug_path)
        log_text = log_text or ""
        debug_text = debug_text or ""
        exit_code = _report_exit_code(report, task_id) if not report_error else None
        timeout_seconds = _report_timeout_seconds(report) if not report_error else None
        native_path = workspace / "events.jsonl"
        native, native_error = _native_trace_metrics(native_path)
        scored_watchdog_timeout = bool(
            exit_code == 124
            and timeout_seconds is not None
            and native is not None
            and not native["complete"]
            and native["incomplete_model_turn"]
            and native["dropped_events_total"] == 0
            and native["failed_model_requests"] == 0
            and native["metrics"]["harness_errors"] == 0
            and native["metrics"]["network_errors"] == 0
        )

        readiness_checks = [
            {
                "name": "scenario_exists",
                "passed": (repo_root / task["scenario"]).is_file(),
                "detail": task["scenario"],
            },
            {
                "name": "workspace_exists",
                "passed": workspace.is_dir(),
                "detail": str(workspace),
            },
            {
                "name": "stdout_log_readable",
                "passed": log_error is None,
                "detail": log_error or str(log_path),
            },
            {
                "name": "trace_log_readable",
                "passed": debug_error is None,
                "detail": debug_error or str(debug_path),
            },
            {
                "name": "exit_code_recorded",
                "passed": exit_code is not None,
                "detail": report_error or f"exit_code={exit_code}",
            },
        ]
        if os.path.lexists(native_path):
            readiness_checks.append(
                {
                    "name": "native_events_complete",
                    "passed": native is not None
                    and (bool(native["complete"]) or scored_watchdog_timeout),
                    "detail": native_error
                    or (
                        f"run_started={native['starts']} run_finished={native['finishes']} "
                        f"stop_reasons={native['stop_reasons']} "
                        f"dropped_events={native['dropped_events_total']} "
                        f"scored_watchdog_timeout={scored_watchdog_timeout}"
                    ),
                }
            )
        metrics, trace_failures = _trace_metrics(debug_text)
        model_id_match = MODEL_RE.search(ANSI_RE.sub("", debug_text))
        parsed_model_id = model_id_match.group(1) if model_id_match else "unknown"
        model = dict((config or {}).get("model", {}))
        model.setdefault("provider", "unknown")
        model.setdefault("id", parsed_model_id)
        harness = dict((config or {}).get("harness", {}))
        harness.setdefault("config_id", "legacy-e2e:unknown")
        harness.setdefault("revision", "unknown")
        harness.setdefault("permission_mode", task["constraints"]["permission_mode"])
        harness.pop("fingerprint", None)
        harness["fingerprint"] = hashlib.sha256(
            stable_json(harness).encode("utf-8")
        ).hexdigest()[:16]
        scenario_text, scenario_error = _read(repo_root / task["scenario"])
        task_fingerprint = hashlib.sha256(
            stable_json(
                {
                    "task": task,
                    "scenario_sha256": hashlib.sha256(
                        (scenario_text or "").encode("utf-8")
                    ).hexdigest(),
                }
            ).encode("utf-8")
        ).hexdigest()[:16]
        if scenario_error:
            invalid_reasons_for_scenario = ["scenario_unreadable"]
        else:
            invalid_reasons_for_scenario = []
        task_fingerprint_provenance = "inferred_from_current_suite"
        rollout_run_id = f"{run_dir.name}:{task_id}:0"
        rollout_trial = 0
        grader_fingerprint = _grader_fingerprint(task, repo_root)
        if native is not None:
            native_meta = native["metadata"]
            metrics = native["metrics"]
            if scored_watchdog_timeout:
                timeout_ms = int(timeout_seconds) * 1000
                observed_wall_ms = int(metrics.get("wall_time_ms") or 0)
                missing_model_ms = max(0, timeout_ms - observed_wall_ms)
                metrics["wall_time_ms"] = max(observed_wall_ms, timeout_ms)
                metrics["model_request_time_ms"] = int(
                    metrics.get("model_request_time_ms") or 0
                ) + missing_model_ms
                metrics["model_request_count"] = int(
                    metrics.get("model_request_count") or 0
                ) + 1
                outcomes = dict(metrics.get("model_request_outcomes") or {})
                outcomes["watchdog_timeout"] = outcomes.get("watchdog_timeout", 0) + 1
                metrics["model_request_outcomes"] = outcomes
                tool_stage_ms = int(metrics.get("tool_stage_time_ms") or 0)
                metrics["harness_time_ms"] = max(
                    0,
                    int(metrics["wall_time_ms"])
                    - int(metrics["model_request_time_ms"])
                    - tool_stage_ms,
                )
            trace_failures = native["tool_failures"]
            rollout_run_id = native_meta["run_id"]
            rollout_trial = int(native_meta["trial"])
            task_fingerprint = native_meta["task_fingerprint"]
            task_fingerprint_provenance = "recorded_at_execution"
            grader_fingerprint = native_meta["grader_fingerprint"]
            model = {
                "provider": native_meta["model_provider"],
                "id": native_meta["model_id"],
                "fingerprint": native_meta["model_fingerprint"],
            }
            harness = {
                "config_id": native_meta["harness_config_id"],
                "revision": native_meta["harness_revision"],
                "fingerprint": native_meta["harness_fingerprint"],
                "permission_mode": native_meta["permission_mode"],
                "environment_fingerprint": native_meta["environment_fingerprint"],
            }
            if native_meta.get("max_metered_tokens") is not None:
                harness["runtime_budget"] = {
                    "max_metered_tokens": native_meta["max_metered_tokens"],
                    "max_cost_usd": native_meta["max_cost_usd"],
                }
            identity_matches = (
                native_meta.get("suite_id") == suite["suite_id"]
                and native_meta.get("task_id") == task_id
                and native_meta.get("runtime_model_provider")
                == native_meta.get("model_provider")
                and native_meta.get("runtime_model_id") == native_meta.get("model_id")
                and native_meta.get("runtime_permission_mode")
                == native_meta.get("permission_mode")
                and grader_fingerprint
                == _grader_fingerprint(task, repo_root)
            )
            readiness_checks.append(
                {
                    "name": "execution_identity_matches",
                    "passed": identity_matches,
                    "detail": "recorded model/permission/suite/task/grader identities",
                }
            )

        outcome_checks = [
            _evaluate_check(
                check,
                workspace,
                log_text,
                debug_text,
                repo_root=repo_root,
            )
            for check in task["success"]["checks"]
        ]
        evaluator_errors = [
            check["evaluator_error"] for check in outcome_checks if check["evaluator_error"]
        ]
        evaluator_status = "invalid" if evaluator_errors else "ready"
        if evaluator_status == "invalid":
            outcome_status = "unscored"
        else:
            outcome_status = (
                "pass" if all(check["passed"] for check in outcome_checks) else "fail"
            )
        failed_checks = sum(1 for check in outcome_checks if not check["passed"])

        invalid_reasons = list(invalid_reasons_for_scenario)
        if not all(item["passed"] for item in readiness_checks):
            invalid_reasons.append("readiness_failed")
        if exit_code is not None and exit_code != 0 and not scored_watchdog_timeout:
            invalid_reasons.append(f"nonzero_exit:{exit_code}")
        if metrics["harness_errors"]:
            invalid_reasons.append("harness_or_provider_error")
        if native is not None:
            terminal_reasons = native["stop_reasons"]
            terminal_failure = any(reason != "end_turn" for reason in terminal_reasons)
            if scored_watchdog_timeout:
                terminal_failure = terminal_reasons[-1:] != ["incomplete"] or any(
                    reason != "end_turn" for reason in terminal_reasons[:-1]
                )
            if terminal_failure:
                invalid_reasons.append(
                    "native_terminal_failure:" + ",".join(terminal_reasons)
                )
            if native["dropped_events_total"]:
                invalid_reasons.append(
                    f"native_events_dropped:{native['dropped_events_total']}"
                )
            if native["failed_model_requests"]:
                invalid_reasons.append(
                    f"native_model_request_failed:{native['failed_model_requests']}"
                )
        execution_status = "invalid" if invalid_reasons else "completed"
        trajectory = _trajectory_judgement(
            task.get("trajectory_constraints", {}), metrics
        )
        trustworthy_success = (
            execution_status == "completed"
            and outcome_status == "pass"
            and trajectory["status"] == "pass"
            and evaluator_status == "ready"
        )
        rollout: Dict[str, Any] = {
            "schema_version": SCHEMA_VERSION,
            "run_id": rollout_run_id,
            "suite_id": suite["suite_id"],
            "task_id": task_id,
            "task_fingerprint": task_fingerprint,
            "task_fingerprint_provenance": task_fingerprint_provenance,
            "trial": rollout_trial,
            "layers": task["layers"],
            "model": model,
            "harness": harness,
            "readiness": {
                "status": "pass"
                if all(item["passed"] for item in readiness_checks)
                else "fail",
                "checks": readiness_checks,
            },
            "execution": {
                "status": execution_status,
                "exit_code": exit_code,
                "invalid_reasons": invalid_reasons,
            },
            "outcome": {"status": outcome_status, "checks": outcome_checks},
            "trajectory": {
                **trajectory,
                "tool_failures": trace_failures,
            },
            "evaluator": {
                "status": evaluator_status,
                "kind": task["grader"]["kind"],
                "version": task["grader"]["version"],
                "fingerprint": grader_fingerprint,
                "errors": evaluator_errors,
            },
            "judgement": {
                "valid_for_scoring": execution_status == "completed"
                and evaluator_status == "ready",
                "trustworthy_success": trustworthy_success,
            },
            "metrics": metrics,
            "attribution": _attribution(
                execution_status,
                exit_code,
                metrics,
                outcome_status,
                failed_checks,
                evaluator_status,
            ),
            "artifacts": {
                "workspace": str(workspace),
                "stdout_log": str(log_path),
                "trace_log": str(debug_path),
                "events": str(native_path) if native_path.exists() else None,
                "report": str(report_path),
            },
        }
        results.append(rollout)
    return results
