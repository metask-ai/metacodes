"""Execute TinyKG x Lean cells through one native rollout boundary.

The executor deliberately reuses ``project_harness_e3_pilot._run_one`` for
provider authorization, native events, sandboxing, host re-observation, and
budget commit.  It does not merge a memory report with a Lean report after the
fact.  The only factor switches are the local TinyKG store attachment and the
presence of an already verified active project-rule bundle.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
from typing import Any, Mapping, Sequence

from .attribution_protocol import EXPECTED_CELLS, PROTOCOL_ID
from .e2e_adapter import _native_trace_metrics
from .memory_budget_journal import BudgetJournal, usd_to_microusd_ceiling
from .memory_replay import _artifact_tree_digest
from .model import ValidationError, stable_json
from .project_harness_e3_experiment import (
    E3Error,
    _canonical_sha256,
    _validate_committed_budget_receipt,
    analyze_journal,
    grade_workspace,
)
from .project_harness_e3_pilot import (
    FactorialRuntimeTreatment,
    _run_one,
)
from .project_harness_evolution import _sha256_file
from .tinykg_lean_factorial import (
    REFERENCE_SCHEMA,
    ROLLOUT_SCHEMA,
)


SOURCE_SCHEMA = "metacodes-tinykg-lean-factorial-source-v1"
EXECUTOR_SCHEMA = "metacodes-tinykg-lean-factorial-executor-v1"
MAX_JSON_BYTES = 64 * 1024 * 1024
_TINYKG_DYNAMIC_SECTION = re.compile(
    r"(?ms)^# (?:Memory|Knowledge Graph|Deferred tools)\n.*?"
    r"(?:\n\n(?=^# )|\Z)"
)
_DEFERRED_SECTION = re.compile(
    r"(?ms)^# Deferred tools\n(.*?)(?:\n\n(?=^# )|\Z)"
)


def _fail(where: str, detail: str) -> None:
    raise ValidationError(f"{where}: {detail}")


def _read_regular(path: Path, *, root: Path, where: str) -> bytes:
    spelled = path.absolute()
    try:
        root = root.resolve(strict=True)
        before = spelled.lstat()
        if stat.S_ISLNK(before.st_mode):
            _fail(where, "symlink is forbidden")
        resolved = spelled.resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError) as exc:
        _fail(where, f"escaped the run root or cannot be inspected: {exc}")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(spelled, flags)
    except OSError as exc:
        _fail(where, f"cannot open without following links: {exc}")
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            or opened.st_size < 0
            or opened.st_size > MAX_JSON_BYTES
        ):
            _fail(where, "is not a bounded single-link regular file")
        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, MAX_JSON_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_JSON_BYTES:
                _fail(where, "exceeds the size cap")
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
        or total != opened.st_size
    ):
        _fail(where, "changed while being read")
    return b"".join(chunks)


def _json(payload: bytes, where: str) -> Mapping[str, Any]:
    try:
        value = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError) as exc:
        _fail(where, f"invalid JSON: {exc}")
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    return value


def _stable_core_prefix(first_request: Mapping[str, Any]) -> str:
    system = first_request.get("system")
    tools = first_request.get("tools")
    model = first_request.get("model")
    cache_control = first_request.get("cache_control")
    if (
        not isinstance(system, str)
        or not isinstance(tools, list)
        or not isinstance(model, str)
        or not isinstance(cache_control, dict)
    ):
        _fail("factorial first request", "missing the stable provider prefix")
    deferred = list(_DEFERRED_SECTION.finditer(system))
    if len(deferred) > 1:
        _fail("factorial first request", "has duplicate deferred-tool sections")
    if deferred:
        listed = re.findall(r"(?m)^- ([A-Za-z][A-Za-z0-9_]*) — ", deferred[0].group(1))
        if listed != ["FormalAuditTask"]:
            _fail(
                "factorial first request",
                "cannot erase a non-TinyKG deferred-tool treatment",
            )
    # Memory, the graph instructions, and the only KG-gated deferred tool are
    # all intentional TinyKG treatment increments.  Remove exactly those
    # sections, then canonicalize only trailing whitespace introduced by the
    # section separators.  Any other actor-system drift remains hash-visible.
    stripped = _TINYKG_DYNAMIC_SECTION.sub("", system).rstrip() + "\n"
    return hashlib.sha256(
        json.dumps(
            {
                "model": model,
                "system": stripped,
                "tools": tools,
                "cache_control": cache_control,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=False,
        ).encode("utf-8")
    ).hexdigest()


def _reopen_source(
    *,
    item: Mapping[str, Any],
    run_dir: Path,
    manifest: Mapping[str, Any],
    schedule: Mapping[str, Any],
    budget_journal: BudgetJournal,
) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
    receipt_path = Path(str(item.get("receipt_path", "")))
    payload = _read_regular(receipt_path, root=run_dir, where="factorial source receipt")
    if hashlib.sha256(payload).hexdigest() != item.get("receipt_sha256"):
        _fail("factorial source receipt", "SHA-256 drift")
    source = _json(payload, "factorial source receipt")
    if (
        source.get("schema_version") != SOURCE_SCHEMA
        or source.get("sequence") != schedule.get("sequence")
        or source.get("case_id") != schedule.get("case_id")
        or source.get("quality_evidence")
        is not (source.get("evidence_level") == "E3-paid-model-rollout")
    ):
        _fail("factorial source receipt", "identity or evidence-level drift")
    artifacts = source.get("artifacts")
    hashes = source.get("artifact_sha256")
    if not isinstance(artifacts, dict) or not isinstance(hashes, dict):
        _fail("factorial source receipt", "artifact commitments are missing")
    for name in (
        "events",
        "journal",
        "first_request",
        "stdout",
        "stderr",
        "sandbox_profile",
        "sandbox_evidence",
    ):
        path = Path(str(artifacts.get(name, "")))
        _read_regular(path, root=run_dir, where=f"factorial source artifact {name}")
        if _sha256_file(path) != hashes.get(name):
            _fail(f"factorial source artifact {name}", "SHA-256 drift")
    cassette = Path(str(artifacts.get("cassette", ""))).resolve(strict=True)
    try:
        cassette.relative_to(run_dir.resolve(strict=True))
    except ValueError:
        _fail("factorial source cassette", "escaped the run root")
    if _artifact_tree_digest(cassette) != hashes.get("cassette"):
        _fail("factorial source cassette", "tree digest drift")

    case_by_id = {
        str(case.get("id")): case
        for case in manifest.get("cases", [])
        if isinstance(case, dict)
    }
    case = case_by_id.get(str(schedule["case_id"]))
    if case is None:
        _fail("factorial source receipt", "case is outside the frozen manifest")
    workspace = Path(str(artifacts.get("workspace_final", ""))).resolve(strict=True)
    try:
        workspace.relative_to(run_dir.resolve(strict=True))
    except ValueError:
        _fail("factorial source workspace", "escaped the run root")
    if grade_workspace(case, workspace) != source.get("grader"):
        _fail("factorial source workspace", "host grader replay drift")
    governance = analyze_journal(
        path=Path(str(artifacts["journal"])),
        arm=str(source["arm"]),
        oracle_class=str(case["oracle_class"]),
        project_sha256=str(manifest["project_sha256"]),
        kernel_sha256=str(source["kernel_sha256"]),
        candidate_id=(
            str(source["candidate_id"])
            if source.get("candidate_id") is not None
            else None
        ),
        task_success=bool(source["grader"]["passed"]),
    )
    if governance != source.get("governance"):
        _fail("factorial source journal", "host governance replay drift")
    native, native_error = _native_trace_metrics(Path(str(artifacts["events"])))
    if (
        native_error is not None
        or native is None
        or native.get("complete") is not True
        or native.get("dropped_events_total") != 0
    ):
        _fail("factorial source native events", native_error or "incomplete trace")
    budget = source.get("budget_transaction")
    if not isinstance(budget, dict) or budget.get("state") != "committed":
        _fail("factorial source budget", "missing committed transaction")
    usage = source.get("usage")
    if not isinstance(usage, dict):
        _fail("factorial source budget", "source usage is unavailable")
    try:
        actual_metered_tokens = sum(
            int(usage[key])
            for key in (
                "input_tokens",
                "output_tokens",
                "cache_read_tokens",
                "cache_write_tokens",
            )
        )
        actual_cost_microusd = usd_to_microusd_ceiling(float(usage["cost_usd"]))
    except (KeyError, TypeError, ValueError) as exc:
        _fail("factorial source budget", f"invalid metered usage: {exc}")
    expected_run_id = (
        f"{manifest['manifest_id']}:{schedule['sequence']}:{schedule['case_id']}:"
        f"{source['arm']}-{schedule['cell']}"
    )
    _validate_committed_budget_receipt(
        budget,
        manifest=manifest,
        expected_run_id=expected_run_id,
        expected_harness_fingerprint=str(source["harness_fingerprint"]),
        actual_cost_microusd=actual_cost_microusd,
        actual_metered_tokens=actual_metered_tokens,
    )
    if budget_journal.transaction_receipt(str(budget["transaction_id"])) != budget:
        _fail("factorial source budget", "durable journal receipt drift")
    return source, native


def build_projection(
    *,
    item: Mapping[str, Any],
    run_dir: Path,
    manifest: Mapping[str, Any],
    schedule: Mapping[str, Any],
    budget_journal: BudgetJournal,
) -> Mapping[str, Any]:
    source, native = _reopen_source(
        item=item,
        run_dir=run_dir,
        manifest=manifest,
        schedule=schedule,
        budget_journal=budget_journal,
    )
    cell = str(schedule["cell"])
    factors = EXPECTED_CELLS.get(cell)
    treatment = source.get("factorial_treatment")
    if factors is None or not isinstance(treatment, dict) or treatment.get("cell") != cell:
        _fail("factorial source treatment", "cell drift")
    tinykg = treatment.get("tinykg")
    lean = treatment.get("lean")
    if not isinstance(tinykg, dict) or not isinstance(lean, dict):
        _fail("factorial source treatment", "factor evidence is missing")
    if (tinykg.get("enabled"), lean.get("enabled")) != factors:
        _fail("factorial source treatment", "factor declaration drift")

    artifacts = source["artifacts"]
    first_request_path = Path(str(artifacts["first_request"]))
    first_request = _json(
        _read_regular(
            first_request_path,
            root=run_dir,
            where="factorial first request",
        ),
        "factorial first request",
    )
    case = next(
        case
        for case in manifest["cases"]
        if isinstance(case, dict) and case.get("id") == schedule["case_id"]
    )
    governance = source["governance"]
    usage = source["usage"]
    memory_bytes = int(tinykg.get("memory_exposed_bytes", 0))
    false_intervention = bool(
        governance.get("safe_action_false_intervention", False)
        or governance.get("safe_case_intervention", False)
    )
    effective_intervention = bool(
        factors[1]
        and governance.get("formal_block", False)
        and governance.get("trustworthy_task_success", False)
        and not false_intervention
    )
    budget = source["budget_transaction"]
    return {
        "sequence": schedule["sequence"],
        "case_id": schedule["case_id"],
        "position": schedule["position"],
        "cell": cell,
        "factors": {"tinykg": factors[0], "lean": factors[1]},
        "identity": {
            "model_fingerprint": manifest["execution"]["model_fingerprint"],
            "harness_revision": _canonical_sha256(
                {
                    "executor_schema": EXECUTOR_SCHEMA,
                    "repository_commit": manifest["repository"]["commit"],
                }
            ),
            "task_fingerprint": source["task_fingerprint"],
            "actor_prompt_sha256": hashlib.sha256(
                str(case["prompt"]).encode("utf-8")
            ).hexdigest(),
            "tool_schema_sha256": source["factorial_tool_schema_sha256"],
            "stable_core_prefix_sha256": _stable_core_prefix(first_request),
            "first_request_sha256": _sha256_file(first_request_path),
        },
        "treatment": {
            "tinykg": {
                key: tinykg[key]
                for key in (
                    "enabled",
                    "transport",
                    "store_scope",
                    "remote_writes",
                    "recall_receipt_verified",
                    "read_count",
                    "store_revision_sha256",
                )
            },
            "lean": {
                key: lean[key]
                for key in (
                    "enabled",
                    "bundle_loaded",
                    "checker_sha256",
                    "bundle_sha256",
                    "checker_calls",
                    "formal_decisions",
                    "unsafe_false_interventions",
                )
            },
        },
        "outcomes": {
            "task_success": bool(source["grader"]["passed"]),
            "trustworthy_success": bool(
                governance["trustworthy_task_success"]
            ),
            "error_recurrence": bool(
                governance["existing_file_write_recurrence"]
            ),
            "effective_intervention": effective_intervention,
            "false_intervention": false_intervention if factors[1] else False,
            "recovery_success": bool(
                factors[1] and governance["recovery_after_block"]
            ),
        },
        "usage": {
            "cost_microusd": int(budget["actual_cost_microusd"]),
            "metered_tokens": int(budget["actual_metered_tokens"]),
            "provider_requests": int(source["provider_requests"]),
            "wall_time_ms": int(usage["wall_time_ms"]),
            "model_time_ms": int(usage["model_request_time_ms"]),
            "tool_time_ms": int(usage["tool_time_ms"]),
            "checker_time_ns": int(governance["checker_elapsed_ns_total"]),
            "memory_exposed_tokens": (memory_bytes + 3) // 4,
        },
        "quality_evidence": bool(source["quality_evidence"]),
    }


def _write_private(path: Path, payload: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                _fail("factorial receipt", "short write")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def persist_projection(
    *, projection: Mapping[str, Any], run_dir: Path
) -> Mapping[str, Any]:
    sequence = int(projection["sequence"])
    receipt = {
        "schema_version": ROLLOUT_SCHEMA,
        "protocol_id": PROTOCOL_ID,
        "projection_sha256": hashlib.sha256(
            stable_json(projection).encode("utf-8")
        ).hexdigest(),
        "host_reopened_source_evidence": True,
        "raw_artifacts_local_only": True,
        "projection": dict(projection),
    }
    path = run_dir / "factorial-receipts" / f"receipt-{sequence:05d}.json"
    payload = (stable_json(receipt) + "\n").encode("utf-8")
    _write_private(path, payload)
    return {
        "sequence": sequence,
        "path": path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "projection": projection,
    }


def execute_cell(
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
    tinykg_binary: Path,
    tinykg_binary_sha256: str,
    seed_batch: bytes,
    recall_query: str,
    test_base_url: str | None = None,
) -> Mapping[str, Any]:
    cell = str(schedule["cell"])
    try:
        tinykg_enabled, lean_enabled = EXPECTED_CELLS[cell]
    except KeyError as exc:
        _fail("factorial schedule", f"unknown cell {cell!r}")
        raise AssertionError from exc
    e3_schedule = {
        "sequence": schedule["sequence"],
        "case_id": schedule["case_id"],
        "trial": int(schedule["sequence"]) // 4,
        "position": schedule["position"],
        "arm": "evolved_enforced" if lean_enabled else "signal_only",
    }
    treatment = FactorialRuntimeTreatment(
        cell=cell,
        tinykg_enabled=tinykg_enabled,
        lean_enabled=lean_enabled,
        tinykg_binary=tinykg_binary,
        tinykg_binary_sha256=tinykg_binary_sha256,
        seed_batch=seed_batch if tinykg_enabled else b"",
        recall_query=recall_query if tinykg_enabled else "",
    )
    try:
        source_item = _run_one(
            repo=repo,
            manifest=manifest,
            templates=templates,
            schedule=e3_schedule,
            run_dir=run_dir,
            ripgrep=ripgrep,
            ripgrep_sha256=ripgrep_sha256,
            api_key=api_key,
            budget=budget,
            timeout_seconds=timeout_seconds,
            test_base_url=test_base_url,
            receipt_schema=SOURCE_SCHEMA,
            factorial_treatment=treatment,
        )
    except (E3Error, ValidationError) as exc:
        raise type(exc)(f"factorial cell {cell}: {exc}") from exc
    projection = build_projection(
        item=source_item,
        run_dir=run_dir,
        manifest=manifest,
        schedule=schedule,
        budget_journal=budget,
    )
    persisted = persist_projection(projection=projection, run_dir=run_dir)
    return {**persisted, "source": source_item}


def persist_references(
    *, receipts: Sequence[Mapping[str, Any]], run_dir: Path
) -> Path:
    ordered = sorted(receipts, key=lambda item: int(item["sequence"]))
    if [int(item["sequence"]) for item in ordered] != list(range(len(ordered))):
        _fail("factorial references", "receipt sequence is not contiguous")
    root = run_dir.resolve(strict=True)
    references = []
    for item in ordered:
        path = Path(str(item["path"])).resolve(strict=True)
        try:
            relative = path.relative_to(root)
        except ValueError:
            _fail("factorial references", "receipt escaped the run root")
        if _sha256_file(path) != item["sha256"]:
            _fail("factorial references", "receipt SHA-256 drift")
        references.append(
            {
                "sequence": item["sequence"],
                "path": relative.as_posix(),
                "sha256": item["sha256"],
            }
        )
    path = run_dir / "factorial-references.json"
    payload = (
        stable_json(
            {
                "schema_version": REFERENCE_SCHEMA,
                "protocol_id": PROTOCOL_ID,
                "receipts": references,
            }
        )
        + "\n"
    ).encode("utf-8")
    _write_private(path, payload)
    return path
