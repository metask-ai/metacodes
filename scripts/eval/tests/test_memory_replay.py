import contextlib
import copy
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.cli import main
from scripts.eval.memory_benchmark import summarize_memory, write_memory_rows
from scripts.eval.memory_replay import (
    load_manifest,
    load_observations,
    load_runtime_receipt,
    replay_observations,
    validate_manifest,
)
from scripts.eval.model import ValidationError, stable_json


REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = REPO_ROOT / "evals" / "memory" / "fixtures"
MANIFEST_PATH = FIXTURES / "smoke-manifest.json"
OBSERVATIONS_PATH = FIXTURES / "smoke-observations.jsonl"
SOURCE_PATH = FIXTURES / "smoke-source.json"
RECEIPT_PATH = FIXTURES / "smoke-runtime-receipt.json"


def raw_manifest():
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def observations():
    return [copy.deepcopy(row) for row in load_observations(OBSERVATIONS_PATH)]


class MemoryReplayTest(unittest.TestCase):
    def replay(self, observed=None, manifest=None, source=SOURCE_PATH, receipt=None):
        manifest_value = manifest if manifest is not None else load_manifest(MANIFEST_PATH)
        observation_value = observed if observed is not None else observations()
        receipt_value = (
            copy.deepcopy(receipt)
            if receipt is not None
            else copy.deepcopy(load_runtime_receipt(RECEIPT_PATH))
        )
        if observed is not None:
            receipt_value["observations_sha256"] = hashlib.sha256(
                stable_json(observation_value).encode("utf-8")
            ).hexdigest()
        return replay_observations(
            manifest_value,
            observation_value,
            dataset_source=source,
            runtime_receipt=receipt_value,
        )

    def test_smoke_replay_is_complete_and_binds_frozen_identity(self):
        rows = self.replay()
        self.assertEqual([row["sequence"] for row in rows], list(range(8)))
        self.assertEqual(len(rows), 4 * 2 * 1)
        self.assertEqual({row["identity"]["adapter_id"] for row in rows}, {"synthetic-replay"})
        self.assertEqual({row["identity"]["split_seed"] for row in rows}, {20260806})
        self.assertEqual(len({row["identity"]["manifest_sha256"] for row in rows}), 1)
        self.assertEqual(len({row["identity"]["runtime_receipt_sha256"] for row in rows}), 1)
        summary = summarize_memory(rows)
        self.assertEqual(
            summary["groups"]["episodic_recall/tinykg_lexical/test"]["outcome_success_rate"],
            1.0,
        )
        self.assertEqual(
            summary["procedural_transfer"]["tinykg_lexical"]["offline_gain_over_cold_start"],
            1.0,
        )

    def test_replay_output_is_byte_deterministic(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.jsonl"
            second = Path(directory) / "second.jsonl"
            write_memory_rows(first, self.replay())
            write_memory_rows(second, self.replay())
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_cli_replay_smoke_writes_rows_and_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "rows.jsonl"
            markdown = root / "report.md"
            summary = root / "summary.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                code = main(
                    [
                        "replay-memory",
                        "--manifest",
                        str(MANIFEST_PATH),
                        "--observations",
                        str(OBSERVATIONS_PATH),
                        "--dataset-source",
                        str(SOURCE_PATH),
                        "--runtime-receipt",
                        str(RECEIPT_PATH),
                        "--output",
                        str(output),
                        "--markdown",
                        str(markdown),
                        "--json",
                        str(summary),
                    ]
                )
            self.assertEqual(code, 0)
            self.assertIn("rows=8", stdout.getvalue())
            self.assertEqual(len(output.read_text(encoding="utf-8").splitlines()), 8)
            self.assertIn("procedural_transfer", markdown.read_text(encoding="utf-8"))
            self.assertEqual(json.loads(summary.read_text(encoding="utf-8"))["rows"], 8)

    def test_cli_replay_refuses_to_overwrite_inputs_or_alias_outputs(self):
        base = [
            "replay-memory",
            "--manifest",
            str(MANIFEST_PATH),
            "--observations",
            str(OBSERVATIONS_PATH),
            "--dataset-source",
            str(SOURCE_PATH),
            "--runtime-receipt",
            str(RECEIPT_PATH),
        ]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(main(base + ["--output", str(MANIFEST_PATH)]), 2)
        self.assertIn("overwrite an input artifact", stderr.getvalue())

        with tempfile.TemporaryDirectory() as directory:
            shared = Path(directory) / "shared.json"
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(
                    main(
                        base
                        + [
                            "--output",
                            str(shared),
                            "--json",
                            str(shared),
                        ]
                    ),
                    2,
                )
            self.assertIn("output paths must be distinct", stderr.getvalue())

    def test_dataset_source_sha_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "source.json"
            changed.write_text('{"tampered":true}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
                self.replay(source=changed)

    def test_runtime_receipt_rejects_identity_or_observation_drift(self):
        receipt = copy.deepcopy(load_runtime_receipt(RECEIPT_PATH))
        receipt["model_id"] = "different-model"
        with self.assertRaisesRegex(ValidationError, "model_id"):
            self.replay(receipt=receipt)

        observed = observations()
        observed[0]["prediction"] = "tampered"
        with self.assertRaisesRegex(ValidationError, "observations_sha256"):
            replay_observations(
                load_manifest(MANIFEST_PATH),
                observed,
                dataset_source=SOURCE_PATH,
                runtime_receipt=load_runtime_receipt(RECEIPT_PATH),
            )

    def test_missing_and_duplicate_observations_fail_closed(self):
        observed = observations()
        with self.assertRaisesRegex(ValidationError, "incomplete schedule"):
            self.replay(observed=observed[:-1])

        duplicated = observations()
        duplicated[-1] = copy.deepcopy(duplicated[0])
        with self.assertRaisesRegex(ValidationError, "duplicate schedule row"):
            self.replay(observed=duplicated)

    def test_observations_cannot_inject_gold_or_success(self):
        for field, value in (("gold_answers", ["red"]), ("success", True)):
            observed = observations()
            observed[0][field] = value
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValidationError, "unknown fields"):
                    self.replay(observed=observed)

    def test_manifest_rejects_treatment_leakage_and_unfrozen_order(self):
        manifest = raw_manifest()
        manifest["cases"][0]["prompt"] += " Use TinyKG."
        with self.assertRaisesRegex(ValidationError, "leaks treatment terms"):
            validate_manifest(manifest)

        manifest = raw_manifest()
        manifest["execution"]["arms"][1]["id"] = "experimental_graph"
        for entry in manifest["schedule"]:
            if entry["arm"] == "tinykg_lexical":
                entry["arm"] = "experimental_graph"
        manifest["cases"][0]["prompt"] += " experimental_graph"
        with self.assertRaisesRegex(ValidationError, "leaks treatment terms"):
            validate_manifest(manifest)

        manifest = raw_manifest()
        manifest["schedule"][5]["case_id"] = "procedural-config-offline-1"
        manifest["schedule"][7]["case_id"] = "procedural-config-online-1"
        with self.assertRaisesRegex(ValidationError, "runs offline before online"):
            validate_manifest(manifest)

    def test_invalid_evaluator_remains_auditable_and_unscored(self):
        observed = observations()
        observed[1]["evaluator"] = {
            "status": "invalid",
            "invalid_reason": "fixture grader unavailable",
            "deterministic_success": None,
        }
        rows = self.replay(observed=observed)
        row = rows[1]
        self.assertEqual(row["execution"]["status"], "completed")
        self.assertEqual(row["evaluator"]["status"], "invalid")
        self.assertEqual(row["outcome"]["status"], "unscored")
        self.assertIsNone(row["outcome"]["success"])

    def test_invalid_procedural_execution_does_not_fake_success(self):
        observed = observations()
        observed[4]["execution"] = {
            "status": "invalid",
            "invalid_reason": "workspace setup failed",
        }
        observed[4]["evaluator"]["deterministic_success"] = None
        observed[4]["prediction"] = ""
        row = self.replay(observed=observed)[4]
        self.assertEqual(row["outcome"]["status"], "unscored")
        self.assertIsNone(row["outcome"]["success"])

        observed = observations()
        observed[5]["evaluator"]["deterministic_success"] = None
        with self.assertRaisesRegex(ValidationError, "must report a boolean"):
            self.replay(observed=observed)

    def test_offline_transfer_is_bound_to_usable_online_graph(self):
        observed = observations()
        observed[7]["graph"]["revision"] = "fixture-r-other"
        with self.assertRaisesRegex(ValidationError, "offline graph revision"):
            self.replay(observed=observed)

        observed = observations()
        observed[5]["execution"] = {
            "status": "invalid",
            "invalid_reason": "online workspace failed",
        }
        observed[5]["evaluator"]["deterministic_success"] = None
        with self.assertRaisesRegex(ValidationError, "invalid online predecessor"):
            self.replay(observed=observed)

    def test_empty_prediction_is_kept_as_a_scored_failure(self):
        observed = observations()
        observed[0]["prediction"] = ""
        row = self.replay(observed=observed)[0]
        self.assertEqual(row["execution"]["status"], "completed")
        self.assertEqual(row["outcome"]["status"], "fail")
        self.assertFalse(row["outcome"]["success"])

    def test_no_memory_and_offline_leakage_fail_closed(self):
        observed = observations()
        observed[0]["retrieval"]["retrieved_evidence_ids"] = ["episode:preference:1"]
        with self.assertRaisesRegex(ValidationError, "must not report retrieved"):
            self.replay(observed=observed)

        observed = observations()
        observed[4]["memory"]["write_mode"] = "online"
        observed[4]["memory"]["inserted_nodes"] = 1
        with self.assertRaisesRegex(ValidationError, "no_memory must disable memory writes"):
            self.replay(observed=observed)

        observed = observations()
        observed[7]["memory"]["inserted_nodes"] = 1
        with self.assertRaisesRegex(ValidationError, "read_only memory must not insert nodes"):
            self.replay(observed=observed)


if __name__ == "__main__":
    unittest.main()
