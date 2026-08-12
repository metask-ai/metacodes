import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.cli import main
from scripts.eval.memory_longmem_adapter import (
    ADAPTER_ID,
    ADAPTER_REVISION,
    SELECTION_ALGORITHM,
    adapt_longmem,
    artifact_bytes,
    load_longmem_records,
    select_records,
)
from scripts.eval.memory_replay import validate_manifest
from scripts.eval.model import ValidationError, stable_json


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def execution() -> dict:
    return {
        "model_id": "adapter-smoke-no-rollout",
        "model_fingerprint": digest("adapter-smoke-model"),
        "harness_revision": "adapter-test-revision",
        "arms": [
            {"id": "no_memory", "fingerprint": digest("no-memory-v1")},
            {"id": "tinykg_lexical", "fingerprint": digest("tinykg-lexical-v1")},
        ],
        "trials": 1,
        "retrieval_limits": {
            "max_k": 10,
            "max_hops": 3,
            "max_semantic_variants": 4,
        },
    }


def session(user: str, assistant: str, *, has_answer=False) -> list[dict]:
    user_turn = {"role": "user", "content": user}
    if has_answer:
        user_turn["has_answer"] = True
    return [
        user_turn,
        {"role": "assistant", "content": assistant, "has_answer": False},
    ]


def longmem_record(index: int, *, abstention=False) -> dict:
    raw_id = f"question_{index:02d}" + ("_abs" if abstention else "")
    evidence_id = f"answer_{index:02d}"
    return {
        "question_id": raw_id,
        "question_type": "single-session-preference" if index % 2 else "temporal-reasoning",
        "question": f"What preference did I state in case {index}?",
        "answer": f"Preference {index}",
        "question_date": "2024/01/10 (Wed) 12:00",
        "haystack_session_ids": [f"distractor_{index:02d}", evidence_id],
        "haystack_dates": ["2024/01/02 (Tue) 09:00", "2024/01/05 (Fri) 10:00"],
        "haystack_sessions": [
            session("Talk about an unrelated subject.", "Here is unrelated information."),
            session(
                f"I prefer Preference {index}.",
                "I will remember that preference.",
                has_answer=not abstention,
            ),
        ],
        "answer_session_ids": [evidence_id],
    }


class LongMemMemoryAdapterTest(unittest.TestCase):
    def write_source(self, root: Path, records=None) -> tuple[Path, str]:
        path = root / "longmemeval_s_cleaned.json"
        value = records if records is not None else [longmem_record(i) for i in range(6)]
        path.write_text(stable_json(value) + "\n", encoding="utf-8")
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def adapt(self, root: Path, records=None, *, limit=3, split_seed=20260806):
        source, source_sha = self.write_source(root, records)
        source_slice, manifest = adapt_longmem(
            source,
            execution(),
            expected_source_sha256=source_sha,
            limit=limit,
            split_seed=split_seed,
            source_url="https://example.invalid/longmemeval.json",
            source_revision="fixture-v1",
        )
        return source_slice, manifest

    def test_corpus_strips_all_hidden_labels_and_manifest_keeps_them(self):
        records = [longmem_record(1), longmem_record(2, abstention=True), longmem_record(3)]
        with tempfile.TemporaryDirectory() as directory:
            source_slice, manifest = self.adapt(Path(directory), records, limit=3)
        self.assertEqual(source_slice["adapter_id"], ADAPTER_ID)
        self.assertEqual(source_slice["adapter_revision"], ADAPTER_REVISION)
        self.assertEqual(source_slice["selection"]["algorithm"], SELECTION_ALGORITHM)
        validate_manifest(manifest)
        raw_ids = {record["question_id"] for record in records}
        for case in source_slice["cases"]:
            self.assertNotIn("answer", case)
            self.assertNotIn("answer_session_ids", case)
            self.assertNotIn("abstention", case)
            self.assertTrue(raw_ids.isdisjoint(case["id"] for _ in [0]))
            for history_session in case["sessions"]:
                self.assertNotIn("source_session_id", history_session)
                for turn in history_session["turns"]:
                    self.assertNotIn("has_answer", turn)
        corpus_ids = {case["id"] for case in source_slice["cases"]}
        self.assertEqual(corpus_ids, {case["id"] for case in manifest["cases"]})
        abstention_rows = [
            case for case in manifest["cases"] if case["gold_answers"] == ["Preference 2"]
        ]
        self.assertEqual(len(abstention_rows[0]["expected_evidence_ids"]), 1)
        non_abstention = [
            case for case in manifest["cases"] if case["gold_answers"] == ["Preference 1"]
        ][0]
        self.assertEqual(len(non_abstention["expected_evidence_ids"]), 1)
        self.assertIn("Question date: 2024/01/10 (Wed) 12:00", non_abstention["prompt"])

    def test_duplicate_non_gold_session_occurrences_get_unique_ids(self):
        record = longmem_record(1)
        record["haystack_session_ids"].insert(1, record["haystack_session_ids"][0])
        record["haystack_dates"].insert(1, "2024/01/03 (Wed) 09:30")
        record["haystack_sessions"].insert(
            1,
            session("Talk about an unrelated subject.", "Here is unrelated information."),
        )
        with tempfile.TemporaryDirectory() as directory:
            source_slice, manifest = self.adapt(Path(directory), [record], limit=1)
        session_ids = [item["id"] for item in source_slice["cases"][0]["sessions"]]
        self.assertEqual(len(session_ids), len(set(session_ids)))
        self.assertEqual(len(manifest["cases"][0]["expected_evidence_ids"]), 1)

    def test_empty_distractor_turn_and_unsorted_dates_are_preserved(self):
        record = longmem_record(1)
        record["haystack_sessions"][0][0]["content"] = ""
        record["haystack_dates"] = list(reversed(record["haystack_dates"]))
        record["haystack_sessions"] = list(reversed(record["haystack_sessions"]))
        record["haystack_session_ids"] = list(reversed(record["haystack_session_ids"]))
        with tempfile.TemporaryDirectory() as directory:
            source_slice, _ = self.adapt(Path(directory), [record], limit=1)
        case = source_slice["cases"][0]
        self.assertEqual(case["sessions"][0]["source_position"], 0)
        self.assertEqual(case["sessions"][1]["turns"][0]["content"], "")

    def test_integer_answer_is_canonically_normalized_for_deterministic_scoring(self):
        record = longmem_record(1)
        record["answer"] = 120
        with tempfile.TemporaryDirectory() as directory:
            _, manifest = self.adapt(Path(directory), [record], limit=1)
        self.assertEqual(manifest["cases"][0]["gold_answers"], ["120"])

    def test_hash_selection_is_input_order_independent_and_byte_deterministic(self):
        records = [longmem_record(i) for i in range(10)]
        forward = select_records(records, limit=4, split_seed=7)
        reverse = select_records(reversed(records), limit=4, split_seed=7)
        self.assertEqual(
            [row["question_id"] for row in forward],
            [row["question_id"] for row in reverse],
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first_source, first_manifest = self.adapt(root, records, limit=4, split_seed=7)
            second_source, second_manifest = self.adapt(root, records, limit=4, split_seed=7)
        self.assertEqual(artifact_bytes(first_source), artifact_bytes(second_source))
        self.assertEqual(artifact_bytes(first_manifest), artifact_bytes(second_manifest))

    def test_invalid_source_structures_fail_closed(self):
        mutations = []

        mismatched = longmem_record(1)
        mismatched["haystack_dates"] = mismatched["haystack_dates"][:-1]
        mutations.append(([mismatched], "length aligned"))

        missing_gold = longmem_record(1)
        missing_gold["answer_session_ids"] = ["absent"]
        mutations.append(([missing_gold], "observed 0"))

        ambiguous_gold = longmem_record(1)
        ambiguous_gold["haystack_session_ids"][0] = ambiguous_gold["answer_session_ids"][0]
        mutations.append(([ambiguous_gold], "observed 2"))

        invalid_flag = longmem_record(1)
        invalid_flag["haystack_sessions"][0][0]["has_answer"] = "yes"
        mutations.append(([invalid_flag], "expected boolean"))

        invalid_weekday = longmem_record(1)
        invalid_weekday["haystack_dates"][0] = "2024/01/02 (Wed) 09:00"
        mutations.append(([invalid_weekday], "weekday does not match"))

        duplicate_questions = [longmem_record(1), longmem_record(1)]
        mutations.append((duplicate_questions, "duplicate question id"))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, (records, message) in enumerate(mutations):
                path = root / f"invalid-{index}.json"
                path.write_text(stable_json(records) + "\n", encoding="utf-8")
                with self.subTest(message=message):
                    with self.assertRaisesRegex(ValidationError, message):
                        load_longmem_records(path)

    def test_source_sha_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            source, _ = self.write_source(Path(directory))
            with self.assertRaisesRegex(ValidationError, "source SHA-256"):
                adapt_longmem(
                    source,
                    execution(),
                    expected_source_sha256="0" * 64,
                    limit=2,
                    split_seed=1,
                )

    def test_cli_freezes_source_and_manifest_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, source_sha = self.write_source(root)
            execution_path = root / "execution.json"
            execution_path.write_text(stable_json(execution()) + "\n", encoding="utf-8")
            output_source = root / "slice.json"
            output_manifest = root / "manifest.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(
                    [
                        "adapt-longmem-memory",
                        "--source",
                        str(source),
                        "--expected-source-sha256",
                        source_sha,
                        "--execution",
                        str(execution_path),
                        "--output-source",
                        str(output_source),
                        "--output-manifest",
                        str(output_manifest),
                        "--limit",
                        "4",
                        "--split-seed",
                        "17",
                    ]
                )
            self.assertEqual(code, 0)
            self.assertIn("cases=4", stdout.getvalue())
            manifest = json.loads(output_manifest.read_text(encoding="utf-8"))
            self.assertEqual(
                manifest["dataset"]["source_sha256"],
                hashlib.sha256(output_source.read_bytes()).hexdigest(),
            )
            validate_manifest(manifest)

    def test_cli_refuses_aliasing_or_overwriting_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, source_sha = self.write_source(root)
            execution_path = root / "execution.json"
            execution_path.write_text(stable_json(execution()) + "\n", encoding="utf-8")
            base = [
                "adapt-longmem-memory",
                "--source",
                str(source),
                "--expected-source-sha256",
                source_sha,
                "--execution",
                str(execution_path),
                "--limit",
                "2",
            ]
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(
                    main(
                        base
                        + [
                            "--output-source",
                            str(source),
                            "--output-manifest",
                            str(root / "manifest.json"),
                        ]
                    ),
                    2,
                )
            self.assertIn("overwrite an input artifact", stderr.getvalue())

            shared = root / "shared.json"
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(
                    main(
                        base
                        + [
                            "--output-source",
                            str(shared),
                            "--output-manifest",
                            str(shared),
                        ]
                    ),
                    2,
                )
            self.assertIn("output paths must be distinct", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
