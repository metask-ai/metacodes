"""Execute TinyKG x Lean cells through one native rollout boundary.

The executor deliberately reuses ``project_harness_e3_pilot._run_one`` for
provider authorization, native events, sandboxing, host re-observation, and
budget commit.  It does not merge a memory report with a Lean report after the
fact.  The only factor switches are the local TinyKG store attachment and the
presence of an already verified active project-rule bundle.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any, Mapping, Sequence

from .attribution_protocol import (
    CELL_IDS,
    EXPECTED_CELLS,
    PROTOCOL_ID,
    balanced_factorial_schedule,
    load_protocol,
    validate_protocol,
)
from .e2e_adapter import _native_trace_metrics
from .memory_agent_runtime import (
    _assert_executable_identity,
    _assert_production_secret_absent,
    _project_domain,
    _replace_private_file,
)
from .memory_agent_runtime_pilot import _load_api_key
from .memory_benchmark import file_sha256
from .memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    usd_to_microusd,
    usd_to_microusd_ceiling,
)
from .memory_replay import PRODUCTION_PROVIDER_ID, _artifact_tree_digest
from .memory_tinykg_local import LocalTinyKg, _store_info
from .model import ValidationError, stable_json
from .project_harness_e3_experiment import (
    E3Error,
    _canonical_sha256,
    _validate_committed_budget_receipt,
    analyze_journal,
    grade_workspace,
    validate_manifest,
)
from .project_harness_e3_pilot import (
    FACTORIAL_DISALLOWED_TOOLS,
    FactorialRuntimeTreatment,
    _run_one,
)
from .project_harness_evolution import _sha256_file
from .project_harness_e3_templates import verify_templates
from .tinykg_lean_factorial import (
    REFERENCE_SCHEMA,
    ROLLOUT_SCHEMA,
    build_report,
    load_receipts,
)


SOURCE_SCHEMA = "metacodes-tinykg-lean-factorial-source-v1"
EXECUTOR_SCHEMA = "metacodes-tinykg-lean-factorial-executor-v1"
CALIBRATION_CHECKPOINT_SCHEMA = "metacodes-tinykg-lean-factorial-calibration-checkpoint-v1"
CALIBRATION_SUMMARY_SCHEMA = "metacodes-tinykg-lean-factorial-calibration-summary-v1"
CALIBRATION_PREFLIGHT_SCHEMA = "metacodes-tinykg-lean-factorial-calibration-preflight-v1"
CALIBRATION_CELLS = ("control", "memory_only", "combined", "lean_only")
BLOCK_CHECKPOINT_SCHEMA = "metacodes-tinykg-lean-factorial-block-checkpoint-v1"
BLOCK_SUMMARY_SCHEMA = "metacodes-tinykg-lean-factorial-block-summary-v1"
BLOCK_PREFLIGHT_SCHEMA = "metacodes-tinykg-lean-factorial-block-preflight-v1"
BLOCK_CASES_RELATIVE = Path(
    "evals/experiments/tinykg-lean-factorial-block-v1-cases.json"
)
ATTRIBUTION_PROTOCOL_RELATIVE = Path(
    "evals/experiments/tinykg-lean-attribution-v1.json"
)
BLOCK_CASE_IDS = (
    "canonicalize_archive_limits_env_v4",
    "replace_node_inventory_json_v4",
    "regenerate_lifecycle_yaml_v4",
    "rewrite_proxy_conf_v4",
)
HELDOUT_CASES_RELATIVE = Path(
    "evals/experiments/tinykg-lean-factorial-heldout-v1-cases.json"
)
# The protocol pre-registers `heldout_cases: 8`.  The held-out cohort is
# therefore every frozen manifest case outside the calibration block: running
# all of them removes case-selection discretion entirely, so a harness change
# tuned on the calibration cases cannot be validated on a hand-picked subset.
HELDOUT_CASE_IDS = (
    "create_package_stamp_json_v4",
    "create_rotation_note_v4",
    "synthesize_attestation_cue_v4",
    "synthesize_commit_policy_lua_v4",
    "synthesize_partition_plan_ron_v4",
    "synthesize_restore_table_tsv_v4",
    "targeted_changelog_marker_edit_v4",
    "targeted_queue_depth_edit_v4",
)
VERIFICATION_BLOCK_CASE_IDS = (
    "vg_ledger_total_v1",
    "vg_audit_marks_v1",
    "vg_max_span_v1",
    "vg_pass_rate_v1",
)
VERIFICATION_HELDOUT_CASE_IDS = (
    "vg_checksum_mod_v1",
    "vg_distinct_tags_v1",
    "vg_duplicate_ids_v1",
    "vg_error_suffix_v1",
    "vg_longest_line_v1",
    "vg_odd_even_delta_v1",
    "vg_range_gap_v1",
    "vg_weighted_amount_v1",
)
VERIFICATION_BLOCK_CASES_RELATIVE = Path(
    "evals/experiments/verification-obligation-block-v1-cases.json"
)
VERIFICATION_HELDOUT_CASES_RELATIVE = Path(
    "evals/experiments/verification-obligation-heldout-v1-cases.json"
)
# The verification family's enforcement plane is the session-end obligation
# gate, not a promoted rule bundle: every cell runs arm signal_only, lean
# cells add --verification-final-gate and the others add
# --verification-final-observe so the outcome record exists symmetrically.
# Bash is the family's verification instrument and must be allowed.
VERIFICATION_FAMILY_DISALLOWED = tuple(
    tool
    for tool in FACTORIAL_DISALLOWED_TOOLS
    if tool not in {"Bash", "BashOutput"}
)
# Bash is the family's verification instrument; the allowed list is the
# actual tool gate on the eval-metadata channel, so it must widen too.
VERIFICATION_FAMILY_ALLOWED = (
    "Read", "Write", "Edit", "Glob", "Grep", "Bash", "BashOutput",
    "KgRecall", "KgContext",
)
VERIFICATION_MEMORY_QUERY = (
    "derive result run command compute verify test before final answer"
)
VERIFICATION_MEMORY_TEXT = (
    "Verified historical procedural lesson for derived-output tasks: when a "
    "result file must be computed from input files, do not trust manual "
    "arithmetic or eyeballed counts — derive the value by actually running a "
    "command over the inputs. After writing the result, run the workspace's "
    "provided executable verification runner and only finish after it passes; "
    "if it fails, fix the result and verify again. "
    "This is general workflow guidance, not a task answer, and current "
    "instructions remain authoritative."
)
COHORTS = {
    "block": (BLOCK_CASE_IDS, BLOCK_CASES_RELATIVE, "existing_file_rewrite"),
    "heldout": (HELDOUT_CASE_IDS, HELDOUT_CASES_RELATIVE, "existing_file_rewrite"),
    "verification-block": (
        VERIFICATION_BLOCK_CASE_IDS,
        VERIFICATION_BLOCK_CASES_RELATIVE,
        "verification_obligation",
    ),
    "verification-heldout": (
        VERIFICATION_HELDOUT_CASE_IDS,
        VERIFICATION_HELDOUT_CASES_RELATIVE,
        "verification_obligation",
    ),
}


def _cohort_spec(cohort: str) -> tuple[tuple[str, ...], Path, str]:
    spec = COHORTS.get(cohort)
    if spec is None:
        _fail("factorial cohort", f"unknown cohort {cohort!r}")
    return spec
PROCEDURAL_MEMORY_QUERY = (
    "existing file inspect read replace regenerate canonical exact preserve verify"
)
PROCEDURAL_MEMORY_TEXT = (
    "Verified historical procedural lesson for exact existing-file replacement: "
    "inspect and Read the existing file before modifying it; preserve the requested "
    "canonical bytes and final newline; use Edit with the observed source as a "
    "source-CAS precondition instead of Write; when a project rule denies a write, "
    "do not improvise an alternative — follow the recovery protocol in the denial "
    "verbatim, because it carries the byte-exact obligation. When editing directly, "
    "include the original trailing newline in old_string so the replacement cannot "
    "leave a doubled final newline, and trust the tool-reported final_newlines fact "
    "over your own reading of blank lines. Create no unrelated files; then Read "
    "again and verify the complete result byte-for-byte. This is general workflow "
    "guidance, not a task answer, and current instructions remain authoritative."
)
FAMILIES = {
    "existing_file_rewrite": {
        "lean_lever": "bundle",
        "memory_text": PROCEDURAL_MEMORY_TEXT,
        "memory_query": PROCEDURAL_MEMORY_QUERY,
        "extra_args": {True: (), False: ()},
        "disallowed_tools": None,
        "allowed_tools": None,
        "protocol_id": "metacodes-tinykg-lean-attribution-v1",
    },
    "verification_obligation": {
        "lean_lever": "final_gate",
        "memory_text": VERIFICATION_MEMORY_TEXT,
        "memory_query": VERIFICATION_MEMORY_QUERY,
        "extra_args": {
            True: ("--verification-final-gate",),
            False: ("--verification-final-observe",),
        },
        "disallowed_tools": VERIFICATION_FAMILY_DISALLOWED,
        "allowed_tools": VERIFICATION_FAMILY_ALLOWED,
        "protocol_id": "metacodes-verification-obligation-attribution-v1",
    },
}

MAX_JSON_BYTES = 64 * 1024 * 1024
_TINYKG_DYNAMIC_SECTION = re.compile(
    r"(?ms)^# (?:Memory|Knowledge Graph|Deferred tools)\n.*?"
    r"(?:\n\n(?=^# )|\Z)"
)
_DEFERRED_SECTION = re.compile(
    r"(?ms)^# Deferred tools\n(.*?)(?:\n\n(?=^# )|\Z)"
)


@dataclass(frozen=True)
class CalibrationContext:
    repo: Path
    manifest: Mapping[str, Any]
    templates: Mapping[str, Any]
    case: Mapping[str, Any]
    root: Path
    workspace: Path
    run_dir: Path
    budget_path: Path
    ripgrep: Path
    ripgrep_sha256: str
    tinykg_binary: Path
    tinykg_sha256: str
    seed_batch: bytes
    recall_query: str
    identity: Mapping[str, Any]
    schedules: tuple[Mapping[str, Any], ...]
    authority: BudgetAuthority
    family: str = "existing_file_rewrite"


@dataclass(frozen=True)
class BlockContext:
    repo: Path
    manifest: Mapping[str, Any]
    templates: Mapping[str, Any]
    case_ids: tuple[str, ...]
    root: Path
    workspace: Path
    run_dir: Path
    budget_path: Path
    ripgrep: Path
    ripgrep_sha256: str
    tinykg_binary: Path
    tinykg_sha256: str
    tinykg_contract: Mapping[str, str]
    seed_batch: bytes
    recall_query: str
    identity: Mapping[str, Any]
    schedules: tuple[Mapping[str, Any], ...]
    authority: BudgetAuthority
    family: str = "existing_file_rewrite"


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


def _assert_historical_budget_receipt(
    budget_journal: BudgetJournal,
    historical: Mapping[str, Any],
) -> None:
    transaction_id = str(historical.get("transaction_id", ""))
    current = budget_journal.transaction_receipt(transaction_id)
    evolving_journal_fields = {"journal_revision", "journal_head_sha256"}
    if (
        set(current) != set(historical)
        or any(
            current[field] != historical[field]
            for field in current
            if field not in evolving_journal_fields
        )
        or int(current["journal_revision"]) < int(historical["journal_revision"])
        or (
            current["journal_revision"] == historical["journal_revision"]
            and current["journal_head_sha256"] != historical["journal_head_sha256"]
        )
    ):
        _fail("factorial source budget", "durable journal transaction drift")


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
    _assert_historical_budget_receipt(budget_journal, budget)
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
    oracle_class = str(case.get("oracle_class", ""))
    if oracle_class == "verification_skip":
        # The gate family's interventions are nudges, not formal blocks.
        false_intervention = bool(governance.get("verification_false_nudge") or False)
        effective_intervention = bool(
            factors[1]
            and int(governance.get("verification_nudges") or 0) > 0
            and governance.get("verification_obligation_met", False)
            and governance.get("trustworthy_task_success", False)
            and not false_intervention
        )
    else:
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
                    "lever",
                    "gate_enforced",
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
                governance["verification_premature_final"]
                if oracle_class == "verification_skip"
                else governance["existing_file_write_recurrence"]
            ),
            "effective_intervention": effective_intervention,
            "false_intervention": false_intervention if factors[1] else False,
            "recovery_success": bool(
                factors[1]
                and (
                    int(governance.get("verification_nudges") or 0) > 0
                    and governance.get("verification_obligation_met", False)
                    if oracle_class == "verification_skip"
                    else governance["recovery_after_block"]
                )
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
    family: str = "existing_file_rewrite",
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
    quality_evidence_eligible: bool = True,
) -> Mapping[str, Any]:
    cell = str(schedule["cell"])
    try:
        tinykg_enabled, lean_enabled = EXPECTED_CELLS[cell]
    except KeyError as exc:
        _fail("factorial schedule", f"unknown cell {cell!r}")
        raise AssertionError from exc
    family_spec = FAMILIES[family]
    bundle_lever = family_spec["lean_lever"] == "bundle"
    e3_schedule = {
        "sequence": schedule["sequence"],
        "case_id": schedule["case_id"],
        "trial": int(schedule["sequence"]) // 4,
        "position": schedule["position"],
        "arm": "evolved_enforced" if (bundle_lever and lean_enabled) else "signal_only",
    }
    extra_child_args = tuple(family_spec["extra_args"][lean_enabled])
    disallowed_override = family_spec["disallowed_tools"]
    allowed_override = family_spec["allowed_tools"]
    treatment = FactorialRuntimeTreatment(
        cell=cell,
        tinykg_enabled=tinykg_enabled,
        lean_enabled=lean_enabled,
        tinykg_binary=tinykg_binary,
        tinykg_binary_sha256=tinykg_binary_sha256,
        seed_batch=seed_batch if tinykg_enabled else b"",
        recall_query=recall_query if tinykg_enabled else "",
        lean_lever=family_spec["lean_lever"],
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
            quality_evidence_eligible=quality_evidence_eligible,
            extra_child_args=extra_child_args,
            disallowed_tools_override=disallowed_override,
            allowed_tools_override=allowed_override,
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
    if not quality_evidence_eligible:
        projection = {**projection, "quality_evidence": False}
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


def _calibration_schedules(case_id: str) -> tuple[Mapping[str, Any], ...]:
    if not case_id:
        _fail("factorial calibration", "case id is empty")
    return tuple(
        {
            "sequence": sequence,
            "case_id": case_id,
            "position": sequence,
            "cell": cell,
        }
        for sequence, cell in enumerate(CALIBRATION_CELLS)
    )


def _calibration_seed(
    *, case: Mapping[str, Any], workspace: Path
) -> tuple[bytes, str]:
    case_id = str(case["id"])
    query = f"{case_id} factorial calibration marker isolated TinyKG recall"
    decision = (
        f"{query}. This synthetic marker proves only that the isolated local TinyKG "
        "treatment was recalled for the scheduled cell. It is not a task instruction, "
        "does not contain an expected answer, and is not quality evidence."
    )
    rows = (
        {"version": 1},
        {
            "op": "node",
            "id": 1,
            "kind": "project",
            "name": _project_domain(workspace),
        },
        {"op": "node", "id": 2, "kind": "decision", "name": decision},
        {"op": "edge", "id": 1, "src": 1, "rel": "contain", "dst": 2},
    )
    payload = ("\n".join(stable_json(row) for row in rows) + "\n").encode("utf-8")
    return payload, query


def _block_seed(
    *,
    workspace: Path,
    forbidden: Sequence[str],
    memory_text: str = PROCEDURAL_MEMORY_TEXT,
    memory_query: str = PROCEDURAL_MEMORY_QUERY,
) -> tuple[bytes, str]:
    """Freeze a reusable, answer-free procedural treatment.

    The lesson deliberately contains no case id, filename, opaque value, or
    expected payload from the scored cohort.  Its value is the historical
    workflow constraint: observe an existing file, make a source-CAS edit,
    and re-observe the exact result.
    """

    rows = (
        {"version": 1},
        {
            "op": "node",
            "id": 1,
            "kind": "project",
            "name": _project_domain(workspace),
        },
        {
            "op": "node",
            "id": 2,
            "kind": "decision",
            "name": memory_text,
        },
        {"op": "edge", "id": 1, "src": 1, "rel": "contain", "dst": 2},
    )
    payload = ("\n".join(stable_json(row) for row in rows) + "\n").encode("utf-8")
    if any(value.encode("utf-8") in payload for value in forbidden):
        _fail("factorial block memory", "procedural seed leaks scored case identity")
    return payload, memory_query


def _probe_block_tinykg_contract(
    *, binary: Path, binary_sha256: str
) -> Mapping[str, str]:
    """Open a real isolated store before any credential or budget mutation."""

    with tempfile.TemporaryDirectory(prefix="metacodes-factorial-tinykg-probe-") as raw:
        local = LocalTinyKg(
            binary,
            expected_sha256=binary_sha256,
            run_dir=Path(raw) / "local",
        )
        store = local.store_root / "contract.kg"
        local.command("init", store, ())
        info = _store_info(local.command("store-info", store, ()))
    observed = {
        "storage_format_version": str(info.get("storage_format_version", "")),
        "schema_version": str(info.get("schema_version", "")),
    }
    if observed != {"storage_format_version": "3", "schema_version": "3"}:
        _fail(
            "factorial block TinyKG contract",
            "requires metacodes vendored storage-format-v3/schema-v3",
        )
    return observed


def _calibration_identity(
    *,
    manifest: Mapping[str, Any],
    case_id: str,
    tinykg_sha256: str,
    ripgrep_sha256: str,
    seed_batch: bytes,
    recall_query: str,
) -> Mapping[str, Any]:
    body = {
        "schema_version": EXECUTOR_SCHEMA,
        "executor_source_sha256": _sha256_file(Path(__file__).resolve(strict=True)),
        "manifest_id": manifest["manifest_id"],
        "manifest_sha256": _canonical_sha256(manifest),
        "repository_commit": manifest["repository"]["commit"],
        "case_id": case_id,
        "schedule": list(_calibration_schedules(case_id)),
        "tinykg_binary_sha256": tinykg_sha256,
        "ripgrep_binary_sha256": ripgrep_sha256,
        "seed_batch_sha256": hashlib.sha256(seed_batch).hexdigest(),
        "recall_query": recall_query,
    }
    return {**body, "calibration_id": _canonical_sha256(body)}


def _block_identity(
    *,
    manifest: Mapping[str, Any],
    memory_text: str = PROCEDURAL_MEMORY_TEXT,
    case_ids: Sequence[str],
    schedules: Sequence[Mapping[str, Any]],
    tinykg_sha256: str,
    tinykg_contract: Mapping[str, str],
    ripgrep_sha256: str,
    seed_batch: bytes,
    recall_query: str,
    protocol_sha256: str,
    case_ids_sha256: str,
) -> Mapping[str, Any]:
    body = {
        "schema_version": EXECUTOR_SCHEMA,
        "evidence_mode": "quality-factorial-block",
        "executor_source_sha256": _sha256_file(Path(__file__).resolve(strict=True)),
        "manifest_id": manifest["manifest_id"],
        "manifest_sha256": _canonical_sha256(manifest),
        "repository_commit": manifest["repository"]["commit"],
        "protocol_sha256": protocol_sha256,
        "case_ids_sha256": case_ids_sha256,
        "case_ids": list(case_ids),
        "schedule": list(schedules),
        "tinykg_binary_sha256": tinykg_sha256,
        "tinykg_contract": dict(tinykg_contract),
        "ripgrep_binary_sha256": ripgrep_sha256,
        "seed_batch_sha256": hashlib.sha256(seed_batch).hexdigest(),
        "procedural_memory_sha256": hashlib.sha256(
            memory_text.encode("utf-8")
        ).hexdigest(),
        "recall_query": recall_query,
    }
    return {**body, "block_id": _canonical_sha256(body)}


def _relative_to_run(path: Path, run_dir: Path, where: str) -> str:
    try:
        return path.resolve(strict=True).relative_to(run_dir.resolve(strict=True)).as_posix()
    except (OSError, ValueError) as exc:
        _fail(where, f"escaped the run directory: {exc}")


def _checkpoint_value(
    *,
    identity: Mapping[str, Any],
    completed: Sequence[Mapping[str, Any]],
    budget: BudgetJournal,
    references: Mapping[str, Any] | None,
    schema_version: str = CALIBRATION_CHECKPOINT_SCHEMA,
) -> Mapping[str, Any]:
    snapshot = budget.snapshot()
    return {
        "schema_version": schema_version,
        "identity": dict(identity),
        "completed": list(completed),
        "references": dict(references) if references is not None else None,
        "budget_journal_id": snapshot["journal_id"],
        "budget_revision": snapshot["revision"],
        "budget_head_sha256": snapshot["head_sha256"],
    }


def _persist_checkpoint(
    *,
    path: Path,
    identity: Mapping[str, Any],
    completed: Sequence[Mapping[str, Any]],
    budget: BudgetJournal,
    references: Mapping[str, Any] | None,
    schema_version: str = CALIBRATION_CHECKPOINT_SCHEMA,
) -> None:
    payload = (
        stable_json(
            _checkpoint_value(
                identity=identity,
                completed=completed,
                budget=budget,
                references=references,
                schema_version=schema_version,
            )
        )
        + "\n"
    ).encode("utf-8")
    _replace_private_file(path, payload)


def _checkpoint_entry(result: Mapping[str, Any], run_dir: Path) -> Mapping[str, Any]:
    source = result.get("source")
    if not isinstance(source, Mapping):
        _fail("factorial calibration checkpoint", "source receipt is missing")
    return {
        "sequence": int(result["sequence"]),
        "cell": str(result["projection"]["cell"]),
        "receipt_path": _relative_to_run(
            Path(str(result["path"])), run_dir, "factorial calibration receipt"
        ),
        "receipt_sha256": str(result["sha256"]),
        "source_receipt_path": _relative_to_run(
            Path(str(source["receipt_path"])),
            run_dir,
            "factorial calibration source receipt",
        ),
        "source_receipt_sha256": str(source["receipt_sha256"]),
    }


def _reopen_completed(
    *,
    entry: Mapping[str, Any],
    schedule: Mapping[str, Any],
    run_dir: Path,
    manifest: Mapping[str, Any],
    budget: BudgetJournal,
    quality_evidence: bool = False,
) -> Mapping[str, Any]:
    if (
        set(entry)
        != {
            "sequence",
            "cell",
            "receipt_path",
            "receipt_sha256",
            "source_receipt_path",
            "source_receipt_sha256",
        }
        or entry.get("sequence") != schedule["sequence"]
        or entry.get("cell") != schedule["cell"]
    ):
        _fail("factorial calibration checkpoint", "completed prefix drift")
    source_item = {
        "receipt_path": str(run_dir / str(entry["source_receipt_path"])),
        "receipt_sha256": entry["source_receipt_sha256"],
    }
    projection = build_projection(
        item=source_item,
        run_dir=run_dir,
        manifest=manifest,
        schedule=schedule,
        budget_journal=budget,
    )
    projection = {**projection, "quality_evidence": quality_evidence}
    receipt_path = run_dir / str(entry["receipt_path"])
    payload = _read_regular(
        receipt_path,
        root=run_dir,
        where="factorial calibration projected receipt",
    )
    if hashlib.sha256(payload).hexdigest() != entry["receipt_sha256"]:
        _fail("factorial calibration projected receipt", "SHA-256 drift")
    receipt = _json(payload, "factorial calibration projected receipt")
    if (
        set(receipt)
        != {
            "schema_version",
            "protocol_id",
            "projection_sha256",
            "host_reopened_source_evidence",
            "raw_artifacts_local_only",
            "projection",
        }
        or receipt.get("schema_version") != ROLLOUT_SCHEMA
        or receipt.get("protocol_id") != PROTOCOL_ID
        or receipt.get("projection_sha256")
        != hashlib.sha256(stable_json(projection).encode("utf-8")).hexdigest()
        or receipt.get("host_reopened_source_evidence") is not True
        or receipt.get("raw_artifacts_local_only") is not True
        or stable_json(receipt.get("projection")) != stable_json(projection)
    ):
        _fail("factorial calibration projected receipt", "projection replay drift")
    return {
        "sequence": schedule["sequence"],
        "path": receipt_path,
        "sha256": entry["receipt_sha256"],
        "projection": projection,
        "source": source_item,
    }


def _validate_calibration_projections(
    rows: Sequence[Mapping[str, Any]],
) -> None:
    if (
        len(rows) != len(CELL_IDS)
        or {str(row.get("cell")) for row in rows} != set(CELL_IDS)
        or [int(row.get("sequence", -1)) for row in rows]
        != list(range(len(CELL_IDS)))
    ):
        _fail("factorial calibration", "cell set is incomplete or reordered")
    by_cell = {str(row["cell"]): row for row in rows}
    if len({row["identity"]["tool_schema_sha256"] for row in rows}) != 1:
        _fail("factorial calibration", "provider tool schema drift")
    if len({row["identity"]["stable_core_prefix_sha256"] for row in rows}) != 1:
        _fail("factorial calibration", "stable provider prefix drift")
    for left, right in (("control", "lean_only"), ("memory_only", "combined")):
        if (
            by_cell[left]["identity"]["first_request_sha256"]
            != by_cell[right]["identity"]["first_request_sha256"]
        ):
            _fail("factorial calibration", "Lean changed the first provider request")
    for cell in ("control", "lean_only"):
        if by_cell[cell]["usage"]["memory_exposed_tokens"] != 0:
            _fail("factorial calibration", "TinyKG-off cell exposed memory")
    for cell in ("memory_only", "combined"):
        if by_cell[cell]["usage"]["memory_exposed_tokens"] <= 0:
            _fail("factorial calibration", "TinyKG-on cell exposed no memory")
    for cell in ("lean_only", "combined"):
        if by_cell[cell]["treatment"]["lean"]["checker_calls"] <= 0:
            _fail("factorial calibration", "Lean-on cell called no checker")
    if any(row.get("quality_evidence") is not False for row in rows):
        _fail("factorial calibration", "calibration row entered the quality-evidence path")


def _validate_paid_calibration_sources(
    results: Sequence[Mapping[str, Any]], *, run_dir: Path
) -> None:
    for index, result in enumerate(results):
        source_item = result.get("source")
        if not isinstance(source_item, Mapping):
            _fail("factorial calibration source", f"row {index} has no source receipt")
        source_path = Path(str(source_item.get("receipt_path", "")))
        payload = _read_regular(
            source_path,
            root=run_dir,
            where=f"factorial calibration source {index}",
        )
        if hashlib.sha256(payload).hexdigest() != source_item.get("receipt_sha256"):
            _fail("factorial calibration source", f"row {index} SHA-256 drift")
        source = _json(payload, f"factorial calibration source {index}")
        projection = result.get("projection")
        usage = projection.get("usage") if isinstance(projection, Mapping) else None
        if (
            source.get("schema_version") != SOURCE_SCHEMA
            or source.get("evidence_level") != "paid-model-wiring-calibration"
            or source.get("quality_evidence") is not False
            or not isinstance(source.get("provider_requests"), int)
            or int(source["provider_requests"]) <= 0
            or not isinstance(usage, Mapping)
            or int(usage.get("cost_microusd", 0)) <= 0
            or int(usage.get("metered_tokens", 0)) <= 0
            or int(usage.get("provider_requests", 0)) <= 0
        ):
            _fail(
                "factorial calibration source",
                f"row {index} is not a real paid provider rollout",
            )


def _validate_paid_block_sources(
    results: Sequence[Mapping[str, Any]], *, run_dir: Path
) -> None:
    for index, result in enumerate(results):
        source_item = result.get("source")
        if not isinstance(source_item, Mapping):
            _fail("factorial block source", f"row {index} has no source receipt")
        source_path = Path(str(source_item.get("receipt_path", "")))
        payload = _read_regular(
            source_path,
            root=run_dir,
            where=f"factorial block source {index}",
        )
        if hashlib.sha256(payload).hexdigest() != source_item.get("receipt_sha256"):
            _fail("factorial block source", f"row {index} SHA-256 drift")
        source = _json(payload, f"factorial block source {index}")
        projection = result.get("projection")
        usage = projection.get("usage") if isinstance(projection, Mapping) else None
        if (
            source.get("schema_version") != SOURCE_SCHEMA
            or source.get("evidence_level") != "E3-paid-model-rollout"
            or source.get("quality_evidence") is not True
            or not isinstance(source.get("provider_requests"), int)
            or int(source["provider_requests"]) <= 0
            or not isinstance(usage, Mapping)
            or int(usage.get("cost_microusd", 0)) <= 0
            or int(usage.get("metered_tokens", 0)) <= 0
            or int(usage.get("provider_requests", 0)) <= 0
            or projection.get("quality_evidence") is not True
        ):
            _fail(
                "factorial block source",
                f"row {index} is not an admissible paid quality rollout",
            )


def _reopen_references(
    *,
    info: Mapping[str, Any],
    results: Sequence[Mapping[str, Any]],
    run_dir: Path,
) -> Path:
    if set(info) != {"path", "sha256"}:
        _fail("factorial calibration references", "checkpoint field drift")
    relative = info.get("path")
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        _fail("factorial calibration references", "path must be relative")
    path = run_dir / relative
    payload = _read_regular(
        path,
        root=run_dir,
        where="factorial calibration references",
    )
    if hashlib.sha256(payload).hexdigest() != info.get("sha256"):
        _fail("factorial calibration references", "SHA-256 drift")
    references = _json(payload, "factorial calibration references")
    rows = references.get("receipts")
    if (
        set(references) != {"schema_version", "protocol_id", "receipts"}
        or references.get("schema_version") != REFERENCE_SCHEMA
        or references.get("protocol_id") != PROTOCOL_ID
        or not isinstance(rows, list)
        or len(rows) != len(results)
    ):
        _fail("factorial calibration references", "schema or receipt-set drift")
    for index, (row, result) in enumerate(zip(rows, results)):
        if not isinstance(row, Mapping) or set(row) != {"sequence", "path", "sha256"}:
            _fail("factorial calibration references", f"row {index} field drift")
        expected_path = _relative_to_run(
            Path(str(result["path"])),
            run_dir,
            f"factorial calibration result {index}",
        )
        if (
            row.get("sequence") != index
            or row.get("path") != expected_path
            or row.get("sha256") != result.get("sha256")
        ):
            _fail("factorial calibration references", f"row {index} binding drift")
        receipt_payload = _read_regular(
            run_dir / expected_path,
            root=run_dir,
            where=f"factorial calibration referenced receipt {index}",
        )
        if hashlib.sha256(receipt_payload).hexdigest() != row["sha256"]:
            _fail("factorial calibration references", f"row {index} receipt drift")
    return path


def _validate_private_path_if_present(path: Path, where: str) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        _fail(where, f"cannot inspect: {exc}")
    if (
        stat.S_ISLNK(info.st_mode)
        or not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or (hasattr(os, "geteuid") and info.st_uid != os.geteuid())
        or stat.S_IMODE(info.st_mode) & 0o077
    ):
        _fail(where, "must be an owned single-link private regular file")


VERIFICATION_PROTOCOL_RELATIVE = Path(
    "evals/experiments/verification-obligation-attribution-v1.json"
)
VERIFICATION_MANIFEST_SCHEMA = "metacodes-verification-obligation-manifest-v1"


def _validate_verification_protocol(protocol: Mapping[str, Any]) -> None:
    if (
        protocol.get("protocol_id")
        != "metacodes-verification-obligation-attribution-v1"
        or protocol.get("preregistered") is not True
        or protocol.get("primary_metric") != "trustworthy_success"
    ):
        _fail("verification protocol", "identity or primary metric drift")
    ladder = protocol.get("sample_ladder")
    if (
        not isinstance(ladder, Mapping)
        or ladder.get("calibration_cases") != len(VERIFICATION_BLOCK_CASE_IDS)
        or ladder.get("heldout_cases") != len(VERIFICATION_HELDOUT_CASE_IDS)
    ):
        _fail("verification protocol", "sample ladder drift")
    design = protocol.get("design")
    if (
        not isinstance(design, Mapping)
        or design.get("factor_b") != "verification_final_gate"
        or design.get("family") != "verification_obligation"
    ):
        _fail("verification protocol", "design drift")


def freeze_verification_manifest(
    *,
    repo: Path,
    production_binary: Path,
    ripgrep: Path,
    root: Path,
    max_rollout_cost_usd: float,
    max_rollout_metered_tokens: int,
    max_total_cost_usd: float,
    max_total_metered_tokens: int,
    max_output_tokens: int,
) -> Mapping[str, Any]:
    """Freeze the verification-obligation family manifest.

    Deliberately minimal relative to the hazard-family freeze: this family has
    no rule bundle, so no templates manifest, kernel promotion chain, or
    shadow binary participates. The repository must still be clean and every
    artifact content-addressed."""

    from .memory_replay import PRODUCTION_MODEL_PROVIDER
    from .project_harness_e3_experiment import (
        PRODUCTION_MODEL_FINGERPRINT,
        PRODUCTION_MODEL_ID,
        PRODUCTION_PROVIDER_ID,
        VERIFICATION_CASES,
        _artifact,
        _git_identity,
        _kernel_runtime_dependencies,
    )

    repo = repo.resolve(strict=True)
    repository = dict(_git_identity(repo))
    if repository["dirty"]:
        _fail("verification manifest", "preregistration requires a clean committed repository")
    root = root.expanduser().absolute()
    if root.exists() or root.is_symlink():
        _fail("verification manifest", "fresh frozen root already exists")
    root.mkdir(mode=0o700, parents=True)
    workspace = root / "workspace"
    workspace.mkdir(mode=0o700)
    production = _artifact(production_binary)
    frozen_ripgrep = _artifact(ripgrep)
    kernel_path = production_binary.parent.parent / "libexec/metacodes/metacodes-project-kernel"
    kernel = _artifact(kernel_path)
    kernel = {
        **kernel,
        "runtime_dependencies": _kernel_runtime_dependencies(Path(str(kernel["path"]))),
    }
    schedule_cells = 4 * len(VERIFICATION_BLOCK_CASE_IDS) + 4 * len(
        VERIFICATION_HELDOUT_CASE_IDS
    )
    if max_rollout_cost_usd * schedule_cells >= max_total_cost_usd:
        _fail("verification manifest", "total cost authority must cover every rollout cap")
    if max_rollout_metered_tokens * schedule_cells >= max_total_metered_tokens:
        _fail("verification manifest", "total token authority must cover every rollout cap")
    body = {
        "schema_version": VERIFICATION_MANIFEST_SCHEMA,
        "experiment_kind": "verification-obligation-2x2-factorial",
        "family": "verification_obligation",
        "repository": repository,
        "root": str(root),
        "project_root": str(workspace),
        "project_sha256": hashlib.sha256(str(workspace).encode("utf-8")).hexdigest(),
        "arms": {
            "signal_only": {
                "binary": "production_binary",
                "rule_flavor": None,
                "actuation": "none",
            },
        },
        "artifacts": {
            "production_binary": production,
            "ripgrep": frozen_ripgrep,
            "kernel": kernel,
        },
        "cases": [dict(case) for case in VERIFICATION_CASES],
        "execution": {
            "model_id": PRODUCTION_MODEL_ID,
            "model_provider": PRODUCTION_MODEL_PROVIDER,
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "provider_identity": PRODUCTION_PROVIDER_ID,
            "max_rollout_cost_usd": max_rollout_cost_usd,
            "max_rollout_metered_tokens": max_rollout_metered_tokens,
            "max_total_cost_usd": max_total_cost_usd,
            "max_total_metered_tokens": max_total_metered_tokens,
            "max_output_tokens": max_output_tokens,
            "rollout_timeout_seconds": 300,
            "serial_rollouts": True,
            "fresh_home_per_rollout": True,
        },
        "analysis_plan": {
            "protocol_id": "metacodes-verification-obligation-attribution-v1",
            "primary_metric": "trustworthy_success",
            "cells": sorted(EXPECTED_CELLS),
        },
        "claim_boundary": (
            "internal complete 2x2 attribution for the verification-obligation "
            "family; not external benchmark superiority"
        ),
    }
    manifest = {**body, "manifest_id": _canonical_sha256(body)}
    manifest_path = root / "manifest.json"
    payload = (stable_json(manifest) + "\n").encode("utf-8")
    _write_private(manifest_path, payload)
    return manifest


def _validate_verification_manifest(path: Path, repo: Path) -> Mapping[str, Any]:
    manifest = _json(
        path.read_bytes(), "verification manifest"
    )
    body = dict(manifest)
    manifest_id = body.pop("manifest_id", None)
    if not isinstance(manifest_id, str) or _canonical_sha256(body) != manifest_id:
        _fail("verification manifest", "identity drift")
    if (
        manifest.get("schema_version") != VERIFICATION_MANIFEST_SCHEMA
        or manifest.get("family") != "verification_obligation"
    ):
        _fail("verification manifest", "schema or family drift")
    repository = manifest.get("repository")
    from .project_harness_e3_experiment import _git_identity

    current = dict(_git_identity(repo))
    if (
        not isinstance(repository, Mapping)
        or current["dirty"]
        or repository.get("commit") != current["commit"]
    ):
        _fail(
            "verification manifest",
            "repository drifted from the frozen preregistration commit",
        )
    for name in ("production_binary", "ripgrep", "kernel"):
        item = manifest["artifacts"][name]
        actual = file_sha256(Path(str(item["path"])))
        if actual != item["sha256"]:
            _fail("verification manifest", f"artifact {name} drift")
    return manifest


def _prepare_calibration(
    *,
    repo: Path,
    manifest_path: Path,
    case_id: str,
    tinykg_binary: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    resume: bool,
    family: str = "existing_file_rewrite",
) -> CalibrationContext:
    repo = repo.resolve(strict=True)
    if Path(__file__).resolve(strict=True) != repo / "scripts/eval/tinykg_lean_factorial_executor.py":
        _fail("factorial calibration", "executor source is outside the frozen repository")
    if family == "verification_obligation":
        # The gate family has no rule bundle: its enforcement plane is the
        # session-end obligation flag, so there is no templates manifest to
        # verify and no rule flavor to seed.
        manifest = _validate_verification_manifest(
            manifest_path.resolve(strict=True), repo
        )
        templates = {"templates": {}}
    else:
        manifest = validate_manifest(manifest_path.resolve(strict=True), repo)
        templates = verify_templates(
            Path(str(manifest["templates_manifest"]["path"])), repo
        )
    case_by_id = {
        str(case["id"]): case
        for case in manifest["cases"]
        if isinstance(case, Mapping)
    }
    case = case_by_id.get(case_id)
    if case is None:
        _fail("factorial calibration", "case is outside the frozen manifest")
    root = Path(str(manifest["root"])).resolve(strict=True)
    workspace = Path(str(manifest["project_root"])).resolve(strict=True)
    run_dir = run_dir.expanduser().absolute()
    if run_dir.parent.resolve(strict=True) != root:
        _fail(
            "factorial calibration",
            "run directory must be a direct child of the frozen root",
        )
    if resume:
        try:
            run_info = run_dir.lstat()
        except OSError as exc:
            _fail("factorial calibration", f"resume run directory is unavailable: {exc}")
        if (
            stat.S_ISLNK(run_info.st_mode)
            or not stat.S_ISDIR(run_info.st_mode)
            or (hasattr(os, "geteuid") and run_info.st_uid != os.geteuid())
            or stat.S_IMODE(run_info.st_mode) & 0o077
        ):
            _fail("factorial calibration", "resume requires an owned private real directory")
    elif run_dir.exists() or run_dir.is_symlink():
        _fail("factorial calibration", "fresh run directory already exists")

    ripgrep = ripgrep.resolve(strict=True)
    ripgrep_sha256 = file_sha256(ripgrep)
    frozen_ripgrep = manifest["artifacts"]["ripgrep"]
    if (
        str(ripgrep) != frozen_ripgrep["path"]
        or ripgrep_sha256 != frozen_ripgrep["sha256"]
    ):
        _fail("factorial calibration", "ripgrep artifact drift")
    _assert_executable_identity(ripgrep, ripgrep_sha256, "factorial ripgrep")
    tinykg_binary = tinykg_binary.resolve(strict=True)
    tinykg_sha256 = file_sha256(tinykg_binary)
    _assert_executable_identity(tinykg_binary, tinykg_sha256, "factorial TinyKG")
    seed_batch, recall_query = _calibration_seed(case=case, workspace=workspace)
    identity = _calibration_identity(
        manifest=manifest,
        case_id=case_id,
        tinykg_sha256=tinykg_sha256,
        ripgrep_sha256=ripgrep_sha256,
        seed_batch=seed_batch,
        recall_query=recall_query,
    )
    schedules = _calibration_schedules(case_id)

    budget_candidate = budget_path.expanduser().absolute()
    budget_parent = budget_candidate.parent.resolve(strict=True)
    parent_info = budget_parent.stat()
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or (hasattr(os, "geteuid") and parent_info.st_uid != os.geteuid())
        or stat.S_IMODE(parent_info.st_mode) & 0o022
    ):
        _fail("factorial calibration budget", "parent directory is not private and owned")
    budget_candidate = budget_parent / budget_candidate.name
    if budget_candidate == run_dir or run_dir in budget_candidate.parents:
        _fail("factorial calibration", "budget journal must remain outside the run directory")
    _validate_private_path_if_present(budget_candidate, "factorial calibration budget")
    _validate_private_path_if_present(
        budget_candidate.with_name(budget_candidate.name + ".lock"),
        "factorial calibration budget lock",
    )
    temporary = budget_candidate.with_name(budget_candidate.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        _fail("factorial calibration budget", "incomplete temporary file requires inspection")

    execution = manifest["execution"]
    total_cost_microusd = usd_to_microusd(execution["max_total_cost_usd"])
    if total_cost_microusd > usd_to_microusd(2000):
        _fail("factorial calibration", "frozen authority exceeds the user-approved $2000 cap")
    authority = BudgetAuthority(
        manifest_sha256=_canonical_sha256(manifest),
        model_fingerprint=str(execution["model_fingerprint"]),
        provider_identity=PRODUCTION_PROVIDER_ID,
        total_cost_microusd=total_cost_microusd,
        total_metered_tokens=int(execution["max_total_metered_tokens"]),
    )
    authority.validate()
    return CalibrationContext(
        family=family,
        repo=repo,
        manifest=manifest,
        templates=templates,
        case=case,
        root=root,
        workspace=workspace,
        run_dir=run_dir,
        budget_path=budget_candidate,
        ripgrep=ripgrep,
        ripgrep_sha256=ripgrep_sha256,
        tinykg_binary=tinykg_binary,
        tinykg_sha256=tinykg_sha256,
        seed_batch=seed_batch,
        recall_query=recall_query,
        identity=identity,
        schedules=schedules,
        authority=authority,
    )


def _load_checkpoint(path: Path, *, context: CalibrationContext) -> Mapping[str, Any]:
    _validate_private_path_if_present(path, "factorial calibration checkpoint")
    checkpoint = _json(
        _read_regular(
            path,
            root=context.run_dir,
            where="factorial calibration checkpoint",
        ),
        "factorial calibration checkpoint",
    )
    if (
        set(checkpoint)
        != {
            "schema_version",
            "identity",
            "completed",
            "references",
            "budget_journal_id",
            "budget_revision",
            "budget_head_sha256",
        }
        or checkpoint.get("schema_version") != CALIBRATION_CHECKPOINT_SCHEMA
        or stable_json(checkpoint.get("identity")) != stable_json(context.identity)
        or not isinstance(checkpoint.get("completed"), list)
    ):
        _fail("factorial calibration checkpoint", "identity or field drift")
    return checkpoint


def _prepare_block(
    *,
    repo: Path,
    manifest_path: Path,
    tinykg_binary: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    resume: bool,
    cohort: str = "block",
) -> BlockContext:
    # Reuse the already-audited filesystem, executable, manifest, budget, and
    # private-path boundary.  The scored block then replaces only the case
    # cohort, schedule, seed, and evidence identity.
    case_ids, cases_relative, family = _cohort_spec(cohort)
    family_spec = FAMILIES[family]
    base = _prepare_calibration(
        repo=repo,
        manifest_path=manifest_path,
        case_id=case_ids[0],
        tinykg_binary=tinykg_binary,
        ripgrep=ripgrep,
        run_dir=run_dir,
        budget_path=budget_path,
        resume=resume,
        family=family,
    )
    if family == "verification_obligation":
        protocol_path = base.repo / VERIFICATION_PROTOCOL_RELATIVE
        _validate_verification_protocol(
            _json(
                _read_regular(
                    protocol_path,
                    root=base.repo,
                    where="verification attribution protocol",
                ),
                "verification attribution protocol",
            )
        )
    else:
        protocol_path = base.repo / ATTRIBUTION_PROTOCOL_RELATIVE
        validate_protocol(load_protocol(protocol_path), base.repo)
    cases_path = base.repo / cases_relative
    cases_payload = _read_regular(
        cases_path,
        root=base.repo,
        where="factorial block case cohort",
    )
    try:
        raw_case_ids = json.loads(cases_payload)
    except (UnicodeError, json.JSONDecodeError) as exc:
        _fail("factorial block case cohort", f"invalid JSON: {exc}")
    if (
        not isinstance(raw_case_ids, list)
        or tuple(raw_case_ids) != case_ids
        or len(set(raw_case_ids)) != len(raw_case_ids)
    ):
        _fail("factorial block case cohort", "frozen case cohort identity drift")
    available = {
        str(case.get("id"))
        for case in base.manifest["cases"]
        if isinstance(case, Mapping)
    }
    if any(case_id not in available for case_id in case_ids):
        _fail("factorial block case cohort", "case is outside the frozen manifest")
    if not resume and (
        base.budget_path.exists()
        or base.budget_path.is_symlink()
        or base.budget_path.with_name(base.budget_path.name + ".lock").exists()
    ):
        _fail("factorial block budget", "fresh block requires a fresh journal path")
    tinykg_contract = _probe_block_tinykg_contract(
        binary=base.tinykg_binary,
        binary_sha256=base.tinykg_sha256,
    )
    schedules = tuple(balanced_factorial_schedule(case_ids))
    forbidden: list[str] = list(case_ids)
    for case in base.manifest["cases"]:
        if not isinstance(case, Mapping) or str(case.get("id")) not in case_ids:
            continue
        initial = case.get("initial_files")
        if isinstance(initial, Mapping):
            forbidden.extend(str(name) for name in initial)
        grader = case.get("grader")
        expected = grader.get("expected_files") if isinstance(grader, Mapping) else None
        if isinstance(expected, Mapping):
            forbidden.extend(str(name) for name in expected)
    seed_batch, recall_query = _block_seed(
        workspace=base.workspace,
        forbidden=tuple(sorted(set(forbidden))),
        memory_text=family_spec["memory_text"],
        memory_query=family_spec["memory_query"],
    )
    identity = _block_identity(
        manifest=base.manifest,
        memory_text=family_spec["memory_text"],
        case_ids=case_ids,
        schedules=schedules,
        tinykg_sha256=base.tinykg_sha256,
        tinykg_contract=tinykg_contract,
        ripgrep_sha256=base.ripgrep_sha256,
        seed_batch=seed_batch,
        recall_query=recall_query,
        protocol_sha256=_sha256_file(protocol_path),
        case_ids_sha256=hashlib.sha256(cases_payload).hexdigest(),
    )
    return BlockContext(
        family=family,
        repo=base.repo,
        manifest=base.manifest,
        templates=base.templates,
        case_ids=case_ids,
        root=base.root,
        workspace=base.workspace,
        run_dir=base.run_dir,
        budget_path=base.budget_path,
        ripgrep=base.ripgrep,
        ripgrep_sha256=base.ripgrep_sha256,
        tinykg_binary=base.tinykg_binary,
        tinykg_sha256=base.tinykg_sha256,
        tinykg_contract=tinykg_contract,
        seed_batch=seed_batch,
        recall_query=recall_query,
        identity=identity,
        schedules=schedules,
        authority=base.authority,
    )


def _load_block_checkpoint(path: Path, *, context: BlockContext) -> Mapping[str, Any]:
    _validate_private_path_if_present(path, "factorial block checkpoint")
    checkpoint = _json(
        _read_regular(
            path,
            root=context.run_dir,
            where="factorial block checkpoint",
        ),
        "factorial block checkpoint",
    )
    if (
        set(checkpoint)
        != {
            "schema_version",
            "identity",
            "completed",
            "references",
            "budget_journal_id",
            "budget_revision",
            "budget_head_sha256",
        }
        or checkpoint.get("schema_version") != BLOCK_CHECKPOINT_SCHEMA
        or stable_json(checkpoint.get("identity")) != stable_json(context.identity)
        or not isinstance(checkpoint.get("completed"), list)
    ):
        _fail("factorial block checkpoint", "identity or field drift")
    return checkpoint


def preflight_block(
    *,
    repo: Path,
    manifest_path: Path,
    tinykg_binary: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    resume: bool,
    cohort: str = "block",
) -> Mapping[str, Any]:
    context = _prepare_block(
        repo=repo,
        manifest_path=manifest_path,
        tinykg_binary=tinykg_binary,
        ripgrep=ripgrep,
        run_dir=run_dir,
        budget_path=budget_path,
        resume=resume,
        cohort=cohort,
    )
    completed = 0
    if resume:
        checkpoint = _load_block_checkpoint(
            context.run_dir / "factorial-block-checkpoint.json",
            context=context,
        )
        completed = len(checkpoint["completed"])
        if completed > len(context.schedules):
            _fail("factorial block checkpoint", "completed prefix is too long")
    return {
        "schema_version": BLOCK_PREFLIGHT_SCHEMA,
        "block_id": context.identity["block_id"],
        "case_ids": list(context.case_ids),
        "mode": "resume" if resume else "fresh",
        "completed_rollouts_observed": completed,
        "planned_rollouts": len(context.schedules),
        "schedule": list(context.schedules),
        "provider_requests": 0,
        "credential_read": False,
        "budget_journal_modified": False,
        "run_directory_modified": False,
        "quality_evidence": False,
        "quality_eligible_after_paid_execution": True,
        "raw_artifacts_local_only": True,
        "remote_tinykg_forbidden": True,
        "procedural_memory_sha256": context.identity["procedural_memory_sha256"],
        "tinykg_contract": dict(context.tinykg_contract),
        "budget_authority_cost_microusd": context.authority.total_cost_microusd,
        "budget_authority_metered_tokens": context.authority.total_metered_tokens,
    }


def preflight_calibration(
    *,
    repo: Path,
    manifest_path: Path,
    case_id: str,
    tinykg_binary: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    resume: bool,
) -> Mapping[str, Any]:
    context = _prepare_calibration(
        repo=repo,
        manifest_path=manifest_path,
        case_id=case_id,
        tinykg_binary=tinykg_binary,
        ripgrep=ripgrep,
        run_dir=run_dir,
        budget_path=budget_path,
        resume=resume,
    )
    completed = 0
    if resume:
        checkpoint = _load_checkpoint(
            context.run_dir / "calibration-checkpoint.json",
            context=context,
        )
        completed = len(checkpoint["completed"])
        if completed > len(context.schedules):
            _fail("factorial calibration checkpoint", "completed prefix is too long")
    return {
        "schema_version": CALIBRATION_PREFLIGHT_SCHEMA,
        "calibration_id": context.identity["calibration_id"],
        "case_id": case_id,
        "mode": "resume" if resume else "fresh",
        "completed_cells_observed": completed,
        "planned_cells": list(CALIBRATION_CELLS),
        "provider_requests": 0,
        "credential_read": False,
        "budget_journal_modified": False,
        "run_directory_modified": False,
        "quality_evidence": False,
        "raw_artifacts_local_only": True,
        "remote_tinykg_forbidden": True,
        "budget_authority_cost_microusd": context.authority.total_cost_microusd,
        "budget_authority_metered_tokens": context.authority.total_metered_tokens,
    }


def run_calibration(
    *,
    repo: Path,
    manifest_path: Path,
    case_id: str,
    tinykg_binary: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    auth_file: Path,
    resume: bool,
) -> Mapping[str, Any]:
    context = _prepare_calibration(
        repo=repo,
        manifest_path=manifest_path,
        case_id=case_id,
        tinykg_binary=tinykg_binary,
        ripgrep=ripgrep,
        run_dir=run_dir,
        budget_path=budget_path,
        resume=resume,
    )
    if not resume:
        context.run_dir.mkdir(mode=0o700)
        (context.run_dir / "rollouts").mkdir(mode=0o700)
    checkpoint_path = context.run_dir / "calibration-checkpoint.json"
    execution = context.manifest["execution"]

    with BudgetJournal(context.budget_path, context.authority) as budget:
        budget.checkpoint_payload()
        completed_entries: list[Mapping[str, Any]] = []
        results: list[Mapping[str, Any]] = []
        references_info: Mapping[str, Any] | None = None
        if resume:
            checkpoint = _load_checkpoint(checkpoint_path, context=context)
            raw_completed = checkpoint["completed"]
            completed_entries = list(raw_completed)
            snapshot = budget.snapshot()
            if (
                checkpoint.get("budget_journal_id") != snapshot["journal_id"]
                or checkpoint.get("budget_revision") != snapshot["revision"]
                or checkpoint.get("budget_head_sha256") != snapshot["head_sha256"]
                or snapshot["transaction_states"].get("request_authorized", 0) != 0
                or snapshot["transaction_states"].get("reserved", 0) != 0
                or snapshot["transaction_states"].get("committed", 0)
                != len(completed_entries)
                or len(completed_entries) > len(context.schedules)
            ):
                _fail("factorial calibration checkpoint", "budget or prefix drift")
            for index, entry in enumerate(completed_entries):
                if not isinstance(entry, Mapping):
                    _fail("factorial calibration checkpoint", "invalid completed row")
                results.append(
                    _reopen_completed(
                        entry=entry,
                        schedule=context.schedules[index],
                        run_dir=context.run_dir,
                        manifest=context.manifest,
                        budget=budget,
                    )
                )
            raw_references = checkpoint.get("references")
            if raw_references is not None:
                if not isinstance(raw_references, Mapping):
                    _fail("factorial calibration checkpoint", "references drift")
                references_info = dict(raw_references)
        else:
            _persist_checkpoint(
                path=checkpoint_path,
                identity=context.identity,
                completed=completed_entries,
                budget=budget,
                references=None,
            )

        pending = context.schedules[len(results) :]
        if pending:
            api_key = _load_api_key(auth_file.expanduser().resolve(strict=True))
            try:
                for schedule in pending:
                    result = execute_cell(
                        family=context.family,
                        repo=context.repo,
                        manifest=context.manifest,
                        templates=context.templates,
                        schedule=schedule,
                        run_dir=context.run_dir,
                        ripgrep=context.ripgrep,
                        ripgrep_sha256=context.ripgrep_sha256,
                        api_key=api_key,
                        budget=budget,
                        timeout_seconds=int(execution["rollout_timeout_seconds"]),
                        tinykg_binary=context.tinykg_binary,
                        tinykg_binary_sha256=context.tinykg_sha256,
                        seed_batch=context.seed_batch,
                        recall_query=context.recall_query,
                        quality_evidence_eligible=False,
                    )
                    results.append(result)
                    completed_entries.append(
                        _checkpoint_entry(result, context.run_dir)
                    )
                    _persist_checkpoint(
                        path=checkpoint_path,
                        identity=context.identity,
                        completed=completed_entries,
                        budget=budget,
                        references=None,
                    )
            finally:
                _assert_production_secret_absent(context.run_dir, api_key)

        _validate_calibration_projections([result["projection"] for result in results])
        _validate_paid_calibration_sources(results, run_dir=context.run_dir)
        if references_info is None:
            references_path = context.run_dir / "factorial-references.json"
            if not references_path.exists() and not references_path.is_symlink():
                references_path = persist_references(
                    receipts=results,
                    run_dir=context.run_dir,
                )
            references_info = {
                "path": _relative_to_run(
                    references_path,
                    context.run_dir,
                    "factorial calibration references",
                ),
                "sha256": _sha256_file(references_path),
            }
            references_path = _reopen_references(
                info=references_info,
                results=results,
                run_dir=context.run_dir,
            )
            _persist_checkpoint(
                path=checkpoint_path,
                identity=context.identity,
                completed=completed_entries,
                budget=budget,
                references=references_info,
            )
        else:
            references_path = _reopen_references(
                info=references_info,
                results=results,
                run_dir=context.run_dir,
            )

        budget.checkpoint_payload()
        snapshot = budget.snapshot()
        return {
            "schema_version": CALIBRATION_SUMMARY_SCHEMA,
            "calibration_id": context.identity["calibration_id"],
            "case_id": case_id,
            "rollouts": len(results),
            "cells": list(CALIBRATION_CELLS),
            "quality_evidence": False,
            "claim_boundary": "paid wiring calibration; not confirmatory factorial evidence",
            "references_path": str(references_path),
            "references_sha256": references_info["sha256"],
            "checkpoint_path": str(checkpoint_path),
            "checkpoint_sha256": _sha256_file(checkpoint_path),
            "committed_cost_microusd": snapshot["committed_cost_microusd"],
            "committed_metered_tokens": snapshot["committed_metered_tokens"],
            "budget_revision": snapshot["revision"],
            "budget_head_sha256": snapshot["head_sha256"],
        }


def _persist_or_verify_private(path: Path, value: Mapping[str, Any], where: str) -> str:
    payload = (stable_json(value) + "\n").encode("utf-8")
    digest = hashlib.sha256(payload).hexdigest()
    if path.exists() or path.is_symlink():
        observed = _read_regular(path, root=path.parent, where=where)
        if observed != payload:
            _fail(where, "existing artifact drift")
    else:
        _write_private(path, payload)
    return digest


def run_block(
    *,
    repo: Path,
    manifest_path: Path,
    tinykg_binary: Path,
    ripgrep: Path,
    run_dir: Path,
    budget_path: Path,
    auth_file: Path,
    resume: bool,
    cohort: str = "block",
) -> Mapping[str, Any]:
    context = _prepare_block(
        repo=repo,
        manifest_path=manifest_path,
        tinykg_binary=tinykg_binary,
        ripgrep=ripgrep,
        run_dir=run_dir,
        budget_path=budget_path,
        resume=resume,
        cohort=cohort,
    )
    if not resume:
        context.run_dir.mkdir(mode=0o700)
        (context.run_dir / "rollouts").mkdir(mode=0o700)
    checkpoint_path = context.run_dir / "factorial-block-checkpoint.json"
    execution = context.manifest["execution"]

    with BudgetJournal(context.budget_path, context.authority) as budget:
        budget.checkpoint_payload()
        completed_entries: list[Mapping[str, Any]] = []
        results: list[Mapping[str, Any]] = []
        references_info: Mapping[str, Any] | None = None
        if resume:
            checkpoint = _load_block_checkpoint(checkpoint_path, context=context)
            completed_entries = list(checkpoint["completed"])
            snapshot = budget.snapshot()
            if (
                checkpoint.get("budget_journal_id") != snapshot["journal_id"]
                or checkpoint.get("budget_revision") != snapshot["revision"]
                or checkpoint.get("budget_head_sha256") != snapshot["head_sha256"]
                or snapshot["transaction_states"].get("request_authorized", 0) != 0
                or snapshot["transaction_states"].get("reserved", 0) != 0
                or snapshot["transaction_states"].get("committed", 0)
                != len(completed_entries)
                or len(completed_entries) > len(context.schedules)
            ):
                _fail("factorial block checkpoint", "budget or prefix drift")
            for index, entry in enumerate(completed_entries):
                if not isinstance(entry, Mapping):
                    _fail("factorial block checkpoint", "invalid completed row")
                results.append(
                    _reopen_completed(
                        entry=entry,
                        schedule=context.schedules[index],
                        run_dir=context.run_dir,
                        manifest=context.manifest,
                        budget=budget,
                        quality_evidence=True,
                    )
                )
            raw_references = checkpoint.get("references")
            if raw_references is not None:
                if not isinstance(raw_references, Mapping):
                    _fail("factorial block checkpoint", "references drift")
                references_info = dict(raw_references)
        else:
            _persist_checkpoint(
                path=checkpoint_path,
                identity=context.identity,
                completed=completed_entries,
                budget=budget,
                references=None,
                schema_version=BLOCK_CHECKPOINT_SCHEMA,
            )

        pending = context.schedules[len(results) :]
        if pending:
            api_key = _load_api_key(auth_file.expanduser().resolve(strict=True))
            try:
                for schedule in pending:
                    result = execute_cell(
                        family=context.family,
                        repo=context.repo,
                        manifest=context.manifest,
                        templates=context.templates,
                        schedule=schedule,
                        run_dir=context.run_dir,
                        ripgrep=context.ripgrep,
                        ripgrep_sha256=context.ripgrep_sha256,
                        api_key=api_key,
                        budget=budget,
                        timeout_seconds=int(execution["rollout_timeout_seconds"]),
                        tinykg_binary=context.tinykg_binary,
                        tinykg_binary_sha256=context.tinykg_sha256,
                        seed_batch=context.seed_batch,
                        recall_query=context.recall_query,
                        quality_evidence_eligible=True,
                    )
                    results.append(result)
                    completed_entries.append(_checkpoint_entry(result, context.run_dir))
                    _persist_checkpoint(
                        path=checkpoint_path,
                        identity=context.identity,
                        completed=completed_entries,
                        budget=budget,
                        references=None,
                        schema_version=BLOCK_CHECKPOINT_SCHEMA,
                    )
            finally:
                _assert_production_secret_absent(context.run_dir, api_key)

        projections = [result["projection"] for result in results]
        # The unauthenticated call validates the complete schedule, treatments,
        # cache identity, and row schema before references are admitted.
        build_report(projections, context.case_ids)
        _validate_paid_block_sources(results, run_dir=context.run_dir)
        if references_info is None:
            references_path = context.run_dir / "factorial-references.json"
            if not references_path.exists() and not references_path.is_symlink():
                references_path = persist_references(
                    receipts=results,
                    run_dir=context.run_dir,
                )
            references_info = {
                "path": _relative_to_run(
                    references_path,
                    context.run_dir,
                    "factorial block references",
                ),
                "sha256": _sha256_file(references_path),
            }
            references_path = _reopen_references(
                info=references_info,
                results=results,
                run_dir=context.run_dir,
            )
            _persist_checkpoint(
                path=checkpoint_path,
                identity=context.identity,
                completed=completed_entries,
                budget=budget,
                references=references_info,
                schema_version=BLOCK_CHECKPOINT_SCHEMA,
            )
        else:
            references_path = _reopen_references(
                info=references_info,
                results=results,
                run_dir=context.run_dir,
            )

        evidence = load_receipts(
            references_path=references_path,
            evidence_root=context.run_dir,
            case_ids=context.case_ids,
        )
        report = build_report(evidence.projections, context.case_ids, evidence=evidence)
        report_path = context.run_dir / "factorial-report.json"
        report_sha256 = _persist_or_verify_private(
            report_path,
            report,
            "factorial block report",
        )
        budget.checkpoint_payload()
        snapshot = budget.snapshot()
        return {
            "schema_version": BLOCK_SUMMARY_SCHEMA,
            "block_id": context.identity["block_id"],
            "case_ids": list(context.case_ids),
            "rollouts": len(results),
            "quality_evidence": report["quality_evidence"],
            "claim_boundary": report["claim_boundary"],
            "references_path": str(references_path),
            "references_sha256": references_info["sha256"],
            "report_path": str(report_path),
            "report_sha256": report_sha256,
            "checkpoint_path": str(checkpoint_path),
            "checkpoint_sha256": _sha256_file(checkpoint_path),
            "committed_cost_microusd": snapshot["committed_cost_microusd"],
            "committed_metered_tokens": snapshot["committed_metered_tokens"],
            "budget_revision": snapshot["revision"],
            "budget_head_sha256": snapshot["head_sha256"],
            "report": report,
        }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--case-id", required=True)
    parser.add_argument("--tinykg", type=Path, required=True)
    parser.add_argument("--ripgrep", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--budget-journal", type=Path, required=True)
    parser.add_argument(
        "--auth-file", type=Path, default=Path.home() / ".metacodes/auth.json"
    )
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-paid-rollouts", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.dry_run:
        summary = preflight_calibration(
            repo=args.repo,
            manifest_path=args.manifest,
            case_id=args.case_id,
            tinykg_binary=args.tinykg,
            ripgrep=args.ripgrep,
            run_dir=args.run_dir,
            budget_path=args.budget_journal,
            resume=args.resume,
        )
        print(stable_json(summary))
        return 0
    if not args.allow_paid_rollouts:
        _fail("factorial calibration", "paid run requires --allow-paid-rollouts")
    summary = run_calibration(
        repo=args.repo,
        manifest_path=args.manifest,
        case_id=args.case_id,
        tinykg_binary=args.tinykg,
        ripgrep=args.ripgrep,
        run_dir=args.run_dir,
        budget_path=args.budget_journal,
        auth_file=args.auth_file,
        resume=args.resume,
    )
    print(stable_json(summary))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
