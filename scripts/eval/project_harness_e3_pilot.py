"""Freeze, dry-run, execute, and report the paid GLM project-Harness E3 pilot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tempfile
import time
from typing import Any, Dict, List, Mapping, Sequence

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.e2e_adapter import finalize_evaluation_fd, _native_trace_metrics  # type: ignore
    from scripts.eval.memory_agent_runtime import (  # type: ignore
        PRODUCTION_CREDENTIAL_MAX_BYTES,
        PRODUCTION_FORCE_COMPACT_AT,
        SAFE_STOP_REASONS,
        _assert_executable_identity,
        _assert_production_sandbox_identity,
        _assert_production_secret_absent,
        _artifact_tree_digest,
        _cassette_context_cache,
        _copy_memory_tree,
        _estimated_costs_match,
        _materialize_pinned_ripgrep,
        _materialize_production_sandbox,
        _native_pricing_provenance,
        _parse_result,
        _production_environment,
        _replace_private_file,
        _run_production_sandbox_probe,
        _write_new,
    )
    from scripts.eval.memory_agent_runtime_pilot import _load_api_key  # type: ignore
    from scripts.eval.memory_benchmark import file_sha256  # type: ignore
    from scripts.eval.memory_budget_journal import (  # type: ignore
        BudgetAuthority,
        BudgetJournal,
        BudgetTransaction,
        usd_to_microusd,
        usd_to_microusd_ceiling,
    )
    from scripts.eval.memory_replay import (  # type: ignore
        PRODUCTION_AUTO_COMPACT_POLICY,
        PRODUCTION_CHILD_PATH,
        PRODUCTION_PRICING_PROVENANCE,
        PRODUCTION_PROVIDER_ID,
        PRODUCTION_SANDBOX_BACKEND,
        _validate_production_provider_tool_schema,
    )
    from scripts.eval.model import stable_json  # type: ignore
    from scripts.eval.project_harness_e3_experiment import (  # type: ignore
        ANALYSIS_PLAN,
        ARMS,
        E3_AUTO_MEMORY_POLICY,
        E3_LONG_HORIZON_ARM,
        E3_ALLOWED_TOOLS,
        E3_DISALLOWED_TOOLS,
        E3Error,
        _canonical_sha256,
        _harness_fingerprint,
        _kernel_runtime_dependencies,
        _reopen_rollout_receipt,
        analyze_journal,
        build_report,
        freeze_manifest,
        grade_workspace,
        rollout_schema_for_manifest,
        validate_manifest,
    )
    from scripts.eval.project_harness_e3_templates import verify_templates  # type: ignore
    from scripts.eval.project_harness_evolution import _read_json, _read_regular, _sha256_file  # type: ignore
else:
    from .e2e_adapter import finalize_evaluation_fd, _native_trace_metrics
    from .memory_agent_runtime import (
        PRODUCTION_CREDENTIAL_MAX_BYTES,
        PRODUCTION_FORCE_COMPACT_AT,
        SAFE_STOP_REASONS,
        _assert_executable_identity,
        _assert_production_sandbox_identity,
        _assert_production_secret_absent,
        _artifact_tree_digest,
        _cassette_context_cache,
        _copy_memory_tree,
        _estimated_costs_match,
        _materialize_pinned_ripgrep,
        _materialize_production_sandbox,
        _native_pricing_provenance,
        _parse_result,
        _production_environment,
        _replace_private_file,
        _run_production_sandbox_probe,
        _write_new,
    )
    from .memory_agent_runtime_pilot import _load_api_key
    from .memory_benchmark import file_sha256
    from .memory_budget_journal import (
        BudgetAuthority,
        BudgetJournal,
        BudgetTransaction,
        usd_to_microusd,
        usd_to_microusd_ceiling,
    )
    from .memory_replay import (
        PRODUCTION_AUTO_COMPACT_POLICY,
        PRODUCTION_CHILD_PATH,
        PRODUCTION_PRICING_PROVENANCE,
        PRODUCTION_PROVIDER_ID,
        PRODUCTION_SANDBOX_BACKEND,
        _validate_production_provider_tool_schema,
    )
    from .model import stable_json
    from .project_harness_e3_experiment import (
        ANALYSIS_PLAN,
        ARMS,
        E3_AUTO_MEMORY_POLICY,
        E3_LONG_HORIZON_ARM,
        E3_ALLOWED_TOOLS,
        E3_DISALLOWED_TOOLS,
        E3Error,
        _canonical_sha256,
        _harness_fingerprint,
        _kernel_runtime_dependencies,
        _reopen_rollout_receipt,
        analyze_journal,
        build_report,
        freeze_manifest,
        grade_workspace,
        rollout_schema_for_manifest,
        validate_manifest,
    )
    from .project_harness_e3_templates import verify_templates
    from .project_harness_evolution import _read_json, _read_regular, _sha256_file


CHECKPOINT_SCHEMA = "metacodes-project-harness-e3-checkpoint-v1"
CHECKPOINT_NAME = "checkpoint.json"
MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
MAX_TIMEOUT_STREAM_BYTES = 1024 * 1024
TIMEOUT_TRUNCATION_MARKER = b"\n[metacodes timeout diagnostic truncated]\n"


def _safe_component(value: str) -> str:
    encoded = "".join(character if character.isalnum() or character in "-_" else "-" for character in value)
    if not encoded or len(encoded) > 160:
        raise E3Error("invalid rollout path component")
    return encoded


def _timeout_stream_bytes(value: str | bytes | None) -> bytes:
    """Normalize TimeoutExpired streams without trusting text-mode behavior.

    CPython documents ``TimeoutExpired.output`` as bytes even when the child
    was launched with ``text=True``.  Other runtimes may preserve ``str``.
    Treating either representation explicitly avoids losing the only provider
    diagnostic at the paid authorization boundary.
    """

    if value is None:
        return b""
    if isinstance(value, bytes):
        return value
    if isinstance(value, str):
        return value.encode("utf-8")
    raise E3Error("paid E3 timeout returned an unsupported stream type")


def _bounded_timeout_stream(
    value: str | bytes | None,
    *,
    api_key: str,
) -> tuple[bytes, Mapping[str, Any]]:
    """Redact the credential and retain a bounded head/tail diagnostic."""

    raw = _timeout_stream_bytes(value)
    redacted = raw
    redactions = 0
    encodings = {
        api_key.encode("utf-8"),
        json.dumps(api_key, ensure_ascii=False)[1:-1].encode("utf-8"),
    }
    for secret in sorted(encodings, key=len, reverse=True):
        if not secret:
            continue
        count = redacted.count(secret)
        if count:
            redacted = redacted.replace(secret, b"[REDACTED_CREDENTIAL]")
            redactions += count
    truncated = len(redacted) > MAX_TIMEOUT_STREAM_BYTES
    if truncated:
        retained = MAX_TIMEOUT_STREAM_BYTES - len(TIMEOUT_TRUNCATION_MARKER)
        head = retained // 2
        tail = retained - head
        persisted = redacted[:head] + TIMEOUT_TRUNCATION_MARKER + redacted[-tail:]
    else:
        persisted = redacted
    return persisted, {
        "captured_bytes": len(raw),
        "persisted_bytes": len(persisted),
        "persisted_sha256": hashlib.sha256(persisted).hexdigest(),
        "truncated": truncated,
        "credential_redactions": redactions,
    }


def _reset_workspace(workspace: Path, case: Mapping[str, Any], root: Path) -> None:
    if workspace.resolve(strict=True) != (root / "workspace").resolve(strict=True):
        raise E3Error("workspace reset target drift")
    for entry in list(workspace.iterdir()):
        info = entry.lstat()
        if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
            shutil.rmtree(entry)
        else:
            entry.unlink()
    for name, content in case["initial_files"].items():
        if Path(name).name != name or name in {"", ".", ".."}:
            raise E3Error("case file name is unsafe")
        _write_new(workspace / name, content.encode("utf-8"))


def _rule_target(home: Path, template: Mapping[str, Any]) -> Path:
    template_home = Path(str(template["home_root"]))
    source = Path(str(template["rules_dir"]))
    try:
        relative = source.relative_to(template_home)
    except ValueError as exc:
        raise E3Error("template rules escaped template HOME") from exc
    target = home / relative
    _copy_memory_tree(source, target)
    return target


def _find_project_journal(home: Path) -> Path:
    paths = sorted((home / ".metacodes/projects").glob("*/*/tool-observations.jsonl"))
    if len(paths) != 1:
        raise E3Error(f"expected one project-Harness journal, observed {len(paths)}")
    return paths[0]


def _environment_fingerprint(
    *,
    workspace: Path,
    sandbox_sha256: str,
    ripgrep_sha256: str,
    kernel_sha256: str,
) -> str:
    return _canonical_sha256(
        {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "workspace": str(workspace),
            "sandbox_backend": PRODUCTION_SANDBOX_BACKEND,
            "sandbox_profile_sha256": sandbox_sha256,
            "ripgrep_binary_sha256": ripgrep_sha256,
            "kernel_sha256": kernel_sha256,
            "child_path": PRODUCTION_CHILD_PATH,
            "auto_compact_policy": PRODUCTION_AUTO_COMPACT_POLICY,
            "auto_memory_policy": E3_AUTO_MEMORY_POLICY,
            "long_horizon_arm": E3_LONG_HORIZON_ARM,
        }
    )


def _runtime_metadata(
    *,
    manifest: Mapping[str, Any],
    case: Mapping[str, Any],
    schedule: Mapping[str, Any],
    events_path: Path,
    run_id: str,
    harness_fingerprint: str,
    environment_fingerprint: str,
) -> Mapping[str, Any]:
    execution = manifest["execution"]
    return {
        "schema_version": 3,
        "events_path": str(events_path),
        "run_id": run_id,
        "trial": schedule["trial"],
        "suite_id": manifest["manifest_id"],
        "task_id": case["id"],
        "task_fingerprint": _canonical_sha256(case),
        "model_provider": execution["model_provider"],
        "model_id": execution["model_id"],
        "model_fingerprint": execution["model_fingerprint"],
        "harness_config_id": f"project-harness:{schedule['arm']}",
        "harness_revision": manifest["repository"]["commit"],
        "harness_fingerprint": harness_fingerprint,
        "permission_mode": "bypass_permissions",
        "environment_fingerprint": environment_fingerprint,
        "grader_fingerprint": case["grader"]["fingerprint"],
        "max_metered_tokens": execution["max_rollout_metered_tokens"],
        "max_cost_usd": execution["max_rollout_cost_usd"],
        "allowed_tools": list(E3_ALLOWED_TOOLS),
    }


def _checkpoint_payload(
    manifest: Mapping[str, Any],
    completed: Sequence[Mapping[str, Any]],
    budget: BudgetJournal,
) -> bytes:
    snapshot = budget.snapshot()
    value = {
        "schema_version": CHECKPOINT_SCHEMA,
        "manifest_id": manifest["manifest_id"],
        "completed": list(completed),
        "budget_journal_id": snapshot["journal_id"],
        "budget_revision": snapshot["revision"],
        "budget_head_sha256": snapshot["head_sha256"],
    }
    return (stable_json(value) + "\n").encode("utf-8")


def _rollout_window(
    schedule: Sequence[Mapping[str, Any]],
    completed_count: int,
    max_rollouts: int | None,
) -> List[Mapping[str, Any]]:
    if completed_count < 0 or completed_count > len(schedule):
        raise E3Error("E3 completed rollout count is outside the frozen schedule")
    if max_rollouts is not None and (
        not isinstance(max_rollouts, int)
        or isinstance(max_rollouts, bool)
        or max_rollouts <= 0
    ):
        raise E3Error("E3 invocation rollout limit must be an integer > 0")
    remaining = schedule[completed_count:]
    return list(remaining if max_rollouts is None else remaining[:max_rollouts])


def _load_resume(
    *,
    run_dir: Path,
    manifest: Mapping[str, Any],
    budget: BudgetJournal,
) -> List[Mapping[str, Any]]:
    resolved_run_dir = run_dir.resolve(strict=True)
    checkpoint = _read_json(run_dir / CHECKPOINT_NAME)
    completed = checkpoint.get("completed")
    if (
        checkpoint.get("schema_version") != CHECKPOINT_SCHEMA
        or checkpoint.get("manifest_id") != manifest["manifest_id"]
        or not isinstance(completed, list)
    ):
        raise E3Error("E3 resume checkpoint identity drift")
    snapshot = budget.snapshot()
    if (
        checkpoint.get("budget_journal_id") != snapshot["journal_id"]
        or checkpoint.get("budget_revision") != snapshot["revision"]
        or checkpoint.get("budget_head_sha256") != snapshot["head_sha256"]
        or snapshot["transaction_states"].get("request_authorized", 0) != 0
        or snapshot["transaction_states"].get("reserved", 0) != 0
        or snapshot["transaction_states"].get("committed", 0) != len(completed)
    ):
        raise E3Error("E3 resume budget has unsettled or uncheckpointed work")
    for index, item in enumerate(completed):
        if not isinstance(item, Mapping) or item.get("sequence") != index:
            raise E3Error("E3 completed prefix is not contiguous")
        receipt = Path(str(item.get("receipt_path", "")))
        if _sha256_file(receipt) != item.get("receipt_sha256"):
            raise E3Error("E3 completed receipt drift")
        row = _read_json(receipt)
        expected = manifest["schedule"][index]
        if any(row.get(key) != expected[key] for key in ("sequence", "case_id", "trial", "arm")):
            raise E3Error("E3 completed receipt/schedule drift")
        _reopen_rollout_receipt(
            manifest=manifest,
            run_dir=resolved_run_dir,
            expected=expected,
            path=receipt,
        )
    return list(completed)


def _copy_workspace_snapshot(workspace: Path, target: Path) -> None:
    _copy_memory_tree(workspace, target)


def _run_one(
    *,
    repo: Path,
    manifest: Mapping[str, Any],
    templates: Mapping[str, Any],
    schedule: Mapping[str, Any],
    run_dir: Path,
    ripgrep: Path,
    ripgrep_sha256: str,
    api_key: str,
    budget: BudgetJournal,
    timeout_seconds: int,
    test_base_url: str | None = None,
) -> Mapping[str, Any]:
    sequence = int(schedule["sequence"])
    arm = str(schedule["arm"])
    frozen_cases = manifest.get("cases")
    if not isinstance(frozen_cases, list):
        raise E3Error("E3 manifest has no frozen case cohort")
    case_by_id = {
        str(case.get("id")): case
        for case in frozen_cases
        if isinstance(case, Mapping)
    }
    if len(case_by_id) != len(frozen_cases):
        raise E3Error("E3 frozen case cohort is malformed or duplicated")
    try:
        case = case_by_id[str(schedule["case_id"])]
    except KeyError as exc:
        raise E3Error("E3 schedule case is outside the frozen cohort") from exc
    root = Path(str(manifest["root"]))
    workspace = Path(str(manifest["project_root"]))
    _reset_workspace(workspace, case, root)
    component = _safe_component(f"{sequence:05d}-{case['id']}-{arm}")
    artifact_dir = run_dir / "rollouts" / component
    artifact_dir.mkdir(mode=0o700, parents=True)
    sealed_home = artifact_dir / "sealed-home"
    child_tmp = artifact_dir / "tmp"
    cassette = artifact_dir / "cassette"
    for directory in (sealed_home, child_tmp, cassette):
        directory.mkdir(mode=0o700)
    pinned_ripgrep = _materialize_pinned_ripgrep(ripgrep, ripgrep_sha256, sealed_home)

    arm_config = manifest["arms"][arm]
    binary_item = manifest["artifacts"][arm_config["binary"]]
    binary = Path(str(binary_item["path"]))
    binary_sha256 = str(binary_item["sha256"])
    kernel_item = manifest["artifacts"]["kernel"]
    kernel = Path(str(kernel_item["path"]))
    kernel_sha256 = str(kernel_item["sha256"])
    kernel_dependencies = _kernel_runtime_dependencies(kernel)
    if kernel_item.get("runtime_dependencies") != kernel_dependencies:
        raise E3Error("E3 kernel runtime dependency drift before rollout")
    kernel_dependency_paths = tuple(
        Path(str(item["loader_path"])) for item in kernel_dependencies
    )
    _assert_executable_identity(binary, binary_sha256, "E3 metacodes binary before rollout")
    _assert_executable_identity(kernel, kernel_sha256, "E3 project kernel before rollout")
    rules_target: Path | None = None
    candidate_id: str | None = None
    flavor = arm_config["rule_flavor"]
    if flavor is not None:
        template = templates["templates"][flavor]
        rules_target = _rule_target(sealed_home, template)
        candidate_id = str(template["candidate_id"])

    profile_path = artifact_dir / "production-seatbelt.sb"
    evidence_path = artifact_dir / "production-seatbelt-probe.json"
    sandbox = _materialize_production_sandbox(
        profile_path=profile_path,
        evidence_path=evidence_path,
        artifact_dir=artifact_dir,
        workspace=workspace,
        store=None,
        metacodes=binary,
        tinykg=None,
        ripgrep=pinned_ripgrep,
        additional_read_only_files=(kernel, *kernel_dependency_paths),
        read_only_roots=((rules_target,) if rules_target is not None else ()),
    )
    sentinels = run_dir / "isolation-sentinels"
    sentinels.mkdir(exist_ok=True)
    sibling = sentinels / f"{component}.sentinel"
    _write_new(sibling, f"forbidden:{component}\n".encode("utf-8"))
    read_only_probes = (
        ((rules_target, rules_target / "active.json"),)
        if rules_target is not None
        else ()
    )
    _run_production_sandbox_probe(
        sandbox,
        host_read_path=repo / "scripts/eval/project_harness_e3_pilot.py",
        sibling_read_path=sibling,
        writable_root=child_tmp,
        evidence_path=evidence_path,
        read_only_probes=read_only_probes,
    )
    _assert_production_sandbox_identity(sandbox, evidence_path)

    harness_fingerprint = _harness_fingerprint(manifest, arm, templates, ripgrep_sha256)
    run_id = f"{manifest['manifest_id']}:{sequence}:{case['id']}:{arm}"
    events = artifact_dir / "native-events.jsonl"
    metadata_path = artifact_dir / "runtime-metadata.json"
    metadata = _runtime_metadata(
        manifest=manifest,
        case=case,
        schedule=schedule,
        events_path=events,
        run_id=run_id,
        harness_fingerprint=harness_fingerprint,
        environment_fingerprint=_environment_fingerprint(
            workspace=workspace,
            sandbox_sha256=sandbox.profile_sha256,
            ripgrep_sha256=ripgrep_sha256,
            kernel_sha256=kernel_sha256,
        ),
    )
    _write_new(metadata_path, (stable_json(metadata) + "\n").encode("utf-8"))
    metadata_fd = os.open(metadata_path, os.O_RDONLY)
    metadata_path.unlink()
    events_file = tempfile.TemporaryFile(dir=artifact_dir)
    env = _production_environment(os.environ)
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
            "METACODES_RECORD_DIR": str(cassette),
            "METACODES_EVAL_METADATA_FD": str(metadata_fd),
            "METACODES_EVAL_FD": str(events_file.fileno()),
            "METACODES_FORCE_COMPACT_AT": PRODUCTION_FORCE_COMPACT_AT,
            "METACODES_NO_AUTO_RECALL": "1",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "METACODES_LONG_HORIZON_ARM": E3_LONG_HORIZON_ARM,
            "METACODES_PROJECT_KERNEL_PATH": str(kernel),
            "METACODES_PROJECT_KERNEL_SHA256": kernel_sha256,
            "RG_BIN": str(pinned_ripgrep),
        }
    )
    execution = manifest["execution"]
    child_args = [
            str(binary),
            "--model", str(execution["model_id"]),
            "--max-tokens", str(execution["max_output_tokens"]),
            "--disallowedTools", ",".join(E3_DISALLOWED_TOOLS),
            "--permission", "bypassPermissions",
            "--no-theme",
            "--record", str(cassette),
            "-p", str(case["prompt"]),
            "--json",
    ]
    if test_base_url is not None:
        child_args[1:1] = ["--base-url", test_base_url]
    command = sandbox.command(child_args)
    reserved = budget.reserve(
        BudgetTransaction(
            run_id=run_id,
            manifest_sha256=_canonical_sha256(manifest),
            model_fingerprint=str(execution["model_fingerprint"]),
            harness_fingerprint=harness_fingerprint,
            provider_identity=PRODUCTION_PROVIDER_ID,
            max_cost_microusd=usd_to_microusd(execution["max_rollout_cost_usd"]),
            max_metered_tokens=int(execution["max_rollout_metered_tokens"]),
        )
    )
    credential_read_fd, credential_write_fd = os.pipe()
    started = time.monotonic_ns()
    authorized: Mapping[str, Any] | None = None
    try:
        credential = api_key.encode("utf-8")
        pipe_buf = os.fpathconf(credential_write_fd, "PC_PIPE_BUF")
        if len(credential) > min(PRODUCTION_CREDENTIAL_MAX_BYTES, pipe_buf):
            raise E3Error("credential exceeds anonymous FD limit")
        if os.write(credential_write_fd, credential) != len(credential):
            raise E3Error("short credential write")
        os.close(credential_write_fd)
        credential_write_fd = -1
        env["METACODES_API_KEY_FD"] = str(credential_read_fd)
        authorized = budget.authorize_request(
            str(reserved["transaction_id"]),
            expected_revision=int(reserved["journal_revision"]),
            expected_head_sha256=str(reserved["journal_head_sha256"]),
        )
        completed = subprocess.run(
            command,
            cwd=workspace,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_seconds,
            check=False,
            pass_fds=(metadata_fd, events_file.fileno(), credential_read_fd),
        )
    except subprocess.TimeoutExpired as exc:
        elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
        stdout_payload, stdout_evidence = _bounded_timeout_stream(
            exc.stdout,
            api_key=api_key,
        )
        stderr_payload, stderr_evidence = _bounded_timeout_stream(
            exc.stderr,
            api_key=api_key,
        )
        stdout_path = artifact_dir / "stdout.ndjson"
        stderr_path = artifact_dir / "stderr.log"
        _write_new(stdout_path, stdout_payload)
        _write_new(stderr_path, stderr_payload)
        native_events: Mapping[str, Any]
        try:
            finalize_evaluation_fd(events_file.fileno(), events)
            native_events = {
                "persisted": True,
                "bytes": events.stat().st_size,
                "sha256": _sha256_file(events),
            }
        except BaseException as finalize_error:
            native_events = {
                "persisted": False,
                "error_type": type(finalize_error).__name__,
                "error_sha256": hashlib.sha256(
                    str(finalize_error).encode("utf-8")
                ).hexdigest(),
            }
        finally:
            events_file.close()
        snapshot = budget.snapshot()
        failure = {
            "schema_version": "metacodes-project-harness-e3-child-timeout-v1",
            "quality_evidence": False,
            "sequence": sequence,
            "run_id_sha256": hashlib.sha256(run_id.encode("utf-8")).hexdigest(),
            "timed_out": True,
            "timeout_seconds": timeout_seconds,
            "elapsed_ms_host": elapsed_ms,
            # subprocess.run raises only after killing and waiting for its
            # direct child. This does not claim that arbitrary descendants or
            # the remote provider stopped processing the authorized request.
            "direct_child_killed_and_reaped": True,
            "remote_request_outcome": "unknown",
            "automatic_retry_forbidden": True,
            "budget_transaction": authorized,
            "budget_journal": {
                "journal_id": snapshot["journal_id"],
                "revision": snapshot["revision"],
                "head_sha256": snapshot["head_sha256"],
                "transaction_states": snapshot["transaction_states"],
                "exposure_cost_microusd": snapshot["exposure_cost_microusd"],
                "exposure_metered_tokens": snapshot["exposure_metered_tokens"],
            },
            "cassette": {
                "request_files": len(list(cassette.glob("req-*.json"))),
                "response_files": len(list(cassette.glob("resp-*.json"))),
            },
            "stdout": stdout_evidence,
            "stderr": stderr_evidence,
            "native_events": native_events,
        }
        _write_new(
            artifact_dir / "child-timeout.json",
            (stable_json(failure) + "\n").encode("utf-8"),
        )
        _assert_production_secret_absent(root, api_key)
        raise E3Error(
            f"paid E3 child timed out at sequence {sequence} after "
            f"{timeout_seconds}s; automatic retry is forbidden"
        ) from exc
    except BaseException:
        if not events_file.closed:
            events_file.close()
        if authorized is None:
            budget.abort_pre_request(str(reserved["transaction_id"]))
        _assert_production_secret_absent(root, api_key)
        raise
    finally:
        if credential_write_fd >= 0:
            os.close(credential_write_fd)
        os.close(credential_read_fd)
        os.close(metadata_fd)
    elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
    stdout_path = artifact_dir / "stdout.ndjson"
    stderr_path = artifact_dir / "stderr.log"
    _write_new(stdout_path, completed.stdout.encode("utf-8"))
    _write_new(stderr_path, completed.stderr.encode("utf-8"))
    try:
        finalize_evaluation_fd(events_file.fileno(), events)
    finally:
        events_file.close()
        _assert_production_secret_absent(root, api_key)
    _assert_executable_identity(binary, binary_sha256, "E3 metacodes binary after rollout")
    _assert_executable_identity(kernel, kernel_sha256, "E3 project kernel after rollout")
    if kernel_item.get("runtime_dependencies") != _kernel_runtime_dependencies(kernel):
        raise E3Error("E3 kernel runtime dependency drift after rollout")
    _assert_production_sandbox_identity(sandbox, evidence_path)
    if completed.returncode != 0:
        failure = {
            "schema_version": "metacodes-project-harness-e3-child-failure-v1",
            "sequence": sequence,
            "run_id_sha256": hashlib.sha256(run_id.encode("utf-8")).hexdigest(),
            "returncode": completed.returncode,
            "budget_transaction": authorized,
            "automatic_retry_forbidden": True,
        }
        _write_new(artifact_dir / "child-failure.json", (stable_json(failure) + "\n").encode("utf-8"))
        raise E3Error(f"paid E3 child failed at sequence {sequence}; automatic retry is forbidden")
    result = _parse_result(completed.stdout)
    native, native_error = _native_trace_metrics(events)
    if native_error is not None or native is None or native.get("complete") is not True:
        raise E3Error(f"native E3 trace is invalid: {native_error}")
    usage = native["metrics"]
    if result["stop_reason"] not in SAFE_STOP_REASONS or native["dropped_events_total"] != 0:
        raise E3Error("E3 rollout ended with an unsafe or incomplete stop")
    if not _estimated_costs_match(float(usage["cost_usd"]), float(result["cost_usd"])):
        raise E3Error("E3 native/result cost drift")
    metered_tokens = sum(
        int(usage[key])
        for key in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")
    )
    if (
        metered_tokens <= 0
        or metered_tokens > int(execution["max_rollout_metered_tokens"])
        or float(usage["cost_usd"]) > float(execution["max_rollout_cost_usd"])
        or _native_pricing_provenance(events, "E3 pricing") != PRODUCTION_PRICING_PROVENANCE
        or usage["auto_compact_event_count"] != 0
        or usage["compact_request_count"] != 0
    ):
        raise E3Error("E3 usage/budget/cache policy drift")
    committed = budget.commit(
        str(reserved["transaction_id"]),
        actual_cost_microusd=usd_to_microusd_ceiling(float(usage["cost_usd"])),
        actual_metered_tokens=metered_tokens,
    )
    requests = sorted(cassette.glob("req-*.json"))
    if not requests:
        raise E3Error("E3 provider cassette is empty")
    _validate_production_provider_tool_schema(cassette, f"E3 rollout {sequence}", E3_ALLOWED_TOOLS)
    cache = _cassette_context_cache(cassette, str(execution["model_id"]), f"E3 rollout {sequence} cache")
    first_request = requests[0]
    journal = _find_project_journal(sealed_home)
    grader = grade_workspace(case, workspace)
    governance = analyze_journal(
        path=journal,
        arm=arm,
        oracle_class=str(case["oracle_class"]),
        project_sha256=str(manifest["project_sha256"]),
        kernel_sha256=kernel_sha256,
        candidate_id=candidate_id,
        task_success=bool(grader["passed"]),
    )
    snapshot = artifact_dir / "workspace-final"
    _copy_workspace_snapshot(workspace, snapshot)
    receipt: Mapping[str, Any] = {
        "schema_version": rollout_schema_for_manifest(manifest),
        "evidence_level": (
            "E3-paid-model-rollout" if test_base_url is None else "E2-loopback-runner-boundary"
        ),
        "quality_evidence": test_base_url is None,
        "auto_memory_policy": E3_AUTO_MEMORY_POLICY,
        "long_horizon_arm": E3_LONG_HORIZON_ARM,
        "sequence": sequence,
        "case_id": case["id"],
        "trial": schedule["trial"],
        "position": schedule["position"],
        "arm": arm,
        "oracle_class": case["oracle_class"],
        "horizon_class": case["horizon_class"],
        "correction_family": case["correction_family"],
        "manifest_id": manifest["manifest_id"],
        "task_fingerprint": _canonical_sha256(case),
        "harness_fingerprint": harness_fingerprint,
        "binary_sha256": binary_sha256,
        "kernel_sha256": kernel_sha256,
        "candidate_id": candidate_id,
        "bundle_sha256": (
            templates["templates"][flavor]["bundle_sha256"] if flavor is not None else None
        ),
        "provider_requests": len(requests),
        "provider_visible_first_request_sha256": _sha256_file(first_request),
        "provider_visible_first_request_bytes": first_request.stat().st_size,
        "result": {
            "stop_reason": result["stop_reason"],
            "turns": result["turns"],
            "tool_calls": result["tool_calls"],
            "text_sha256": hashlib.sha256(result["text"].encode("utf-8")).hexdigest(),
        },
        "grader": grader,
        "governance": governance,
        "usage": {
            key: usage[key]
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
                "cost_usd",
                "wall_time_ms",
                "model_request_time_ms",
                "tool_time_ms",
                "harness_time_ms",
            )
        },
        "context_cache": cache,
        "budget_transaction": committed,
        "elapsed_ms_host": elapsed_ms,
        "artifacts": {
            "receipt": str(artifact_dir / "rollout-receipt.json"),
            "events": str(events),
            "journal": str(journal),
            "first_request": str(first_request),
            "cassette": str(cassette),
            "stdout": str(stdout_path),
            "stderr": str(stderr_path),
            "workspace_final": str(snapshot),
            "sandbox_profile": str(profile_path),
            "sandbox_evidence": str(evidence_path),
        },
        "artifact_sha256": {
            "events": _sha256_file(events),
            "journal": _sha256_file(journal),
            "first_request": _sha256_file(first_request),
            "stdout": _sha256_file(stdout_path),
            "stderr": _sha256_file(stderr_path),
            "sandbox_profile": _sha256_file(profile_path),
            "sandbox_evidence": _sha256_file(evidence_path),
            "cassette": _artifact_tree_digest(cassette),
        },
    }
    receipt_path = artifact_dir / "rollout-receipt.json"
    _write_new(receipt_path, (stable_json(receipt) + "\n").encode("utf-8"))
    _assert_production_secret_absent(root, api_key)
    return {
        "sequence": sequence,
        "receipt_path": str(receipt_path),
        "receipt_sha256": _sha256_file(receipt_path),
    }


def run_paid(
    *,
    repo: Path,
    manifest_path: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    auth_file: Path,
    resume: bool,
    max_rollouts: int | None = None,
) -> Mapping[str, Any]:
    repo = repo.resolve(strict=True)
    manifest = validate_manifest(manifest_path.resolve(strict=True), repo)
    if manifest["analysis_plan"] != ANALYSIS_PLAN:
        raise E3Error("historical E3 manifests are report-only")
    # Reject a malformed host-only pause control before creating a run
    # directory, opening the budget journal, or loading the credential.
    _rollout_window(manifest["schedule"], 0, max_rollouts)
    templates = verify_templates(Path(str(manifest["templates_manifest"]["path"])), repo)
    root = Path(str(manifest["root"]))
    run_dir = run_dir.absolute()
    if run_dir.parent.resolve(strict=True) != root.resolve(strict=True):
        raise E3Error("paid E3 run directory must be a direct child of the frozen root")
    if resume:
        if not run_dir.is_dir() or run_dir.is_symlink():
            raise E3Error("E3 resume requires an existing real run directory")
    else:
        if run_dir.exists() or run_dir.is_symlink():
            raise E3Error("paid E3 run directory must be fresh")
        run_dir.mkdir(mode=0o700)
        (run_dir / "rollouts").mkdir(mode=0o700)
    ripgrep = ripgrep.resolve(strict=True)
    ripgrep_sha256 = file_sha256(ripgrep)
    frozen_ripgrep = manifest["artifacts"]["ripgrep"]
    if str(ripgrep) != frozen_ripgrep["path"] or ripgrep_sha256 != frozen_ripgrep["sha256"]:
        raise E3Error("E3 ripgrep artifact drift")
    _assert_executable_identity(ripgrep, ripgrep_sha256, "E3 ripgrep")
    budget_candidate = budget_path.absolute()
    if budget_candidate.parent.resolve(strict=True) == run_dir.resolve(strict=True) or run_dir.resolve(strict=True) in budget_candidate.parents:
        raise E3Error("budget journal must remain outside the fresh run directory")
    execution = manifest["execution"]
    authority = BudgetAuthority(
        manifest_sha256=_canonical_sha256(manifest),
        model_fingerprint=str(execution["model_fingerprint"]),
        provider_identity=PRODUCTION_PROVIDER_ID,
        total_cost_microusd=usd_to_microusd(execution["max_total_cost_usd"]),
        total_metered_tokens=int(execution["max_total_metered_tokens"]),
    )
    with BudgetJournal(budget_candidate, authority) as budget:
        completed = _load_resume(run_dir=run_dir, manifest=manifest, budget=budget) if resume else []
        if not resume:
            _replace_private_file(run_dir / CHECKPOINT_NAME, _checkpoint_payload(manifest, completed, budget))
        api_key = _load_api_key(auth_file.resolve(strict=True))
        try:
            for schedule in _rollout_window(
                manifest["schedule"],
                len(completed),
                max_rollouts,
            ):
                item = _run_one(
                    repo=repo,
                    manifest=manifest,
                    templates=templates,
                    schedule=schedule,
                    run_dir=run_dir,
                    ripgrep=ripgrep,
                    ripgrep_sha256=ripgrep_sha256,
                    api_key=api_key,
                    budget=budget,
                    timeout_seconds=int(
                        manifest["execution"]["rollout_timeout_seconds"]
                    ),
                )
                completed.append(item)
                budget_checkpoint = run_dir / f"budget-checkpoint-r{budget.snapshot()['revision']}.json"
                _write_new(budget_checkpoint, budget.checkpoint_payload())
                _replace_private_file(run_dir / CHECKPOINT_NAME, _checkpoint_payload(manifest, completed, budget))
        finally:
            _assert_production_secret_absent(root, api_key)
        if len(completed) < len(manifest["schedule"]):
            checkpoint = run_dir / CHECKPOINT_NAME
            return {
                "run_dir": str(run_dir),
                "manifest_id": manifest["manifest_id"],
                "status": "paused_after_rollout_limit",
                "completed_rollouts": len(completed),
                "remaining_rollouts": len(manifest["schedule"]) - len(completed),
                "quality_evidence": False,
                "report_path": None,
                "checkpoint_path": str(checkpoint),
                "checkpoint_sha256": _sha256_file(checkpoint),
                "budget": budget.snapshot(),
            }
        report = build_report(manifest_path, run_dir, repo)
        report_path = run_dir / "report.json"
        _write_new(report_path, (stable_json(report) + "\n").encode("utf-8"))
        return {
            "run_dir": str(run_dir),
            "manifest_id": manifest["manifest_id"],
            "rollouts": report["rollouts"],
            "quality_evidence": report["quality_evidence"],
            "significant_benefit": report["significant_benefit"],
            "production_preference_supported": report[
                "production_preference_supported"
            ],
            "estimated_cost_usd": sum(
                float(arm["estimated_cost_usd"]) for arm in report["arms"].values()
            ),
            "budget": budget.snapshot(),
            "report_path": str(report_path),
            "report_sha256": _sha256_file(report_path),
        }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    freeze = sub.add_parser("freeze")
    freeze.add_argument("--repo", type=Path, required=True)
    freeze.add_argument("--templates", type=Path, required=True)
    freeze.add_argument("--production", type=Path, required=True)
    freeze.add_argument("--shadow", type=Path, required=True)
    freeze.add_argument("--ripgrep", type=Path, required=True)
    freeze.add_argument("--output", type=Path, required=True)
    freeze.add_argument("--max-rollout-cost-usd", type=float, default=0.90)
    freeze.add_argument("--max-rollout-metered-tokens", type=int, default=300_000)
    freeze.add_argument("--max-total-cost-usd", type=float, default=50.0)
    freeze.add_argument("--max-total-metered-tokens", type=int, default=15_000_000)
    freeze.add_argument("--max-output-tokens", type=int, default=4096)
    dry = sub.add_parser("dry-run")
    dry.add_argument("--repo", type=Path, required=True)
    dry.add_argument("--manifest", type=Path, required=True)
    dry.add_argument("--ripgrep", type=Path, required=True)
    run = sub.add_parser("run")
    run.add_argument("--repo", type=Path, required=True)
    run.add_argument("--manifest", type=Path, required=True)
    run.add_argument("--ripgrep", type=Path, required=True)
    run.add_argument("--run-dir", type=Path, required=True)
    run.add_argument("--budget-journal", type=Path, required=True)
    run.add_argument("--auth-file", type=Path, default=Path.home() / ".metacodes/auth.json")
    run.add_argument(
        "--max-rollouts-this-invocation",
        type=int,
        help="durably checkpoint and pause after this many newly completed rollouts",
    )
    run.add_argument("--allow-paid-rollouts", action="store_true")
    run.add_argument("--resume", action="store_true")
    report = sub.add_parser("report")
    report.add_argument("--repo", type=Path, required=True)
    report.add_argument("--manifest", type=Path, required=True)
    report.add_argument("--run-dir", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "freeze":
        manifest = freeze_manifest(
            repo=args.repo,
            templates_manifest=args.templates,
            production_binary=args.production,
            shadow_binary=args.shadow,
            ripgrep=args.ripgrep,
            max_rollout_cost_usd=args.max_rollout_cost_usd,
            max_rollout_metered_tokens=args.max_rollout_metered_tokens,
            max_total_cost_usd=args.max_total_cost_usd,
            max_total_metered_tokens=args.max_total_metered_tokens,
            max_output_tokens=args.max_output_tokens,
        )
        _write_new(args.output, (stable_json(manifest) + "\n").encode("utf-8"))
        print(stable_json({"manifest_id": manifest["manifest_id"], "quality_evidence": False, "provider_requests": 0}))
        return 0
    if args.command == "dry-run":
        manifest = validate_manifest(args.manifest.resolve(strict=True), args.repo.resolve(strict=True))
        ripgrep = args.ripgrep.resolve(strict=True)
        ripgrep_sha256 = file_sha256(ripgrep)
        frozen_ripgrep = manifest["artifacts"]["ripgrep"]
        if str(ripgrep) != frozen_ripgrep["path"] or ripgrep_sha256 != frozen_ripgrep["sha256"]:
            raise E3Error("E3 dry-run ripgrep artifact drift")
        _assert_executable_identity(ripgrep, ripgrep_sha256, "E3 dry-run ripgrep")
        print(
            stable_json(
                {
                    "dry_run": True,
                    "quality_evidence": False,
                    "provider_requests": 0,
                    "credential_loaded": False,
                    "manifest_id": manifest["manifest_id"],
                    "rollouts": len(manifest["schedule"]),
                    "budget": {
                        key: value
                        for key, value in manifest["execution"].items()
                        if key.startswith("max_")
                    },
                }
            )
        )
        return 0
    if args.command == "report":
        print(stable_json(build_report(
            args.manifest.resolve(strict=True),
            args.run_dir.resolve(strict=True),
            args.repo.resolve(strict=True),
        )))
        return 0
    if not args.allow_paid_rollouts:
        raise E3Error("paid E3 run requires --allow-paid-rollouts")
    summary = run_paid(
        repo=args.repo,
        manifest_path=args.manifest,
        ripgrep=args.ripgrep,
        run_dir=args.run_dir,
        budget_path=args.budget_journal,
        auth_file=args.auth_file,
        resume=args.resume,
        max_rollouts=args.max_rollouts_this_invocation,
    )
    print(stable_json(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
