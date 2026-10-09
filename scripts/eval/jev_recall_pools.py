"""Zero-provider LongMemEval-S evaluation of the System-One KgRecall order.

``build`` turns an adapted LongMemEval-S slice into the driver input of
``metacodes-jev-recall-eval`` (``zig build eval:jev-recall-driver``): one
isolated TinyKG store per case, built by the paid runner's own batch code
(``mixed``: session and turn nodes, as the TinyKG arms see them; ``turn``:
turn nodes only), searched the way ``KgClient.recallTyped`` searches, the
first eight hits kept. The case question is the recall query (a stand-in for
the compact query a model writes) and the case prompt the user request.

``report`` reads the driver output back against the gold sessions and
compares where the first gold hit sits in TinyKG's BM25 order and in the
judged order (``scoped_recall.judgedOrder``) on the same pool.

Neither step contacts a provider; the driver's only peer is the judge named
by ``METACODES_JEV_URL``.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

from .memory_agent_runtime import _agent_batch, _atomic_memory_batch
from .memory_tinykg_local import LocalTinyKg, build_case_batch
from .model import ValidationError

POOL_SIZE = 8
# KgClient over-samples so client-side filtering can still fill the pool.
SEARCH_LIMIT = POOL_SIZE * 2 + 4
# KgRecall accepts 1..400-byte queries.
MAX_QUERY_BYTES = 400
DOMAIN = "jev-recall-order-eval"
# _agent_batch puts the project root first; KgClient searches its subtree.
PROJECT_NODE_ID = "1"
DEV_CASES = 200


def _utf8_prefix(text: str, limit: int) -> str:
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    return data[:limit].decode("utf-8", errors="ignore")


def recallable(hits: Sequence[Mapping[str, Any]]) -> List[Dict[str, Any]]:
    """The hits ``KgClient.searchSubtreeInto`` keeps, in its order.

    It drops project containers, task-plane nodes and todo memories, keeps
    the first occurrence of a node id, and sorts the rest by score
    descending (``std.mem.sort`` is stable, as is ``sorted``)."""

    kept: List[Dict[str, Any]] = []
    seen = set()
    for hit in hits:
        node = hit.get("node")
        if not isinstance(node, dict):
            continue
        kind = node.get("kind")
        node_id = node.get("id")
        if not isinstance(kind, str) or not isinstance(node_id, int) or node_id < 0:
            continue
        schema = node.get("schema") if isinstance(node.get("schema"), dict) else {}
        schema_type = schema.get("schema_type") if isinstance(schema.get("schema_type"), str) else ""
        if kind in {"project", "task", "verification"} or schema_type == "todo":
            continue
        if node_id in seen:
            continue
        seen.add(node_id)
        score = hit.get("score")
        kept.append(
            {
                "node_id": node_id,
                "kind": kind,
                "schema_type": schema_type,
                "score": float(score) if isinstance(score, (int, float)) else 0.0,
                "text": node.get("text") if isinstance(node.get("text"), str) else "",
            }
        )
    return sorted(kept, key=lambda candidate: -candidate["score"])[:POOL_SIZE]


def build(args: argparse.Namespace) -> None:
    source = json.loads(Path(args.source).read_text(encoding="utf-8"))
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    cases = manifest["cases"][: args.limit] if args.limit else manifest["cases"]
    local = LocalTinyKg(
        Path(args.tinykg),
        expected_sha256=args.tinykg_sha256,
        run_dir=Path(args.run_dir),
    )
    output = Path(args.output)
    gold_output = Path(args.gold)
    with output.open("x", encoding="utf-8") as pools, gold_output.open("x", encoding="utf-8") as golds:
        for position, case in enumerate(cases):
            raw_batch, raw_logical, root_id, _ = build_case_batch(source, manifest, case["id"])
            if args.store == "turn":
                raw_batch, raw_logical, root_id = _atomic_memory_batch(raw_batch, raw_logical)
            batch, logical_ids, _root, _counts = _agent_batch(raw_batch, raw_logical, root_id, DOMAIN)
            name = f"{position:04d}"
            store = local.store_root / f"{name}.kg"
            batch_path = local.batch_root / f"{name}.jsonl"
            batch_path.write_bytes(batch)
            local.command("init", store, ())
            local.command("apply", store, (str(batch_path),))
            local.command("rebuild-text", store, ())
            question = source_question(source, case["id"])
            query = _utf8_prefix(question, MAX_QUERY_BYTES)
            result = json.loads(
                local.command(
                    "search",
                    store,
                    (
                        query,
                        "--project",
                        PROJECT_NODE_ID,
                        "--limit",
                        str(SEARCH_LIMIT),
                        "--profile",
                        "agent-memory",
                        "--format",
                        "json",
                        "--include-text",
                    ),
                )
            )
            candidates = recallable(result.get("hits") or [])
            gold_sessions = set(case["expected_evidence_ids"])
            gold_nodes = sorted(
                node_id for node_id, session in logical_ids.items() if session in gold_sessions
            )
            pools.write(
                json.dumps(
                    {
                        "case_id": case["id"],
                        "query": query,
                        "user_request": case["prompt"],
                        "candidates": candidates,
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
            golds.write(
                json.dumps(
                    {
                        "case_id": case["id"],
                        "position": position,
                        "question_type": case_question_type(source, case["id"]),
                        "gold_node_ids": gold_nodes,
                    }
                )
                + "\n"
            )
            shutil.rmtree(store)
            batch_path.unlink()
            if (position + 1) % 50 == 0:
                print(f"built {position + 1}/{len(cases)} {args.store} pools", file=sys.stderr)


def _source_case(source: Mapping[str, Any], case_id: str) -> Mapping[str, Any]:
    for case in source["cases"]:
        if case.get("id") == case_id:
            return case
    raise ValidationError(f"LongMemEval-S source has no case {case_id!r}")


def source_question(source: Mapping[str, Any], case_id: str) -> str:
    return str(_source_case(source, case_id)["question"])


def case_question_type(source: Mapping[str, Any], case_id: str) -> str:
    return str(_source_case(source, case_id).get("question_type", ""))


def first_gold(order: Sequence[int], gold: set) -> int | None:
    for position, node_id in enumerate(order):
        if node_id in gold:
            return position
    return None


def exact_mcnemar(only_a: int, only_b: int) -> float:
    """Two-sided exact McNemar p-value on the discordant pairs."""

    n = only_a + only_b
    if n == 0:
        return 1.0
    k = min(only_a, only_b)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2**n
    return min(1.0, 2 * tail)


def compare(rows: Sequence[Tuple[int, int]]) -> Dict[str, Any]:
    """rows: (BM25 position, judged position) of the first gold hit."""

    def at(k: int) -> Dict[str, Any]:
        base = sum(1 for bm25, _ in rows if bm25 < k)
        judged = sum(1 for _, order in rows if order < k)
        only_judged = sum(1 for bm25, order in rows if order < k <= bm25)
        only_bm25 = sum(1 for bm25, order in rows if bm25 < k <= order)
        return {
            "bm25": base,
            "judged": judged,
            "only_judged": only_judged,
            "only_bm25": only_bm25,
            "p": round(exact_mcnemar(only_judged, only_bm25), 4),
        }

    n = len(rows)
    return {
        "cases": n,
        "gold_at_1": at(1),
        "gold_at_3": at(3),
        "mrr_bm25": round(sum(1 / (bm25 + 1) for bm25, _ in rows) / n, 4) if n else None,
        "mrr_judged": round(sum(1 / (order + 1) for _, order in rows) / n, 4) if n else None,
        "rank_better": sum(1 for bm25, order in rows if order < bm25),
        "rank_worse": sum(1 for bm25, order in rows if order > bm25),
        "rank_same": sum(1 for bm25, order in rows if order == bm25),
        "p_rank": round(
            exact_mcnemar(
                sum(1 for bm25, order in rows if order < bm25),
                sum(1 for bm25, order in rows if order > bm25),
            ),
            4,
        ),
    }


def report(args: argparse.Namespace) -> None:
    pools = {row["case_id"]: row for row in _jsonl(Path(args.cases))}
    golds = {row["case_id"]: row for row in _jsonl(Path(args.gold))}
    results = list(_jsonl(Path(args.results)))
    splits: Dict[str, List[Tuple[int, int]]] = {"dev": [], "holdout": []}
    by_type: Dict[str, List[Tuple[int, int]]] = {}
    counts = {"cases": 0, "unanswered": 0, "no_hits": 0, "gold_not_in_pool": 0, "moved": 0}
    elapsed: List[int] = []
    for result in results:
        counts["cases"] += 1
        case_id = result["case_id"]
        if result["status"] != "judged":
            counts["no_hits"] += 1
            continue
        if result["outcome"] != "answered":
            counts["unanswered"] += 1
            continue
        elapsed.append(int(result["elapsed_ms"]))
        bm25_order = [candidate["node_id"] for candidate in pools[case_id]["candidates"]]
        judged_order = result["order"]
        if sorted(judged_order) != sorted(bm25_order):
            raise ValidationError(f"{case_id}: judged order is not a permutation of the pool")
        if judged_order != bm25_order:
            counts["moved"] += 1
        gold = set(golds[case_id]["gold_node_ids"])
        bm25_first = first_gold(bm25_order, gold)
        judged_first = first_gold(judged_order, gold)
        if bm25_first is None:
            counts["gold_not_in_pool"] += 1
            continue
        row = (bm25_first, judged_first)
        split = "dev" if golds[case_id]["position"] < DEV_CASES else "holdout"
        splits[split].append(row)
        if split == "holdout":
            by_type.setdefault(golds[case_id]["question_type"], []).append(row)
    elapsed.sort()
    summary = {
        "counts": counts,
        "elapsed_ms_p50": elapsed[len(elapsed) // 2] if elapsed else None,
        "elapsed_ms_p99": elapsed[min(len(elapsed) - 1, int(len(elapsed) * 0.99))] if elapsed else None,
        "dev": compare(splits["dev"]),
        "holdout": compare(splits["holdout"]),
        "holdout_by_type": {name: compare(rows) for name, rows in sorted(by_type.items())},
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))


def _jsonl(path: Path):
    with path.open(encoding="utf-8") as handle:
        for line in handle.read().split("\n"):
            if line.strip():
                yield json.loads(line)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build", help="build driver input pools from an adapted slice")
    build_parser.add_argument("--source", required=True, help="adapt-longmem-memory --output-source")
    build_parser.add_argument("--manifest", required=True, help="adapt-longmem-memory --output-manifest")
    build_parser.add_argument("--tinykg", required=True)
    build_parser.add_argument("--tinykg-sha256", required=True)
    build_parser.add_argument("--store", choices=("mixed", "turn"), required=True)
    build_parser.add_argument("--run-dir", required=True, help="new directory for scratch stores")
    build_parser.add_argument("--output", required=True, help="driver input JSONL (must not exist)")
    build_parser.add_argument("--gold", required=True, help="gold JSONL (must not exist)")
    build_parser.add_argument("--limit", type=int, default=0)
    build_parser.set_defaults(func=build)
    report_parser = commands.add_parser("report", help="compare BM25 and judged order against gold")
    report_parser.add_argument("--cases", required=True, help="the build output")
    report_parser.add_argument("--gold", required=True)
    report_parser.add_argument("--results", required=True, help="metacodes-jev-recall-eval output")
    report_parser.set_defaults(func=report)
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
