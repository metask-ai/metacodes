"""Validate the staged TinyKG x Lean attribution experiment contract.

This module owns experiment ordering and claim boundaries.  It deliberately
does not execute a paid rollout: the existing memory and RuleImpact runners
retain their own credential, journal, isolation, and receipt boundaries.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any, Mapping, Sequence

from .memory_budget_journal import MAX_USER_AUTHORITY_USD
from .model import ValidationError


SCHEMA_VERSION = 1
PROTOCOL_ID = "metacodes-tinykg-lean-attribution-v1"
CELL_IDS = ("control", "memory_only", "lean_only", "combined")
EXPECTED_CELLS = {
    "control": (False, False),
    "memory_only": (True, False),
    "lean_only": (False, True),
    "combined": (True, True),
}
STAGE_IDS = (
    "s0_zero_paid_wiring",
    "s1_tinykg_main_effect",
    "s2_lean_main_effect",
    "s3_factorial_interaction",
    "s4_workbuddy_external_validation",
)
EXPECTED_PREDECESSORS = {
    "s0_zero_paid_wiring": (),
    "s1_tinykg_main_effect": ("s0_zero_paid_wiring",),
    "s2_lean_main_effect": ("s0_zero_paid_wiring",),
    "s3_factorial_interaction": (
        "s1_tinykg_main_effect",
        "s2_lean_main_effect",
    ),
    "s4_workbuddy_external_validation": ("s3_factorial_interaction",),
}
EXPECTED_STAGE_ARMS = {
    "s1_tinykg_main_effect": ("no_memory", "tinykg_lexical"),
    "s2_lean_main_effect": (
        "signal_only",
        "evolved_shadow",
        "evolved_enforced",
    ),
    "s3_factorial_interaction": CELL_IDS,
}
PRIMARY_CONTRAST_IDS = (
    "tinykg_main",
    "lean_main",
    "combined_total",
    "factorial_interaction",
)
REQUIRED_PROMOTION_TERMS = (
    "treatment actuation verified",
    "no trustworthy-success regression",
    "zero unsafe Lean false interventions",
    "zero remote TinyKG writes",
    "combined arm no worse",
    "at least one preregistered quality or recurrence metric improves",
    "cache contract passes",
    "frozen before WorkBuddy",
)


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


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def load_protocol(path: Path) -> Mapping[str, Any]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        _fail("attribution protocol", f"cannot read: {exc}")
    if len(raw) > 1024 * 1024:
        _fail("attribution protocol", "exceeds 1 MiB")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail("attribution protocol", f"invalid JSON: {exc}")
    return _mapping(value, "attribution protocol")


def _validate_cells(protocol: Mapping[str, Any]) -> None:
    cells = _sequence(protocol.get("factorial_cells"), "factorial_cells")
    if len(cells) != len(EXPECTED_CELLS):
        _fail("factorial_cells", "must contain the complete 2x2 design")
    observed: dict[str, tuple[bool, bool]] = {}
    for index, raw in enumerate(cells):
        cell = _mapping(raw, f"factorial_cells[{index}]")
        if set(cell) != {"id", "tinykg", "lean"}:
            _fail(f"factorial_cells[{index}]", "field drift")
        cell_id = cell.get("id")
        tinykg = cell.get("tinykg")
        lean = cell.get("lean")
        if not isinstance(cell_id, str) or not isinstance(tinykg, bool) or not isinstance(lean, bool):
            _fail(f"factorial_cells[{index}]", "invalid id or factor type")
        if cell_id in observed:
            _fail("factorial_cells", f"duplicate cell {cell_id}")
        observed[cell_id] = (tinykg, lean)
    if observed != EXPECTED_CELLS:
        _fail("factorial_cells", "does not encode control, two main effects, and combined")


def _validate_stages(protocol: Mapping[str, Any], root: Path) -> None:
    stages = _sequence(protocol.get("stages"), "stages")
    ids = tuple(
        str(_mapping(stage, f"stages[{index}]").get("id"))
        for index, stage in enumerate(stages)
    )
    if ids != STAGE_IDS:
        _fail("stages", "must preserve mechanism -> interaction -> WorkBuddy order")
    for index, raw in enumerate(stages):
        stage = _mapping(raw, f"stages[{index}]")
        stage_id = str(stage["id"])
        predecessors = tuple(_sequence(stage.get("predecessors"), f"stages[{index}].predecessors"))
        if predecessors != EXPECTED_PREDECESSORS[stage_id]:
            _fail(stage_id, "predecessor drift")
        expected_arms = EXPECTED_STAGE_ARMS.get(stage_id)
        if expected_arms is not None and tuple(stage.get("arms", ())) != expected_arms:
            _fail(stage_id, "arm drift")
        quality = stage.get("quality_evidence")
        if not isinstance(quality, bool):
            _fail(stage_id, "quality_evidence must be boolean")
        if stage_id == "s0_zero_paid_wiring" and quality:
            _fail(stage_id, "wiring smoke cannot be quality evidence")
        if stage_id == "s0_zero_paid_wiring":
            expected_runners = (
                "scripts/eval/memory_agent_runtime_smoke.py",
                "scripts/eval/run_project_rule_evolution_mac_pilot.py",
                "scripts/eval/project_harness_experiment.py",
            )
            runners = tuple(_sequence(stage.get("runners"), f"stages[{index}].runners"))
            if runners != expected_runners:
                _fail(stage_id, "must freeze memory, ontology-to-rule, and project-gate wiring")
            for runner in runners:
                if not isinstance(runner, str) or not (root / runner).is_file():
                    _fail(stage_id, f"runner is unavailable: {runner}")
        else:
            runner = stage.get("runner")
            if not isinstance(runner, str) or not runner:
                _fail(stage_id, "runner is missing")
            if not runner.startswith("external:"):
                if not (root / runner).is_file():
                    _fail(stage_id, f"runner is unavailable: {runner}")
        if stage_id == "s3_factorial_interaction":
            if stage.get("runner") != "scripts/eval/tinykg_lean_factorial_block.py":
                _fail(stage_id, "must use the unified native factorial executor")
            analyzer = stage.get("analyzer")
            if analyzer != "scripts/eval/tinykg_lean_factorial.py" or not (
                root / str(analyzer)
            ).is_file():
                _fail(stage_id, "authenticated factorial analyzer is unavailable")


def _validate_sources(protocol: Mapping[str, Any], root: Path) -> None:
    sources: dict[str, str] = {}
    datasets = _mapping(protocol.get("datasets"), "datasets")
    for dataset_id in ("episodic", "multihop", "procedural_smoke"):
        dataset = _mapping(datasets.get(dataset_id), f"datasets.{dataset_id}")
        path = dataset.get("pin")
        sha256 = dataset.get("pin_sha256")
        if not isinstance(path, str) or not isinstance(sha256, str):
            _fail(f"datasets.{dataset_id}", "pin identity is incomplete")
        sources[path] = sha256
    lean = _mapping(datasets.get("lean_rule_impact"), "datasets.lean_rule_impact")
    if lean.get("calibration_cases") != 4 or lean.get("heldout_cases") != 8:
        _fail("datasets.lean_rule_impact", "case-count drift")
    cases_path = lean.get("cases")
    cases_sha = lean.get("cases_sha256")
    if not isinstance(cases_path, str) or not isinstance(cases_sha, str):
        _fail("datasets.lean_rule_impact", "case identity is incomplete")
    sources[cases_path] = cases_sha
    source_contract = _mapping(protocol.get("source_contract"), "source_contract")
    for path, sha256 in source_contract.items():
        if not isinstance(path, str) or not isinstance(sha256, str):
            _fail("source_contract", "path/digest must be strings")
        sources[path] = sha256
    for relative, expected in sources.items():
        if len(expected) != 64 or any(char not in "0123456789abcdef" for char in expected):
            _fail(relative, "invalid SHA-256")
        path = root / relative
        if not path.is_file():
            _fail(relative, "required source is unavailable")
        if _sha256_file(path) != expected:
            _fail(relative, "source identity drift")
    procedural = _mapping(datasets["procedural_smoke"], "datasets.procedural_smoke")
    if procedural.get("quality_evidence") is not False:
        _fail("datasets.procedural_smoke", "two-family fixture cannot be quality evidence")


def _validate_measurement(protocol: Mapping[str, Any]) -> None:
    contrasts = _sequence(protocol.get("primary_contrasts"), "primary_contrasts")
    if tuple(str(_mapping(item, "primary contrast").get("id")) for item in contrasts) != PRIMARY_CONTRAST_IDS:
        _fail("primary_contrasts", "primary contrast drift")
    interaction = _mapping(contrasts[-1], "factorial interaction")
    if interaction.get("formula") != "combined - memory_only - lean_only + control":
        _fail("factorial interaction", "difference-in-differences formula drift")

    cache = _mapping(protocol.get("cache_contract"), "cache_contract")
    expected_cache = {
        "stable_core_prefix_equal_all_cells": True,
        "full_first_request_equal_when_only_lean_changes": True,
        "full_first_request_equal_when_tinykg_changes": False,
        "tinykg_increment_measured_separately": True,
    }
    for key, expected in expected_cache.items():
        if cache.get(key) is not expected:
            _fail("cache_contract", f"{key} drift")

    promotion = _mapping(protocol.get("promotion"), "promotion")
    requirements = _sequence(promotion.get("requires"), "promotion.requires")
    combined = "\n".join(str(item) for item in requirements)
    for term in REQUIRED_PROMOTION_TERMS:
        if term not in combined:
            _fail("promotion.requires", f"missing gate: {term}")

    ladder = _sequence(protocol.get("sample_ladder"), "sample_ladder")
    expected_ladder = ("calibration", "development", "internal_confirmatory")
    if tuple(str(_mapping(row, "sample ladder").get("id")) for row in ladder) != expected_ladder:
        _fail("sample_ladder", "stage drift")
    memory_counts = [int(_mapping(row, "sample ladder")["minimum_memory_cases_per_arm"]) for row in ladder]
    factorial_counts = [int(_mapping(row, "sample ladder")["minimum_factorial_cases"]) for row in ladder]
    if memory_counts != sorted(memory_counts) or memory_counts[0] < 6:
        _fail("sample_ladder", "memory cases must grow and cover all six LongMemEval categories")
    if factorial_counts != sorted(factorial_counts) or factorial_counts[0] < 4:
        _fail("sample_ladder", "factorial cases must grow from one complete Williams block")
    if int(_mapping(ladder[0], "sample ladder")["minimum_lean_calibration_cases"]) != 4:
        _fail("sample_ladder", "Lean calibration must bind all four frozen calibration cases")
    for row in ladder[1:]:
        if int(_mapping(row, "sample ladder")["minimum_lean_heldout_cases"]) != 8:
            _fail("sample_ladder", "Lean development/confirmatory must bind all eight frozen held-out cases")
    if int(_mapping(ladder[-1], "sample ladder")["trials"]) < 3:
        _fail("sample_ladder", "confirmatory stage requires repeated trials")


def validate_protocol(protocol: Mapping[str, Any], root: Path) -> Mapping[str, Any]:
    if protocol.get("schema_version") != SCHEMA_VERSION or protocol.get("protocol_id") != PROTOCOL_ID:
        _fail("attribution protocol", "schema/protocol identity drift")
    model = _mapping(protocol.get("model"), "model")
    if model.get("id") != "glm-5.2":
        _fail("model", "the attribution program freezes glm-5.2")
    _validate_cells(protocol)
    _validate_stages(protocol, root)
    _validate_sources(protocol, root)
    _validate_measurement(protocol)

    isolation = _mapping(protocol.get("isolation"), "isolation")
    if isolation.get("remote_skill_harness_forbidden") is not True:
        _fail("isolation", "remote TinyKG must be forbidden for benchmark rows")
    budget = _mapping(protocol.get("budget"), "budget")
    authority = budget.get("maximum_user_authority_usd")
    if not isinstance(authority, (int, float)) or isinstance(authority, bool):
        _fail("budget", "invalid user authority")
    if float(authority) != 2000.0 or float(authority) > MAX_USER_AUTHORITY_USD:
        _fail("budget", "must bind the explicit $2000 user authority")
    if budget.get("preflight_paid_rollouts_enabled") is not False:
        _fail("budget", "protocol preflight must remain zero-paid")
    if budget.get("provider_retries") != 0 or budget.get("journal_required") is not True:
        _fail("budget", "single-attempt durable-journal boundary drift")

    gaps = _sequence(protocol.get("known_gaps"), "known_gaps")
    if any("production executor" in str(gap) for gap in gaps):
        _fail("known_gaps", "resolved factorial production-executor gap is stale")
    return protocol


def balanced_factorial_schedule(case_ids: Sequence[str]) -> list[Mapping[str, Any]]:
    """Return a deterministic four-period Williams schedule.

    A complete block contains four cases.  Each cell appears once in every
    position and every ordered carryover appears once within that block.
    """

    if not case_ids or len(case_ids) % 4 != 0 or len(set(case_ids)) != len(case_ids):
        _fail("factorial schedule", "requires distinct, non-empty case ids in blocks of four")
    rows = (
        (0, 1, 3, 2),
        (1, 2, 0, 3),
        (2, 3, 1, 0),
        (3, 0, 2, 1),
    )
    ranked = sorted(
        case_ids,
        key=lambda case_id: hashlib.sha256(
            f"{PROTOCOL_ID}\0{case_id}".encode("utf-8")
        ).digest(),
    )
    schedule: list[Mapping[str, Any]] = []
    for index, case_id in enumerate(ranked):
        order = rows[index % len(rows)]
        for position, cell_index in enumerate(order):
            schedule.append(
                {
                    "sequence": len(schedule),
                    "case_id": case_id,
                    "position": position,
                    "cell": CELL_IDS[cell_index],
                }
            )
    return schedule


def dry_run_plan(protocol: Mapping[str, Any]) -> Mapping[str, Any]:
    stages = _sequence(protocol["stages"], "stages")
    return {
        "schema_version": "metacodes-attribution-dry-run-v1",
        "protocol_id": protocol["protocol_id"],
        "provider_requests": 0,
        "paid_rollouts_enabled": False,
        "quality_evidence": False,
        "stage_order": [stage["id"] for stage in stages],
        "factorial_cells": list(CELL_IDS),
        "workbuddy_blocked_by": ["s3_factorial_interaction"],
        "known_gaps": list(protocol["known_gaps"]),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("validate", "dry-run"),
        help="Validate the frozen contract or print its zero-paid execution plan.",
    )
    parser.add_argument("--protocol", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    root = args.root.resolve()
    protocol = validate_protocol(load_protocol(args.protocol.resolve()), root)
    if args.command == "validate":
        result = {
            "schema_version": "metacodes-attribution-validation-v1",
            "protocol_id": protocol["protocol_id"],
            "valid": True,
            "provider_requests": 0,
            "paid_rollouts_enabled": False,
        }
    else:
        result = dry_run_plan(protocol)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
