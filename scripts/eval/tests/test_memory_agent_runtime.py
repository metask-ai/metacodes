import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.memory_agent_runtime import (
    _project_domain,
    _xxhash64,
)
from scripts.eval.memory_replay import (
    _artifact_tree_digest,
    load_manifest,
    load_observations,
    load_runtime_receipt,
    replay_observations,
    validate_runtime_artifacts,
    validate_runtime_receipt,
)
from scripts.eval.model import ValidationError, stable_json


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "evals/memory/fixtures"


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


class MemoryAgentRuntimeContractTest(unittest.TestCase):
    def test_dependency_free_xxhash_matches_zig_vectors(self):
        vectors = {
            b"": "ef46db3751d8e999",
            b"x": "5c80c09683041123",
            b"hello": "26c7827d889f6da3",
            b"a" * 31: "fe47067cda802916",
            b"a" * 32: "856e843298f99ad7",
            b"a" * 33: "18f3ff0c21e3b24b",
            b"a" * 100: "375041e8b1decfb3",
        }
        for payload, expected in vectors.items():
            with self.subTest(length=len(payload)):
                self.assertEqual(f"{_xxhash64(payload):016x}", expected)
        root = Path("/tmp/native-memory-project")
        resolved = str(root.resolve())
        expected_domain = f"{root.name}-{_xxhash64(resolved.encode()):016x}"[: len(root.name) + 9]
        self.assertEqual(_project_domain(root), expected_domain)

    def _v2(self):
        manifest = load_manifest(FIXTURES / "smoke-manifest.json")
        observations = [
            copy.deepcopy(row)
            for row in load_observations(FIXTURES / "smoke-observations.jsonl")
        ]
        for observation in observations:
            observation["trajectory"]["model_requests"] = 1
        base = copy.deepcopy(load_runtime_receipt(FIXTURES / "smoke-runtime-receipt.json"))
        base.update(
            {
                "schema_version": 2,
                "observations_sha256": hashlib.sha256(
                    stable_json(observations).encode("utf-8")
                ).hexdigest(),
                "execution_mode": "native-agent-loop-scripted-wiring-smoke",
                "quality_evidence": False,
                "metacodes_binary_sha256": digest("metacodes"),
                "tinykg_binary_sha256": digest("tinykg"),
                "external_network_calls": 0,
                "paid_cost_usd": 0.0,
                "estimated_cost_usd": 0.0,
                "rollouts": [],
            }
        )
        for sequence, (entry, observation) in enumerate(
            zip(manifest["schedule"], observations)
        ):
            tinykg = entry["arm"] == "tinykg_lexical"
            base["rollouts"].append(
                {
                    "sequence": sequence,
                    "case_id": entry["case_id"],
                    "trial": entry["trial"],
                    "arm": entry["arm"],
                    "run_id": f"runtime:{sequence}",
                    "task_fingerprint": hashlib.sha256(
                        stable_json(
                            next(
                                case
                                for case in manifest["cases"]
                                if case["id"] == entry["case_id"]
                            )
                        ).encode("utf-8")
                    ).hexdigest(),
                    "metacodes_binary_sha256": digest("metacodes"),
                    "tinykg_binary_sha256": digest("tinykg") if tinykg else None,
                    "native_events_sha256": digest(f"events:{sequence}"),
                    "result_sha256": digest(f"result:{sequence}"),
                    "stderr_sha256": digest(f"stderr:{sequence}"),
                    "cassette_sha256": digest(f"cassette:{sequence}"),
                    "transcript_sha256": digest(f"transcript:{sequence}"),
                    "workspace_sha256": digest(f"workspace:{sequence}"),
                    "artifact_paths": {
                        "native_events": f"rollouts/{sequence}/native-events.jsonl",
                        "result": f"rollouts/{sequence}/stdout.ndjson",
                        "stderr": f"rollouts/{sequence}/stderr.log",
                        "cassette": f"rollouts/{sequence}/cassette",
                        "transcript": f"rollouts/{sequence}/sealed-home",
                        "workspace": f"rollouts/{sequence}/workspace",
                        "store": f"stores/{sequence}.kg" if tinykg else None,
                    },
                    "store_revision_before": digest(f"store:{sequence}") if tinykg else "none",
                    "store_revision_after": digest(f"store:{sequence}") if tinykg else "none",
                    "raw_store_digest_before": digest(f"raw-store:{sequence}") if tinykg else "none",
                    "raw_store_digest_after": digest(f"raw-store:{sequence}") if tinykg else "none",
                    "stop_reason": "end_turn",
                    "provider_mode": "scripted-local",
                    "provider_requests": 1,
                    "external_network_calls": 0,
                    "paid_cost_usd": 0.0,
                    "estimated_cost_usd": 0.0,
                    "observation_sha256": hashlib.sha256(
                        stable_json(observation).encode("utf-8")
                    ).hexdigest(),
                    "host_elapsed_ms": 1.0,
                }
            )
        return manifest, observations, base

    def _materialize_artifacts(self, root, receipt):
        for rollout in receipt["rollouts"]:
            paths = rollout["artifact_paths"]
            for path_key, hash_key in (
                ("native_events", "native_events_sha256"),
                ("result", "result_sha256"),
                ("stderr", "stderr_sha256"),
            ):
                path = root / paths[path_key]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"{path_key}:{rollout['sequence']}\n", encoding="utf-8")
                rollout[hash_key] = hashlib.sha256(path.read_bytes()).hexdigest()
            for path_key, hash_key in (
                ("cassette", "cassette_sha256"),
                ("transcript", "transcript_sha256"),
                ("workspace", "workspace_sha256"),
            ):
                path = root / paths[path_key]
                path.mkdir(parents=True)
                (path / "artifact.txt").write_text(
                    f"{path_key}:{rollout['sequence']}\n",
                    encoding="utf-8",
                )
                rollout[hash_key] = _artifact_tree_digest(path)
            if paths["store"] is not None:
                store = root / paths["store"]
                store.mkdir(parents=True)
                (store / "events.bin").write_bytes(f"store:{rollout['sequence']}".encode())
                raw_digest = _artifact_tree_digest(store)
                rollout["raw_store_digest_before"] = raw_digest
                rollout["raw_store_digest_after"] = raw_digest

    def test_v2_receipt_binds_native_rows_and_rejects_replay_laundering(self):
        manifest, observations, receipt = self._v2()
        validate_runtime_receipt(
            receipt,
            manifest,
            observations,
            manifest["dataset"]["source_sha256"],
        )

        mutations = []
        quality = copy.deepcopy(receipt)
        quality["quality_evidence"] = True
        mutations.append((quality, "quality_evidence"))

        remote = copy.deepcopy(receipt)
        remote["rollouts"][0]["external_network_calls"] = 1
        mutations.append((remote, "external_network_calls"))

        replay_only = copy.deepcopy(observations)
        replay_only[0]["trajectory"]["model_requests"] = 0
        receipt_for_replay = copy.deepcopy(receipt)
        receipt_for_replay["observations_sha256"] = hashlib.sha256(
            stable_json(replay_only).encode("utf-8")
        ).hexdigest()
        receipt_for_replay["rollouts"][0]["observation_sha256"] = hashlib.sha256(
            stable_json(replay_only[0]).encode("utf-8")
        ).hexdigest()
        with self.assertRaisesRegex(ValidationError, "model_requests"):
            validate_runtime_receipt(
                receipt_for_replay,
                manifest,
                replay_only,
                manifest["dataset"]["source_sha256"],
            )

        drift = copy.deepcopy(receipt)
        drift["rollouts"][1]["native_events_sha256"] = "0" * 64
        # A hash-shaped value is structurally valid; changing the observation
        # binding is what prevents a different run from masquerading as row 1.
        drift["rollouts"][1]["observation_sha256"] = "0" * 64
        mutations.append((drift, "observation_sha256"))

        for mutated, message in mutations:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValidationError, message):
                    validate_runtime_receipt(
                        mutated,
                        manifest,
                        observations,
                        manifest["dataset"]["source_sha256"],
                    )

    def test_v2_receipt_rejects_nonfinite_or_boolean_numeric_fields(self):
        manifest, observations, receipt = self._v2()
        mutations = []
        for field, value in (
            ("estimated_cost_usd", float("nan")),
            ("estimated_cost_usd", float("inf")),
            ("paid_cost_usd", False),
            ("external_network_calls", False),
        ):
            mutated = copy.deepcopy(receipt)
            mutated[field] = value
            mutations.append((mutated, field))
        elapsed = copy.deepcopy(receipt)
        elapsed["rollouts"][0]["host_elapsed_ms"] = float("nan")
        mutations.append((elapsed, "host_elapsed_ms"))
        for mutated, message in mutations:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValidationError, message):
                    validate_runtime_receipt(
                        mutated,
                        manifest,
                        observations,
                        manifest["dataset"]["source_sha256"],
                    )

    def test_v2_reopens_raw_artifacts_and_rejects_tampering(self):
        manifest, observations, receipt = self._v2()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._materialize_artifacts(root, receipt)
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(receipt, root)

            events = root / receipt["rollouts"][0]["artifact_paths"]["native_events"]
            events.write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "native_events_sha256"):
                validate_runtime_artifacts(receipt, root)

            events.write_text("native_events:0\n", encoding="utf-8")
            workspace = root / receipt["rollouts"][0]["artifact_paths"]["workspace"]
            (workspace / "late.lock").write_text("must be hashed\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "workspace_sha256"):
                validate_runtime_artifacts(receipt, root)

    def test_v2_rejects_artifact_path_escape_before_replay(self):
        manifest, observations, receipt = self._v2()
        receipt["rollouts"][0]["artifact_paths"]["native_events"] = "../outside"
        with self.assertRaisesRegex(ValidationError, "normalized relative POSIX path"):
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )

    def test_v2_replay_requires_raw_artifact_root(self):
        manifest, observations, receipt = self._v2()
        with self.assertRaisesRegex(ValidationError, "requires the receipt directory"):
            replay_observations(
                manifest,
                observations,
                dataset_source=FIXTURES / "smoke-source.json",
                runtime_receipt=receipt,
            )


if __name__ == "__main__":
    unittest.main()
