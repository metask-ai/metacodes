import contextlib
import copy
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.cli import main
from scripts.eval.memory_procedural_adapter import (
    ADAPTER_ID,
    ADAPTER_REVISION,
    SELECTION_ALGORITHM,
    adapt_procedural,
    artifact_bytes,
    evaluate_workspace,
    select_families,
    validate_validator_bundle,
)
from scripts.eval.memory_replay import validate_manifest
from scripts.eval.model import ValidationError, stable_json


ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "evals/memory/fixtures/procedural-coding-source.json"
EXECUTION = ROOT / "evals/memory/fixtures/procedural-adapter-smoke-execution.json"


def load_fixture() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def execution() -> dict:
    return json.loads(EXECUTION.read_text(encoding="utf-8"))


class ProceduralMemoryAdapterTest(unittest.TestCase):
    def write_source(self, root: Path, value: dict) -> tuple[Path, str]:
        path = root / "procedural.json"
        path.write_text(stable_json(value) + "\n", encoding="utf-8")
        return path, hashlib.sha256(path.read_bytes()).hexdigest()

    def adapt_value(self, root: Path, value: dict, *, limit_families=4):
        source, source_sha = self.write_source(root, value)
        return adapt_procedural(
            source,
            execution(),
            expected_source_sha256=source_sha,
            limit_families=limit_families,
            split_seed=20260806,
        )

    def test_real_fixture_freezes_public_workspaces_hidden_validators_and_causal_schedule(self):
        fixture_sha = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
        source_slice, validators, manifest = adapt_procedural(
            FIXTURE,
            execution(),
            expected_source_sha256=fixture_sha,
            limit_families=2,
            split_seed=20260806,
        )
        self.assertEqual(source_slice["adapter_id"], ADAPTER_ID)
        self.assertEqual(source_slice["adapter_revision"], ADAPTER_REVISION)
        self.assertEqual(source_slice["selection"]["algorithm"], SELECTION_ALGORITHM)
        self.assertEqual(source_slice["selection"]["selected_families"], 2)
        self.assertEqual(source_slice["selection"]["selected_cases"], 6)
        self.assertEqual(len(validators["cases"]), 6)
        self.assertEqual(len(manifest["cases"]), 6)
        self.assertEqual(len(manifest["schedule"]), 12)
        self.assertEqual(
            manifest["dataset"]["source_sha256"],
            hashlib.sha256(artifact_bytes(source_slice)).hexdigest(),
        )
        validate_validator_bundle(validators, source_slice)
        validate_manifest(manifest)

        public_json = stable_json(source_slice)
        self.assertNotIn("oracle_files", public_json)
        self.assertNotIn('"validator":', public_json)
        self.assertNotIn("workspace_assertions_v1", public_json)
        for family in source_slice["families"]:
            splits = [case["split"] for case in family["cases"]]
            self.assertEqual(splits.count("online"), 1)
            self.assertGreaterEqual(splits.count("offline"), 2)
            self.assertEqual(splits[0], "online")
            for case in family["cases"]:
                self.assertEqual(
                    case["workspace"]["fingerprint"],
                    next(
                        item["workspace_sha256"]
                        for item in validators["cases"]
                        if item["case_id"] == case["id"]
                    ),
                )

        schedule_positions = {
            (entry["case_id"], entry["arm"]): entry["sequence"]
            for entry in manifest["schedule"]
        }
        for family in source_slice["families"]:
            online = next(case for case in family["cases"] if case["split"] == "online")
            offline = [case for case in family["cases"] if case["split"] == "offline"]
            for arm in ("no_memory", "tinykg_lexical"):
                self.assertTrue(
                    all(
                        schedule_positions[(online["id"], arm)]
                        < schedule_positions[(case["id"], arm)]
                        for case in offline
                    )
                )

    def test_adapter_is_byte_deterministic_and_family_selection_is_input_order_independent(self):
        value = load_fixture()
        with tempfile.TemporaryDirectory() as directory:
            first = self.adapt_value(Path(directory), value, limit_families=1)
            repeated = self.adapt_value(Path(directory), value, limit_families=1)
            reversed_value = copy.deepcopy(value)
            reversed_value["families"].reverse()
            second = self.adapt_value(Path(directory), reversed_value, limit_families=1)
        for first_artifact, repeated_artifact in zip(first, repeated):
            self.assertEqual(artifact_bytes(first_artifact), artifact_bytes(repeated_artifact))
        self.assertEqual(
            [family["id"] for family in first[0]["families"]],
            [family["id"] for family in second[0]["families"]],
        )
        # Raw source order is intentionally hash-bound, so the upstream digest
        # changes.  Selection and the selected family payload remain stable.
        self.assertEqual(first[0]["families"], second[0]["families"])
        self.assertEqual(first[1]["cases"], second[1]["cases"])
        self.assertEqual(first[2]["cases"], second[2]["cases"])
        self.assertEqual(first[2]["schedule"], second[2]["schedule"])

    def test_each_family_requires_exactly_one_online_and_multiple_offline_siblings(self):
        value = load_fixture()
        value["families"][0]["cases"][1]["split"] = "online"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValidationError, "exactly one online"):
                self.adapt_value(Path(directory), value)

        value = load_fixture()
        value["families"][0]["cases"] = value["families"][0]["cases"][:2]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValidationError, "at least two offline"):
                self.adapt_value(Path(directory), value)

    def test_template_binding_and_treatment_leakage_fail_closed(self):
        value = load_fixture()
        del value["families"][0]["cases"][0]["bindings"]["old"]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValidationError, "template bindings"):
                self.adapt_value(Path(directory), value)

        value = load_fixture()
        value["families"][0]["cases"][0]["bindings"]["new"] = "tinykg"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValidationError, "leaks treatment terms"):
                self.adapt_value(Path(directory), value)

    def test_workspace_paths_and_known_solution_are_validated(self):
        value = load_fixture()
        value["families"][0]["cases"][0]["workspace"]["files"][0]["path"] = "../escape"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValidationError, "inside the materialized workspace"):
                self.adapt_value(Path(directory), value)

        value = load_fixture()
        value["families"][0]["cases"][0]["oracle_files"][0]["content"] = "wrong"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValidationError, "known solution fails"):
                self.adapt_value(Path(directory), value)

    def test_workspace_validator_rejects_baseline_file_set_changes_and_partial_edits(self):
        fixture_sha = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
        source_slice, validators, _ = adapt_procedural(
            FIXTURE,
            execution(),
            expected_source_sha256=fixture_sha,
            limit_families=2,
            split_seed=20260806,
        )
        public = source_slice["families"][0]["cases"][0]
        validator = next(
            item["validator"]
            for item in validators["cases"]
            if item["case_id"] == public["id"]
        )
        baseline = {item["path"]: item["content"] for item in public["workspace"]["files"]}
        passed, failures = evaluate_workspace(baseline, baseline, validator)
        self.assertFalse(passed)
        self.assertTrue(any("required paths" in failure for failure in failures))
        with_extra = dict(baseline)
        with_extra["unexpected.txt"] = "leak"
        passed, failures = evaluate_workspace(baseline, with_extra, validator)
        self.assertFalse(passed)
        self.assertTrue(any("file set changed" in failure for failure in failures))

    def test_validator_bundle_tampering_is_detected(self):
        fixture_sha = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
        source_slice, validators, _ = adapt_procedural(
            FIXTURE,
            execution(),
            expected_source_sha256=fixture_sha,
            limit_families=2,
            split_seed=20260806,
        )
        tampered = copy.deepcopy(validators)
        tampered["cases"][0]["validator"]["checks"][0]["value"] += "tamper"
        with self.assertRaisesRegex(ValidationError, "do not match fingerprint"):
            validate_validator_bundle(tampered, source_slice)

        tampered = copy.deepcopy(validators)
        tampered["dataset_source_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValidationError, "does not bind"):
            validate_validator_bundle(tampered, source_slice)

        tampered = copy.deepcopy(validators)
        tampered["cases"][0]["family_id"] = "wrong-family"
        with self.assertRaisesRegex(ValidationError, "does not match public family"):
            validate_validator_bundle(tampered, source_slice)

        tampered_source = copy.deepcopy(source_slice)
        tampered_source["families"][0]["cases"][0]["workspace"]["files"][0]["content"] += "tamper"
        tampered_bundle = copy.deepcopy(validators)
        tampered_bundle["dataset_source_sha256"] = hashlib.sha256(
            artifact_bytes(tampered_source)
        ).hexdigest()
        with self.assertRaisesRegex(ValidationError, "does not match public file contents"):
            validate_validator_bundle(tampered_bundle, tampered_source)

    def test_source_hash_mismatch_and_invalid_selection_fail_before_outputs(self):
        with self.assertRaisesRegex(ValidationError, "SHA-256"):
            adapt_procedural(
                FIXTURE,
                execution(),
                expected_source_sha256="0" * 64,
                limit_families=2,
                split_seed=20260806,
            )
        with self.assertRaisesRegex(ValidationError, "requested 7 families"):
            select_families(load_fixture()["families"], limit_families=7, split_seed=1)

    def test_cli_writes_three_distinct_artifacts_and_rejects_overlap(self):
        fixture_sha = hashlib.sha256(FIXTURE.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output_source = root / "source.json"
            output_validators = root / "validators.json"
            output_manifest = root / "manifest.json"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                rc = main(
                    [
                        "adapt-procedural-memory",
                        "--source",
                        str(FIXTURE),
                        "--expected-source-sha256",
                        fixture_sha,
                        "--execution",
                        str(EXECUTION),
                        "--output-source",
                        str(output_source),
                        "--output-validators",
                        str(output_validators),
                        "--output-manifest",
                        str(output_manifest),
                    ]
                )
            self.assertEqual(rc, 0)
            self.assertIn("families=2 cases=6", stdout.getvalue())
            source_slice = json.loads(output_source.read_text(encoding="utf-8"))
            validators = json.loads(output_validators.read_text(encoding="utf-8"))
            manifest = json.loads(output_manifest.read_text(encoding="utf-8"))
            validate_validator_bundle(validators, source_slice)
            validate_manifest(manifest)

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                overlap_rc = main(
                    [
                        "adapt-procedural-memory",
                        "--source",
                        str(FIXTURE),
                        "--expected-source-sha256",
                        fixture_sha,
                        "--execution",
                        str(EXECUTION),
                        "--output-source",
                        str(output_source),
                        "--output-validators",
                        str(output_source),
                        "--output-manifest",
                        str(output_manifest),
                    ]
                )
            self.assertEqual(overlap_rc, 2)
            self.assertIn("output paths must be distinct", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
