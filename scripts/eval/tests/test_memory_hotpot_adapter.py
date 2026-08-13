import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.cli import main
from scripts.eval.memory_hotpot_adapter import (
    ADAPTER_ID,
    ADAPTER_REVISION,
    SELECTION_ALGORITHM,
    adapt_hotpot,
    artifact_bytes,
    load_hotpot_records,
    select_records,
)
from scripts.eval.memory_benchmark import QA_EXECUTION_INSTRUCTIONS, qa_execution_prompt
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


def hotpot_record(index: int) -> dict:
    source_id = f"5a8b57f25542995d1e6f{index:04x}"
    return {
        "_id": source_id,
        "question": f"Which bridge connects subject {index} to its birthplace?",
        "answer": f"Bridge {index}",
        "type": "bridge",
        "level": "hard",
        "supporting_facts": [[f"Subject {index}", 0], [f"Bridge {index}", 1]],
        "context": [
            [
                f"Bridge {index}",
                [
                    f"Bridge {index} is a named structure.",
                    f"Bridge {index} is located in City {index}.",
                ],
            ],
            [
                f"Subject {index}",
                [
                    f"Subject {index} was born in City {index}.",
                    f"Subject {index} later moved elsewhere.",
                ],
            ],
            ["Distractor", ["This sentence is deliberately irrelevant."]],
        ],
    }


class HotpotMemoryAdapterTest(unittest.TestCase):
    def write_source(self, root: Path, records=None) -> tuple[Path, str]:
        path = root / "hotpot.json"
        value = records if records is not None else [hotpot_record(i) for i in range(6)]
        path.write_text(stable_json(value) + "\n", encoding="utf-8")
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def adapt(self, root: Path, records=None, *, limit=3, split_seed=20260806):
        source, source_sha = self.write_source(root, records)
        source_slice, manifest = adapt_hotpot(
            source,
            execution(),
            expected_source_sha256=source_sha,
            limit=limit,
            split_seed=split_seed,
            source_url="https://example.invalid/hotpot.json",
            source_revision="fixture-v1",
        )
        return source, source_slice, manifest

    def test_official_shape_builds_hidden_gold_manifest_and_evidence_slice(self):
        with tempfile.TemporaryDirectory() as directory:
            source, source_slice, manifest = self.adapt(Path(directory))
            source_size = source.stat().st_size
        self.assertEqual(source_slice["adapter_id"], ADAPTER_ID)
        self.assertEqual(source_slice["adapter_revision"], ADAPTER_REVISION)
        self.assertEqual(source_slice["selection"]["algorithm"], SELECTION_ALGORITHM)
        self.assertEqual(source_slice["selection"]["selected_cases"], 3)
        self.assertEqual(source_slice["upstream"]["source_bytes"], source_size)
        self.assertEqual(len(manifest["cases"]), 3)
        self.assertEqual(len(manifest["schedule"]), 6)
        self.assertEqual(
            manifest["dataset"]["source_sha256"],
            hashlib.sha256(artifact_bytes(source_slice)).hexdigest(),
        )
        validate_manifest(manifest)
        for source_case, manifest_case in zip(source_slice["cases"], manifest["cases"]):
            self.assertEqual(
                manifest_case["prompt"], qa_execution_prompt(source_case["question"])
            )
            self.assertTrue(manifest_case["prompt"].endswith(QA_EXECUTION_INSTRUCTIONS))
            self.assertNotIn("answer", source_case)
            self.assertNotIn("expected_evidence_ids", source_case)
            self.assertNotIn(manifest_case["gold_answers"][0], manifest_case["prompt"])
            evidence = {
                sentence["id"]: sentence
                for document in source_case["documents"]
                for sentence in document["sentences"]
            }
            self.assertTrue(all("supporting" not in sentence for sentence in evidence.values()))
            self.assertEqual(len(manifest_case["expected_evidence_ids"]), 2)
            self.assertTrue(set(manifest_case["expected_evidence_ids"]).issubset(evidence))

    def test_hash_selection_does_not_depend_on_input_order(self):
        records = [hotpot_record(i) for i in range(10)]
        forward = select_records(records, limit=4, split_seed=7)
        reverse = select_records(reversed(records), limit=4, split_seed=7)
        self.assertEqual(
            [row["_id"] for row in forward],
            [row["_id"] for row in reverse],
        )

    def test_artifacts_are_byte_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, first_source, first_manifest = self.adapt(root, split_seed=99)
            _, second_source, second_manifest = self.adapt(root, split_seed=99)
        self.assertEqual(artifact_bytes(first_source), artifact_bytes(second_source))
        self.assertEqual(artifact_bytes(first_manifest), artifact_bytes(second_manifest))

    def test_source_sha_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            source, _ = self.write_source(Path(directory))
            with self.assertRaisesRegex(ValidationError, "source SHA-256"):
                adapt_hotpot(
                    source,
                    execution(),
                    expected_source_sha256="0" * 64,
                    limit=2,
                    split_seed=1,
                )

    def test_invalid_supports_and_duplicate_source_ids_fail_closed(self):
        mutations = []

        missing_title = [hotpot_record(1)]
        missing_title[0]["supporting_facts"][0][0] = "Absent title"
        mutations.append((missing_title, "absent from context"))

        out_of_range = [hotpot_record(1)]
        out_of_range[0]["supporting_facts"][0][1] = 20
        mutations.append((out_of_range, "out of range"))

        one_support = [hotpot_record(1)]
        one_support[0]["supporting_facts"] = one_support[0]["supporting_facts"][:1]
        mutations.append((one_support, "at least two"))

        empty_support = [hotpot_record(1)]
        empty_support[0]["context"][1][1][0] = ""
        mutations.append((empty_support, "supporting fact text must not be empty"))

        duplicate_ids = [hotpot_record(1), hotpot_record(1)]
        mutations.append((duplicate_ids, "duplicate source id"))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, (records, message) in enumerate(mutations):
                path = root / f"invalid-{index}.json"
                path.write_text(stable_json(records) + "\n", encoding="utf-8")
                with self.subTest(message=message):
                    with self.assertRaisesRegex(ValidationError, message):
                        load_hotpot_records(path)

    def test_empty_distractor_sentence_preserves_official_sentence_indices(self):
        records = [hotpot_record(1)]
        records[0]["context"][2][1][0] = ""
        with tempfile.TemporaryDirectory() as directory:
            path, _ = self.write_source(Path(directory), records)
            loaded = load_hotpot_records(path)
        self.assertEqual(loaded[0]["context"][2][1][0], "")

    def test_source_bound_quarantine_excludes_only_exact_known_defect(self):
        records = [hotpot_record(i) for i in range(4)]
        bad = records[2]
        bad["supporting_facts"][1][1] = 902
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, source_sha = self.write_source(root, records)
            policy = {
                "schema_version": 1,
                "dataset_sha256": source_sha,
                "exclusions": [
                    {
                        "source_id": bad["_id"],
                        "issue": "support_sentence_out_of_range",
                        "title": bad["supporting_facts"][1][0],
                        "sentence_id": 902,
                        "observed_sentence_count": 2,
                    }
                ],
            }
            source_slice, manifest = adapt_hotpot(
                source,
                execution(),
                expected_source_sha256=source_sha,
                limit=2,
                split_seed=13,
                source_policy=policy,
            )
            self.assertEqual(source_slice["selection"]["eligible_cases"], 3)
            self.assertEqual(source_slice["selection"]["excluded_cases"], 1)
            self.assertEqual(source_slice["source_policy"], policy)
            self.assertNotIn(bad["_id"], [case["source_id"] for case in source_slice["cases"]])
            validate_manifest(manifest)

            wrong_policy = json.loads(stable_json(policy))
            wrong_policy["exclusions"][0]["title"] = "Wrong title"
            with self.assertRaisesRegex(ValidationError, "out of range"):
                load_hotpot_records(source, source_policy=wrong_policy)

            clean_source, clean_sha = self.write_source(
                root,
                [hotpot_record(0), hotpot_record(1), hotpot_record(3)],
            )
            unused_policy = json.loads(stable_json(policy))
            unused_policy["dataset_sha256"] = clean_sha
            unused_policy["exclusions"][0] = {
                "source_id": hotpot_record(0)["_id"],
                "issue": "support_sentence_out_of_range",
                "title": hotpot_record(0)["supporting_facts"][1][0],
                "sentence_id": 902,
                "observed_sentence_count": 2,
            }
            with self.assertRaisesRegex(ValidationError, "did not match"):
                load_hotpot_records(clean_source, source_policy=unused_policy)

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
                        "adapt-hotpot-memory",
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
                        "--source-url",
                        "https://example.invalid/hotpot.json",
                        "--source-revision",
                        "fixture-v1",
                    ]
                )
            self.assertEqual(code, 0)
            self.assertIn("cases=4", stdout.getvalue())
            source_value = json.loads(output_source.read_text(encoding="utf-8"))
            manifest = json.loads(output_manifest.read_text(encoding="utf-8"))
            self.assertEqual(
                manifest["dataset"]["source_sha256"],
                hashlib.sha256(output_source.read_bytes()).hexdigest(),
            )
            self.assertEqual(source_value["selection"]["split_seed"], 17)
            validate_manifest(manifest)

    def test_cli_refuses_aliasing_or_overwriting_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, source_sha = self.write_source(root)
            execution_path = root / "execution.json"
            execution_path.write_text(stable_json(execution()) + "\n", encoding="utf-8")
            base = [
                "adapt-hotpot-memory",
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
