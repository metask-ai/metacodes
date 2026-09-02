from __future__ import annotations

import copy
import unittest
from pathlib import Path

from scripts.eval.memory_budget_journal import usd_to_microusd
from scripts.eval.model import ValidationError
from scripts.eval.plugin_pair_analysis import validate_paid_row
from scripts.eval.plugin_pair_runner import _canonical_sha256
from scripts.eval.plugin_release_gate import load_protocol_structure


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"


def row(protocol_sha256: str, model_fingerprint: str) -> dict:
    return {
        "harness": {
            "runtime_budget": {
                "max_metered_tokens": 2000000,
                "max_cost_usd": 2.0,
            }
        },
        "plugin_treatment": {
            "protocol_sha256": protocol_sha256,
            "frozen_manifest_sha256": "manifest",
            "arm": "candidate",
            "inventory_sha256": "inventory",
        },
        "metrics": {
            "input_tokens": 10,
            "output_tokens": 5,
            "cache_read_tokens": 0,
            "cache_write_tokens": 0,
            "cost_usd": 0.1,
        },
        "budget_transaction": {
            "state": "committed",
            "provider_identity": "anthropic:glm-5.2",
            "model_fingerprint": model_fingerprint,
            "max_cost_microusd": usd_to_microusd(2.0),
            "max_metered_tokens": 2000000,
            "actual_cost_microusd": usd_to_microusd(0.1),
            "actual_metered_tokens": 15,
        },
    }


class PluginPairAnalysisTest(unittest.TestCase):
    def test_paid_row_binds_treatment_budget_and_usage(self) -> None:
        protocol = load_protocol_structure(ROOT, PROTOCOL)
        protocol_sha256 = __import__("hashlib").sha256(PROTOCOL.read_bytes()).hexdigest()
        value = row(protocol_sha256, _canonical_sha256(protocol["coding_pair"]["model"]))
        validate_paid_row(
            value,
            protocol=protocol,
            protocol_sha256=protocol_sha256,
            frozen_manifest_sha256="manifest",
            arm="candidate",
            inventory_sha256="inventory",
        )
        tampered = copy.deepcopy(value)
        tampered["budget_transaction"]["actual_metered_tokens"] = 14
        with self.assertRaisesRegex(ValidationError, "does not match observed usage"):
            validate_paid_row(
                tampered,
                protocol=protocol,
                protocol_sha256=protocol_sha256,
                frozen_manifest_sha256="manifest",
                arm="candidate",
                inventory_sha256="inventory",
            )
        # A row from a run frozen under another manifest is not this run's
        # evidence, however sound its budget receipt.
        relabelled = copy.deepcopy(value)
        relabelled["plugin_treatment"]["frozen_manifest_sha256"] = "other-manifest"
        with self.assertRaisesRegex(ValidationError, "incorrect treatment attestation"):
            validate_paid_row(
                relabelled,
                protocol=protocol,
                protocol_sha256=protocol_sha256,
                frozen_manifest_sha256="manifest",
                arm="candidate",
                inventory_sha256="inventory",
            )


if __name__ == "__main__":
    unittest.main()
