from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.model import ValidationError
from scripts.eval.plugin_pair_runner import (
    _require_scoring_checkpoints,
    _verify_arm_inventory,
    build_plan,
    load_user_authority,
)
from scripts.eval.plugin_release_gate import load_protocol


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
        ):
            digest = _verify_arm_inventory(
                ROOT,
                protocol,
                "candidate",
                ROOT / "unused-wrapper",
            )
        self.assertEqual(64, len(digest))

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
