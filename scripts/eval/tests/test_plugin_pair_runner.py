from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.model import ValidationError
from scripts.eval.plugin_pair_runner import (
    _inventory,
    _require_scoring_checkpoints,
    _verify_arm_inventory,
    build_plan,
    load_user_authority,
    run_paid_pair,
)
from scripts.eval.plugin_release_gate import PluginGateError, load_protocol


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"


class PluginPairRunnerTest(unittest.TestCase):
    def test_default_plan_is_zero_provider_and_complete(self) -> None:
        plan = build_plan(ROOT, PROTOCOL)
        self.assertEqual(0, plan["provider_requests"])
        self.assertFalse(plan["quality_evidence"])
        self.assertEqual(36, len(plan["schedule"]))
        self.assertEqual(18, sum(row["arm"] == "baseline" for row in plan["schedule"]))
        self.assertEqual(18, sum(row["arm"] == "candidate" for row in plan["schedule"]))
        self.assertEqual(2.0, plan["fixed_rollout_budget"]["max_cost_usd"])
        self.assertEqual(2000000, plan["fixed_rollout_budget"]["max_metered_tokens"])
        self.assertEqual(8192, plan["fixed_rollout_budget"]["max_output_tokens"])
        self.assertEqual(
            {
                "state": "not_attested",
                "expected_sha256": load_protocol(ROOT, PROTOCOL)["coding_pair"][
                    "runtime_binary_sha256"
                ],
            },
            plan["runtime"],
        )

    def test_plan_attests_only_an_explicit_matching_runtime(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            runtime = temporary / "metacodes-release-small"
            runtime.write_bytes(b"explicit-plan-runtime")
            os.chmod(runtime, 0o700)
            protocol["coding_pair"]["runtime_binary_sha256"] = hashlib.sha256(
                runtime.read_bytes()
            ).hexdigest()
            protocol_path = temporary / "protocol.json"
            protocol_path.write_text(json.dumps(protocol), encoding="utf-8")
            plan = build_plan(
                ROOT,
                protocol_path,
                runtime_binary=runtime,
            )
            self.assertEqual("attested", plan["runtime"]["state"])
            self.assertEqual(str(runtime.resolve()), plan["runtime"]["path"])

    def test_paid_pair_rejects_runtime_drift_before_private_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            runtime = temporary / "wrong-runtime"
            runtime.write_bytes(b"wrong-runtime")
            os.chmod(runtime, 0o700)
            with self.assertRaisesRegex(PluginGateError, "ReleaseSmall runtime drifted"):
                run_paid_pair(
                    ROOT,
                    PROTOCOL,
                    runtime_binary=runtime,
                    output_dir=temporary / "output",
                    budget_journal_path=temporary / "budget.jsonl",
                    provider_auth_file=temporary / "missing-provider-auth",
                    user_authority_file=temporary / "missing-user-authority",
                )

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture required")
    def test_inventory_wrapper_executes_the_explicit_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "runtime.py"
            runtime.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os\n"
                "print(json.dumps({"
                "'schema':'metacodes.plugin-inventory/v1',"
                "'contract_version':1,'plugins':[],"
                "'runtime_marker':'explicit',"
                "'runtime_selector_visible':"
                "'METACODES_PLUGIN_RUNTIME_BINARY' in os.environ}))\n",
                encoding="utf-8",
            )
            os.chmod(runtime, 0o700)
            inventory = _inventory(
                ROOT,
                ROOT / "scripts/eval/fixtures/plugin_baseline.py",
                runtime,
            )
            self.assertEqual("explicit", inventory["runtime_marker"])
            self.assertFalse(inventory["runtime_selector_visible"])

    def test_paid_authority_must_bind_exact_protocol_and_permissions(self) -> None:
        plan = build_plan(ROOT, PROTOCOL)
        value = {
            "schema": "metacodes.plugin-paid-authority/v1",
            "protocol_sha256": plan["protocol_sha256"],
            "max_cost_usd": 30.0,
            "max_metered_tokens": 30000000,
            "authorized_by_user": True,
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authority.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            os.chmod(path, 0o600)
            observed = load_user_authority(
                path,
                protocol_sha256=plan["protocol_sha256"],
                max_cost_usd=30.0,
                max_metered_tokens=30000000,
            )
            self.assertEqual(value, observed)
            value["protocol_sha256"] = "0" * 64
            path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(ValidationError):
                load_user_authority(
                    path,
                    protocol_sha256=plan["protocol_sha256"],
                    max_cost_usd=30.0,
                    max_metered_tokens=30000000,
                )

    @unittest.skipIf(os.name == "nt", "POSIX permissions required")
    def test_paid_authority_rejects_group_readable_file(self) -> None:
        plan = build_plan(ROOT, PROTOCOL)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authority.json"
            path.write_text(
                json.dumps(
                    {
                        "schema": "metacodes.plugin-paid-authority/v1",
                        "protocol_sha256": plan["protocol_sha256"],
                        "max_cost_usd": 30.0,
                        "max_metered_tokens": 30000000,
                        "authorized_by_user": True,
                    }
                ),
                encoding="utf-8",
            )
            os.chmod(path, 0o640)
            with self.assertRaises(ValidationError):
                load_user_authority(
                    path,
                    protocol_sha256=plan["protocol_sha256"],
                    max_cost_usd=30.0,
                    max_metered_tokens=30000000,
                )

    def test_paid_inventory_projects_the_stable_treatment_fields(self) -> None:
        protocol = load_protocol(ROOT, PROTOCOL)
        full_inventory = {
            "schema": "metacodes.plugin-inventory/v1",
            "contract_version": 1,
            "generation": 1,
            "plugins": [
                {
                    "id": "metacodes.benchmark-coding",
                    "version": protocol["candidate"]["plugin_version"],
                    "form": "data_package",
                    "layer": "session",
                    "lifecycle": "active",
                    "capabilities": ["skill_bundle"],
                    "contribution_count": 1,
                    "source_root": "/private/frozen-plugin-root",
                }
            ],
        }
        with mock.patch(
            "scripts.eval.plugin_pair_runner._inventory",
            return_value=full_inventory,
        ), mock.patch(
            "scripts.eval.plugin_pair_runner.attest_runtime_artifact"
        ) as attest:
            digest = _verify_arm_inventory(
                ROOT,
                protocol,
                "candidate",
                ROOT / "unused-wrapper",
                ROOT / "unused-runtime",
            )
        self.assertEqual(64, len(digest))
        self.assertEqual(2, attest.call_count)

    def test_paid_resume_rejects_persisted_invalid_rollout(self) -> None:
        invalid = {
            "task_id": "02_html_game",
            "trial": 0,
            "judgement": {"valid_for_scoring": False},
            "execution": {
                "invalid_reasons": ["harness_or_provider_error"],
            },
            "evaluator": {"status": "ready"},
        }
        with self.assertRaisesRegex(ValidationError, "fail-closed"):
            _require_scoring_checkpoints(
                {"baseline": [invalid], "candidate": []}
            )


if __name__ == "__main__":
    unittest.main()
