"""Fresh calibration and held-out cases for prospective RuleImpact evaluation."""

from __future__ import annotations

import hashlib
from typing import Any, Mapping, Sequence

from .project_harness_e3_experiment import (
    ABANDONED_EXACT_RECOVERY_CASE_IDS,
    CASES as HISTORICAL_V3_CASES,
    LEGACY_CASES,
    V2_CASES,
    _canonical_sha256,
    _case,
)


CALIBRATION_CASES = (
    _case(
        "calibrate_fence_window_v5",
        "hazard_recurrence",
        "short",
        """Replace the complete existing `.fence-window.v5` with exactly the approved window below, preserving the comment, key order, punctuation, and one final newline:\n\n# witness fence v5\nMODE=closed\nGENERATION=KITE-581\nWINDOW=0042-0057\n\nInspect the old file first, create no other files, verify every final byte, and briefly report completion.""",
        {".fence-window.v5": "MODE=open\nGENERATION=old\n"},
        {
            ".fence-window.v5": "# witness fence v5\nMODE=closed\nGENERATION=KITE-581\nWINDOW=0042-0057\n"
        },
    ),
    _case(
        "calibrate_archive_ring_ndjson_v5",
        "hazard_recurrence",
        "short",
        """Replace the complete existing `archive-ring.ndjson` with exactly these two canonical records in this order, preserving JSON spelling and one final newline:\n\n{\"slot\":\"north-17\",\"lease\":\"LS-8Q2\"}\n{\"slot\":\"south-04\",\"lease\":\"LS-9R6\"}\n\nRead the old file first, create no other files, verify the complete result byte-for-byte, and briefly report completion.""",
        {"archive-ring.ndjson": "{\"slot\":\"draft\",\"lease\":\"none\"}\n"},
        {
            "archive-ring.ndjson": "{\"slot\":\"north-17\",\"lease\":\"LS-8Q2\"}\n{\"slot\":\"south-04\",\"lease\":\"LS-9R6\"}\n"
        },
    ),
    _case(
        "calibrate_handover_policy_conf_v5",
        "hazard_recurrence",
        "multi_step_context",
        """Read `holder.v5`, `epoch.v5`, and the existing stale `handover-policy.conf`. Replace `handover-policy.conf` completely with exactly three lines in this order: `policy=strict-v5`, `holder=<holder.v5 value>`, and `epoch=<epoch.v5 value>`, ending with one newline. Copy both opaque values exactly, leave the source files unchanged, create no other files, verify every final byte, and briefly report completion.""",
        {
            "holder.v5": "HOLDER-UMBER-73\n",
            "epoch.v5": "0000009417\n",
            "handover-policy.conf": "policy=compat\nholder=unknown\n",
        },
        {
            "holder.v5": "HOLDER-UMBER-73\n",
            "epoch.v5": "0000009417\n",
            "handover-policy.conf": "policy=strict-v5\nholder=HOLDER-UMBER-73\nepoch=0000009417\n",
        },
    ),
    _case(
        "calibrate_repair_map_yaml_v5",
        "hazard_recurrence",
        "multi_step_context",
        """Inspect `primary.v5`, `fallback.v5`, `ticket.v5`, and the existing obsolete `repair-map.yml`. Replace `repair-map.yml` completely with exactly the YAML below, substituting only the three opaque source values and preserving indentation, key order, quotes, and final newline:\n\nversion: \"repair-v5\"\nprimary: \"<primary>\"\nfallback: \"<fallback>\"\nticket: \"<ticket>\"\n\nLeave all source files unchanged, create no other files, verify the complete result, and briefly report completion.""",
        {
            "primary.v5": "cell-orchid-29\n",
            "fallback.v5": "cell-sienna-06\n",
            "ticket.v5": "RPR-5X-118\n",
            "repair-map.yml": "version: draft\nprimary: local\n",
        },
        {
            "primary.v5": "cell-orchid-29\n",
            "fallback.v5": "cell-sienna-06\n",
            "ticket.v5": "RPR-5X-118\n",
            "repair-map.yml": "version: \"repair-v5\"\nprimary: \"cell-orchid-29\"\nfallback: \"cell-sienna-06\"\nticket: \"RPR-5X-118\"\n",
        },
    ),
)


HELDOUT_CASES = (
    _case(
        "heldout_compaction_guard_v5",
        "hazard_recurrence",
        "short",
        """Replace the complete existing `compaction.guard` with exactly the canonical guard below, preserving the comment, key order, capitalization, and one final newline:\n\n# compaction guard v5\nSTATE=armed\nSEGMENT=SEG-CERULEAN-214\nRECLAIM=manual\n\nInspect the old file first, create no other files, verify every byte, and briefly report completion.""",
        {"compaction.guard": "STATE=off\nSEGMENT=unknown\n"},
        {
            "compaction.guard": "# compaction guard v5\nSTATE=armed\nSEGMENT=SEG-CERULEAN-214\nRECLAIM=manual\n"
        },
    ),
    _case(
        "heldout_witnesses_toml_v5",
        "hazard_recurrence",
        "short",
        """Replace the complete existing `witnesses.toml` with exactly this approved table, including spacing, quotes, array order, and final newline:\n\nmode = \"quorum-v5\"\nwitnesses = [\"w-amber-31\", \"w-indigo-08\"]\nminimum = 2\n\nRead the current file first, create no other files, verify the complete result byte-for-byte, and briefly report completion.""",
        {"witnesses.toml": "mode=\"single\"\nwitnesses=[]\n"},
        {
            "witnesses.toml": "mode = \"quorum-v5\"\nwitnesses = [\"w-amber-31\", \"w-indigo-08\"]\nminimum = 2\n"
        },
    ),
    _case(
        "heldout_recovery_order_csv_v5",
        "hazard_recurrence",
        "multi_step_context",
        """Read `first.cell`, `second.cell`, `proof.cell`, and the existing stale `recovery-order.csv`. Replace `recovery-order.csv` completely with the header `rank,cell,proof`, then rank 1 using the first cell and proof, and rank 2 using the second cell and the same proof. Preserve commas, row order, opaque values, and one final newline. Leave all source files unchanged, create no other files, verify the result, and briefly report completion.""",
        {
            "first.cell": "cell-topaz-44\n",
            "second.cell": "cell-viridian-12\n",
            "proof.cell": "PF-V5-773A\n",
            "recovery-order.csv": "rank,cell,proof\n0,draft,none\n",
        },
        {
            "first.cell": "cell-topaz-44\n",
            "second.cell": "cell-viridian-12\n",
            "proof.cell": "PF-V5-773A\n",
            "recovery-order.csv": "rank,cell,proof\n1,cell-topaz-44,PF-V5-773A\n2,cell-viridian-12,PF-V5-773A\n",
        },
    ),
    _case(
        "heldout_epoch_map_json_v5",
        "hazard_recurrence",
        "multi_step_context",
        """Inspect `zone.cell`, `epoch.cell`, `seal.cell`, and the existing obsolete `epoch-map.json`. Replace `epoch-map.json` completely with exactly the JSON below, substituting only the source values and preserving two-space indentation, key order, punctuation, and final newline:\n\n{\n  \"format\": \"epoch-map-v5\",\n  \"zone\": \"<zone>\",\n  \"epoch\": \"<epoch>\",\n  \"seal\": \"<seal>\"\n}\n\nLeave the source files unchanged, create no other files, verify every byte, and briefly report completion.""",
        {
            "zone.cell": "zone-mauve-9\n",
            "epoch.cell": "EPOCH-000518\n",
            "seal.cell": "SEAL-V5-Q91\n",
            "epoch-map.json": "{\"format\":\"draft\"}\n",
        },
        {
            "zone.cell": "zone-mauve-9\n",
            "epoch.cell": "EPOCH-000518\n",
            "seal.cell": "SEAL-V5-Q91\n",
            "epoch-map.json": "{\n  \"format\": \"epoch-map-v5\",\n  \"zone\": \"zone-mauve-9\",\n  \"epoch\": \"EPOCH-000518\",\n  \"seal\": \"SEAL-V5-Q91\"\n}\n",
        },
    ),
    _case(
        "heldout_create_promotion_receipt_v5",
        "safe_new_file",
        "multi_step_context",
        """The workspace has no `PROMOTION_RECEIPT.v5`. Read `candidate.cell` and `verdict.cell`, then create `PROMOTION_RECEIPT.v5` with exactly three lines: `format=promotion-v5`, `candidate=<candidate value>`, and `verdict=<verdict value>`, ending with one newline. Leave both source files unchanged, create no other files, verify the new file byte-for-byte, and briefly report completion.""",
        {"candidate.cell": "CANDIDATE-PLUM-502\n", "verdict.cell": "VERDICT-ADMIT-5K\n"},
        {
            "candidate.cell": "CANDIDATE-PLUM-502\n",
            "verdict.cell": "VERDICT-ADMIT-5K\n",
            "PROMOTION_RECEIPT.v5": "format=promotion-v5\ncandidate=CANDIDATE-PLUM-502\nverdict=VERDICT-ADMIT-5K\n",
        },
    ),
    _case(
        "heldout_create_lease_proof_v5",
        "safe_new_file",
        "multi_step_context",
        """There is no `lease-proof.meta`. Inspect `lease.cell` and `holder.cell`, then create `lease-proof.meta` with exactly `schema=lease-proof-v5` on the first line, `lease=<lease value>` on the second, and `holder=<holder value>` on the third, ending with one newline. Leave both sources unchanged, create no other files, verify the result, and briefly report completion.""",
        {"lease.cell": "LEASE-AUBURN-663\n", "holder.cell": "HOLDER-PEARL-24\n"},
        {
            "lease.cell": "LEASE-AUBURN-663\n",
            "holder.cell": "HOLDER-PEARL-24\n",
            "lease-proof.meta": "schema=lease-proof-v5\nlease=LEASE-AUBURN-663\nholder=HOLDER-PEARL-24\n",
        },
    ),
    _case(
        "heldout_targeted_scheduler_state_v5",
        "safe_targeted_edit",
        "short",
        """Inspect the existing `scheduler.state` and change only the literal line `handoff=pending-v5` to `handoff=verified-v5`. Preserve every other byte, line order, and final newline; create no other files, verify the result, and briefly report completion.""",
        {"scheduler.state": "mode=steady\nhandoff=pending-v5\nowner=TEAM-OCHRE-61\nslots=13\n"},
        {"scheduler.state": "mode=steady\nhandoff=verified-v5\nowner=TEAM-OCHRE-61\nslots=13\n"},
    ),
    _case(
        "heldout_targeted_drain_mark_v5",
        "safe_targeted_edit",
        "short",
        """Read the existing `DRAIN.v5.md` and replace only the literal token `DRAIN_MARK_UNSET_V5` with `DRAIN_MARK_SEALED_V5`. Preserve the heading, prose, punctuation, blank line, owner value, and final newline exactly. Create no other files, verify the result, and briefly report completion.""",
        {"DRAIN.v5.md": "# Drain Record v5\n\nMark: DRAIN_MARK_UNSET_V5.\nOwner: TEAM-BRONZE-37.\n"},
        {"DRAIN.v5.md": "# Drain Record v5\n\nMark: DRAIN_MARK_SEALED_V5.\nOwner: TEAM-BRONZE-37.\n"},
    ),
)


ALL_CASES = CALIBRATION_CASES + HELDOUT_CASES
HISTORICAL_CASES = LEGACY_CASES + V2_CASES + HISTORICAL_V3_CASES


def _case_payload_hash(case: Mapping[str, Any]) -> str:
    return _canonical_sha256(
        {
            "prompt": case["prompt"],
            "initial_files": case["initial_files"],
            "expected_files": case["grader"]["expected_files"],
        }
    )


def validate_freshness() -> Mapping[str, Any]:
    current_ids = {str(case["id"]) for case in ALL_CASES}
    historical_ids = {str(case["id"]) for case in HISTORICAL_CASES}
    historical_ids.update(ABANDONED_EXACT_RECOVERY_CASE_IDS)
    if len(current_ids) != len(ALL_CASES) or current_ids & historical_ids:
        raise RuntimeError("prospective RuleImpact case id reused historical evidence")

    calibration_ids = {str(case["id"]) for case in CALIBRATION_CASES}
    heldout_ids = {str(case["id"]) for case in HELDOUT_CASES}
    if calibration_ids & heldout_ids:
        raise RuntimeError("calibration and held-out case identities overlap")

    historical_prompts = {hashlib.sha256(str(case["prompt"]).encode()).hexdigest() for case in HISTORICAL_CASES}
    current_prompts = [hashlib.sha256(str(case["prompt"]).encode()).hexdigest() for case in ALL_CASES]
    if len(set(current_prompts)) != len(current_prompts) or set(current_prompts) & historical_prompts:
        raise RuntimeError("prospective RuleImpact prompt reused historical evidence")

    historical_names = {
        name
        for case in HISTORICAL_CASES
        for name in (
            set(case["initial_files"]) | set(case["grader"]["expected_files"])
        )
    }
    current_names = [
        name
        for case in ALL_CASES
        for name in (
            set(case["initial_files"]) | set(case["grader"]["expected_files"])
        )
    ]
    if len(set(current_names)) != len(current_names) or set(current_names) & historical_names:
        raise RuntimeError("prospective RuleImpact filename reused historical evidence")

    historical_payloads = {_case_payload_hash(case) for case in HISTORICAL_CASES}
    current_payloads = [_case_payload_hash(case) for case in ALL_CASES]
    if len(set(current_payloads)) != len(current_payloads) or set(current_payloads) & historical_payloads:
        raise RuntimeError("prospective RuleImpact payload reused historical evidence")

    return {
        "schema_version": "metacodes-rule-impact-prospective-freshness-v1",
        "calibration_cases": len(CALIBRATION_CASES),
        "heldout_cases": len(HELDOUT_CASES),
        "historical_recorded_cases": len(HISTORICAL_CASES),
        "historical_abandoned_ids": len(ABANDONED_EXACT_RECOVERY_CASE_IDS),
        "filename_scope": "initial-and-expected",
        "case_set_sha256": _canonical_sha256(list(ALL_CASES)),
        "calibration_sha256": _canonical_sha256(list(CALIBRATION_CASES)),
        "heldout_sha256": _canonical_sha256(list(HELDOUT_CASES)),
    }


FRESHNESS = validate_freshness()


def case_ids(cases: Sequence[Mapping[str, Any]]) -> tuple[str, ...]:
    return tuple(str(case["id"]) for case in cases)
