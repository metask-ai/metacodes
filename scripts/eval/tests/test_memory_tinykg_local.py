import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.memory_consolidation import commit_execution_episode
from scripts.eval.memory_procedural_adapter import adapt_procedural, artifact_bytes
from scripts.eval.memory_tinykg_local import (
    LocalTinyKg,
    _store_info,
    build_case_batch,
    run_local_tinykg_smoke,
)
from scripts.eval.model import ValidationError
from scripts.eval.tests.posix_only import requires_posix_exec


ROOT = Path(__file__).resolve().parents[3]
PROCEDURAL_SOURCE = ROOT / "evals/memory/fixtures/procedural-coding-source.json"
PROCEDURAL_EXECUTION = ROOT / "evals/memory/fixtures/procedural-adapter-smoke-execution.json"
NATIVE_TINYKG = Path(os.environ["METACODES_TEST_TINYKG_BIN"]) if os.environ.get(
    "METACODES_TEST_TINYKG_BIN"
) else ROOT / ".missing-explicit-tinykg"


def procedural_artifacts(root: Path) -> tuple[Path, Path]:
    execution = json.loads(PROCEDURAL_EXECUTION.read_text(encoding="utf-8"))
    source_sha256 = hashlib.sha256(PROCEDURAL_SOURCE.read_bytes()).hexdigest()
    source, _, manifest = adapt_procedural(
        PROCEDURAL_SOURCE,
        execution,
        expected_source_sha256=source_sha256,
        limit_families=2,
        split_seed=20260806,
    )
    source_path = root / "source.json"
    manifest_path = root / "manifest.json"
    source_path.write_bytes(artifact_bytes(source))
    manifest_path.write_bytes(artifact_bytes(manifest))
    return source_path, manifest_path


def fake_mutating_tinykg(path: Path) -> str:
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import pathlib
import sys

action = sys.argv[1]
store = pathlib.Path(sys.argv[2])
state = store / "state.json"
if action == "init":
    store.mkdir(parents=True)
    state.write_text(json.dumps({"nodes": 0, "edges": 0}), encoding="utf-8")
    print("ready", store)
elif action == "apply":
    lines = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").splitlines()[1:]
    rows = [json.loads(line) for line in lines]
    counts = {
        "nodes": sum(row.get("op") == "node" for row in rows),
        "edges": sum(row.get("op") == "edge" for row in rows),
    }
    state.write_text(json.dumps(counts, sort_keys=True), encoding="utf-8")
    print("apply", counts["nodes"], counts["edges"])
elif action == "store-info":
    counts = json.loads(state.read_text(encoding="utf-8"))
    print(f"nodes={counts['nodes']}")
    print(f"edges={counts['edges']}")
    print("storage_format_version=2")
elif action == "search":
    if os.environ.get("FAKE_MUTATE_ON_READ") == "1":
        (store / "read-mutation").write_text("mutation", encoding="utf-8")
    print(json.dumps({"hits": [{"score": 1.0, "node": {"id": 1}}]}))
elif action == "neighbors":
    print(json.dumps({
        "summary": {"node_count": 2, "edge_count": 1, "truncated": False},
        "nodes": [{"id": 1}, {"id": 2}],
    }))
else:
    raise SystemExit(3)
""",
        encoding="utf-8",
    )
    path.chmod(0o755)
    return hashlib.sha256(path.read_bytes()).hexdigest()


class LocalTinyKgBatchTest(unittest.TestCase):
    def test_hotpot_batch_contains_public_sentences_and_graph_edges(self):
        source = {
            "cases": [
                {
                    "id": "hotpot:case-1",
                    "documents": [
                        {
                            "id": "doc:one",
                            "title": "Orchid",
                            "sentences": [
                                {"id": "sentence:one", "sentence_id": 0, "text": "Orchid uses trace headers."},
                                {"id": "sentence:two", "sentence_id": 1, "text": "The service listens on 4317."},
                            ],
                        }
                    ],
                }
            ]
        }
        manifest = {"dataset": {"adapter_id": "hotpotqa-distractor"}}
        batch, logical, root, query_case = build_case_batch(source, manifest, "hotpot:case-1")
        rows = [json.loads(line) for line in batch.decode("utf-8").splitlines()]
        self.assertEqual(rows[0], {"version": 1})
        self.assertEqual(sum(row.get("op") == "node" for row in rows), 3)
        self.assertEqual(sum(row.get("op") == "edge" for row in rows), 2)
        self.assertEqual(root, 1)
        self.assertEqual(query_case, "hotpot:case-1")
        self.assertEqual(logical[2], "sentence:one")
        self.assertNotIn("supporting", batch.decode("utf-8"))

    def test_longmem_turn_nodes_map_back_to_official_session_unit(self):
        source = {
            "cases": [
                {
                    "id": "longmem:case-1",
                    "sessions": [
                        {
                            "id": "session:answer",
                            "source_position": 0,
                            "date": "2024/01/05 (Fri) 10:00",
                            "turns": [
                                {"id": "turn:0", "turn_index": 0, "role": "user", "content": "I prefer amber."},
                                {"id": "turn:1", "turn_index": 1, "role": "assistant", "content": "Noted."},
                            ],
                        }
                    ],
                }
            ]
        }
        manifest = {"dataset": {"adapter_id": "longmemeval-s-cleaned"}}
        batch, logical, root, query_case = build_case_batch(source, manifest, "longmem:case-1")
        rows = [json.loads(line) for line in batch.decode("utf-8").splitlines()]
        self.assertEqual(sum(row.get("op") == "node" for row in rows), 3)
        self.assertEqual(sum(row.get("op") == "edge" for row in rows), 2)
        self.assertEqual(root, 1)
        self.assertEqual(query_case, "longmem:case-1")
        self.assertEqual({logical[1], logical[2], logical[3]}, {"session:answer"})
        self.assertNotIn("has_answer", batch.decode("utf-8"))

    def test_procedural_batch_uses_online_evidence_and_queries_offline_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            source_path, manifest_path = procedural_artifacts(Path(directory))
            source = json.loads(source_path.read_text(encoding="utf-8"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        online = next(case for case in manifest["cases"] if case["split"] == "online")
        batch, logical, root, query_case = build_case_batch(source, manifest, online["id"])
        self.assertEqual(root, 1)
        self.assertNotEqual(query_case, online["id"])
        self.assertEqual(manifest["cases"][0]["family_id"], manifest["cases"][1]["family_id"])
        self.assertTrue(logical[1].startswith("procedure:"))
        self.assertIn("Reusable procedure learned", batch.decode("utf-8"))


@unittest.skipUnless(NATIVE_TINYKG.is_file(), "set METACODES_TEST_TINYKG_BIN")
class LocalTinyKgNativeTest(unittest.TestCase):
    def test_execution_episode_import_and_project_membership_are_native(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary_sha256 = hashlib.sha256(NATIVE_TINYKG.read_bytes()).hexdigest()
            local = LocalTinyKg(
                binary=NATIVE_TINYKG,
                expected_sha256=binary_sha256,
                run_dir=root / "isolated-consolidation",
            )
            store = local.store_root / "episode.kg"
            local.command("init", store, ())
            batch = local.batch_root / "project.jsonl"
            batch.write_text(
                '{"version":1}\n'
                '{"op":"node","id":1,"kind":"project","name":"episode-test"}\n',
                encoding="utf-8",
            )
            local.command("apply", store, (str(batch),))
            before = _store_info(local.command("store-info", store, ()))

            memory = local.run_dir / "memory"
            memory.mkdir()
            receipt = commit_execution_episode(
                local=local,
                memory_dir=memory,
                memory_index=memory / "MEMORY.md",
                store=store,
                prompt="Preserve the registry migration protocol intent.",
                stop_reason="end_turn",
                deterministic_success=True,
                baseline={"src/registry.zig": "const version = 1;\n"},
                candidate={"src/registry.zig": "const version = 2;\n"},
                source_events_sha256=hashlib.sha256(b"native-events").hexdigest(),
            )
            after = _store_info(local.command("store-info", store, ()))

            self.assertEqual(receipt["status"], "committed")
            self.assertIn(
                receipt["tinykg_document_id"],
                receipt["tinykg_projection_node_ids"],
            )
            self.assertGreater(len(receipt["tinykg_projection_node_ids"]), 1)
            self.assertGreater(int(after["nodes"]), int(before["nodes"]))
            self.assertGreater(int(after["edges"]), int(before["edges"]))
            self.assertEqual(
                [command["action"] for command in local.commands[-7:]],
                [
                    "store-info",
                    "import-md-doc",
                    "add-edge",
                    "neighbors",
                    "rebuild-text",
                    "store-info",
                    "store-info",
                ],
            )
            self.assertEqual(after["text_current"], "1")
            self.assertEqual(after["text_stale"], "0")
            search = json.loads(
                local.command(
                    "search",
                    store,
                    (
                        "registry protocol",
                        "--project",
                        "1",
                        "--limit",
                        "10",
                        "--format",
                        "json",
                        "--include-text",
                    ),
                )
            )
            self.assertGreater(len(search["hits"]), 0)
            self.assertTrue(all(not command["child_tinykg_env_keys"] for command in local.commands))

    def test_real_local_cli_isolated_store_and_remote_sentinels_remain_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path = procedural_artifacts(root)
            sentinel_store = root / "remote-store-sentinel"
            sentinel_store.mkdir()
            marker = sentinel_store / "DO_NOT_TOUCH"
            marker.write_text("remote-canonical-store", encoding="utf-8")
            remote_config = root / "remote-config-sentinel.json"
            remote_config.write_text('{"url":"http://127.0.0.1:1"}\n', encoding="utf-8")
            run_dir = root / "isolated-run"
            binary_sha256 = hashlib.sha256(NATIVE_TINYKG.read_bytes()).hexdigest()
            poisoned = {
                "TINYKG_STORE": str(sentinel_store),
                "TINYKG_REMOTE_URL": "http://127.0.0.1:1",
                "TINYKG_API_KEY": "must-not-reach-child",
                "TINYKG_REMOTE_EXPECTED_BUILD_ID": "must-not-reach-child",
                "TINYKG_REMOTE_CONFIG": str(remote_config),
                "METACODES_KG_CONFIG": str(remote_config),
                "METACODES_KG_URL": "http://127.0.0.1:1",
                "METACODES_KG_API_KEY": "must-not-reach-child",
                "METACODES_KG_EXPECTED_BUILD_ID": "must-not-reach-child",
                "METACODES_KG_EXPECTED_SCHEMA_DIGEST": "must-not-reach-child",
            }
            with mock.patch.dict(os.environ, poisoned, clear=False):
                trace = run_local_tinykg_smoke(
                    binary=NATIVE_TINYKG,
                    expected_binary_sha256=binary_sha256,
                    source_path=source_path,
                    manifest_path=manifest_path,
                    run_dir=run_dir,
                    output_path=run_dir / "trace.json",
                    case_limit=1,
                )
                repeat_run_dir = root / "isolated-run-repeat"
                repeated_trace = run_local_tinykg_smoke(
                    binary=NATIVE_TINYKG,
                    expected_binary_sha256=binary_sha256,
                    source_path=source_path,
                    manifest_path=manifest_path,
                    run_dir=repeat_run_dir,
                    output_path=repeat_run_dir / "trace.json",
                    case_limit=1,
                )
            self.assertEqual(trace, repeated_trace)
            self.assertEqual(marker.read_text(encoding="utf-8"), "remote-canonical-store")
            self.assertEqual(list(sentinel_store.iterdir()), [marker])
            self.assertEqual(
                remote_config.read_text(encoding="utf-8"),
                '{"url":"http://127.0.0.1:1"}\n',
            )
            self.assertEqual(trace["isolation"]["skill_harness_invocations"], 0)
            self.assertEqual(trace["isolation"]["remote_api_calls"], 0)
            self.assertEqual(trace["isolation"]["remote_store_writes"], 0)
            self.assertTrue(
                set(poisoned).issubset(
                    set(trace["isolation"]["parent_tinykg_env_keys_detected"])
                )
            )
            self.assertTrue(trace["cases"][0]["read_only_preserved"])
            self.assertEqual(
                trace["cases"][0]["graph_revision_before_reads"],
                trace["cases"][0]["graph_revision_after_reads"],
            )
            self.assertGreaterEqual(trace["cases"][0]["retrieval"]["hit_count"], 1)
            self.assertEqual(trace["cases"][0]["graph_probe"]["edge_count"], 1)
            self.assertTrue(all(not command["child_tinykg_env_keys"] for command in trace["commands"]))
            command_text = json.dumps(trace["commands"], sort_keys=True)
            self.assertNotIn("127.0.0.1", command_text)
            self.assertNotIn("must-not-reach-child", command_text)
            self.assertTrue(
                all(
                    command["argv"][0] == "<TINYKG_BINARY>"
                    and command["argv"][2].startswith("<RUN_DIR>/stores/")
                    for command in trace["commands"]
                )
            )

    def test_wrong_binary_hash_and_preexisting_run_fail_before_store_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path = procedural_artifacts(root)
            run_dir = root / "new-run"
            with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
                run_local_tinykg_smoke(
                    binary=NATIVE_TINYKG,
                    expected_binary_sha256="0" * 64,
                    source_path=source_path,
                    manifest_path=manifest_path,
                    run_dir=run_dir,
                    output_path=run_dir / "trace.json",
                )
            self.assertFalse(run_dir.exists())

            run_dir.mkdir()
            binary_sha256 = hashlib.sha256(NATIVE_TINYKG.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValidationError, "must not already exist"):
                run_local_tinykg_smoke(
                    binary=NATIVE_TINYKG,
                    expected_binary_sha256=binary_sha256,
                    source_path=source_path,
                    manifest_path=manifest_path,
                    run_dir=run_dir,
                    output_path=run_dir / "trace.json",
                )


class LocalTinyKgFailClosedTest(unittest.TestCase):
    @requires_posix_exec
    def test_read_only_store_mutation_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path = procedural_artifacts(root)
            fake_binary = root / "fake-tinykg"
            binary_sha256 = fake_mutating_tinykg(fake_binary)
            run_dir = root / "run"
            with mock.patch.dict(os.environ, {"FAKE_MUTATE_ON_READ": "1"}, clear=False):
                with self.assertRaisesRegex(ValidationError, "read-only search/traversal changed"):
                    run_local_tinykg_smoke(
                        binary=fake_binary,
                        expected_binary_sha256=binary_sha256,
                        source_path=source_path,
                        manifest_path=manifest_path,
                        run_dir=run_dir,
                        output_path=run_dir / "trace.json",
                    )
            self.assertFalse((run_dir / "trace.json").exists())

    def test_output_must_remain_inside_fresh_run_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path = procedural_artifacts(root)
            fake_binary = root / "fake-tinykg"
            binary_sha256 = fake_mutating_tinykg(fake_binary)
            run_dir = root / "run"
            with self.assertRaisesRegex(ValidationError, "output must stay inside"):
                run_local_tinykg_smoke(
                    binary=fake_binary,
                    expected_binary_sha256=binary_sha256,
                    source_path=source_path,
                    manifest_path=manifest_path,
                    run_dir=run_dir,
                    output_path=root / "outside.json",
                )
            self.assertFalse(run_dir.exists())


if __name__ == "__main__":
    unittest.main()
