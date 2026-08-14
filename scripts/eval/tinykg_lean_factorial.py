"""Admit and analyze a TinyKG x Lean 2x2 factorial experiment.

This module is deliberately an evidence boundary, not a paid-rollout shortcut.
The production executor must emit one content-addressed receipt per scheduled
cell.  This analyzer reopens those receipts, verifies treatment actuation and
cache comparability, and only then computes main effects and interaction.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any, Mapping, Sequence

from .attribution_protocol import (
    CELL_IDS,
    EXPECTED_CELLS,
    PROTOCOL_ID,
    balanced_factorial_schedule,
    load_protocol,
    validate_protocol,
)
from .model import ValidationError, stable_json
from .statistics import exact_mcnemar, mean_confidence_interval_95


REFERENCE_SCHEMA = "metacodes-tinykg-lean-factorial-references-v1"
ROLLOUT_SCHEMA = "metacodes-tinykg-lean-factorial-rollout-v1"
REPORT_SCHEMA = "metacodes-tinykg-lean-factorial-report-v1"
MAX_REFERENCE_BYTES = 4 * 1024 * 1024
MAX_RECEIPT_BYTES = 16 * 1024 * 1024
HEX = frozenset("0123456789abcdef")

IDENTITY_FIELDS = (
    "model_fingerprint",
    "harness_revision",
    "task_fingerprint",
    "actor_prompt_sha256",
    "tool_schema_sha256",
    "stable_core_prefix_sha256",
    "first_request_sha256",
)
OUTCOME_FIELDS = (
    "task_success",
    "trustworthy_success",
    "error_recurrence",
    "effective_intervention",
    "false_intervention",
    "recovery_success",
)
USAGE_FIELDS = (
    "cost_microusd",
    "metered_tokens",
    "provider_requests",
    "wall_time_ms",
    "model_time_ms",
    "tool_time_ms",
    "checker_time_ns",
    "memory_exposed_tokens",
)


@dataclass(frozen=True)
class LoadedReceipts:
    projections: tuple[Mapping[str, Any], ...]
    references_sha256: str
    receipt_sha256s: tuple[str, ...]

    @property
    def receipt_set_sha256(self) -> str:
        return _canonical_sha256(list(self.receipt_sha256s))


def _fail(where: str, detail: str) -> None:
    raise ValidationError(f"{where}: {detail}")


def _mapping(value: Any, where: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected object")
    return value


def _sequence(value: Any, where: str) -> Sequence[Any]:
    if not isinstance(value, list):
        _fail(where, "expected array")
    return value


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _canonical_sha256(value: Any) -> str:
    return _sha256_bytes(stable_json(value).encode("utf-8"))


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in HEX for char in value)


def _read_regular(path: Path, *, root: Path, label: str, maximum: int) -> bytes:
    spelled = path.absolute()
    try:
        resolved_root = root.resolve(strict=True)
        spelled_info = spelled.lstat()
        if stat.S_ISLNK(spelled_info.st_mode):
            _fail(label, "must not be a symlink")
        resolved = spelled.resolve(strict=True)
        resolved.relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        _fail(label, f"escaped evidence root or cannot be inspected: {exc}")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(spelled, flags)
    except OSError as exc:
        _fail(label, f"cannot open without following links: {exc}")
    try:
        info = os.fstat(descriptor)
        if (info.st_dev, info.st_ino) != (spelled_info.st_dev, spelled_info.st_ino):
            _fail(label, "identity changed before open")
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            _fail(label, "must be a single-link regular file")
        if os.name != "nt" and stat.S_IMODE(info.st_mode) & 0o077:
            _fail(label, "permissions must be 0600 or stricter")
        if info.st_size <= 0 or info.st_size > maximum:
            _fail(label, f"must contain 1..{maximum} bytes")
        chunks: list[bytes] = []
        observed = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - observed))
            if not chunk:
                break
            observed += len(chunk)
            if observed > maximum:
                _fail(label, f"exceeds {maximum} bytes")
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        or observed != info.st_size
    ):
        _fail(label, "changed while being read")
    return b"".join(chunks)


def _load_json(payload: bytes, where: str) -> Mapping[str, Any]:
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(where, f"invalid JSON: {exc}")
    return _mapping(value, where)


def _validate_case_ids(case_ids: Sequence[str]) -> tuple[str, ...]:
    if (
        not case_ids
        or len(case_ids) % 4 != 0
        or len(set(case_ids)) != len(case_ids)
        or any(not isinstance(case_id, str) or not case_id for case_id in case_ids)
    ):
        _fail("factorial cases", "requires distinct non-empty ids in blocks of four")
    return tuple(case_ids)


def dry_run_plan(case_ids: Sequence[str]) -> Mapping[str, Any]:
    cases = _validate_case_ids(case_ids)
    return {
        "schema_version": "metacodes-tinykg-lean-factorial-dry-run-v1",
        "protocol_id": PROTOCOL_ID,
        "provider_requests": 0,
        "paid_rollouts_enabled": False,
        "quality_evidence": False,
        "cases": len(cases),
        "rollouts": len(cases) * len(CELL_IDS),
        "schedule": balanced_factorial_schedule(cases),
        "raw_artifacts_local_only": True,
        "remote_tinykg_forbidden": True,
    }


def _validate_identity(identity: Mapping[str, Any], where: str) -> None:
    if set(identity) != set(IDENTITY_FIELDS):
        _fail(where, "field drift")
    for field in IDENTITY_FIELDS:
        if not _is_sha256(identity.get(field)):
            _fail(where, f"{field} must be SHA-256")


def _validate_tinykg(value: Mapping[str, Any], enabled: bool, where: str) -> None:
    expected_fields = {
        "enabled",
        "transport",
        "store_scope",
        "remote_writes",
        "recall_receipt_verified",
        "read_count",
        "store_revision_sha256",
    }
    if set(value) != expected_fields or value.get("enabled") is not enabled:
        _fail(where, "field or factor drift")
    read_count = value.get("read_count")
    if not isinstance(read_count, int) or isinstance(read_count, bool) or read_count < 0:
        _fail(where, "read_count must be a non-negative integer")
    if value.get("remote_writes") != 0:
        _fail(where, "remote TinyKG writes are forbidden")
    if enabled:
        if (
            value.get("transport") != "cli-exclusive"
            or value.get("store_scope") != "fresh-run-local"
            or value.get("recall_receipt_verified") is not True
            or read_count < 1
            or not _is_sha256(value.get("store_revision_sha256"))
        ):
            _fail(where, "TinyKG treatment was not proven")
    elif any(
        (
            value.get("transport") != "disabled",
            value.get("store_scope") != "none",
            value.get("recall_receipt_verified") is not False,
            read_count != 0,
            value.get("store_revision_sha256") is not None,
        )
    ):
        _fail(where, "TinyKG-off cell exposed graph treatment")


def _validate_lean(value: Mapping[str, Any], enabled: bool, where: str) -> None:
    expected_fields = {
        "enabled",
        "bundle_loaded",
        "checker_sha256",
        "bundle_sha256",
        "checker_calls",
        "formal_decisions",
        "unsafe_false_interventions",
    }
    if set(value) != expected_fields or value.get("enabled") is not enabled:
        _fail(where, "field or factor drift")
    counts: dict[str, int] = {}
    for field in ("checker_calls", "formal_decisions", "unsafe_false_interventions"):
        raw = value.get(field)
        if not isinstance(raw, int) or isinstance(raw, bool) or raw < 0:
            _fail(where, f"{field} must be a non-negative integer")
        counts[field] = raw
    if counts["unsafe_false_interventions"] != 0:
        _fail(where, "unsafe Lean false intervention")
    if enabled:
        if (
            value.get("bundle_loaded") is not True
            or not _is_sha256(value.get("checker_sha256"))
            or not _is_sha256(value.get("bundle_sha256"))
        ):
            _fail(where, "Lean treatment was not loaded")
    elif any(
        (
            value.get("bundle_loaded") is not False,
            value.get("checker_sha256") is not None,
            value.get("bundle_sha256") is not None,
            counts["checker_calls"] != 0,
            counts["formal_decisions"] != 0,
        )
    ):
        _fail(where, "Lean-off cell exposed formal authority")


def _validate_projection(
    projection: Mapping[str, Any], expected: Mapping[str, Any], where: str
) -> Mapping[str, Any]:
    expected_fields = {
        "sequence",
        "case_id",
        "position",
        "cell",
        "factors",
        "identity",
        "treatment",
        "outcomes",
        "usage",
        "quality_evidence",
    }
    if set(projection) != expected_fields:
        _fail(where, "projection field drift")
    for field in ("sequence", "case_id", "position", "cell"):
        if projection.get(field) != expected[field]:
            _fail(where, f"{field} does not match frozen schedule")
    cell = str(projection["cell"])
    factors = _mapping(projection.get("factors"), f"{where}.factors")
    if set(factors) != {"tinykg", "lean"} or (
        factors.get("tinykg"), factors.get("lean")
    ) != EXPECTED_CELLS[cell]:
        _fail(f"{where}.factors", "factor declaration does not match cell")

    identity = _mapping(projection.get("identity"), f"{where}.identity")
    _validate_identity(identity, f"{where}.identity")
    treatment = _mapping(projection.get("treatment"), f"{where}.treatment")
    if set(treatment) != {"tinykg", "lean"}:
        _fail(f"{where}.treatment", "field drift")
    _validate_tinykg(
        _mapping(treatment["tinykg"], f"{where}.treatment.tinykg"),
        bool(factors["tinykg"]),
        f"{where}.treatment.tinykg",
    )
    _validate_lean(
        _mapping(treatment["lean"], f"{where}.treatment.lean"),
        bool(factors["lean"]),
        f"{where}.treatment.lean",
    )

    outcomes = _mapping(projection.get("outcomes"), f"{where}.outcomes")
    if set(outcomes) != set(OUTCOME_FIELDS) or any(
        not isinstance(outcomes.get(field), bool) for field in OUTCOME_FIELDS
    ):
        _fail(f"{where}.outcomes", "requires the complete boolean outcome vector")
    usage = _mapping(projection.get("usage"), f"{where}.usage")
    if set(usage) != set(USAGE_FIELDS):
        _fail(f"{where}.usage", "field drift")
    for field in USAGE_FIELDS:
        raw = usage.get(field)
        if not isinstance(raw, int) or isinstance(raw, bool) or raw < 0:
            _fail(f"{where}.usage", f"{field} must be a non-negative integer")
    if any(
        int(usage[field]) <= 0
        for field in (
            "cost_microusd",
            "metered_tokens",
            "provider_requests",
            "wall_time_ms",
            "model_time_ms",
        )
    ):
        _fail(f"{where}.usage", "quality row requires real paid provider activity")
    if bool(factors["tinykg"]) != (int(usage["memory_exposed_tokens"]) > 0):
        _fail(f"{where}.usage", "memory exposure does not match TinyKG factor")
    checker_calls = int(treatment["lean"]["checker_calls"])
    if (checker_calls > 0) != (int(usage["checker_time_ns"]) > 0):
        _fail(f"{where}.usage", "checker time does not match real checker calls")
    if not bool(factors["lean"]) and any(
        bool(outcomes[field])
        for field in ("effective_intervention", "false_intervention", "recovery_success")
    ):
        _fail(f"{where}.outcomes", "Lean-off cell claims formal control outcomes")
    if projection.get("quality_evidence") is not True:
        _fail(where, "non-quality row cannot enter the factorial report")
    return projection


def load_receipts(
    *, references_path: Path, evidence_root: Path, case_ids: Sequence[str]
) -> LoadedReceipts:
    cases = _validate_case_ids(case_ids)
    reference_payload = _read_regular(
        references_path,
        root=evidence_root,
        label="factorial references",
        maximum=MAX_REFERENCE_BYTES,
    )
    references = _load_json(reference_payload, "factorial references")
    rows = _sequence(references.get("receipts"), "factorial references.receipts")
    schedule = balanced_factorial_schedule(cases)
    if (
        references.get("schema_version") != REFERENCE_SCHEMA
        or references.get("protocol_id") != PROTOCOL_ID
        or len(rows) != len(schedule)
    ):
        _fail("factorial references", "schema, protocol, or schedule length drift")

    projections: list[Mapping[str, Any]] = []
    receipt_sha256s: list[str] = []
    root = evidence_root.resolve(strict=True)
    for index, (raw_ref, expected) in enumerate(zip(rows, schedule)):
        ref = _mapping(raw_ref, f"factorial references.receipts[{index}]")
        if set(ref) != {"sequence", "path", "sha256"} or ref.get("sequence") != index:
            _fail(f"factorial references.receipts[{index}]", "field or sequence drift")
        relative = ref.get("path")
        if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
            _fail(f"factorial references.receipts[{index}].path", "must be relative")
        receipt_payload = _read_regular(
            root / relative,
            root=root,
            label=f"factorial receipt {index}",
            maximum=MAX_RECEIPT_BYTES,
        )
        if not _is_sha256(ref.get("sha256")) or _sha256_bytes(receipt_payload) != ref["sha256"]:
            _fail(f"factorial receipt {index}", "SHA-256 drift")
        receipt_sha256s.append(str(ref["sha256"]))
        receipt = _load_json(receipt_payload, f"factorial receipt {index}")
        if set(receipt) != {
            "schema_version",
            "protocol_id",
            "projection_sha256",
            "host_reopened_source_evidence",
            "raw_artifacts_local_only",
            "projection",
        }:
            _fail(f"factorial receipt {index}", "field drift")
        projection = _mapping(receipt.get("projection"), f"factorial receipt {index}.projection")
        if (
            receipt.get("schema_version") != ROLLOUT_SCHEMA
            or receipt.get("protocol_id") != PROTOCOL_ID
            or receipt.get("projection_sha256") != _canonical_sha256(projection)
            or receipt.get("host_reopened_source_evidence") is not True
            or receipt.get("raw_artifacts_local_only") is not True
        ):
            _fail(f"factorial receipt {index}", "authentication boundary drift")
        projections.append(_validate_projection(projection, expected, f"factorial receipt {index}"))
    return LoadedReceipts(
        projections=tuple(projections),
        references_sha256=_sha256_bytes(reference_payload),
        receipt_sha256s=tuple(receipt_sha256s),
    )


def _validate_comparability(rows: Sequence[Mapping[str, Any]]) -> None:
    if not rows:
        _fail("factorial observations", "empty")
    global_fields = (
        "model_fingerprint",
        "harness_revision",
        "tool_schema_sha256",
        "stable_core_prefix_sha256",
    )
    first_identity = rows[0]["identity"]
    for field in global_fields:
        if any(row["identity"][field] != first_identity[field] for row in rows[1:]):
            _fail("factorial identity", f"global {field} drift")

    lean_checker: str | None = None
    lean_bundle: str | None = None
    total_checker_calls = 0
    for case_id in sorted({str(row["case_id"]) for row in rows}):
        cells = {str(row["cell"]): row for row in rows if row["case_id"] == case_id}
        if set(cells) != set(CELL_IDS):
            _fail(f"factorial case {case_id}", "incomplete cell set")
        case_identity_fields = ("task_fingerprint", "actor_prompt_sha256")
        for field in case_identity_fields:
            if len({row["identity"][field] for row in cells.values()}) != 1:
                _fail(f"factorial case {case_id}", f"{field} drift")
        if cells["control"]["identity"]["first_request_sha256"] != cells["lean_only"]["identity"]["first_request_sha256"]:
            _fail(f"factorial case {case_id}", "Lean changed the no-memory first request")
        if cells["memory_only"]["identity"]["first_request_sha256"] != cells["combined"]["identity"]["first_request_sha256"]:
            _fail(f"factorial case {case_id}", "Lean changed the memory first request")

        for cell in ("lean_only", "combined"):
            lean = cells[cell]["treatment"]["lean"]
            checker = str(lean["checker_sha256"])
            bundle = str(lean["bundle_sha256"])
            lean_checker = checker if lean_checker is None else lean_checker
            lean_bundle = bundle if lean_bundle is None else lean_bundle
            if checker != lean_checker or bundle != lean_bundle:
                _fail("factorial Lean treatment", "checker or bundle drift")
            total_checker_calls += int(lean["checker_calls"])
    if total_checker_calls < 1:
        _fail("factorial Lean treatment", "no real checker call was observed")


def _cell_summary(rows: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    count = len(rows)
    outcomes = {
        field: sum(bool(row["outcomes"][field]) for row in rows)
        for field in OUTCOME_FIELDS
    }
    usage = {
        field: sum(int(row["usage"][field]) for row in rows)
        for field in USAGE_FIELDS
    }
    return {
        "rollouts": count,
        "outcomes": outcomes,
        "outcome_rates": {field: outcomes[field] / count for field in OUTCOME_FIELDS},
        "usage": usage,
        "usage_means": {field: usage[field] / count for field in USAGE_FIELDS},
    }


def _contrast(summaries: Mapping[str, Mapping[str, Any]], left: str, right: str) -> Mapping[str, Any]:
    return {
        "before": left,
        "after": right,
        "outcome_rate_delta": {
            field: summaries[right]["outcome_rates"][field]
            - summaries[left]["outcome_rates"][field]
            for field in OUTCOME_FIELDS
        },
        "usage_mean_delta": {
            field: summaries[right]["usage_means"][field]
            - summaries[left]["usage_means"][field]
            for field in USAGE_FIELDS
        },
    }


def _case_cells(rows: Sequence[Mapping[str, Any]]) -> Mapping[str, Mapping[str, Mapping[str, Any]]]:
    result: dict[str, dict[str, Mapping[str, Any]]] = {}
    for row in rows:
        result.setdefault(str(row["case_id"]), {})[str(row["cell"])] = row
    return result


def _paired_binary(
    rows: Sequence[Mapping[str, Any]], left: str, right: str, field: str
) -> Mapping[str, Any]:
    improvements = regressions = ties = 0
    for cells in _case_cells(rows).values():
        before = bool(cells[left]["outcomes"][field])
        after = bool(cells[right]["outcomes"][field])
        improvements += after and not before
        regressions += before and not after
        ties += before == after
    return {
        "improvements": improvements,
        "regressions": regressions,
        "ties": ties,
        "exact_mcnemar_two_sided_p": exact_mcnemar(regressions, improvements),
    }


def _paired_delta_interval(
    rows: Sequence[Mapping[str, Any]], left: str, right: str, group: str, field: str
) -> Mapping[str, Any]:
    values = [
        float(cells[right][group][field]) - float(cells[left][group][field])
        for cells in _case_cells(rows).values()
    ]
    low, high = mean_confidence_interval_95(values)
    return {
        "paired_values": values,
        "mean": sum(values) / len(values),
        "student_t_95": [low, high],
    }


def _interaction_interval(
    rows: Sequence[Mapping[str, Any]], group: str, field: str
) -> Mapping[str, Any]:
    values = [
        float(cells["combined"][group][field])
        - float(cells["memory_only"][group][field])
        - float(cells["lean_only"][group][field])
        + float(cells["control"][group][field])
        for cells in _case_cells(rows).values()
    ]
    low, high = mean_confidence_interval_95(values)
    return {
        "paired_values": values,
        "mean": sum(values) / len(values),
        "student_t_95": [low, high],
    }


def build_report(
    rows: Sequence[Mapping[str, Any]],
    case_ids: Sequence[str],
    *,
    evidence: LoadedReceipts | None = None,
) -> Mapping[str, Any]:
    cases = _validate_case_ids(case_ids)
    schedule = balanced_factorial_schedule(cases)
    if len(rows) != len(schedule):
        _fail("factorial observations", "schedule length drift")
    validated = [
        _validate_projection(row, expected, f"factorial observation {index}")
        for index, (row, expected) in enumerate(zip(rows, schedule))
    ]
    _validate_comparability(validated)
    summaries = {
        cell: _cell_summary([row for row in validated if row["cell"] == cell])
        for cell in CELL_IDS
    }
    memory = _contrast(summaries, "control", "memory_only")
    lean = _contrast(summaries, "control", "lean_only")
    combined = _contrast(summaries, "control", "combined")
    for contrast, left, right in (
        (memory, "control", "memory_only"),
        (lean, "control", "lean_only"),
        (combined, "control", "combined"),
    ):
        contrast["paired_binary"] = {
            field: _paired_binary(validated, left, right, field)
            for field in OUTCOME_FIELDS
        }
        contrast["paired_usage"] = {
            field: _paired_delta_interval(validated, left, right, "usage", field)
            for field in USAGE_FIELDS
        }
    interaction_outcomes = {
        field: summaries["combined"]["outcome_rates"][field]
        - summaries["memory_only"]["outcome_rates"][field]
        - summaries["lean_only"]["outcome_rates"][field]
        + summaries["control"]["outcome_rates"][field]
        for field in OUTCOME_FIELDS
    }
    interaction_usage = {
        field: summaries["combined"]["usage_means"][field]
        - summaries["memory_only"]["usage_means"][field]
        - summaries["lean_only"]["usage_means"][field]
        + summaries["control"]["usage_means"][field]
        for field in USAGE_FIELDS
    }
    interaction_paired = {
        "outcomes": {
            field: _interaction_interval(validated, "outcomes", field)
            for field in OUTCOME_FIELDS
        },
        "usage": {
            field: _interaction_interval(validated, "usage", field)
            for field in USAGE_FIELDS
        },
    }
    gates = {
        "authenticated_receipt_bundle": evidence is not None
        and tuple(rows) == evidence.projections
        and len(evidence.receipt_sha256s) == len(schedule),
        "complete_frozen_schedule": len(rows) == len(schedule),
        "treatment_actuation_verified": True,
        "zero_remote_tinykg_writes": all(
            row["treatment"]["tinykg"]["remote_writes"] == 0 for row in validated
        ),
        "zero_unsafe_lean_false_interventions": all(
            row["treatment"]["lean"]["unsafe_false_interventions"] == 0 for row in validated
        ),
        "cache_contract_passed": True,
        "combined_no_worse_trustworthy_success": summaries["combined"]["outcome_rates"]["trustworthy_success"]
        >= summaries["control"]["outcome_rates"]["trustworthy_success"],
    }
    return {
        "schema_version": REPORT_SCHEMA,
        "protocol_id": PROTOCOL_ID,
        "quality_evidence": all(gates.values()),
        "claim_boundary": "internal complete 2x2 attribution; not WorkBuddy external superiority",
        "confirmatory_claim_eligible": False,
        "confirmatory_blocker": "paired randomization interval is not yet implemented; Student-t intervals are calibration diagnostics only",
        "cases": len(cases),
        "rollouts": len(rows),
        "evidence": (
            {
                "references_sha256": evidence.references_sha256,
                "receipt_set_sha256": evidence.receipt_set_sha256,
                "receipt_count": len(evidence.receipt_sha256s),
            }
            if evidence is not None
            else None
        ),
        "cells": summaries,
        "contrasts": {
            "tinykg_main": memory,
            "lean_main": lean,
            "combined_total": combined,
            "factorial_interaction": {
                "formula": "combined - memory_only - lean_only + control",
                "outcome_rate_delta": interaction_outcomes,
                "usage_mean_delta": interaction_usage,
                "paired_calibration": interaction_paired,
            },
        },
        "gates": gates,
        "all_gates_passed": all(gates.values()),
    }


def _case_ids_from_file(path: Path) -> tuple[str, ...]:
    try:
        value = json.loads(path.read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail("factorial case ids", f"cannot load: {exc}")
    return _validate_case_ids(_sequence(value, "factorial case ids"))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("dry-run", "report"):
        item = sub.add_parser(command)
        item.add_argument("--protocol", type=Path, required=True)
        item.add_argument("--root", type=Path, required=True)
        item.add_argument("--case-ids", type=Path, required=True)
        if command == "report":
            item.add_argument("--references", type=Path, required=True)
            item.add_argument("--evidence-root", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root = args.root.resolve(strict=True)
    validate_protocol(load_protocol(args.protocol.resolve(strict=True)), root)
    case_ids = _case_ids_from_file(args.case_ids.resolve(strict=True))
    if args.command == "dry-run":
        result = dry_run_plan(case_ids)
    else:
        evidence_root = args.evidence_root.resolve(strict=True)
        evidence = load_receipts(
            references_path=args.references.resolve(strict=True),
            evidence_root=evidence_root,
            case_ids=case_ids,
        )
        result = build_report(evidence.projections, case_ids, evidence=evidence)
    print(stable_json(result))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
