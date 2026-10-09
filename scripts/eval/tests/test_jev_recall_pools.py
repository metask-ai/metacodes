import json
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

from scripts.eval.jev_recall_pools import (
    POOL_SIZE,
    compare,
    exact_mcnemar,
    first_gold,
    main,
    recallable,
)
from scripts.eval.model import ValidationError


def _hit(node_id, score, kind="evidence", schema_type=None, text="t"):
    node = {"id": node_id, "kind": kind, "text": text}
    if schema_type is not None:
        node["schema"] = {"schema_type": schema_type}
    return {"node": node, "score": score}


class RecallablePoolTest(unittest.TestCase):
    """The pool must be the hits KgClient.searchSubtreeInto keeps."""

    def test_drops_containers_task_plane_and_todo_memories(self):
        hits = [
            _hit(1, 9.0, kind="project"),
            _hit(2, 8.0, kind="task"),
            _hit(3, 7.0, kind="verification"),
            _hit(4, 6.0, kind="concept", schema_type="todo"),
            _hit(5, 5.0, kind="concept", schema_type="decision"),
        ]
        pool = recallable(hits)
        self.assertEqual([candidate["node_id"] for candidate in pool], [5])
        self.assertEqual(pool[0]["schema_type"], "decision")

    def test_keeps_first_occurrence_sorts_stably_and_caps_the_pool(self):
        hits = [_hit(node_id, 1.0) for node_id in range(10, 20)]
        hits.insert(0, _hit(30, 2.0))
        hits.append(_hit(10, 5.0))  # duplicate id: the first occurrence wins
        pool = recallable(hits)
        self.assertEqual(len(pool), POOL_SIZE)
        self.assertEqual([candidate["node_id"] for candidate in pool], [30, *range(10, 17)])
        self.assertEqual(pool[1]["score"], 1.0)

    def test_skips_malformed_rows(self):
        hits = [{"node": "x"}, {"node": {"id": -1, "kind": "evidence"}}, {"node": {"id": 2}}, _hit(3, 1.0)]
        self.assertEqual([candidate["node_id"] for candidate in recallable(hits)], [3])


class RankComparisonTest(unittest.TestCase):
    def test_exact_mcnemar_matches_the_binomial_tail(self):
        self.assertEqual(exact_mcnemar(0, 0), 1.0)
        # 15:1 discordant -> 2 * (1 + 16) / 2**16
        self.assertAlmostEqual(exact_mcnemar(15, 1), 34 / 65536)
        self.assertAlmostEqual(exact_mcnemar(1, 15), 34 / 65536)
        self.assertEqual(exact_mcnemar(5, 5), 1.0)

    def test_first_gold_and_compare_count_both_directions(self):
        self.assertEqual(first_gold([7, 8, 9], {9, 8}), 1)
        self.assertIsNone(first_gold([7], {9}))
        # (BM25 position, judged position): one gain at the top, one loss.
        summary = compare([(2, 0), (0, 1), (0, 0)])
        self.assertEqual(summary["gold_at_1"]["bm25"], 2)
        self.assertEqual(summary["gold_at_1"]["judged"], 2)
        self.assertEqual(summary["gold_at_1"]["only_judged"], 1)
        self.assertEqual(summary["gold_at_1"]["only_bm25"], 1)
        self.assertEqual((summary["rank_better"], summary["rank_worse"], summary["rank_same"]), (1, 1, 1))
        self.assertAlmostEqual(summary["mrr_bm25"], round((1 / 3 + 1 + 1) / 3, 4))


class ReportTest(unittest.TestCase):
    def _write(self, directory, name, rows):
        path = Path(directory) / name
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        return str(path)

    def _files(self, directory, order):
        cases = self._write(
            directory,
            "cases.jsonl",
            [{"case_id": "c", "query": "q", "user_request": "r", "candidates": [{"node_id": 1}, {"node_id": 2}]}],
        )
        gold = self._write(
            directory,
            "gold.jsonl",
            [{"case_id": "c", "position": 300, "question_type": "t", "gold_node_ids": [2]}],
        )
        results = self._write(
            directory,
            "results.jsonl",
            [{"case_id": "c", "status": "judged", "outcome": "answered", "elapsed_ms": 5, "order": order}],
        )
        return ["report", "--cases", cases, "--gold", gold, "--results", results]

    def test_a_judged_order_that_is_not_the_pool_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValidationError):
                main(self._files(directory, [2, 3]))

    def test_report_places_the_case_in_holdout(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self._files(directory, [2, 1])
            buffer = StringIO()
            with redirect_stdout(buffer):
                main(args)
            summary = json.loads(buffer.getvalue())
        self.assertEqual(summary["counts"]["moved"], 1)
        self.assertEqual(summary["dev"]["cases"], 0)
        self.assertEqual(summary["holdout"]["gold_at_1"]["only_judged"], 1)
        self.assertEqual(summary["holdout_by_type"]["t"]["cases"], 1)


if __name__ == "__main__":
    unittest.main()
