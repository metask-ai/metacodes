import copy
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path

from scripts.eval.memory_agent_runtime import (
    _copy_memory_tree,
    _project_domain,
    _xxhash64,
)
from scripts.eval.memory_replay import (
    RUNNER_SOURCE_MODULES,
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

    def test_markdown_state_copy_rejects_links_and_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            outside = root / "outside.md"
            outside.write_text("outside\n", encoding="utf-8")
            (source / "escape.md").symlink_to(outside)
            with self.assertRaisesRegex(ValidationError, "symlink is forbidden"):
                _copy_memory_tree(source, root / "target")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            outside = root / "outside.md"
            outside.write_text("outside\n", encoding="utf-8")
            os.link(outside, source / "hardlink.md")
            with self.assertRaisesRegex(ValidationError, "hard-linked file is forbidden"):
                _copy_memory_tree(source, root / "target")

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            with self.assertRaisesRegex(ValidationError, "must not overlap"):
                _copy_memory_tree(source, source / "nested")

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

    def _materialize_v3_artifacts(self, root, manifest, observations, receipt):
        cases = {case["id"]: case for case in manifest["cases"]}
        for source in receipt["runner_sources"]:
            path = root / source["path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"runner-source:{source['module']}\n", encoding="utf-8")
            source["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()

        for rollout in receipt["rollouts"]:
            sequence = rollout["sequence"]
            case = cases[rollout["case_id"]]
            paths = rollout["artifact_paths"]
            file_payloads = {
                "native_events": f"native-events:{sequence}\n",
                "result": stable_json(
                    {
                        "type": "result",
                        "stop_reason": "end_turn",
                        "turns": 1,
                        "tool_calls": rollout["memory_read_events"]
                        + rollout["memory_write_events"],
                        "input_tokens": 1,
                        "output_tokens": 1,
                        "cost_usd": 0.0,
                        "text": "runtime-smoke",
                    }
                )
                + "\n",
                "stderr": "",
            }
            for path_key, hash_key in (
                ("native_events", "native_events_sha256"),
                ("result", "result_sha256"),
                ("stderr", "stderr_sha256"),
            ):
                path = root / paths[path_key]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(file_payloads[path_key], encoding="utf-8")
                rollout[hash_key] = hashlib.sha256(path.read_bytes()).hexdigest()

            for path_key in ("transcript", "workspace"):
                path = root / paths[path_key]
                path.mkdir(parents=True, exist_ok=True)
                (path / "artifact.txt").write_text(
                    f"{path_key}:{sequence}\n",
                    encoding="utf-8",
                )

            cassette = root / paths["cassette"]
            cassette.mkdir(parents=True)
            tools = []
            backend = rollout["memory_backend"]
            online = case["benchmark"] == "procedural_transfer" and case["split"] == "online"
            if backend == "markdown":
                tools = (
                    [
                        ("markdown-memory-1", "Write"),
                        ("markdown-index-1", "Write"),
                    ]
                    if online
                    else [("markdown-read-1", "Read")]
                )
            elif backend == "tinykg":
                tools = (
                    [("kg-remember-1", "KgRemember")]
                    if online
                    else []
                ) + [("kg-recall-1", "KgRecall"), ("kg-context-1", "KgContext")]
            for request_id in range(1, rollout["provider_requests"] + 1):
                messages = []
                if request_id == rollout["provider_requests"] and tools:
                    messages = [
                        {
                            "role": "assistant",
                            "content": [
                                {"type": "tool_use", "id": tool_id, "name": name, "input": {}}
                                for tool_id, name in tools
                            ],
                        },
                        {
                            "role": "user",
                            "content": [
                                {"type": "tool_result", "tool_use_id": tool_id, "content": "{}"}
                                for tool_id, _name in tools
                            ],
                        },
                    ]
                (cassette / f"req-{request_id:03d}.json").write_text(
                    stable_json({"messages": messages}) + "\n",
                    encoding="utf-8",
                )
            rollout["cassette_sha256"] = _artifact_tree_digest(cassette)

            family_key = case.get("family_id") or case["id"]
            if backend == "markdown":
                memory = root / paths["memory_state"]
                memory.mkdir(parents=True, exist_ok=True)
                (memory / "memory.md").write_text(
                    f"durable-memory:{family_key}:{rollout['trial']}\n",
                    encoding="utf-8",
                )
                state_after = _artifact_tree_digest(memory)
                rollout["memory_state_after"] = state_after
                rollout["memory_state_before"] = (
                    digest(f"markdown-before:{sequence}") if online else state_after
                )
            elif backend == "tinykg":
                store = root / paths["store"]
                store.mkdir(parents=True, exist_ok=True)
                (store / "events.bin").write_text(
                    f"tinykg-state:{family_key}:{rollout['trial']}\n",
                    encoding="utf-8",
                )
                raw_after = _artifact_tree_digest(store)
                state_after = digest(
                    f"tinykg-normalized:{family_key}:{rollout['trial']}:{rollout['arm']}"
                )
                rollout["raw_store_digest_after"] = raw_after
                rollout["raw_store_digest_before"] = (
                    digest(f"tinykg-raw-before:{sequence}") if online else raw_after
                )
                rollout["store_revision_after"] = state_after
                rollout["store_revision_before"] = (
                    digest(f"tinykg-before:{sequence}") if online else state_after
                )
                rollout["memory_state_after"] = state_after
                rollout["memory_state_before"] = rollout["store_revision_before"]
            else:
                state_after = "none"

            observations[sequence]["graph"]["revision"] = state_after
            rollout["observation_sha256"] = hashlib.sha256(
                stable_json(observations[sequence]).encode("utf-8")
            ).hexdigest()

        for rollout in receipt["rollouts"]:
            paths = rollout["artifact_paths"]
            for path_key, hash_key in (
                ("transcript", "transcript_sha256"),
                ("workspace", "workspace_sha256"),
            ):
                rollout[hash_key] = _artifact_tree_digest(root / paths[path_key])
        receipt["observations_sha256"] = hashlib.sha256(
            stable_json(observations).encode("utf-8")
        ).hexdigest()

    def _v3(self):
        manifest, observations, receipt = self._v2()
        markdown_fingerprint = digest("markdown-memory")
        manifest["execution"]["arms"][0] = {
            "id": "markdown_memory",
            "fingerprint": markdown_fingerprint,
        }
        cases = {case["id"]: case for case in manifest["cases"]}
        for entry in manifest["schedule"]:
            if entry["arm"] == "no_memory":
                entry["arm"] = "markdown_memory"
        receipt["schema_version"] = 3
        receipt["execution_mode"] = "native-agent-loop-scripted-lifecycle-smoke"
        receipt["runner_sources"] = [
            {
                "module": module,
                "path": f"runner-sources/{module}.py",
                "sha256": digest(f"runner-source:{module}"),
            }
            for module in RUNNER_SOURCE_MODULES
        ]
        receipt["arms"] = copy.deepcopy(manifest["execution"]["arms"])
        receipt["manifest_sha256"] = hashlib.sha256(
            stable_json(manifest).encode("utf-8")
        ).hexdigest()
        for sequence, (entry, observation, rollout) in enumerate(
            zip(manifest["schedule"], observations, receipt["rollouts"])
        ):
            case = cases[entry["case_id"]]
            online = case["benchmark"] == "procedural_transfer" and case["split"] == "online"
            rollout["arm"] = entry["arm"]
            observation["arm"] = entry["arm"]
            rollout["artifact_paths"]["memory_state"] = None
            rollout["memory_phase"] = case["split"]
            if entry["arm"] == "markdown_memory":
                before = digest(f"markdown-before:{sequence}")
                after = digest(f"markdown-after:{sequence}") if online else before
                rollout.update(
                    {
                        "memory_backend": "markdown",
                        "memory_state_before": before,
                        "memory_state_after": after,
                        "memory_read_events": 0 if online else 1,
                        "memory_write_events": 2 if online else 0,
                    }
                )
                rollout["artifact_paths"]["memory_state"] = f"rollouts/{sequence}/sealed-home/memory"
                observation["retrieval"].update(
                    {
                        "enabled": not online,
                        "k": 0 if online else 1,
                        "hop_count": 0 if online else 1,
                        "query_variants": []
                        if online
                        else [{"kind": "exact", "text": case["prompt"]}],
                        "retrieved_evidence_ids": [],
                        "verified_evidence_ids": [],
                    }
                )
                observation["memory"].update(
                    {
                        "write_mode": "online" if online else "read_only",
                        "inserted_nodes": 1 if online else 0,
                        "active_nodes": 2,
                        "provenance_links": 1,
                    }
                )
                observation["graph"]["revision"] = after
                rollout["tinykg_binary_sha256"] = None
                rollout["store_revision_before"] = "none"
                rollout["store_revision_after"] = "none"
                rollout["raw_store_digest_before"] = "none"
                rollout["raw_store_digest_after"] = "none"
            else:
                before = digest(f"tinykg-before:{sequence}")
                after = digest(f"tinykg-after:{sequence}") if online else before
                raw_before = digest(f"tinykg-raw-before:{sequence}")
                raw_after = digest(f"tinykg-raw-after:{sequence}") if online else raw_before
                rollout.update(
                    {
                        "memory_backend": "tinykg",
                        "memory_state_before": before,
                        "memory_state_after": after,
                        "memory_read_events": 2,
                        "memory_write_events": 1 if online else 0,
                        "store_revision_before": before,
                        "store_revision_after": after,
                        "raw_store_digest_before": raw_before,
                        "raw_store_digest_after": raw_after,
                    }
                )
                observation["memory"].update(
                    {
                        "write_mode": "online" if online else "read_only",
                        "inserted_nodes": 1 if online else 0,
                    }
                )
                observation["graph"]["revision"] = after
            provider_requests = (
                2
                if entry["arm"] == "markdown_memory"
                else 4
                if online
                else 3
            )
            rollout["provider_requests"] = provider_requests
            observation["trajectory"]["model_requests"] = provider_requests
            observation["trajectory"]["tool_calls"] = (
                rollout["memory_read_events"] + rollout["memory_write_events"]
            )
            observation["trajectory"]["tool_errors"] = 0
            rollout["observation_sha256"] = hashlib.sha256(
                stable_json(observation).encode("utf-8")
            ).hexdigest()
        receipt["observations_sha256"] = hashlib.sha256(
            stable_json(observations).encode("utf-8")
        ).hexdigest()
        return manifest, observations, receipt

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

    def test_v3_receipt_binds_markdown_and_tinykg_online_offline_lifecycle(self):
        manifest, observations, receipt = self._v3()
        validate_runtime_receipt(
            receipt,
            manifest,
            observations,
            manifest["dataset"]["source_sha256"],
        )

        offline = next(
            index
            for index, entry in enumerate(manifest["schedule"])
            if entry["arm"] == "markdown_memory"
            and next(case for case in manifest["cases"] if case["id"] == entry["case_id"])["split"]
            == "offline"
        )
        leaked = copy.deepcopy(receipt)
        leaked["rollouts"][offline]["memory_write_events"] = 1
        with self.assertRaisesRegex(ValidationError, "read-only phase changed"):
            validate_runtime_receipt(
                leaked,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )

        tiny_online = next(
            index
            for index, entry in enumerate(manifest["schedule"])
            if entry["arm"] == "tinykg_lexical"
            and next(case for case in manifest["cases"] if case["id"] == entry["case_id"])["split"]
            == "online"
        )
        unchanged = copy.deepcopy(receipt)
        unchanged["rollouts"][tiny_online]["store_revision_after"] = unchanged["rollouts"][tiny_online]["store_revision_before"]
        unchanged["rollouts"][tiny_online]["memory_state_after"] = unchanged["rollouts"][tiny_online]["memory_state_before"]
        with self.assertRaisesRegex(ValidationError, "online TinyKG phase"):
            validate_runtime_receipt(
                unchanged,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )

    def test_v3_reopens_source_memory_and_cassette_semantics(self):
        manifest, observations, receipt = self._v3()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._materialize_v3_artifacts(root, manifest, observations, receipt)
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(receipt, root)

            runner = root / receipt["runner_sources"][0]["path"]
            runner.write_text("tampered runner\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "runtime source mismatch"):
                validate_runtime_artifacts(receipt, root)

        manifest, observations, receipt = self._v3()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._materialize_v3_artifacts(root, manifest, observations, receipt)
            markdown = next(
                rollout
                for rollout in receipt["rollouts"]
                if rollout["memory_backend"] == "markdown"
            )
            memory = root / markdown["artifact_paths"]["memory_state"]
            (memory / "late.md").write_text("tampered\n", encoding="utf-8")
            transcript = root / markdown["artifact_paths"]["transcript"]
            markdown["transcript_sha256"] = _artifact_tree_digest(transcript)
            with self.assertRaisesRegex(ValidationError, "memory_state_after"):
                validate_runtime_artifacts(receipt, root)

        manifest, observations, receipt = self._v3()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._materialize_v3_artifacts(root, manifest, observations, receipt)
            offline = next(
                rollout
                for rollout in receipt["rollouts"]
                if rollout["memory_backend"] == "markdown"
                and next(
                    case for case in manifest["cases"] if case["id"] == rollout["case_id"]
                )["split"]
                == "offline"
            )
            cassette = root / offline["artifact_paths"]["cassette"]
            request = cassette / f"req-{offline['provider_requests']:03d}.json"
            body = json.loads(request.read_text(encoding="utf-8"))
            body["messages"][0]["content"].append(
                {
                    "type": "tool_use",
                    "id": "markdown-laundered-1",
                    "name": "Write",
                    "input": {},
                }
            )
            body["messages"][1]["content"].append(
                {
                    "type": "tool_result",
                    "tool_use_id": "markdown-laundered-1",
                    "content": "{}",
                }
            )
            request.write_text(stable_json(body) + "\n", encoding="utf-8")
            offline["cassette_sha256"] = _artifact_tree_digest(cassette)
            with self.assertRaisesRegex(ValidationError, "memory_write_events"):
                validate_runtime_artifacts(receipt, root)


if __name__ == "__main__":
    unittest.main()
