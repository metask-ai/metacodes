"""Case selection, shards and paired analysis of the paid KgRecall order pilot.

The pilot compares two arms on atomic (turn-level) LongMemEval-S memories,
both with the TinyKG tools: ``tinykg_jev_recall_atomic`` (System-One recall
gate only) and ``tinykg_jev_order_atomic`` (the gate plus the judged KgRecall
row order). Its contract is ``evals/memory/pilots/longmem-recall-order-glm52-v1``.

``cases``   lists the eligible holdout cases of a full ``adapt-longmem-memory``
            slice, in holdout order: positions 200-499, no
            single-session-preference (rubric answers), at least one gold
            answer of at most four words (no refusal or free-text answers).
``shard``   writes the upstream LongMemEval-S records of one contiguous run of
            that list. The official adapter orders by a per-question digest
            of the split seed, so adapting a filtered upstream keeps the
            relative order of the cases it keeps.
``analyze`` pairs the ``replay-memory`` rows of every shard by case and runs
            the pre-registered tests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .model import ValidationError, stable_json

CONTROL_ARM = "tinykg_jev_recall_atomic"
TREATMENT_ARM = "tinykg_jev_order_atomic"
HOLDOUT_START = 200
EXCLUDED_TYPES = frozenset({"single-session-preference"})
MAX_GOLD_WORDS = 4
CASES_SCHEMA_VERSION = "metacodes-jev-recall-order-pilot-cases-v1"


def eligible_cases(manifest: Mapping[str, Any], source: Mapping[str, Any]) -> List[Dict[str, Any]]:
    by_id = {case["id"]: case for case in source["cases"]}
    selected: List[Dict[str, Any]] = []
    for position, case in enumerate(manifest["cases"]):
        if position < HOLDOUT_START:
            continue
        source_case = by_id.get(case["id"])
        if source_case is None:
            raise ValidationError(f"source slice has no case {case['id']!r}")
        question_type = str(source_case["question_type"])
        if question_type in EXCLUDED_TYPES:
            continue
        if not any(len(str(answer).split()) <= MAX_GOLD_WORDS for answer in case["gold_answers"]):
            continue
        selected.append(
            {
                "case_id": case["id"],
                "position": position,
                "question_type": question_type,
                "source_id_sha256": source_case["source_id_sha256"],
            }
        )
    return selected


def cmd_cases(args: argparse.Namespace) -> int:
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    source = json.loads(Path(args.source).read_text(encoding="utf-8"))
    if len(manifest["cases"]) != 500:
        raise ValidationError("the case list is defined over the full 500-case slice")
    cases = eligible_cases(manifest, source)
    document = {
        "schema_version": CASES_SCHEMA_VERSION,
        "manifest_sha256": hashlib.sha256(Path(args.manifest).read_bytes()).hexdigest(),
        "source_sha256": hashlib.sha256(Path(args.source).read_bytes()).hexdigest(),
        "rule": {
            "holdout_positions": [HOLDOUT_START, len(manifest["cases"]) - 1],
            "excluded_question_types": sorted(EXCLUDED_TYPES),
            "max_gold_words": MAX_GOLD_WORDS,
        },
        "cases": cases,
    }
    with Path(args.output).open("x", encoding="utf-8") as handle:
        handle.write(stable_json(document) + "\n")
    print(f"{len(cases)} eligible holdout cases", file=sys.stderr)
    return 0


def cmd_shard(args: argparse.Namespace) -> int:
    document = json.loads(Path(args.cases).read_text(encoding="utf-8"))
    if document.get("schema_version") != CASES_SCHEMA_VERSION:
        raise ValidationError("unsupported case list")
    chosen = document["cases"][args.start : args.start + args.count]
    if len(chosen) != args.count:
        raise ValidationError("shard runs past the end of the case list")
    wanted = {case["source_id_sha256"] for case in chosen}
    upstream = json.loads(Path(args.upstream).read_text(encoding="utf-8"))
    records = [
        record
        for record in upstream
        if hashlib.sha256(str(record["question_id"]).encode("utf-8")).hexdigest() in wanted
    ]
    if len(records) != len(wanted):
        raise ValidationError("upstream file does not hold every case of the shard exactly once")
    with Path(args.output).open("x", encoding="utf-8") as handle:
        json.dump(records, handle, ensure_ascii=False)
    print(
        f"shard start={args.start} count={args.count} "
        f"sha256={hashlib.sha256(Path(args.output).read_bytes()).hexdigest()}",
        file=sys.stderr,
    )
    return 0


def exact_mcnemar(only_a: int, only_b: int) -> float:
    """Two-sided exact McNemar p-value on the discordant pairs."""

    n = only_a + only_b
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(only_a, only_b) + 1)) / 2**n
    return min(1.0, 2 * tail)


def _valid(row: Mapping[str, Any]) -> bool:
    return row["outcome"]["success"] is not None


def _verified_gold(row: Mapping[str, Any]) -> bool:
    retrieval = row["retrieval"]
    return bool(set(retrieval["expected_evidence_ids"]) & set(retrieval["verified_evidence_ids"]))


def _paired(rows: Sequence[Mapping[str, Any]]) -> Tuple[Dict[str, Dict[str, Mapping[str, Any]]], Dict[str, int]]:
    by_case: Dict[str, Dict[str, Mapping[str, Any]]] = {}
    for row in rows:
        arm = row["arm"]
        if arm not in {CONTROL_ARM, TREATMENT_ARM}:
            raise ValidationError(f"unexpected arm {arm!r}")
        slot = by_case.setdefault(row["case_id"], {})
        if arm in slot:
            raise ValidationError(f"duplicate row for {row['case_id']} {arm}")
        slot[arm] = row
    invalid = {CONTROL_ARM: 0, TREATMENT_ARM: 0}
    for slot in by_case.values():
        for arm, row in slot.items():
            if not _valid(row):
                invalid[arm] += 1
    return by_case, invalid


def analyze(rows: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    by_case, invalid = _paired(rows)
    pairs = [
        (slot[CONTROL_ARM], slot[TREATMENT_ARM])
        for slot in by_case.values()
        if CONTROL_ARM in slot and TREATMENT_ARM in slot and _valid(slot[CONTROL_ARM]) and _valid(slot[TREATMENT_ARM])
    ]

    def paired_binary(metric) -> Dict[str, Any]:
        control = sum(1 for c, _ in pairs if metric(c))
        treatment = sum(1 for _, t in pairs if metric(t))
        only_treatment = sum(1 for c, t in pairs if metric(t) and not metric(c))
        only_control = sum(1 for c, t in pairs if metric(c) and not metric(t))
        return {
            "control": control,
            "treatment": treatment,
            "only_treatment": only_treatment,
            "only_control": only_control,
            "p": round(exact_mcnemar(only_treatment, only_control), 4),
        }

    def mean(values: Sequence[float]) -> float | None:
        return round(sum(values) / len(values), 6) if values else None

    every = [row for slot in by_case.values() for row in slot.values()]
    return {
        "cases": len(by_case),
        "valid_pairs": len(pairs),
        "invalid_rows": invalid,
        "primary_verified_gold_evidence": paired_binary(_verified_gold),
        "secondary_exact_match": paired_binary(lambda row: bool(row["outcome"]["success"])),
        "diagnostics": {
            arm: {
                "mean_cost_usd": mean([float(row["cost"]["cost_usd"]) for row in every if row["arm"] == arm]),
                "max_cost_usd": max((float(row["cost"]["cost_usd"]) for row in every if row["arm"] == arm), default=None),
                "mean_exposed_memory_tokens": mean(
                    [float(row["memory"]["exposed_tokens"]) for row in every if row["arm"] == arm]
                ),
            }
            for arm in (CONTROL_ARM, TREATMENT_ARM)
        },
    }


def cmd_analyze(args: argparse.Namespace) -> int:
    rows: List[Mapping[str, Any]] = []
    for path in args.rows:
        for line in Path(path).read_text(encoding="utf-8").split("\n"):
            if line.strip():
                rows.append(json.loads(line))
    print(json.dumps(analyze(rows), indent=2, sort_keys=True))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    cases = commands.add_parser("cases", help="list eligible holdout cases in holdout order")
    cases.add_argument("--manifest", required=True, help="full 500-case adapt-longmem-memory manifest")
    cases.add_argument("--source", required=True, help="its source slice")
    cases.add_argument("--output", required=True)
    cases.set_defaults(func=cmd_cases)
    shard = commands.add_parser("shard", help="filter the upstream file to one run of the case list")
    shard.add_argument("--cases", required=True)
    shard.add_argument("--upstream", required=True, help="longmemeval_s_cleaned.json")
    shard.add_argument("--start", type=int, required=True)
    shard.add_argument("--count", type=int, required=True)
    shard.add_argument("--output", required=True)
    shard.set_defaults(func=cmd_shard)
    analyze_parser = commands.add_parser("analyze", help="paired analysis over replay-memory rows")
    analyze_parser.add_argument("rows", nargs="+", help="replay-memory --output files of every shard")
    analyze_parser.set_defaults(func=cmd_analyze)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
