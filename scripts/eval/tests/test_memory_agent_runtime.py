import copy
import contextlib
import hashlib
import io
import json
import os
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.memory_agent_runtime import (
    PRODUCTION_MODEL_FINGERPRINT,
    ProductionRuntimeConfig,
    _assert_production_sandbox_identity,
    _assert_executable_identity,
    _assert_production_secret_absent,
    _cassette_tool_data,
    _copy_memory_tree,
    _estimated_costs_match,
    _host_recall_covers_missing_explicit_recall,
    _project_domain,
    _production_environment,
    _materialize_production_sandbox,
    _run_production_sandbox_probe,
    _safe_component,
    _sanitized_environment,
    _verify_scoped_recall_activation,
    _write_failed_validation_checkpoint,
    _xxhash64,
    run_memory_agent_schedule,
)
from scripts.eval.memory_consolidation import commit_execution_episode
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    usd_to_microusd,
    usd_to_microusd_ceiling,
)
from scripts.eval.memory_query_plan import SIDECAR_NAME, build_query_plan_trace
from scripts.eval.memory_replay import (
    LEGACY_RUNNER_SOURCE_MODULES,
    OBSERVATION_SCHEMA_VERSION,
    PRODUCTION_ALLOWED_PROVIDER_TOOLS,
    CONSOLIDATION_SCHEMA_VERSION,
    PRODUCTION_PRICING_PROVENANCE,
    PRODUCTION_AUTO_COMPACT_POLICY,
    PRODUCTION_CHILD_PATH,
    PRODUCTION_DISALLOWED_PROVIDER_TOOLS,
    PRODUCTION_FILESYSTEM_ISOLATION,
    LEGACY_PRODUCTION_RUNNER_SOURCE_MODULES,
    PRODUCTION_RUNNER_SOURCE_MODULES,
    PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    PRE_CONSOLIDATION_PRODUCTION_RUNNER_SOURCE_MODULES,
    PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
    PRODUCTION_SANDBOX_BACKEND,
    PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION,
    PRODUCTION_TOOL_NETWORK_ISOLATION,
    SCOPED_RECALL_PREFIX,
    RUNNER_SOURCE_MODULES,
    _artifact_tree_digest,
    _cassette_memory_activity,
    _cassette_memory_exposure,
    _cassette_treatment_activation,
    _production_harness_fingerprint,
    _query_plan_source_bound,
    _validate_consolidation_artifacts,
    load_manifest,
    load_observations,
    load_runtime_receipt,
    replay_observations,
    validate_runtime_artifacts,
    validate_runtime_receipt,
)
from scripts.eval.memory_agent_runtime_pilot import (
    _load_api_key,
    main as production_pilot_main,
)
from scripts.eval.e2e_adapter import NATIVE_EVENT_SCHEMA_VERSION
from scripts.eval.model import ValidationError, stable_json


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "evals/memory/fixtures"
TEST_RIPGREP = Path(sys.executable).resolve()
TEST_RIPGREP_SHA256 = hashlib.sha256(TEST_RIPGREP.read_bytes()).hexdigest()
REAL_TINYKG = ROOT / "zig-out/vendor/tinykg/tinykg"


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


class MemoryAgentRuntimeContractTest(unittest.TestCase):
    def test_host_scoped_recall_fallback_is_an_exact_query(self):
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            (cassette / "req-001.json").write_text(
                stable_json(
                    {
                        "messages": [
                            {
                                "content": [
                                    {
                                        "type": "text",
                                        "text": "Host recall injected node_id=7 before tools.",
                                    }
                                ]
                            }
                        ]
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            observed = _cassette_tool_data(
                cassette,
                {7: "procedure:family:v2"},
                "Register the sibling using the established protocol.",
            )

        self.assertEqual(observed["retrieved"], ["procedure:family:v2"])
        self.assertEqual(
            observed["query_variants"],
            [
                {
                    "kind": "exact",
                    "text": "Register the sibling using the established protocol.",
                }
            ],
        )

    def test_failed_paid_validation_checkpoint_is_explicitly_invalid_and_recoverable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            observations = b'{"case_id":"case-1"}\n'
            candidate = {"schema_version": "candidate-receipt", "rollouts": []}
            diagnostic = _write_failed_validation_checkpoint(
                root,
                observations_payload=observations,
                receipt=candidate,
                error=ValidationError("validator outcome drift"),
                budget_journal_receipt={"revision": 9, "head_sha256": digest("head")},
            )

            wrapper = json.loads(
                (root / diagnostic["runtime_candidate_file"]).read_text(encoding="utf-8")
            )
            self.assertEqual(wrapper["status"], "invalid")
            self.assertEqual(wrapper["candidate_runtime_receipt"], candidate)
            self.assertEqual(diagnostic["budget_journal_revision"], 9)
            self.assertFalse((root / "runtime-receipt.json").exists())
            self.assertFalse((root / "observations.jsonl").exists())
            for path in root.iterdir():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_completed_host_no_hit_does_not_require_duplicate_model_recall(self):
        missing_explicit = {
            "status": "invalid",
            "invalid_reasons": ["TinyKG backend executed no KgRecall"],
        }
        self.assertTrue(
            _host_recall_covers_missing_explicit_recall(
                {"status": "no_hits"},
                missing_explicit,
            )
        )
        self.assertTrue(
            _host_recall_covers_missing_explicit_recall(
                {"status": "injected"},
                missing_explicit,
            )
        )
        self.assertFalse(
            _host_recall_covers_missing_explicit_recall(
                {"status": "search_error"},
                missing_explicit,
            )
        )
        self.assertFalse(
            _host_recall_covers_missing_explicit_recall(None, missing_explicit)
        )

    def test_v6_query_plan_source_identity_remains_replayable(self):
        receipt = {
            "schema_version": PRE_SCOPED_RECALL_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION,
            "runner_sources": [
                {"module": module}
                for module in PRE_CONSOLIDATION_PRODUCTION_RUNNER_SOURCE_MODULES
            ],
        }
        self.assertTrue(_query_plan_source_bound(receipt, "production v6 receipt"))

    def test_execution_episode_consolidation_is_bounded_private_and_content_addressed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            memory = root / "memory"
            memory.mkdir()
            index = memory / "MEMORY.md"
            receipt = commit_execution_episode(
                local=mock.Mock(),
                memory_dir=memory,
                memory_index=index,
                store=None,
                prompt="Preserve the registry protocol across all surfaces.",
                stop_reason="end_turn",
                deterministic_success=True,
                baseline={"src/registry.zig": "const version = 1;\n"},
                candidate={"src/registry.zig": "const version = 2;\n"},
                source_events_sha256=digest("native-events"),
            )
            episode = memory / receipt["episode_file"]
            self.assertEqual(receipt["status"], "committed")
            self.assertEqual(receipt["changed_files"], ["src/registry.zig"])
            self.assertEqual(
                hashlib.sha256(episode.read_bytes()).hexdigest(),
                receipt["episode_sha256"],
            )
            self.assertEqual(
                hashlib.sha256(index.read_bytes()).hexdigest(),
                receipt["memory_index_sha256"],
            )
            self.assertEqual(episode.stat().st_mode & 0o777, 0o600)
            self.assertEqual(index.stat().st_mode & 0o777, 0o600)
            self.assertIn("source_events_sha256", episode.read_text(encoding="utf-8"))
            self.assertIn(f"]({episode.name})", index.read_text(encoding="utf-8"))
            self.assertTrue(
                all(
                    receipt[key] is None
                    for key in (
                        "tinykg_document_id",
                        "tinykg_projection_node_ids",
                        "tinykg_revision_before",
                        "tinykg_revision_after",
                        "tinykg_raw_digest_before",
                        "tinykg_raw_digest_after",
                        "tinykg_nodes_before",
                        "tinykg_nodes_after",
                        "tinykg_edges_before",
                        "tinykg_edges_after",
                    )
                )
            )
            rollout = {"consolidation": receipt, "stop_reason": "end_turn"}
            _validate_consolidation_artifacts(rollout, memory, "test consolidation")
            episode_payload = episode.read_bytes()
            episode.write_text("tampered episode\n", encoding="utf-8")
            episode.chmod(0o600)
            with self.assertRaisesRegex(ValidationError, "episode bytes drifted"):
                _validate_consolidation_artifacts(rollout, memory, "test consolidation")
            episode.write_bytes(episode_payload)
            episode.chmod(0o600)
            index.write_bytes(index.read_bytes() + b"tampered index\n")
            index.chmod(0o600)
            with self.assertRaisesRegex(ValidationError, "MEMORY.md bytes drifted"):
                _validate_consolidation_artifacts(rollout, memory, "test consolidation")

    def test_scoped_recall_receipt_must_match_provider_visible_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            cassette = Path(directory)
            prompt = "Apply the registry protocol migration."
            block = (
                "<system-reminder>\n"
                "# 相关持久记忆(按你的请求自动召回,可能不全)\n"
                "- [42] preserve protocol intent\n"
                "</system-reminder>"
            ).encode("utf-8")
            (cassette / "req-001.json").write_text(
                stable_json(
                    {
                        "messages": [
                            {
                                "role": "user",
                                "content": [
                                    {"type": "text", "text": block.decode("utf-8")}
                                ],
                            }
                        ]
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            receipt = {
                "schema_version": "metacodes-scoped-recall-v1",
                "status": "injected",
                "query_sha256": hashlib.sha256(prompt.encode("utf-8")[:400]).hexdigest(),
                "result_count": 1,
                "injected_count": 1,
                "injected_bytes": len(block),
                "injection_sha256": hashlib.sha256(block).hexdigest(),
            }
            observed = _verify_scoped_recall_activation(
                {"scoped_recalls": [receipt]},
                cassette,
                prompt,
                tinykg_enabled=True,
                where="test scoped recall",
            )
            self.assertEqual(observed, receipt)

            forged = copy.deepcopy(receipt)
            forged["injection_sha256"] = "0" * 64
            with self.assertRaisesRegex(ValidationError, "does not match provider bytes"):
                _verify_scoped_recall_activation(
                    {"scoped_recalls": [forged]},
                    cassette,
                    prompt,
                    tinykg_enabled=True,
                    where="test scoped recall",
                )
            with self.assertRaisesRegex(ValidationError, "expected one native"):
                _verify_scoped_recall_activation(
                    {"scoped_recalls": []},
                    cassette,
                    prompt,
                    tinykg_enabled=True,
                    where="test scoped recall",
                )

    def test_runtime_cost_cross_check_uses_journal_precision(self):
        # Reproduces the first production pilot rollout: native usage events
        # retained the sub-micro sum while the public result rounded to 6 dp.
        self.assertTrue(_estimated_costs_match(0.0689886, 0.068989))
        self.assertFalse(_estimated_costs_match(0.0689874, 0.068989))
        self.assertFalse(_estimated_costs_match(float("nan"), 0.0))
        self.assertFalse(_estimated_costs_match(0.0, float("inf")))
        self.assertFalse(_estimated_costs_match(-0.000001, 0.0))

    def test_checked_in_pilot_v2_binds_artifacts_schedule_and_carryover(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v2"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])

        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        self.assertEqual(manifest["execution"], execution)
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            {item["id"]: item["fingerprint"] for item in manifest["execution"]["arms"]},
            {item["id"]: item["fingerprint"] for item in contract["protocol"]["arms"]},
        )
        budget = contract["budget_authority"]
        self.assertAlmostEqual(
            budget["carryover_max_cost_usd"] + budget["max_total_cost_usd"],
            budget["program_max_cost_usd"],
        )
        self.assertEqual(
            budget["carryover_max_metered_tokens"]
            + budget["max_total_metered_tokens"],
            budget["program_max_metered_tokens"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v3_uses_unseen_family_and_remaining_tranche(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v3"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        self.assertEqual(
            source["upstream"]["source_sha256"],
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["capability-contract-propagation"],
        )
        public_source = stable_json(source)
        self.assertNotIn("config-field-migration", public_source)
        self.assertNotIn("error-contract-propagation", public_source)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            contract["provider_tool_policy"]["allowed_provider_tools"],
            list(PRODUCTION_ALLOWED_PROVIDER_TOOLS),
        )
        budget = contract["budget_authority"]
        self.assertLessEqual(
            budget["carryover_max_cost_usd"] + budget["max_total_cost_usd"],
            budget["pilot_program_max_cost_usd"],
        )
        self.assertLessEqual(
            budget["carryover_max_metered_tokens"]
            + budget["max_total_metered_tokens"],
            budget["pilot_program_max_metered_tokens"],
        )
        self.assertLessEqual(
            budget["pilot_program_max_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v4_binds_host_observable_unseen_family(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v4"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        self.assertEqual(
            source["upstream"]["source_sha256"],
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["lifecycle-state-propagation"],
        )
        public_source = stable_json(source)
        for exposed_family in (
            "config-field-migration",
            "error-contract-propagation",
            "capability-contract-propagation",
        ):
            self.assertNotIn(exposed_family, public_source)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            {item["id"]: item["fingerprint"] for item in execution["arms"]},
            {item["id"]: item["fingerprint"] for item in contract["protocol"]["arms"]},
        )
        self.assertEqual(
            contract["tinykg_runtime"]["online_consolidation_commands"],
            ["import-md-doc", "add-edge", "neighbors", "store-info"],
        )
        budget = contract["budget_authority"]
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v5_binds_crash_exposure_and_frozen_schedule(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v5"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        self.assertEqual(
            source["upstream"]["source_sha256"],
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["error-contract-propagation"],
        )
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            {item["id"]: item["fingerprint"] for item in execution["arms"]},
            {item["id"]: item["fingerprint"] for item in contract["protocol"]["arms"]},
        )
        predecessor = contract["predecessor_uncertain_request"]
        self.assertEqual(predecessor["state"], "request_authorized")
        self.assertTrue(predecessor["automatic_retry_forbidden"])
        budget = contract["budget_authority"]
        self.assertGreaterEqual(
            budget["prior_conservative_cost_usd"],
            predecessor["maximum_cost_usd"],
        )
        self.assertGreaterEqual(
            budget["prior_conservative_metered_tokens"],
            predecessor["maximum_metered_tokens"],
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v6_binds_unseen_family_and_all_uncertain_requests(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v6"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads((pilot / "attempt-001-observation.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        # The host-owned source fixture grows when a new unseen family is
        # staged.  Historical pilots bind the exact upstream snapshot through
        # their frozen source slice and contract, not through today's fixture.
        self.assertEqual(
            source["upstream"]["source_sha256"],
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["hook-contract-propagation"],
        )
        public_source = stable_json(source)
        for exposed_family in (
            "config-field-migration",
            "error-contract-propagation",
            "capability-contract-propagation",
            "lifecycle-state-propagation",
        ):
            self.assertNotIn(exposed_family, public_source)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            {item["id"]: item["fingerprint"] for item in execution["arms"]},
            {item["id"]: item["fingerprint"] for item in contract["protocol"]["arms"]},
        )
        predecessors = contract["predecessor_uncertain_requests"]
        self.assertEqual(
            {item["transaction_id"] for item in predecessors},
            {
                "27da31d17143929fba09e07328a178c5cfc09e35708c7d1c781a1f15dc438a0d",
                "b5a9a0c309f62b92f97e4241cffcfa9f14b05917beb9ccc5d8c1f116c4035830",
            },
        )
        self.assertTrue(all(item["state"] == "request_authorized" for item in predecessors))
        self.assertTrue(all(item["automatic_retry_forbidden"] for item in predecessors))
        budget = contract["budget_authority"]
        self.assertGreaterEqual(
            budget["prior_conservative_cost_usd"],
            sum(item["maximum_cost_usd"] for item in predecessors),
        )
        self.assertGreaterEqual(
            budget["prior_conservative_metered_tokens"],
            sum(item["maximum_metered_tokens"] for item in predecessors),
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "halted")
        self.assertEqual(attempt["outcome"]["completed_provider_requests"], 4)
        self.assertEqual(attempt["outcome"]["remaining_provider_requests_not_started"], 5)
        self.assertEqual(
            sum(item["actual_metered_tokens"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_metered_tokens"],
        )
        self.assertAlmostEqual(
            sum(item["actual_cost_usd"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_cost_usd"],
        )
        self.assertEqual(
            attempt["failure"]["classification"],
            "treatment-activation-evidence-failure",
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v7_binds_durable_cwd_fix_and_larger_rollout_reserve(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v7"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads((pilot / "attempt-001-observation.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        # Historical source identity lives in the frozen slice and contract;
        # today's host fixture may already contain the next unseen family.
        self.assertEqual(
            source["upstream"]["source_sha256"],
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["policy-action-propagation"],
        )
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            {item["id"]: item["fingerprint"] for item in execution["arms"]},
            {item["id"]: item["fingerprint"] for item in contract["protocol"]["arms"]},
        )
        predecessor = contract["predecessor_halted_attempt"]
        self.assertEqual(predecessor["pilot_id"], "procedural-glm52-v6")
        self.assertEqual(predecessor["status"], "halted")
        self.assertFalse(predecessor["quality_evidence"])
        self.assertEqual(predecessor["completed_provider_requests"], 4)
        self.assertEqual(predecessor["remaining_provider_requests_not_started"], 5)
        self.assertEqual(predecessor["uncertain_authorized_transactions"], 0)
        uncertain = contract["predecessor_uncertain_requests"]
        self.assertEqual(len(uncertain), 2)
        self.assertTrue(all(item["automatic_retry_forbidden"] for item in uncertain))
        budget = contract["budget_authority"]
        self.assertEqual(budget["max_rollout_cost_usd"], 1.5)
        self.assertEqual(budget["max_rollout_metered_tokens"], 600000)
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        self.assertGreaterEqual(
            budget["max_total_cost_usd"],
            len(rows) * budget["max_rollout_cost_usd"],
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "invalid")
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        self.assertFalse(attempt["outcome"]["canonical_runtime_receipt_published"])
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], len(rows))
        self.assertEqual(attempt["outcome"]["workspace_validator_successes"], len(rows))
        self.assertEqual(
            sum(item["provider_http_requests"] for item in attempt["rollouts"]),
            attempt["outcome"]["provider_http_requests"],
        )
        self.assertEqual(
            sum(item["actual_metered_tokens"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_metered_tokens"],
        )
        self.assertAlmostEqual(
            sum(item["actual_cost_usd"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_cost_usd"],
        )
        self.assertEqual(
            attempt["treatment_activation"]["tinykg_offline_rows_with_search_error"],
            2,
        )
        self.assertTrue(attempt["treatment_activation"]["tinykg_store_text_stale_after_online"])
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v8_binds_unseen_transfer_and_text_catalog_publication(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v8"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads((pilot / "attempt-001-observation.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        # Historical source identity lives in the frozen slice and contract;
        # the checked-in fixture may already contain a later unseen family.
        self.assertEqual(
            source["upstream"]["source_sha256"],
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["compatibility-convention-transfer"],
        )
        public_source = stable_json(source)
        self.assertIn("Reuse the previously established family compatibility convention", public_source)
        self.assertNotIn("COMPAT_TASK_HANDOFF", public_source)
        self.assertNotIn("COMPAT_ONTOLOGY_PROMOTE", public_source)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(
            {item["id"]: item["fingerprint"] for item in execution["arms"]},
            {item["id"]: item["fingerprint"] for item in contract["protocol"]["arms"]},
        )
        self.assertEqual(
            contract["tinykg_runtime"]["online_consolidation_commands"],
            ["import-md-doc", "add-edge", "neighbors", "rebuild-text", "store-info"],
        )
        predecessors = contract["predecessor_attempts"]
        self.assertEqual(
            {(item["pilot_id"], item["status"]) for item in predecessors},
            {("procedural-glm52-v6", "halted"), ("procedural-glm52-v7", "invalid")},
        )
        self.assertTrue(all(not item["quality_evidence"] for item in predecessors))
        budget = contract["budget_authority"]
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        self.assertGreaterEqual(
            budget["max_total_cost_usd"],
            len(rows) * budget["max_rollout_cost_usd"],
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "halted")
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        self.assertFalse(attempt["outcome"]["canonical_runtime_receipt_published"])
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], 6)
        self.assertEqual(attempt["budget_journal"]["uncertain_authorized_transactions"], 1)
        self.assertTrue(attempt["outcome"]["automatic_retry_forbidden"])
        self.assertEqual(
            sum(item["actual_metered_tokens"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_metered_tokens"],
        )
        self.assertAlmostEqual(
            sum(item["actual_cost_usd"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_cost_usd"],
        )
        self.assertEqual(
            attempt["failure"]["classification"],
            "post-provider-toolchain-identity-drift",
        )
        self.assertTrue(
            attempt["uncertain_rollout_diagnostic"][
                "workspace_deterministic_success_recomputed_offline"
            ]
        )
        self.assertLessEqual(
            attempt["program_authority"]["conservative_cost_usd_after_attempt"],
            attempt["program_authority"]["user_authorization_max_cost_usd"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v9_uses_new_family_and_receipt_v8_contract(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v9"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads(
            (pilot / "attempt-001-observation.json").read_text(encoding="utf-8")
        )
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["recovery-protocol-transfer"],
        )
        public_source = stable_json(source)
        self.assertIn("Reuse the previously established family recovery protocol", public_source)
        self.assertNotIn("RECOVERY_JOURNAL_REPAIR", public_source)
        self.assertNotIn("RECOVERY_LEASE_RECOVER", public_source)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(contract["protocol"]["observation_schema_version"], 2)
        self.assertEqual(contract["protocol"]["production_receipt_schema_version"], 8)
        uncertain = contract["predecessor_uncertain_requests"]
        self.assertEqual(len(uncertain), 3)
        self.assertTrue(all(item["automatic_retry_forbidden"] for item in uncertain))
        self.assertIn(
            "ee403d91d4be42294b54ba7f45ba2dde1ced3a6b622c691e6f84b21b75fd22bd",
            {item["transaction_id"] for item in uncertain},
        )
        budget = contract["budget_authority"]
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        self.assertGreater(
            budget["max_total_cost_usd"],
            len(rows) * budget["max_rollout_cost_usd"],
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "halted")
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], 4)
        self.assertEqual(attempt["outcome"]["remaining_rollouts_not_started"], 5)
        self.assertEqual(attempt["budget_journal"]["uncertain_authorized_transactions"], 0)
        self.assertEqual(
            attempt["failure"]["classification"],
            "offline-markdown-treatment-mutation",
        )
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v10_uses_new_fixture_and_read_only_adapter(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v10"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads(
            (pilot / "attempt-001-observation.json").read_text(encoding="utf-8")
        )
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(
            [family["id"] for family in source["families"]],
            ["audit-receipt-transfer"],
        )
        self.assertEqual(
            source["adapter_revision"],
            "workspace-validator-family-v2-offline-read-only",
        )
        public_source = stable_json(source)
        self.assertIn("Reuse the previously established family audit receipt protocol", public_source)
        self.assertIn("persistent memory, if available, is read-only", public_source)
        self.assertNotIn("AUDIT_BUDGET_COMMIT_V2", public_source)
        self.assertNotIn("AUDIT_MEMORY_MIGRATE_V2", public_source)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(contract["protocol"]["production_receipt_schema_version"], 8)
        self.assertIn(
            "Seatbelt probe v2",
            contract["paid_execution_requirements"]["offline_memory_immutability"],
        )
        budget = contract["budget_authority"]
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        self.assertGreater(
            budget["max_total_cost_usd"],
            len(rows) * budget["max_rollout_cost_usd"],
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "halted")
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], 4)
        self.assertEqual(attempt["budget_journal"]["uncertain_authorized_transactions"], 0)
        self.assertEqual(
            attempt["failure"]["classification"],
            "offline-markdown-no-op-write-misclassified",
        )
        self.assertTrue(attempt["memory_safety"]["seatbelt_read_only_roots_enforced"])
        self.assertEqual(
            attempt["memory_safety"]["markdown_revision_before"],
            attempt["memory_safety"]["markdown_revision_after"],
        )
        self.assertEqual(attempt["memory_safety"]["activity_after_fix_markdown_writes"], 0)
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v11_binds_write_result_semantics_fix(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v11"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads(
            (pilot / "attempt-001-observation.json").read_text(encoding="utf-8")
        )
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertIn(
            "only successful memory write results count as mutations",
            contract["paid_execution_requirements"]["tool_result_semantics"],
        )
        budget = contract["budget_authority"]
        self.assertGreaterEqual(
            budget["max_total_metered_tokens"],
            len(rows) * budget["max_rollout_metered_tokens"],
        )
        self.assertGreater(
            budget["max_total_cost_usd"],
            len(rows) * budget["max_rollout_cost_usd"],
        )
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "halted")
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], 4)
        self.assertEqual(attempt["budget_journal"]["uncertain_authorized_transactions"], 1)
        self.assertEqual(
            attempt["failure"]["classification"],
            "offline-tinykg-cli-lock-denied-before-graph-activation",
        )
        self.assertTrue(attempt["memory_safety"]["markdown_memory_prompt_active"])
        self.assertFalse(attempt["memory_safety"]["knowledge_graph_prompt_active"])
        self.assertEqual(
            attempt["memory_safety"]["raw_tinykg_store_digest_before"],
            attempt["memory_safety"]["raw_tinykg_store_digest_after"],
        )
        self.assertEqual(attempt["unsettled_transaction"]["state"], "request_authorized")
        self.assertTrue(attempt["outcome"]["automatic_retry_forbidden"])
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v12_binds_real_tinykg_read_probe(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v12"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads(
            (pilot / "attempt-001-observation.json").read_text(encoding="utf-8")
        )
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        self.assertEqual(contract["harness"]["git_commit"], "3e2b32ed357a8715dda9bdd09c4d09cbca0c851a")
        rows = [
            [item["sequence"], item["case_id"], item["trial"], item["arm"]]
            for item in manifest["schedule"]
        ]
        self.assertEqual(rows, contract["schedule"]["ordered_rows"])
        ordered_tsv = "".join("\t".join(str(value) for value in row) + "\n" for row in rows)
        self.assertEqual(
            hashlib.sha256(ordered_tsv.encode("utf-8")).hexdigest(),
            contract["schedule"]["ordered_tsv_sha256"],
        )
        self.assertEqual(contract["protocol"]["sandbox_probe_schema_version"], 3)
        self.assertIn(
            "store-info and one bounded lexical search",
            contract["paid_execution_requirements"]["tinykg_read_preflight"],
        )
        self.assertEqual(contract["budget_authority"]["prior_conservative_cost_usd"], 7.6764158)
        self.assertEqual(
            contract["budget_authority"]["prior_conservative_metered_tokens"],
            4729364,
        )
        self.assertEqual(attempt["outcome"]["status"], "halted")
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        self.assertFalse(attempt["outcome"]["canonical_runtime_receipt_published"])
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], 0)
        self.assertEqual(attempt["budget_journal"]["uncertain_authorized_transactions"], 1)
        self.assertEqual(
            attempt["failure"]["classification"],
            "request-authorized-invalid-api-key",
        )
        self.assertEqual(attempt["provider_evidence"]["provider_http_status"], 401)
        self.assertEqual(
            attempt["provider_evidence"]["provider_error_code"], "INVALID_API_KEY"
        )
        self.assertEqual(attempt["provider_evidence"]["http_requests"], 1)
        self.assertEqual(attempt["provider_evidence"]["turns"], 0)
        self.assertEqual(attempt["provider_evidence"]["tool_calls"], 0)
        self.assertFalse(attempt["provider_evidence"]["credential_present_in_artifacts"])
        self.assertEqual(attempt["unsettled_transaction"]["state"], "request_authorized")
        self.assertTrue(attempt["outcome"]["automatic_retry_forbidden"])
        self.assertAlmostEqual(
            attempt["program_authority"]["conservative_cost_usd_after_attempt"],
            contract["budget_authority"]["prior_conservative_cost_usd"]
            + attempt["unsettled_transaction"]["max_cost_usd"],
        )
        self.assertEqual(
            attempt["program_authority"]["conservative_metered_tokens_after_attempt"],
            contract["budget_authority"]["prior_conservative_metered_tokens"]
            + attempt["unsettled_transaction"]["max_metered_tokens"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        budget = contract["budget_authority"]
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(rows))

    def test_checked_in_pilot_v13_uses_fresh_identity_after_invalid_key(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v13"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        attempt = json.loads(
            (pilot / "attempt-001-observation.json").read_text(encoding="utf-8")
        )
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(manifest["manifest_id"], "coding-intent-families-2026080815-1")
        self.assertEqual(contract["pilot_id"], "procedural-glm52-v13")
        self.assertEqual(contract["generation"]["split_seed"], 2026080815)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        self.assertIn(
            "distinct from the rejected v12 credential",
            contract["paid_execution_requirements"]["credential_transport"],
        )
        predecessor = contract["predecessor_attempts"]
        self.assertEqual(
            [(item["pilot_id"], item["status"]) for item in predecessor],
            [("procedural-glm52-v12", "halted")],
        )
        uncertain = contract["predecessor_uncertain_requests"]
        self.assertEqual(len(uncertain), 5)
        self.assertTrue(all(item["automatic_retry_forbidden"] for item in uncertain))
        self.assertIn(
            "2a53fc44a007fab397e642486802368e951730f7ecc4ff75aae85b7c817369e0",
            {item["transaction_id"] for item in uncertain},
        )
        budget = contract["budget_authority"]
        self.assertEqual(budget["prior_conservative_cost_usd"], 9.1764158)
        self.assertEqual(budget["prior_conservative_metered_tokens"], 5329364)
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        self.assertEqual(attempt["outcome"]["status"], "invalid")
        self.assertFalse(attempt["outcome"]["quality_evidence"])
        self.assertFalse(attempt["outcome"]["canonical_runtime_receipt_published"])
        self.assertEqual(attempt["outcome"]["committed_rollout_transactions"], 9)
        self.assertEqual(attempt["outcome"]["uncertain_authorized_transactions"], 0)
        self.assertEqual(
            attempt["failure"]["classification"],
            "post-run-runtime-receipt-validation",
        )
        self.assertEqual(
            attempt["governance_signal"]["host_scoped_recall_fallback_kind_observed"],
            "automatic",
        )
        self.assertTrue(
            attempt["governance_signal"]["tool_schema_must_require_lexical_plan"]
        )
        self.assertTrue(attempt["outcome"]["automatic_retry_forbidden"])
        self.assertAlmostEqual(
            sum(item["actual_cost_usd"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_cost_usd"],
        )
        self.assertEqual(
            sum(item["actual_metered_tokens"] for item in attempt["rollouts"]),
            attempt["budget_journal"]["committed_metered_tokens"],
        )
        self.assertEqual(
            sum(item["provider_http_requests"] for item in attempt["rollouts"]),
            attempt["outcome"]["provider_http_requests"],
        )
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(manifest["schedule"]))

    def test_checked_in_pilot_v14_uses_unseen_family_and_governed_recall_arm(self):
        pilot = ROOT / "evals/memory/pilots/procedural-glm52-v14"
        contract = json.loads((pilot / "pilot-contract.json").read_text(encoding="utf-8"))
        source = json.loads((pilot / "source.json").read_text(encoding="utf-8"))
        manifest = load_manifest(pilot / "manifest.json")
        execution = json.loads((pilot / "execution.json").read_text(encoding="utf-8"))

        for name, identity in contract["artifacts"].items():
            payload = (pilot / name).read_bytes()
            self.assertEqual(len(payload), identity["bytes"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), identity["sha256"])
        fixture = ROOT / contract["generation"]["source_path"]
        self.assertEqual(
            hashlib.sha256(fixture.read_bytes()).hexdigest(),
            contract["generation"]["expected_upstream_sha256"],
        )
        self.assertEqual([family["id"] for family in source["families"]], ["config-field-migration"])
        prior_families = {
            json.loads(path.read_text(encoding="utf-8"))["generation"].get("family_id")
            for path in (ROOT / "evals/memory/pilots").glob("procedural-glm52-v*/pilot-contract.json")
            if path.parent.name != "procedural-glm52-v14"
        }
        self.assertNotIn("config-field-migration", prior_families)
        self.assertEqual(manifest["execution"], execution)
        self.assertEqual(manifest["manifest_id"], "coding-intent-families-2026080817-1")
        self.assertEqual(contract["pilot_id"], "procedural-glm52-v14")
        self.assertEqual(contract["generation"]["split_seed"], 2026080817)
        self.assertEqual(contract["harness"]["revision"], execution["harness_revision"])
        self.assertEqual(
            contract["harness"]["binary_sha256"],
            "80d10a08698a3f820dc260d98e1394056bd87c9fd7fb48fedabb4b3b125952aa",
        )
        tinykg_arm = next(item for item in contract["protocol"]["arms"] if item["id"] == "tinykg_lexical")
        self.assertIn("governed-plan-v2", tinykg_arm["fingerprint_basis"])
        self.assertEqual(
            tinykg_arm["fingerprint"],
            next(item["fingerprint"] for item in execution["arms"] if item["id"] == "tinykg_lexical"),
        )
        self.assertIn(
            "requires lexical_plan",
            contract["paid_execution_requirements"]["governed_recall"],
        )
        predecessor = contract["predecessor_attempts"]
        self.assertEqual(
            [(item["pilot_id"], item["status"]) for item in predecessor],
            [("procedural-glm52-v13", "invalid")],
        )
        budget = contract["budget_authority"]
        self.assertEqual(budget["prior_conservative_cost_usd"], 9.9901358)
        self.assertEqual(budget["prior_conservative_metered_tokens"], 6101602)
        self.assertLessEqual(
            budget["prior_conservative_cost_usd"] + budget["max_total_cost_usd"],
            budget["user_authorization_max_cost_usd"],
        )
        self.assertTrue(contract["current_phase"]["paid_rollouts_authorized"])
        self.assertFalse(contract["current_phase"]["quality_evidence"])
        ProductionRuntimeConfig(
            api_key="test-only",
            allow_paid_rollouts=True,
            max_total_cost_usd=budget["max_total_cost_usd"],
            max_total_metered_tokens=budget["max_total_metered_tokens"],
            max_rollout_cost_usd=budget["max_rollout_cost_usd"],
            max_rollout_metered_tokens=budget["max_rollout_metered_tokens"],
            max_output_tokens=budget["max_output_tokens"],
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        ).validate(len(manifest["schedule"]))

    def _materialize_valid_production_events(self, root, rollout, grader_fingerprint):
        cassette = root / rollout["artifact_paths"]["cassette"]
        uses = {}
        results = set()
        for request_path in sorted(cassette.glob("req-*.json")):
            body = json.loads(request_path.read_text(encoding="utf-8"))
            for message in body.get("messages", []):
                for item in message.get("content", []):
                    if item.get("type") == "tool_use":
                        uses[item["id"]] = item["name"]
                    elif item.get("type") == "tool_result":
                        results.add(item["tool_use_id"])
        completed_tools = [(tool_id, name) for tool_id, name in uses.items() if tool_id in results]
        metadata = {
            "run_id": rollout["run_id"],
            "invocation": 0,
            "trial": rollout["trial"],
            "suite_id": "memory-production-test",
            "task_id": rollout["case_id"],
            "task_fingerprint": rollout["task_fingerprint"],
            "task_fingerprint_provenance": "recorded_at_execution",
            "model_provider": "anthropic",
            "model_id": "glm-5.2",
            "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
            "runtime_model_provider": "anthropic",
            "runtime_model_id": "glm-5.2",
            "harness_config_id": "candidate",
            "harness_revision": "production-memory-pilot-v1",
            "harness_fingerprint": rollout["harness_fingerprint"],
            "permission_mode": "bypass_permissions",
            "runtime_permission_mode": "bypass_permissions",
            "environment_fingerprint": rollout["environment_fingerprint"],
            "grader_fingerprint": grader_fingerprint,
            "max_metered_tokens": 300_000,
            "max_cost_usd": 0.9,
        }
        trace = "production-test-trace"
        events = [{"run_started": {"trace_id": trace, "metadata": metadata}}]
        scoped_recall = rollout.get("scoped_recall")
        if isinstance(scoped_recall, dict):
            events.append({"scoped_recall": copy.deepcopy(scoped_recall)})
        request_count = rollout["provider_requests"]
        for request_index in range(1, request_count + 1):
            events.append(
                {"turn_started": {"trace_id": trace, "depth": 0, "turn": request_index}}
            )
            events.append(
                {
                    "model_request_finished": {
                        "trace_id": trace,
                        "depth": 0,
                        "turn": request_index,
                        "attempt": 0,
                        "elapsed_ms": 1,
                        "outcome": "success",
                    }
                }
            )
            turn_tools = completed_tools if request_index == 1 else []
            for tool_id, name in turn_tools:
                events.extend(
                    [
                        {
                            "policy_decision": {
                                "trace_id": trace,
                                "depth": 0,
                                "id": tool_id,
                                "tool": name,
                                "decision": "allow",
                                "source": "permission_chain",
                                "allowed": True,
                            }
                        },
                        {
                            "tool_started": {
                                "trace_id": trace,
                                "id": tool_id,
                                "name": name,
                                "input_bytes": 2,
                                "input_sha256": digest(f"input:{tool_id}"),
                            }
                        },
                        {
                            "tool_finished": {
                                "trace_id": trace,
                                "id": tool_id,
                                "name": name,
                                "is_error": False,
                                "error_code": None,
                                "error_category": None,
                                "recoverable": None,
                                "elapsed_ms": 1,
                                "result_bytes": 2,
                                "result_sha256": digest(f"result:{tool_id}"),
                            }
                        },
                    ]
                )
            if turn_tools:
                events.append(
                    {
                        "tool_stage_finished": {
                            "trace_id": trace,
                            "depth": 0,
                            "turn": request_index,
                            "tool_calls": len(turn_tools),
                            "elapsed_ms": len(turn_tools),
                        }
                    }
                )
            events.append(
                {
                    "turn_finished": {
                        "trace_id": trace,
                        "depth": 0,
                        "turn": request_index,
                        "tool_calls": len(turn_tools),
                    }
                }
            )
        events.append(
            {
                "usage": {
                    "trace_id": trace,
                    "input_tokens": rollout["metered_tokens"],
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "estimated_cost_usd": rollout["estimated_cost_usd"],
                    "pricing_provenance": PRODUCTION_PRICING_PROVENANCE,
                }
            }
        )
        events.append(
            {
                "run_finished": {
                    "trace_id": trace,
                    "depth": 0,
                    "turns": request_count,
                    "tool_calls": len(completed_tools),
                    "stop_reason": "end_turn",
                    "wall_time_ms": request_count + len(completed_tools) + 10,
                    "dropped_events": 0,
                }
            }
        )
        event_path = root / rollout["artifact_paths"]["native_events"]
        event_path.write_text(
            "".join(
                stable_json(
                    {
                        "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                        "sequence": index,
                        "monotonic_elapsed_ns": index,
                        "session_id": "single",
                        "event": event,
                    }
                )
                + "\n"
                for index, event in enumerate(events)
            ),
            encoding="utf-8",
        )
        rollout["native_events_sha256"] = hashlib.sha256(event_path.read_bytes()).hexdigest()

    def test_production_budget_authority_is_fail_closed_and_secret_free(self):
        valid = ProductionRuntimeConfig(
            api_key="super-secret-key",
            allow_paid_rollouts=True,
            max_total_cost_usd=10.0,
            max_total_metered_tokens=3_100_000,
            max_rollout_cost_usd=0.9,
            max_rollout_metered_tokens=300_000,
            max_output_tokens=4096,
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        )
        valid.validate(9)
        self.assertNotIn("super-secret-key", repr(valid))

        unauthorized = copy.copy(valid)
        object.__setattr__(unauthorized, "allow_paid_rollouts", False)
        with self.assertRaisesRegex(ValidationError, "explicit paid-rollout authority"):
            unauthorized.validate(9)

        over_limit = copy.copy(valid)
        object.__setattr__(over_limit, "max_total_cost_usd", 1000.01)
        with self.assertRaisesRegex(ValidationError, "must not exceed \\$1000"):
            over_limit.validate(9)

        no_headroom = copy.copy(valid)
        object.__setattr__(no_headroom, "max_total_cost_usd", 8.1)
        with self.assertRaisesRegex(ValidationError, "strictly cover"):
            no_headroom.validate(9)

    def test_runtime_paths_do_not_reveal_treatment_labels(self):
        component = _safe_component("task:0:tinykg_lexical:no_memory:markdown_memory")
        self.assertRegex(component, r"^run-[0-9a-f]{20}$")
        for leaked in ("tinykg", "no-memory", "markdown"):
            self.assertNotIn(leaked, component)

    def test_production_pilot_dry_run_loads_no_credential_and_makes_no_network_call(self):
        manifest = copy.deepcopy(load_manifest(FIXTURES / "smoke-manifest.json"))
        manifest["execution"]["model_id"] = "glm-5.2"
        manifest["execution"]["model_fingerprint"] = PRODUCTION_MODEL_FINGERPRINT
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(stable_json(manifest) + "\n", encoding="utf-8")
            missing_auth = root / "must-not-be-read.json"
            budget_journal = root / "must-not-be-created-budget-journal.json"
            tinykg = root / "fake-tinykg"
            tinykg.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  init) mkdir \"$2\" ;;\n"
                "  apply) printf 'apply version=1 nodes_created=1 nodes_existing=0 edges_created=0 edges_existing=0\\n' ;;\n"
                "  store-info) printf 'nodes=1\\nedges=0\\nstorage_format_version=2\\nschema_version=3\\n' ;;\n"
                "  *) exit 91 ;;\n"
                "esac\n",
                encoding="utf-8",
            )
            tinykg.chmod(0o700)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = production_pilot_main(
                    [
                        "--binary",
                        "/bin/echo",
                        "--tinykg-binary",
                        str(tinykg),
                        "--ripgrep-binary",
                        str(TEST_RIPGREP),
                        "--source",
                        str(FIXTURES / "smoke-source.json"),
                        "--manifest",
                        str(manifest_path),
                        "--auth-file",
                        str(missing_auth),
                        "--budget-journal",
                        str(budget_journal),
                        "--dry-run",
                    ]
                )
            self.assertEqual(code, 0)
            plan = json.loads(output.getvalue())
            self.assertTrue(plan["dry_run"])
            self.assertEqual(plan["network_requests"], 0)
            self.assertFalse(plan["credential_loaded"])
            self.assertEqual(
                plan["tinykg_preflight"]["commands"],
                ["init", "apply", "store-info"],
            )
            self.assertFalse(missing_auth.exists())
            self.assertFalse(budget_journal.exists())

    def test_production_pilot_rejects_incompatible_tinykg_before_credential(self):
        manifest = copy.deepcopy(load_manifest(FIXTURES / "smoke-manifest.json"))
        manifest["execution"]["model_id"] = "glm-5.2"
        manifest["execution"]["model_fingerprint"] = PRODUCTION_MODEL_FINGERPRINT
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(stable_json(manifest) + "\n", encoding="utf-8")
            missing_auth = root / "must-not-be-read.json"
            with self.assertRaisesRegex(ValidationError, "TinyKG compatibility preflight"):
                production_pilot_main(
                    [
                        "--binary",
                        "/bin/echo",
                        "--tinykg-binary",
                        "/bin/echo",
                        "--ripgrep-binary",
                        str(TEST_RIPGREP),
                        "--source",
                        str(FIXTURES / "smoke-source.json"),
                        "--manifest",
                        str(manifest_path),
                        "--auth-file",
                        str(missing_auth),
                        "--dry-run",
                    ]
                )
            self.assertFalse(missing_auth.exists())

    def test_production_secret_scan_rejects_artifact_and_pending_receipt(self):
        secret = 'super-secret-"escaped"-key'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "stdout.ndjson").write_text("safe\n", encoding="utf-8")
            _assert_production_secret_absent(
                root,
                secret,
                pending_payloads=(("pending receipt", b'{"safe":true}'),),
            )

            (root / "cassette.json").write_text(
                json.dumps({"tool_result": secret}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValidationError, "credential leaked into cassette.json"):
                _assert_production_secret_absent(root, secret)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValidationError, "pending runtime receipt"):
                _assert_production_secret_absent(
                    root,
                    secret,
                    pending_payloads=(
                        ("pending runtime receipt", json.dumps(secret).encode("utf-8")),
                    ),
                )

    def test_production_executable_identity_is_rechecked(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "runtime"
            binary.write_bytes(b"frozen-runtime")
            binary.chmod(0o700)
            expected = hashlib.sha256(binary.read_bytes()).hexdigest()
            _assert_executable_identity(binary, expected, "test runtime")
            binary.write_bytes(b"changed-runtime")
            with self.assertRaisesRegex(ValidationError, "changed during the frozen schedule"):
                _assert_executable_identity(binary, expected, "test runtime")

    def test_production_child_environment_excludes_all_credential_channels(self):
        clean = _production_environment(
            {
                "PATH": "/operator/bin",
                "METASK_API_KEY": "must-not-pass",
                "METACODES_API_KEY_FD": "99",
                "METACODES_AUTH_FILE": "/host/auth.json",
                "TINYKG_API_KEY": "remote-must-not-pass",
                "GITHUB_TOKEN": "unrelated-must-not-pass",
                "AWS_SECRET_ACCESS_KEY": "unrelated-must-not-pass",
                "SSH_AUTH_SOCK": "/operator/agent.sock",
            }
        )
        self.assertEqual(clean, {"PATH": PRODUCTION_CHILD_PATH})

    def test_scripted_environment_drops_untrusted_tinykg_domain_override(self):
        clean = _sanitized_environment(
            {
                "PATH": "/operator/bin",
                "METACODES_KG_DOMAIN": "host-domain-must-not-pass",
            }
        )
        self.assertEqual(clean, {"PATH": "/operator/bin"})

    def test_production_auth_rejects_parent_environment_and_reads_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            auth = Path(directory) / "auth.json"
            auth.write_text('{"api_key":"private-file-key"}\n', encoding="utf-8")
            auth.chmod(0o600)
            with mock.patch.dict(os.environ, {"METASK_API_KEY": "parent-env-key"}):
                with self.assertRaisesRegex(ValidationError, "parent's initial environment"):
                    _load_api_key(auth)
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("METASK_API_KEY", None)
                self.assertEqual(_load_api_key(auth), "private-file-key")

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS Seatbelt")
    def test_production_seatbelt_denies_host_sibling_and_process_info(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "run" / "rollouts" / "current"
            workspace = root / "run" / "projects" / "current-workspace"
            store = root / "run" / "stores" / "current.kg"
            child_tmp = artifact / "tmp"
            for path in (artifact, workspace, store, child_tmp):
                path.mkdir(parents=True, exist_ok=True)
            host = root / "host-sentinel.txt"
            sibling = root / "run" / "sibling-sentinel.txt"
            host.write_text("host-secret\n", encoding="utf-8")
            sibling.write_text("sibling-secret\n", encoding="utf-8")
            profile = artifact / "production-seatbelt.sb"
            evidence_path = artifact / "production-seatbelt-probe.json"
            ripgrep = artifact / "sealed-home" / ".metacodes" / "toolchain" / "rg"
            ripgrep.parent.mkdir(parents=True)
            ripgrep.write_bytes(TEST_RIPGREP.read_bytes())
            ripgrep.chmod(0o500)
            memory = artifact / "sealed-home" / ".metacodes" / "projects" / "test" / "memory"
            memory.mkdir(parents=True)
            memory_index = memory / "MEMORY.md"
            memory_index.write_text("- [Procedure](procedure.md) -- durable pattern\n", encoding="utf-8")
            memory_before = hashlib.sha256(memory_index.read_bytes()).hexdigest()
            store_manifest = store / ".tinykg" / "store-manifest.json"
            store_manifest.parent.mkdir()
            store_manifest.write_text('{"revision":1}\n', encoding="utf-8")
            store_before = hashlib.sha256(store_manifest.read_bytes()).hexdigest()

            sandbox = _materialize_production_sandbox(
                profile_path=profile,
                evidence_path=evidence_path,
                artifact_dir=artifact,
                workspace=workspace,
                store=store,
                metacodes=Path("/bin/echo"),
                tinykg=Path("/bin/cat"),
                ripgrep=ripgrep,
                read_only_roots=(memory, store),
                tinykg_read_only_store=store,
            )
            evidence = _run_production_sandbox_probe(
                sandbox,
                host_read_path=host,
                sibling_read_path=sibling,
                writable_root=child_tmp,
                evidence_path=evidence_path,
                read_only_probes=((memory, memory_index), (store, store_manifest)),
            )
            self.assertTrue(evidence["host_read_denied"])
            self.assertTrue(evidence["sibling_read_denied"])
            self.assertTrue(evidence["process_info_denied"])
            self.assertTrue(evidence["workspace_read_write_allowed"])
            self.assertTrue(evidence["read_only_roots_enforced"])
            self.assertEqual(evidence["read_only_root_count"], 2)
            self.assertEqual(hashlib.sha256(memory_index.read_bytes()).hexdigest(), memory_before)
            self.assertEqual(hashlib.sha256(store_manifest.read_bytes()).hexdigest(), store_before)
            self.assertFalse((memory / ".metacodes-seatbelt-write-probe").exists())
            self.assertFalse((store / ".metacodes-seatbelt-write-probe").exists())
            _assert_production_sandbox_identity(sandbox, evidence_path)

            sealed_probe = subprocess.run(
                sandbox.command(
                    [
                        "/bin/sh",
                        "-c",
                        'if /bin/echo changed > "$1" 2>/dev/null; then exit 21; fi; '
                        'if /bin/echo changed > "$2" 2>/dev/null; then exit 22; fi; '
                        'if /bin/echo changed > "$3" 2>/dev/null; then exit 23; fi; '
                        'if /bin/echo changed > "$4" 2>/dev/null; then exit 24; fi; '
                        'if /bin/echo changed > "$5" 2>/dev/null; then exit 25; fi; '
                        'if /bin/echo changed > "$6" 2>/dev/null; then exit 26; fi; '
                        'if /bin/echo changed > "$7" 2>/dev/null; then exit 27; fi',
                        "sealed-profile-probe",
                        str(profile),
                        str(evidence_path),
                        str(ripgrep),
                        str(memory_index),
                        str(memory / "new-memory.md"),
                        str(store_manifest),
                        str(store / "new-store-file"),
                    ]
                ),
                cwd=workspace,
                env={"PATH": PRODUCTION_CHILD_PATH, "LC_ALL": "C", "LANG": "C"},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(sealed_probe.returncode, 0, sealed_probe.stderr)
            self.assertEqual(hashlib.sha256(ripgrep.read_bytes()).hexdigest(), TEST_RIPGREP_SHA256)
            self.assertEqual(hashlib.sha256(memory_index.read_bytes()).hexdigest(), memory_before)
            self.assertEqual(hashlib.sha256(store_manifest.read_bytes()).hexdigest(), store_before)
            self.assertFalse((memory / "new-memory.md").exists())
            self.assertFalse((store / "new-store-file").exists())
            _assert_production_sandbox_identity(sandbox, evidence_path)

    @unittest.skipUnless(
        platform.system() == "Darwin" and REAL_TINYKG.is_file(),
        "requires macOS Seatbelt and the pinned TinyKG binary",
    )
    def test_production_seatbelt_runs_real_read_only_tinykg_before_authorization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "run" / "rollouts" / "current"
            workspace = root / "run" / "projects" / "current-workspace"
            store = root / "run" / "stores" / "current.kg"
            child_tmp = artifact / "tmp"
            for path in (artifact, workspace, store.parent, child_tmp):
                path.mkdir(parents=True, exist_ok=True)
            batch = root / "run" / "episode.jsonl"
            batch.write_text(
                stable_json({"version": 1})
                + "\n"
                + stable_json(
                    {
                        "op": "node",
                        "id": 1,
                        "kind": "observation",
                        "name": "Execution episode durable audit receipt protocol",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            def tinykg(action, *arguments):
                completed = subprocess.run(
                    [str(REAL_TINYKG), action, *map(str, arguments)],
                    env={"PATH": os.defpath, "LC_ALL": "C", "LANG": "C"},
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                return completed.stdout

            tinykg("init", store)
            tinykg("apply", store, batch)
            tinykg("rebuild-text", store)
            store_manifest = store / ".tinykg" / "store-manifest.json"
            store_digest_before = _artifact_tree_digest(store)
            host = root / "host-sentinel.txt"
            sibling = root / "run" / "sibling-sentinel.txt"
            host.write_text("host-secret\n", encoding="utf-8")
            sibling.write_text("sibling-secret\n", encoding="utf-8")
            profile = artifact / "production-seatbelt.sb"
            evidence_path = artifact / "production-seatbelt-probe.json"
            ripgrep = artifact / "sealed-home" / ".metacodes" / "toolchain" / "rg"
            ripgrep.parent.mkdir(parents=True)
            ripgrep.write_bytes(TEST_RIPGREP.read_bytes())
            ripgrep.chmod(0o500)
            sandbox = _materialize_production_sandbox(
                profile_path=profile,
                evidence_path=evidence_path,
                artifact_dir=artifact,
                workspace=workspace,
                store=store,
                metacodes=Path("/bin/echo"),
                tinykg=REAL_TINYKG,
                ripgrep=ripgrep,
                read_only_roots=(store,),
                tinykg_read_only_store=store,
            )
            evidence = _run_production_sandbox_probe(
                sandbox,
                host_read_path=host,
                sibling_read_path=sibling,
                writable_root=child_tmp,
                evidence_path=evidence_path,
                read_only_probes=((store, store_manifest),),
                tinykg_read_probe=(REAL_TINYKG, store, "execution episode"),
            )
            self.assertTrue(evidence["tinykg_read_probe_performed"])
            self.assertTrue(evidence["tinykg_lock_path_clean"])
            self.assertTrue(evidence["tinykg_store_unchanged"])
            self.assertRegex(evidence["tinykg_store_info_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(evidence["tinykg_recall_sha256"], r"^[0-9a-f]{64}$")
            self.assertFalse((store / ".tinykg-cli.lock").exists())
            self.assertEqual(_artifact_tree_digest(store), store_digest_before)
            _assert_production_sandbox_identity(sandbox, evidence_path)

    def test_memory_exposure_uses_only_injected_and_successful_memory_reads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cassette = root / "cassette"
            memory = root / "memory"
            cassette.mkdir()
            memory.mkdir()
            index = b"- [Procedure](procedure.md) -- durable pattern\n"
            graph_line = "- [node_id=7 decision] graph fact\n"
            graph_context = "# Knowledge Graph\n" + graph_line
            body = {
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": index.decode("utf-8")
                                + "\n"
                                + graph_context
                                + "# currentDate\nToday's date is 2026/08/07.\n",
                            }
                        ],
                    },
                    {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "tool_use",
                                "id": "memory-read",
                                "name": "Read",
                                "input": {"file_path": str(memory / "MEMORY.md")},
                            },
                            {
                                "type": "tool_use",
                                "id": "memory-error",
                                "name": "Grep",
                                "input": {"path": str(memory), "pattern": "x"},
                            },
                            {
                                "type": "tool_use",
                                "id": "markdown-read-spoof",
                                "name": "Read",
                                "input": {"file_path": str(root / "source.zig")},
                            },
                            {
                                "type": "tool_use",
                                "id": "kg-read",
                                "name": "KgRecall",
                                "input": {"query": "durable pattern"},
                            },
                            {
                                "type": "tool_use",
                                "id": "nested-provider",
                                "name": "WebSearch",
                                "input": {"query": "must not execute"},
                            },
                            {
                                "type": "tool_use",
                                "id": "memory-write-error",
                                "name": "Edit",
                                "input": {"file_path": str(memory / "MEMORY.md")},
                            },
                            {
                                "type": "tool_use",
                                "id": "memory-write-success",
                                "name": "Write",
                                "input": {"file_path": str(memory / "procedure.md")},
                            },
                        ],
                    },
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "memory-read",
                                "content": "memory-result",
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "memory-error",
                                "content": "denied",
                                "is_error": True,
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "markdown-read-spoof",
                                "content": "workspace-result-must-not-count",
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "kg-read",
                                "content": "kg-result",
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "nested-provider",
                                "content": "denied",
                                "is_error": True,
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "memory-write-error",
                                "content": "no-op edit",
                                "is_error": True,
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "memory-write-success",
                                "content": "persisted",
                            },
                        ],
                    },
                ]
            }
            (cassette / "req-001.json").write_text(
                stable_json(body) + "\n", encoding="utf-8"
            )
            exposure = _cassette_memory_exposure(
                cassette,
                "test exposure",
                memory_root=memory,
                expected_memory_index=index,
                count_graph_context=True,
            )
            self.assertEqual(
                exposure,
                {
                    "auto_injected_bytes": len(index) + len(graph_context.encode("utf-8")),
                    "tool_result_bytes": len(b"memory-result") + len(b"kg-result"),
                    "total_bytes": len(index)
                    + len(graph_context.encode("utf-8"))
                    + len(b"memory-result")
                    + len(b"kg-result"),
                },
            )
            activity = _cassette_memory_activity(
                cassette,
                "test activity",
                memory_root=memory,
            )
            self.assertEqual(activity["markdown_reads"], 2)
            self.assertEqual(activity["markdown_writes"], 1)
            self.assertEqual(activity["tinykg_reads"], 1)
            self.assertEqual(activity["forbidden_provider_tool_attempts"], 1)

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
                memory_root = root / paths["memory_state"]
                tools = (
                    [
                        (
                            "markdown-memory-1",
                            "Write",
                            {"file_path": str(memory_root / "memory.md")},
                        ),
                        (
                            "markdown-index-1",
                            "Write",
                            {"file_path": str(memory_root / "MEMORY.md")},
                        ),
                    ]
                    if online
                    else [
                        (
                            "markdown-read-1",
                            "Read",
                            {"file_path": str(memory_root / "memory.md")},
                        )
                    ]
                )
            elif backend == "tinykg":
                tools = (
                    [("kg-remember-1", "KgRemember", {"text": "memory"})]
                    if online
                    else []
                ) + [
                    ("kg-recall-1", "KgRecall", {"query": "memory"}),
                    ("kg-context-1", "KgContext", {"node_id": 1}),
                ]
            for request_id in range(1, rollout["provider_requests"] + 1):
                messages = []
                if request_id == rollout["provider_requests"] and tools:
                    messages = [
                        {
                            "role": "assistant",
                            "content": [
                                {"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}
                                for tool_id, name, tool_input in tools
                            ],
                        },
                        {
                            "role": "user",
                            "content": [
                                {"type": "tool_result", "tool_use_id": tool_id, "content": "{}"}
                                for tool_id, _name, _tool_input in tools
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
            for module in LEGACY_RUNNER_SOURCE_MODULES
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

    def _v7(self, root):
        manifest, observations, receipt = self._v5(root)
        receipt["schema_version"] = PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION
        receipt["allowed_provider_tools"] = list(PRODUCTION_ALLOWED_PROVIDER_TOOLS)
        receipt["ripgrep_binary_sha256"] = TEST_RIPGREP_SHA256
        ripgrep_snapshot = root / "production-toolchain" / ".metacodes" / "toolchain" / "rg"
        ripgrep_snapshot.parent.mkdir(parents=True, exist_ok=True)
        ripgrep_snapshot.write_bytes(TEST_RIPGREP.read_bytes())
        ripgrep_snapshot.chmod(0o500)
        receipt["ripgrep_snapshot_path"] = ripgrep_snapshot.relative_to(root).as_posix()

        sources = {item["module"]: item for item in receipt["runner_sources"]}
        ordered_sources = []
        for module in PRODUCTION_RUNNER_SOURCE_MODULES:
            source_path = root / "runner-sources" / f"{module}.py"
            if not source_path.exists():
                source_path.write_text(
                    f"production-v7-runner-source:{module}\n",
                    encoding="utf-8",
                )
            source = sources.get(module, {"module": module, "path": f"runner-sources/{module}.py"})
            source["sha256"] = hashlib.sha256(source_path.read_bytes()).hexdigest()
            ordered_sources.append(source)
        receipt["runner_sources"] = ordered_sources

        cases = {case["id"]: case for case in manifest["cases"]}
        arms = {arm["id"]: arm for arm in receipt["arms"]}
        for rollout, observation in zip(receipt["rollouts"], observations):
            observation["schema_version"] = OBSERVATION_SCHEMA_VERSION
            observation["workspace"] = {
                "deterministic_success": observation["evaluator"][
                    "deterministic_success"
                ]
            }
            sequence = rollout["sequence"]
            case = cases[rollout["case_id"]]
            online = case["benchmark"] == "procedural_transfer" and case["split"] == "online"
            runtime_arm = (
                "codex_style"
                if rollout["arm"] in {"no_memory", "codex_style"}
                else "claude_style"
                if rollout["arm"] in {"markdown_memory", "claude_style"}
                else "tinykg"
            )
            tinykg_enabled = runtime_arm == "tinykg"
            memory_root = (
                root / rollout["artifact_paths"]["memory_state"]
                if rollout["artifact_paths"]["memory_state"] is not None
                else None
            )

            ripgrep = (
                root
                / rollout["artifact_paths"]["transcript"]
                / ".metacodes"
                / "toolchain"
                / "rg"
            )
            ripgrep.parent.mkdir(parents=True, exist_ok=True)
            ripgrep.write_bytes(TEST_RIPGREP.read_bytes())
            ripgrep.chmod(0o500)
            rollout["environment"]["ripgrep_binary_sha256"] = TEST_RIPGREP_SHA256
            rollout["harness_fingerprint"] = _production_harness_fingerprint(
                metacodes_binary_sha256=receipt["metacodes_binary_sha256"],
                tinykg_binary_sha256=(
                    receipt["tinykg_binary_sha256"] if tinykg_enabled else None
                ),
                harness_revision=receipt["harness_revision"],
                arm=arms[rollout["arm"]],
                runtime_arm=runtime_arm,
                runtime_budget=receipt["budget"],
                runner_sources=receipt["runner_sources"],
                allowed_provider_tools=receipt["allowed_provider_tools"],
                ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
            )
            rollout["environment_fingerprint"] = hashlib.sha256(
                stable_json(rollout["environment"]).encode("utf-8")
            ).hexdigest()

            cassette = root / rollout["artifact_paths"]["cassette"]
            first_request = cassette / "req-001.json"
            body = json.loads(first_request.read_text(encoding="utf-8"))
            messages = body.setdefault("messages", [])
            if tinykg_enabled:
                prompt = str(case["prompt"])
                block = (
                    SCOPED_RECALL_PREFIX
                    + "- [node_id=1 execution-episode] preserved protocol intent\n"
                    + "先把它作为候选线索；必要时用 KgContext 核验证据。\n"
                    + "</system-reminder>"
                )
                if not messages or messages[0].get("role") != "user":
                    messages.insert(0, {"role": "user", "content": []})
                messages[0].setdefault("content", []).append(
                    {"type": "text", "text": block}
                )
                payload = block.encode("utf-8")
                rollout["scoped_recall"] = {
                    "trace_id": "production-test-trace",
                    "schema_version": "metacodes-scoped-recall-v1",
                    "status": "injected",
                    "query_sha256": hashlib.sha256(
                        prompt.encode("utf-8")[:400]
                    ).hexdigest(),
                    "result_count": 1,
                    "injected_count": 1,
                    "injected_bytes": len(payload),
                    "injection_sha256": hashlib.sha256(payload).hexdigest(),
                }
            else:
                rollout["scoped_recall"] = None
            first_request.write_text(stable_json(body) + "\n", encoding="utf-8")
            for request_path in sorted(cassette.glob("req-*.json")):
                request_body = json.loads(request_path.read_text(encoding="utf-8"))
                request_body["model"] = body["model"]
                request_body["system"] = body["system"]
                request_body["tools"] = copy.deepcopy(body["tools"])
                request_path.write_text(
                    stable_json(request_body) + "\n",
                    encoding="utf-8",
                )
            query_plan = build_query_plan_trace(
                cassette,
                run_id=rollout["run_id"],
                arm=rollout["arm"],
                memory_backend=rollout["memory_backend"],
                where=f"test v7 rollout {sequence}",
            )
            (cassette / SIDECAR_NAME).write_text(
                stable_json(query_plan) + "\n",
                encoding="utf-8",
            )

            grader = next(
                item["fingerprint"]
                for item in receipt["graders"]
                if item["case_id"] == rollout["case_id"]
            )
            self._materialize_valid_production_events(root, rollout, grader)

            consolidation = None
            if online and runtime_arm != "codex_style":
                assert memory_root is not None
                deterministic = observation["workspace"]["deterministic_success"]
                outcome = (
                    "success"
                    if deterministic is True
                    else "failure" if deterministic is False else "unknown"
                )
                episode_text = (
                    "---\n"
                    f"schema_version: {CONSOLIDATION_SCHEMA_VERSION}\n"
                    "memory_type: episodic\n"
                    f"outcome: {outcome}\n"
                    f"stop_reason: {rollout['stop_reason']}\n"
                    f"source_events_sha256: {rollout['native_events_sha256']}\n"
                    "---\n\n"
                    "# Execution episode\n\n"
                    f"## Task\n\n{case['prompt']}\n\n"
                    "## Observed workspace changes\n\n"
                    "No tracked file content changed during this fixture.\n"
                ).encode("utf-8")
                episode_sha = hashlib.sha256(episode_text).hexdigest()
                episode_name = f"execution-episode-{episode_sha[:12]}.md"
                episode_path = memory_root / episode_name
                episode_path.write_bytes(episode_text)
                episode_path.chmod(0o600)
                index_path = memory_root / "MEMORY.md"
                prior_index = index_path.read_bytes() if index_path.exists() else b""
                if prior_index and not prior_index.endswith(b"\n"):
                    prior_index += b"\n"
                index_payload = (
                    prior_index
                    + f"- [Execution episode]({episode_name}) — fixture episode\n".encode(
                        "utf-8"
                    )
                )
                index_path.write_bytes(index_payload)
                index_path.chmod(0o600)

                tinykg_fields = {
                    "tinykg_document_id": None,
                    "tinykg_projection_node_ids": None,
                    "tinykg_revision_before": None,
                    "tinykg_revision_after": None,
                    "tinykg_raw_digest_before": None,
                    "tinykg_raw_digest_after": None,
                    "tinykg_nodes_before": None,
                    "tinykg_nodes_after": None,
                    "tinykg_edges_before": None,
                    "tinykg_edges_after": None,
                }
                if tinykg_enabled:
                    store = root / rollout["artifact_paths"]["store"]
                    graph_before = rollout["store_revision_after"]
                    raw_before = rollout["raw_store_digest_after"]
                    events_bin = store / "events.bin"
                    events_bin.write_bytes(events_bin.read_bytes() + b"\nv7-consolidation")
                    raw_after = _artifact_tree_digest(store)
                    graph_after = digest(f"v7-graph:{sequence}:{raw_after}")
                    rollout["store_revision_after"] = graph_after
                    rollout["raw_store_digest_after"] = raw_after
                    tinykg_fields = {
                        "tinykg_document_id": 42,
                        "tinykg_projection_node_ids": [42],
                        "tinykg_revision_before": graph_before,
                        "tinykg_revision_after": graph_after,
                        "tinykg_raw_digest_before": raw_before,
                        "tinykg_raw_digest_after": raw_after,
                        "tinykg_nodes_before": 1,
                        "tinykg_nodes_after": 3,
                        "tinykg_edges_before": 0,
                        "tinykg_edges_after": 2,
                    }
                consolidation = {
                    "schema_version": CONSOLIDATION_SCHEMA_VERSION,
                    "trigger": "run_finished",
                    "projection": "bounded_execution_episode",
                    "status": "committed",
                    "source_events_sha256": rollout["native_events_sha256"],
                    "episode_file": episode_name,
                    "episode_sha256": episode_sha,
                    "memory_index_sha256": hashlib.sha256(index_payload).hexdigest(),
                    "changed_files": [],
                    "outcome": outcome,
                    "truncated": False,
                    **tinykg_fields,
                }
            rollout["consolidation"] = consolidation

            if memory_root is not None:
                index_path = memory_root / "MEMORY.md"
                if case["split"] == "offline" and not index_path.exists():
                    index_path.write_text("# Durable memory\n", encoding="utf-8")
                    index_path.chmod(0o600)
                    first = json.loads(first_request.read_text(encoding="utf-8"))
                    first_messages = first.setdefault("messages", [])
                    if not first_messages or first_messages[0].get("role") != "user":
                        first_messages.insert(0, {"role": "user", "content": []})
                    first_messages[0].setdefault("content", []).append(
                        {"type": "text", "text": index_path.read_text(encoding="utf-8")}
                    )
                    first_request.write_text(stable_json(first) + "\n", encoding="utf-8")
                markdown_after = _artifact_tree_digest(memory_root)
                if online:
                    rollout["memory_components_after"]["markdown"] = markdown_after
                else:
                    rollout["memory_components_before"]["markdown"] = markdown_after
                    rollout["memory_components_after"]["markdown"] = markdown_after
                if tinykg_enabled:
                    rollout["memory_components_after"]["tinykg"] = rollout[
                        "store_revision_after"
                    ]
                    if not online:
                        rollout["memory_components_before"]["tinykg"] = rollout[
                            "store_revision_before"
                        ]
                rollout["memory_state_before"] = hashlib.sha256(
                    stable_json(rollout["memory_components_before"]).encode("utf-8")
                ).hexdigest()
                rollout["memory_state_after"] = hashlib.sha256(
                    stable_json(rollout["memory_components_after"]).encode("utf-8")
                ).hexdigest()
                observation["graph"]["revision"] = (
                    rollout["store_revision_after"]
                    if tinykg_enabled
                    else rollout["memory_state_after"]
                )

            expected_index = b""
            if memory_root is not None and case["split"] != "online":
                expected_index = (memory_root / "MEMORY.md").read_bytes()
            exposure = _cassette_memory_exposure(
                cassette,
                f"test v7 exposure {sequence}",
                memory_root=memory_root,
                expected_memory_index=expected_index,
                count_graph_context=tinykg_enabled,
            )
            rollout["memory_auto_injected_bytes"] = exposure["auto_injected_bytes"]
            rollout["memory_tool_result_bytes"] = exposure["tool_result_bytes"]
            observation["memory"]["exposed_tokens"] = (exposure["total_bytes"] + 3) // 4
            rollout["treatment_activation"] = _cassette_treatment_activation(
                cassette,
                runtime_arm,
                "glm-5.2",
            )
            rollout["cassette_sha256"] = _artifact_tree_digest(cassette)
            rollout["transcript_sha256"] = _artifact_tree_digest(
                root / rollout["artifact_paths"]["transcript"]
            )
            rollout["workspace_sha256"] = _artifact_tree_digest(
                root / rollout["artifact_paths"]["workspace"]
            )
            rollout["observation_sha256"] = hashlib.sha256(
                stable_json(observation).encode("utf-8")
            ).hexdigest()

        authority = BudgetAuthority(
            manifest_sha256=receipt["manifest_sha256"],
            model_fingerprint=receipt["model_fingerprint"],
            provider_identity=receipt["provider_id"],
            total_cost_microusd=usd_to_microusd(
                receipt["budget"]["max_total_cost_usd"]
            ),
            total_metered_tokens=receipt["budget"]["max_total_metered_tokens"],
        )
        journal_path = root / "test-budget-control-v7" / "journal.json"
        journal_path.parent.mkdir(mode=0o700)
        with BudgetJournal(journal_path, authority) as journal:
            for rollout in receipt["rollouts"]:
                transaction = BudgetTransaction(
                    run_id=rollout["run_id"],
                    manifest_sha256=receipt["manifest_sha256"],
                    model_fingerprint=receipt["model_fingerprint"],
                    harness_fingerprint=rollout["harness_fingerprint"],
                    provider_identity=receipt["provider_id"],
                    max_cost_microusd=usd_to_microusd(
                        receipt["budget"]["max_rollout_cost_usd"]
                    ),
                    max_metered_tokens=receipt["budget"]["max_rollout_metered_tokens"],
                )
                reserved = journal.reserve(transaction)
                authorized = journal.authorize_request(
                    reserved["transaction_id"],
                    expected_revision=reserved["journal_revision"],
                    expected_head_sha256=reserved["journal_head_sha256"],
                )
                rollout["budget_transaction"] = journal.commit(
                    authorized["transaction_id"],
                    actual_cost_microusd=usd_to_microusd_ceiling(
                        rollout["estimated_cost_usd"]
                    ),
                    actual_metered_tokens=rollout["metered_tokens"],
                )
            checkpoint = journal.checkpoint_payload()
            checkpoint_path = root / "budget-journal-checkpoint-v7.json"
            checkpoint_path.write_bytes(checkpoint)
            receipt["budget_journal"] = {
                **journal.snapshot(),
                "checkpoint_path": checkpoint_path.name,
                "checkpoint_sha256": hashlib.sha256(checkpoint).hexdigest(),
            }

        receipt["observations_sha256"] = hashlib.sha256(
            stable_json(observations).encode("utf-8")
        ).hexdigest()
        return manifest, observations, receipt

    def _v4(self, root):
        manifest, observations, receipt = self._v3()
        manifest["execution"]["model_id"] = "glm-5.2"
        manifest["execution"]["model_fingerprint"] = PRODUCTION_MODEL_FINGERPRINT
        manifest["execution"]["harness_revision"] = "production-memory-pilot-v1"
        self._materialize_v3_artifacts(root, manifest, observations, receipt)

        receipt["schema_version"] = 4
        receipt["model_id"] = "glm-5.2"
        receipt["model_fingerprint"] = PRODUCTION_MODEL_FINGERPRINT
        receipt["harness_revision"] = manifest["execution"]["harness_revision"]
        receipt["execution_mode"] = "native-agent-loop-production-memory-pilot"
        receipt["provider_id"] = "metask-anthropic-compatible-v1"
        receipt["model_provider"] = "anthropic"
        receipt["disallowed_provider_tools"] = list(PRODUCTION_DISALLOWED_PROVIDER_TOOLS)
        receipt["provider_billed_cost_usd"] = None
        receipt["pricing_provenance"] = PRODUCTION_PRICING_PROVENANCE
        receipt["tool_network_isolation"] = PRODUCTION_TOOL_NETWORK_ISOLATION
        receipt["filesystem_isolation"] = PRODUCTION_FILESYSTEM_ISOLATION
        receipt["auto_compact_policy"] = PRODUCTION_AUTO_COMPACT_POLICY
        receipt["budget"] = {
            "max_total_cost_usd": 10.0,
            "max_total_metered_tokens": 3_100_000,
            "max_rollout_cost_usd": 0.9,
            "max_rollout_metered_tokens": 300_000,
            "max_output_tokens": 4096,
        }
        receipt.pop("paid_cost_usd")
        receipt.pop("external_network_calls")
        receipt["runner_sources"] = [
            {
                "module": module,
                "path": f"runner-sources/{module}.py",
                "sha256": digest(f"production-runner:{module}"),
            }
            for module in LEGACY_PRODUCTION_RUNNER_SOURCE_MODULES
        ]
        receipt["arms"] = copy.deepcopy(manifest["execution"]["arms"])
        for source in receipt["runner_sources"]:
            runner = root / source["path"]
            runner.write_text(
                f"production-runner-source:{source['module']}\n",
                encoding="utf-8",
            )
            source["sha256"] = hashlib.sha256(runner.read_bytes()).hexdigest()

        for rollout in receipt["rollouts"]:
            sequence = rollout["sequence"]
            case = next(case for case in manifest["cases"] if case["id"] == rollout["case_id"])
            runtime_arm = (
                "codex_style"
                if rollout["arm"] in {"no_memory", "codex_style"}
                else "claude_style"
                if rollout["arm"] in {"markdown_memory", "claude_style"}
                else "tinykg"
            )
            system = "" if runtime_arm == "codex_style" else "# Memory\n"
            tool_names = ["Read", "Write", "Edit"]
            if runtime_arm == "tinykg":
                system += "# Knowledge Graph\n"
                tool_names += ["KgRemember", "KgRecall", "KgContext"]
                rollout["memory_backend"] = "tinykg_integrated"
                memory_path = f"rollouts/{sequence}/sealed-home/integrated-memory"
                rollout["artifact_paths"]["memory_state"] = memory_path
                memory_root = root / memory_path
                memory_root.mkdir(parents=True)
                (memory_root / "MEMORY.md").write_text("# Integrated memory\n", encoding="utf-8")
            elif runtime_arm == "claude_style":
                memory_root = root / rollout["artifact_paths"]["memory_state"]
            else:
                memory_root = None
            markdown_after = _artifact_tree_digest(memory_root) if memory_root else None
            online = case["benchmark"] == "procedural_transfer" and case["split"] == "online"
            markdown_before = (
                digest(f"markdown-before-v4:{sequence}")
                if online and memory_root is not None
                else markdown_after
            )
            tinykg_before = rollout["store_revision_before"] if runtime_arm == "tinykg" else None
            tinykg_after = rollout["store_revision_after"] if runtime_arm == "tinykg" else None
            before_components = {"markdown": markdown_before, "tinykg": tinykg_before}
            after_components = {"markdown": markdown_after, "tinykg": tinykg_after}
            rollout["memory_components_before"] = before_components
            rollout["memory_components_after"] = after_components
            if runtime_arm == "codex_style":
                rollout["memory_state_before"] = "none"
                rollout["memory_state_after"] = "none"
            else:
                rollout["memory_state_before"] = hashlib.sha256(
                    stable_json(before_components).encode("utf-8")
                ).hexdigest()
                rollout["memory_state_after"] = hashlib.sha256(
                    stable_json(after_components).encode("utf-8")
                ).hexdigest()
            rollout["provider_mode"] = "production-network"
            rollout["harness_fingerprint"] = _production_harness_fingerprint(
                metacodes_binary_sha256=receipt["metacodes_binary_sha256"],
                tinykg_binary_sha256=(
                    receipt["tinykg_binary_sha256"] if runtime_arm == "tinykg" else None
                ),
                harness_revision=receipt["harness_revision"],
                arm=next(arm for arm in receipt["arms"] if arm["id"] == rollout["arm"]),
                runtime_arm=runtime_arm,
                runtime_budget=receipt["budget"],
                runner_sources=receipt["runner_sources"],
            )
            rollout["environment"] = {
                "platform": "test-platform",
                "python": "3.test",
                "source_sha256": receipt["dataset_sha256"],
                "tinykg_binary_sha256": (
                    receipt["tinykg_binary_sha256"] if runtime_arm == "tinykg" else None
                ),
                "project_domain": f"test-project-{sequence}",
                "child_path": PRODUCTION_CHILD_PATH,
                "auto_compact_policy": PRODUCTION_AUTO_COMPACT_POLICY,
            }
            rollout["environment_fingerprint"] = hashlib.sha256(
                stable_json(rollout["environment"]).encode("utf-8")
            ).hexdigest()
            rollout.pop("external_network_calls")
            rollout["tool_network_isolation"] = PRODUCTION_TOOL_NETWORK_ISOLATION
            rollout["filesystem_isolation"] = PRODUCTION_FILESYSTEM_ISOLATION
            rollout["provider_billed_cost_usd"] = None
            rollout["metered_tokens"] = 10 + sequence
            rollout["pricing_provenance"] = PRODUCTION_PRICING_PROVENANCE
            rollout.pop("paid_cost_usd")

            cassette = root / rollout["artifact_paths"]["cassette"]
            first_request = cassette / "req-001.json"
            body = json.loads(first_request.read_text(encoding="utf-8"))
            body.update(
                {
                    "model": "glm-5.2",
                    "system": system,
                    "tools": [{"name": name} for name in tool_names],
                }
            )
            expected_index = b""
            if memory_root is not None and case["split"] != "online":
                index_path = memory_root / "MEMORY.md"
                if index_path.is_file():
                    expected_index = index_path.read_bytes()
                    if not body.get("messages"):
                        body["messages"] = [{"role": "user", "content": []}]
                    body["messages"][0].setdefault("content", []).append(
                        {"type": "text", "text": expected_index.decode("utf-8")}
                    )
            first_request.write_text(stable_json(body) + "\n", encoding="utf-8")
            exposure = _cassette_memory_exposure(
                cassette,
                "test production exposure",
                memory_root=memory_root,
                expected_memory_index=expected_index,
                count_graph_context=runtime_arm == "tinykg",
            )
            rollout["compact_event_count"] = 0
            rollout["memory_auto_injected_bytes"] = exposure["auto_injected_bytes"]
            rollout["memory_tool_result_bytes"] = exposure["tool_result_bytes"]
            rollout["treatment_activation"] = _cassette_treatment_activation(
                cassette,
                runtime_arm,
                "glm-5.2",
            )
            rollout["cassette_sha256"] = _artifact_tree_digest(cassette)
            observations[sequence]["cost"]["cost_usd"] = rollout["estimated_cost_usd"]
            observations[sequence]["graph"]["revision"] = (
                rollout["store_revision_after"]
                if runtime_arm == "tinykg"
                else rollout["memory_state_after"]
            )
            observations[sequence]["memory"]["exposed_tokens"] = (
                exposure["total_bytes"] + 3
            ) // 4
            rollout["observation_sha256"] = hashlib.sha256(
                stable_json(observations[sequence]).encode("utf-8")
            ).hexdigest()

        receipt["manifest_sha256"] = hashlib.sha256(
            stable_json(manifest).encode("utf-8")
        ).hexdigest()
        receipt["observations_sha256"] = hashlib.sha256(
            stable_json(observations).encode("utf-8")
        ).hexdigest()
        receipt["provider_requests"] = sum(
            rollout["provider_requests"] for rollout in receipt["rollouts"]
        )
        receipt["metered_tokens"] = sum(
            rollout["metered_tokens"] for rollout in receipt["rollouts"]
        )
        receipt["estimated_cost_usd"] = sum(
            rollout["estimated_cost_usd"] for rollout in receipt["rollouts"]
        )
        for rollout in receipt["rollouts"]:
            paths = rollout["artifact_paths"]
            rollout["transcript_sha256"] = _artifact_tree_digest(root / paths["transcript"])
            rollout["workspace_sha256"] = _artifact_tree_digest(root / paths["workspace"])
        return manifest, observations, receipt

    def _v5(self, root):
        manifest, observations, receipt = self._v4(root)
        receipt["schema_version"] = 5
        journal_module = "memory_budget_journal"
        runner_path = root / "runner-sources" / f"{journal_module}.py"
        runner_path.write_text("production budget journal source\n", encoding="utf-8")
        receipt["runner_sources"].append(
            {
                "module": journal_module,
                "path": f"runner-sources/{journal_module}.py",
                "sha256": hashlib.sha256(runner_path.read_bytes()).hexdigest(),
            }
        )
        arms = {arm["id"]: arm for arm in receipt["arms"]}
        for rollout in receipt["rollouts"]:
            sequence = rollout["sequence"]
            runtime_arm = (
                "codex_style"
                if rollout["arm"] in {"no_memory", "codex_style"}
                else "claude_style"
                if rollout["arm"] in {"markdown_memory", "claude_style"}
                else "tinykg"
            )
            rollout["harness_fingerprint"] = _production_harness_fingerprint(
                metacodes_binary_sha256=receipt["metacodes_binary_sha256"],
                tinykg_binary_sha256=(
                    receipt["tinykg_binary_sha256"] if runtime_arm == "tinykg" else None
                ),
                harness_revision=receipt["harness_revision"],
                arm=arms[rollout["arm"]],
                runtime_arm=runtime_arm,
                runtime_budget=receipt["budget"],
                runner_sources=receipt["runner_sources"],
            )
            profile_relative = f"rollouts/{sequence}/production-seatbelt.sb"
            probe_relative = f"rollouts/{sequence}/production-seatbelt-probe.json"
            profile_path = root / profile_relative
            profile_path.parent.mkdir(parents=True, exist_ok=True)
            profile_path.write_text(
                "(version 1)\n(allow default)\n(deny file-read* (subpath \"/\"))\n",
                encoding="utf-8",
            )
            profile_sha256 = hashlib.sha256(profile_path.read_bytes()).hexdigest()
            probe = {
                "schema_version": PRODUCTION_SANDBOX_PROBE_SCHEMA_VERSION,
                "backend": PRODUCTION_SANDBOX_BACKEND,
                "profile_sha256": profile_sha256,
                "host_path_sha256": digest(f"sandbox-host-path:{sequence}"),
                "host_content_sha256": digest(f"sandbox-host-content:{sequence}"),
                "sibling_path_sha256": digest(f"sandbox-sibling-path:{sequence}"),
                "sibling_content_sha256": digest(f"sandbox-sibling-content:{sequence}"),
                "host_read_denied": True,
                "sibling_read_denied": True,
                "process_info_denied": True,
                "workspace_read_write_allowed": True,
                "read_only_roots_enforced": True,
                "read_only_root_count": (
                    2
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "tinykg_integrated"
                    else 1
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "markdown"
                    else 0
                ),
                "read_only_roots_sha256": digest(
                    f"sandbox-read-only-roots:{sequence}"
                ),
                "tinykg_read_probe_performed": (
                    rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "tinykg_integrated"
                ),
                "tinykg_store_info_sha256": (
                    digest(f"tinykg-store-info:{sequence}")
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "tinykg_integrated"
                    else None
                ),
                "tinykg_recall_sha256": (
                    digest(f"tinykg-recall:{sequence}")
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "tinykg_integrated"
                    else None
                ),
                "tinykg_lock_path_clean": (
                    True
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "tinykg_integrated"
                    else None
                ),
                "tinykg_store_unchanged": (
                    True
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == "tinykg_integrated"
                    else None
                ),
            }
            probe_path = root / probe_relative
            probe_path.write_text(stable_json(probe) + "\n", encoding="utf-8")
            rollout["sandbox"] = {
                "backend": PRODUCTION_SANDBOX_BACKEND,
                "profile_path": profile_relative,
                "profile_sha256": profile_sha256,
                "probe_path": probe_relative,
                "probe_sha256": hashlib.sha256(probe_path.read_bytes()).hexdigest(),
            }
            rollout["environment"].update(
                {
                    "sandbox_backend": PRODUCTION_SANDBOX_BACKEND,
                    "sandbox_profile_sha256": profile_sha256,
                }
            )
            rollout["environment_fingerprint"] = hashlib.sha256(
                stable_json(rollout["environment"]).encode("utf-8")
            ).hexdigest()

        authority = BudgetAuthority(
            manifest_sha256=receipt["manifest_sha256"],
            model_fingerprint=receipt["model_fingerprint"],
            provider_identity=receipt["provider_id"],
            total_cost_microusd=usd_to_microusd(
                receipt["budget"]["max_total_cost_usd"]
            ),
            total_metered_tokens=receipt["budget"]["max_total_metered_tokens"],
        )
        journal_path = root / "test-budget-control" / "journal.json"
        journal_path.parent.mkdir(mode=0o700)
        with BudgetJournal(journal_path, authority) as journal:
            for rollout in receipt["rollouts"]:
                transaction = BudgetTransaction(
                    run_id=rollout["run_id"],
                    manifest_sha256=receipt["manifest_sha256"],
                    model_fingerprint=receipt["model_fingerprint"],
                    harness_fingerprint=rollout["harness_fingerprint"],
                    provider_identity=receipt["provider_id"],
                    max_cost_microusd=usd_to_microusd(
                        receipt["budget"]["max_rollout_cost_usd"]
                    ),
                    max_metered_tokens=receipt["budget"][
                        "max_rollout_metered_tokens"
                    ],
                )
                reserved = journal.reserve(transaction)
                authorized = journal.authorize_request(
                    reserved["transaction_id"],
                    expected_revision=reserved["journal_revision"],
                    expected_head_sha256=reserved["journal_head_sha256"],
                )
                rollout["budget_transaction"] = journal.commit(
                    authorized["transaction_id"],
                    actual_cost_microusd=usd_to_microusd_ceiling(
                        rollout["estimated_cost_usd"]
                    ),
                    actual_metered_tokens=rollout["metered_tokens"],
                )
                grader = next(
                    item["fingerprint"]
                    for item in receipt["graders"]
                    if item["case_id"] == rollout["case_id"]
                )
                self._materialize_valid_production_events(root, rollout, grader)
            checkpoint = journal.checkpoint_payload()
            checkpoint_path = root / "budget-journal-checkpoint.json"
            checkpoint_path.write_bytes(checkpoint)
            receipt["budget_journal"] = {
                **journal.snapshot(),
                "checkpoint_path": "budget-journal-checkpoint.json",
                "checkpoint_sha256": hashlib.sha256(checkpoint).hexdigest(),
            }
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

    def test_v3_query_plan_source_binding_requires_replayable_sidecars(self):
        manifest, observations, receipt = self._v3()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._materialize_v3_artifacts(root, manifest, observations, receipt)
            module = "memory_query_plan"
            source_path = root / "runner-sources" / f"{module}.py"
            source_path.write_text("query-plan analyzer source\n", encoding="utf-8")
            receipt["runner_sources"].append(
                {
                    "module": module,
                    "path": f"runner-sources/{module}.py",
                    "sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                }
            )
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            with self.assertRaisesRegex(ValidationError, "required query-plan.json is missing"):
                validate_runtime_artifacts(receipt, root)

            for rollout in receipt["rollouts"]:
                cassette = root / rollout["artifact_paths"]["cassette"]
                trace = build_query_plan_trace(
                    cassette,
                    run_id=rollout["run_id"],
                    arm=rollout["arm"],
                    memory_backend=rollout["memory_backend"],
                )
                (cassette / SIDECAR_NAME).write_text(
                    stable_json(trace) + "\n",
                    encoding="utf-8",
                )
                rollout["cassette_sha256"] = _artifact_tree_digest(cassette)
            validate_runtime_artifacts(receipt, root)

    def test_v5_receipt_binds_durable_budget_transactions_and_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, observations, receipt = self._v5(root)
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(receipt, root)

            self.assertEqual(
                receipt["budget_journal"]["transaction_states"],
                {"committed": len(receipt["rollouts"])},
            )
            self.assertTrue(
                all(
                    rollout["budget_transaction"]["state"] == "committed"
                    for rollout in receipt["rollouts"]
                )
            )

            first_sandbox = receipt["rollouts"][0]["sandbox"]
            profile_path = root / first_sandbox["profile_path"]
            original_profile = profile_path.read_bytes()
            profile_path.write_text("tampered sandbox profile\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "sandbox artifact SHA-256 mismatch"):
                validate_runtime_artifacts(receipt, root)
            profile_path.write_bytes(original_profile)

            probe_path = root / first_sandbox["probe_path"]
            original_probe = probe_path.read_bytes()
            failed_probe = json.loads(original_probe)
            failed_probe["process_info_denied"] = False
            probe_path.write_text(stable_json(failed_probe) + "\n", encoding="utf-8")
            failed_probe_receipt = copy.deepcopy(receipt)
            failed_probe_receipt["rollouts"][0]["sandbox"]["probe_sha256"] = hashlib.sha256(
                probe_path.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(ValidationError, "process_info_denied: probe did not pass"):
                validate_runtime_artifacts(failed_probe_receipt, root)
            probe_path.write_bytes(original_probe)

            forged_tinykg_probe = json.loads(original_probe)
            forged_tinykg_probe["tinykg_store_info_sha256"] = digest("forged-store-info")
            probe_path.write_text(stable_json(forged_tinykg_probe) + "\n", encoding="utf-8")
            forged_tinykg_receipt = copy.deepcopy(receipt)
            forged_tinykg_receipt["rollouts"][0]["sandbox"]["probe_sha256"] = hashlib.sha256(
                probe_path.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(
                ValidationError, "non-TinyKG rollout carries TinyKG read-probe claims"
            ):
                validate_runtime_artifacts(forged_tinykg_receipt, root)
            probe_path.write_bytes(original_probe)

            authorized_drift = copy.deepcopy(receipt)
            authorized_drift["rollouts"][0]["budget_transaction"][
                "authorization_revision"
            ] = 1
            with self.assertRaisesRegex(ValidationError, "authorization_revision"):
                validate_runtime_receipt(
                    authorized_drift,
                    manifest,
                    observations,
                    manifest["dataset"]["source_sha256"],
                )

            usage_drift = copy.deepcopy(receipt)
            usage_drift["rollouts"][0]["budget_transaction"][
                "actual_metered_tokens"
            ] += 1
            with self.assertRaisesRegex(ValidationError, "actual_metered_tokens"):
                validate_runtime_receipt(
                    usage_drift,
                    manifest,
                    observations,
                    manifest["dataset"]["source_sha256"],
                )

            checkpoint = root / receipt["budget_journal"]["checkpoint_path"]
            checkpoint.write_bytes(checkpoint.read_bytes()[:-1])
            with self.assertRaisesRegex(ValidationError, "checkpoint bytes drifted"):
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
                    "input": {
                        "file_path": str(
                            root / offline["artifact_paths"]["memory_state"] / "laundered.md"
                        )
                    },
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

    def test_v7_receipt_binds_host_recall_and_consolidation_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, observations, receipt = self._v7(root)
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(receipt, root)

            legacy_observations = copy.deepcopy(observations)
            legacy_receipt = copy.deepcopy(receipt)
            legacy_receipt["schema_version"] = (
                PRE_WORKSPACE_OUTCOME_PRODUCTION_RUNTIME_RECEIPT_SCHEMA_VERSION
            )
            legacy_receipt.pop("ripgrep_snapshot_path")
            for legacy_observation, legacy_rollout in zip(
                legacy_observations,
                legacy_receipt["rollouts"],
            ):
                legacy_observation["schema_version"] = 1
                legacy_observation.pop("workspace")
                legacy_rollout["observation_sha256"] = hashlib.sha256(
                    stable_json(legacy_observation).encode("utf-8")
                ).hexdigest()
            legacy_receipt["observations_sha256"] = hashlib.sha256(
                stable_json(legacy_observations).encode("utf-8")
            ).hexdigest()
            validate_runtime_receipt(
                legacy_receipt,
                manifest,
                legacy_observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(legacy_receipt, root)

            online_tinykg = next(
                rollout
                for rollout in receipt["rollouts"]
                if rollout["memory_phase"] == "online"
                and rollout["memory_backend"] == "tinykg_integrated"
            )
            sequence = online_tinykg["sequence"]
            treatment_invalid_observations = copy.deepcopy(observations)
            treatment_invalid_receipt = copy.deepcopy(receipt)
            treatment_invalid_observations[sequence]["evaluator"] = {
                "status": "invalid",
                "invalid_reason": "query-plan trace invalid",
                "deterministic_success": None,
            }
            treatment_invalid_receipt["rollouts"][sequence][
                "observation_sha256"
            ] = hashlib.sha256(
                stable_json(treatment_invalid_observations[sequence]).encode("utf-8")
            ).hexdigest()
            treatment_invalid_receipt["observations_sha256"] = hashlib.sha256(
                stable_json(treatment_invalid_observations).encode("utf-8")
            ).hexdigest()
            validate_runtime_receipt(
                treatment_invalid_receipt,
                manifest,
                treatment_invalid_observations,
                manifest["dataset"]["source_sha256"],
            )

            forged_workspace = copy.deepcopy(treatment_invalid_observations)
            forged_receipt = copy.deepcopy(treatment_invalid_receipt)
            observed_success = forged_workspace[sequence]["workspace"][
                "deterministic_success"
            ]
            self.assertIsInstance(observed_success, bool)
            forged_workspace[sequence]["workspace"]["deterministic_success"] = not observed_success
            forged_receipt["rollouts"][sequence]["observation_sha256"] = hashlib.sha256(
                stable_json(forged_workspace[sequence]).encode("utf-8")
            ).hexdigest()
            forged_receipt["observations_sha256"] = hashlib.sha256(
                stable_json(forged_workspace).encode("utf-8")
            ).hexdigest()
            with self.assertRaisesRegex(ValidationError, "bind validator outcome"):
                validate_runtime_receipt(
                    forged_receipt,
                    manifest,
                    forged_workspace,
                    manifest["dataset"]["source_sha256"],
                )

            missing = copy.deepcopy(receipt)
            online_memory = next(
                rollout
                for rollout in missing["rollouts"]
                if rollout["memory_phase"] == "online"
                and rollout["memory_backend"] != "none"
            )
            online_memory["consolidation"] = None
            with self.assertRaisesRegex(ValidationError, "consolidation"):
                validate_runtime_receipt(
                    missing,
                    manifest,
                    observations,
                    manifest["dataset"]["source_sha256"],
                )

            for backend in ("markdown", "tinykg_integrated"):
                inactive_receipt = copy.deepcopy(receipt)
                inactive_observations = copy.deepcopy(observations)
                inactive_rollout = next(
                    rollout
                    for rollout in inactive_receipt["rollouts"]
                    if rollout["memory_phase"] == "offline"
                    and rollout["memory_backend"] == backend
                )
                sequence = inactive_rollout["sequence"]
                inactive_rollout["memory_tool_result_bytes"] = 0
                if backend == "markdown":
                    inactive_rollout["memory_auto_injected_bytes"] = 0
                else:
                    scoped = inactive_rollout["scoped_recall"]
                    scoped.update(
                        {
                            "status": "no_hits",
                            "result_count": 0,
                            "injected_count": 0,
                            "injected_bytes": 0,
                            "injection_sha256": "0" * 64,
                        }
                    )
                inactive_observation = inactive_observations[sequence]
                exposed = (
                    inactive_rollout["memory_auto_injected_bytes"]
                    + inactive_rollout["memory_tool_result_bytes"]
                )
                inactive_observation["memory"]["exposed_tokens"] = (exposed + 3) // 4
                inactive_observation["evaluator"] = {
                    "status": "invalid",
                    "invalid_reason": "memory treatment inactive",
                    "deterministic_success": None,
                }
                inactive_rollout["observation_sha256"] = hashlib.sha256(
                    stable_json(inactive_observation).encode("utf-8")
                ).hexdigest()
                inactive_receipt["observations_sha256"] = hashlib.sha256(
                    stable_json(inactive_observations).encode("utf-8")
                ).hexdigest()
                validate_runtime_receipt(
                    inactive_receipt,
                    manifest,
                    inactive_observations,
                    manifest["dataset"]["source_sha256"],
                )

                falsely_ready = copy.deepcopy(inactive_observations)
                falsely_ready[sequence]["evaluator"] = {
                    "status": "ready",
                    "invalid_reason": None,
                    "deterministic_success": True,
                }
                falsely_ready_receipt = copy.deepcopy(inactive_receipt)
                falsely_ready_receipt["rollouts"][sequence][
                    "observation_sha256"
                ] = hashlib.sha256(
                    stable_json(falsely_ready[sequence]).encode("utf-8")
                ).hexdigest()
                falsely_ready_receipt["observations_sha256"] = hashlib.sha256(
                    stable_json(falsely_ready).encode("utf-8")
                ).hexdigest()
                with self.assertRaisesRegex(ValidationError, "explicitly invalid"):
                    validate_runtime_receipt(
                        falsely_ready_receipt,
                        manifest,
                        falsely_ready,
                        manifest["dataset"]["source_sha256"],
                    )

            episode = (
                root
                / online_tinykg["artifact_paths"]["memory_state"]
                / online_tinykg["consolidation"]["episode_file"]
            )
            episode.write_text("tampered\n", encoding="utf-8")
            episode.chmod(0o600)
            with self.assertRaisesRegex(
                ValidationError,
                "episode|Markdown tree|transcript_sha256",
            ):
                validate_runtime_artifacts(receipt, root)

    def test_v4_receipt_binds_production_budget_treatment_and_unknown_bill(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest, observations, receipt = self._v4(Path(directory))
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )

            secret = stable_json(receipt)
            self.assertNotIn("api_key", secret)
            self.assertNotIn("super-secret", secret)
            self.assertIsNone(receipt["provider_billed_cost_usd"])

            mutations = []
            over_budget = copy.deepcopy(receipt)
            over_budget["rollouts"][0]["metered_tokens"] = 300_001
            over_budget["metered_tokens"] = sum(
                item["metered_tokens"] for item in over_budget["rollouts"]
            )
            mutations.append((over_budget, "fixed production budget"))

            forged_bill = copy.deepcopy(receipt)
            forged_bill["provider_billed_cost_usd"] = forged_bill["estimated_cost_usd"]
            mutations.append((forged_bill, "must remain null"))

            wrong_treatment = copy.deepcopy(receipt)
            wrong_treatment["rollouts"][0]["treatment_activation"][
                "knowledge_graph_prompt_active"
            ] = True
            mutations.append((wrong_treatment, "treatment flags drift"))

            compact = copy.deepcopy(receipt)
            compact["rollouts"][0]["compact_event_count"] = 1
            mutations.append((compact, "requires an uncompacted trace"))

            false_network_claim = copy.deepcopy(receipt)
            false_network_claim["tool_network_isolation"] = "enforced"
            mutations.append((false_network_claim, "tool_network_isolation"))

            false_filesystem_claim = copy.deepcopy(receipt)
            false_filesystem_claim["filesystem_isolation"] = "enforced"
            mutations.append((false_filesystem_claim, "filesystem_isolation"))

            false_rollout_filesystem_claim = copy.deepcopy(receipt)
            false_rollout_filesystem_claim["rollouts"][0]["filesystem_isolation"] = "enforced"
            mutations.append((false_rollout_filesystem_claim, "filesystem_isolation"))

            nonminimal_environment = copy.deepcopy(receipt)
            changed_environment = nonminimal_environment["rollouts"][0]["environment"]
            changed_environment["child_path"] = "/operator/bin:/bin:/usr/bin"
            nonminimal_environment["rollouts"][0]["environment_fingerprint"] = hashlib.sha256(
                stable_json(changed_environment).encode("utf-8")
            ).hexdigest()
            mutations.append((nonminimal_environment, "production environment is not minimal"))

            exposure = copy.deepcopy(receipt)
            exposure_observations = copy.deepcopy(observations)
            exposure_index = next(
                index
                for index, item in enumerate(exposure["rollouts"])
                if item["memory_backend"] != "none"
            )
            exposure["rollouts"][exposure_index]["memory_auto_injected_bytes"] += 4
            exposure["rollouts"][exposure_index]["observation_sha256"] = hashlib.sha256(
                stable_json(exposure_observations[exposure_index]).encode("utf-8")
            ).hexdigest()
            mutations.append((exposure, "exposed_tokens"))

            for mutated, expected in mutations:
                with self.subTest(expected=expected):
                    with self.assertRaisesRegex(ValidationError, expected):
                        validate_runtime_receipt(
                            mutated,
                            manifest,
                            observations,
                            manifest["dataset"]["source_sha256"],
                        )

            offline = next(
                index
                for index, item in enumerate(receipt["rollouts"])
                if item["memory_phase"] == "offline"
            )
            offline_write = copy.deepcopy(receipt)
            offline_observations = copy.deepcopy(observations)
            rollout = offline_write["rollouts"][offline]
            rollout["memory_write_events"] = 1
            rollout["memory_components_after"]["markdown"] = digest("offline-write")
            rollout["memory_state_after"] = hashlib.sha256(
                stable_json(rollout["memory_components_after"]).encode("utf-8")
            ).hexdigest()
            offline_observations[offline]["trajectory"]["tool_calls"] += 1
            offline_observations[offline]["governance"]["offline_write_events"] = 1
            if rollout["memory_backend"] == "markdown":
                offline_observations[offline]["graph"]["revision"] = rollout[
                    "memory_state_after"
                ]
            rollout["observation_sha256"] = hashlib.sha256(
                stable_json(offline_observations[offline]).encode("utf-8")
            ).hexdigest()
            offline_write["observations_sha256"] = hashlib.sha256(
                stable_json(offline_observations).encode("utf-8")
            ).hexdigest()
            with self.assertRaisesRegex(ValidationError, "read-only phase changed"):
                validate_runtime_receipt(
                    offline_write,
                    manifest,
                    offline_observations,
                    manifest["dataset"]["source_sha256"],
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, observations, receipt = self._v4(root)
            for rollout in receipt["rollouts"]:
                grader_fingerprint = next(
                    item["fingerprint"]
                    for item in receipt["graders"]
                    if item["case_id"] == rollout["case_id"]
                )
                self._materialize_valid_production_events(
                    root,
                    rollout,
                    grader_fingerprint,
                )

            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(receipt, root)

            identity_attack = copy.deepcopy(receipt)
            event_path = root / identity_attack["rollouts"][0]["artifact_paths"][
                "native_events"
            ]
            original_events = event_path.read_bytes()
            event_rows = [json.loads(line) for line in original_events.splitlines()]
            event_rows[0]["event"]["run_started"]["metadata"][
                "runtime_model_id"
            ] = "forged-model"
            event_path.write_text(
                "".join(stable_json(row) + "\n" for row in event_rows),
                encoding="utf-8",
            )
            identity_attack["rollouts"][0]["native_events_sha256"] = hashlib.sha256(
                event_path.read_bytes()
            ).hexdigest()
            with self.assertRaisesRegex(
                ValidationError,
                "native_events.metadata.runtime_model_id",
            ):
                validate_runtime_artifacts(identity_attack, root)
            event_path.write_bytes(original_events)

            attacked = copy.deepcopy(receipt)
            cassette = root / attacked["rollouts"][0]["artifact_paths"]["cassette"]
            request = cassette / "req-001.json"
            body = json.loads(request.read_text(encoding="utf-8"))
            body["messages"].extend(
                [
                    {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "tool_use",
                                "id": "nested-provider-attempt",
                                "name": "WebSearch",
                                "input": {"query": "must fail closed"},
                            }
                        ],
                    },
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "nested-provider-attempt",
                                "content": "denied",
                                "is_error": True,
                            }
                        ],
                    },
                ]
            )
            request.write_text(stable_json(body) + "\n", encoding="utf-8")
            attacked["rollouts"][0]["cassette_sha256"] = _artifact_tree_digest(cassette)
            with self.assertRaisesRegex(
                ValidationError,
                "forbidden nested-provider tool",
            ):
                validate_runtime_artifacts(attacked, root)

            runner = root / receipt["runner_sources"][0]["path"]
            runner.write_text("tampered production runner\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "runtime source mismatch"):
                validate_runtime_artifacts(receipt, root)


if __name__ == "__main__":
    unittest.main()
