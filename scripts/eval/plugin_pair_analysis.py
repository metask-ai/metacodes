#!/usr/bin/env python3
"""Validate and judge one complete frozen plugin coding pair."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any, Mapping, Sequence

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.analysis import gate  # type: ignore
    from scripts.eval.memory_budget_journal import usd_to_microusd_ceiling  # type: ignore
    from scripts.eval.model import ValidationError, load_rollouts  # type: ignore
    from scripts.eval.plugin_pair_runner import (
        _arm_identities,
        frozen_run_fields,
        verify_frozen_manifest,
        _read_private_json,
        build_plan,  # type: ignore
        TOKEN_METRICS,
        _canonical_sha256,
        _metered_tokens,
        _verify_arm_inventory,
    )
    from scripts.eval.plugin_release_gate import (  # type: ignore
        PluginGateError,
        attest_runtime_artifact,
        load_protocol,
    )
else:
    from .analysis import gate
    from .memory_budget_journal import usd_to_microusd_ceiling
    from .model import ValidationError, load_rollouts
    from .plugin_pair_runner import (
        _arm_identities,
        frozen_run_fields,
        verify_frozen_manifest,
        _read_private_json,
        build_plan,
        TOKEN_METRICS,
        _canonical_sha256,
        _metered_tokens,
        _verify_arm_inventory,
    )
    from .plugin_release_gate import (
        PluginGateError,
        attest_runtime_artifact,
        load_protocol,
    )


RECEIPT_SCHEMA = "metacodes.plugin-paid-quality-receipt/v1"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _expected_keys(protocol: Mapping[str, Any]) -> set[tuple[str, int]]:
    pair = protocol["coding_pair"]
    return {
        (str(task_id), trial)
        for task_id in pair["task_ids"]
        for trial in range(int(pair["trials"]))
    }


def validate_paid_row(
    row: Mapping[str, Any],
    *,
    protocol: Mapping[str, Any],
    protocol_sha256: str,
    frozen_manifest_sha256: str,
    arm: str,
    inventory_sha256: str,
) -> None:
    pair = protocol["coding_pair"]
    expected_budget = {
        "max_metered_tokens": pair["max_rollout_metered_tokens"],
        "max_cost_usd": pair["max_rollout_cost_usd"],
    }
    if row.get("harness", {}).get("runtime_budget") != expected_budget:
        raise ValidationError("paid plugin row has incorrect runtime budget provenance")
    if row.get("plugin_treatment") != {
        "protocol_sha256": protocol_sha256,
        "frozen_manifest_sha256": frozen_manifest_sha256,
        "arm": arm,
        "inventory_sha256": inventory_sha256,
    }:
        raise ValidationError("paid plugin row has incorrect treatment attestation")
    receipt = row.get("budget_transaction")
    if not isinstance(receipt, dict) or receipt.get("state") != "committed":
        raise ValidationError("paid plugin row has no committed budget receipt")
    if (
        receipt.get("provider_identity")
        != f"{pair['model']['provider']}:{pair['model']['id']}"
        or receipt.get("model_fingerprint") != _canonical_sha256(pair["model"])
        or receipt.get("max_cost_microusd")
        != usd_to_microusd_ceiling(pair["max_rollout_cost_usd"])
        or receipt.get("max_metered_tokens") != pair["max_rollout_metered_tokens"]
        or receipt.get("actual_cost_microusd")
        != usd_to_microusd_ceiling(row.get("metrics", {}).get("cost_usd"))
        or receipt.get("actual_metered_tokens") != _metered_tokens(row)
    ):
        raise ValidationError("paid plugin row budget receipt does not match observed usage")
    if any(row.get("metrics", {}).get(key) is None for key in TOKEN_METRICS):
        raise ValidationError("paid plugin row has incomplete token telemetry")


def analyze(
    root: Path,
    protocol_path: Path,
    runtime_binary: Path,
    baseline_path: Path,
    candidate_path: Path,
    budget_journal_path: Path,
    frozen_manifest_file: Path,
) -> dict[str, Any]:
    protocol = load_protocol(root, protocol_path)
    runtime = attest_runtime_artifact(protocol, runtime_binary)
    protocol_sha256 = _sha256(protocol_path)
    # The evidence is judged against the same frozen manifest the run was
    # authorized under, re-verified against the tree as it is now.
    _, wrapper_hashes, inventory_hashes = _arm_identities(root, protocol, runtime.path)
    plan = build_plan(root, protocol_path, runtime_binary=runtime.path)
    live_fields = frozen_run_fields(
        root,
        protocol,
        protocol_sha256=protocol_sha256,
        runtime_sha256=runtime.sha256,
        wrapper_hashes=wrapper_hashes,
        inventory_hashes=inventory_hashes,
        schedule=plan["schedule"],
    )
    frozen_manifest_sha256 = verify_frozen_manifest(
        _read_private_json(frozen_manifest_file.expanduser().resolve(), "frozen-run manifest"),
        live_fields,
    )
    baseline = load_rollouts(baseline_path)
    candidate = load_rollouts(candidate_path)
    expected = _expected_keys(protocol)
    for arm, rows in (("baseline", baseline), ("candidate", candidate)):
        observed = {(str(row["task_id"]), int(row["trial"])) for row in rows}
        if observed != expected or len(rows) != len(expected):
            raise ValidationError(f"{arm} evidence is not the complete frozen pair")
    pair = protocol["coding_pair"]
    for arm, rows in (("baseline", baseline), ("candidate", candidate)):
        for row in rows:
            validate_paid_row(
                row,
                protocol=protocol,
                protocol_sha256=protocol_sha256,
                frozen_manifest_sha256=frozen_manifest_sha256,
                arm=arm,
                inventory_sha256=inventory_hashes[arm],
            )

    thresholds = pair["release_thresholds"]
    judgement = gate(
        candidate,
        baseline=baseline,
        max_invalid_rate=float(thresholds["max_invalid_rate"]),
        min_trustworthy_success=float(
            thresholds["min_treatment_trustworthy_success"]
        ),
        max_policy_violations=int(thresholds["max_policy_violations"]),
        max_success_regression=float(thresholds["max_success_rate_regression"]),
        max_cost_increase_usd=float(thresholds["max_mean_cost_increase_usd"]),
        max_latency_increase_ms=float(
            thresholds["max_mean_latency_increase_ms"]
        ),
        max_model_tool_error_increase=float(
            thresholds["max_mean_model_tool_error_increase"]
        ),
        min_latency_attribution_coverage=1.0,
        factor="harness",
    )
    comparison = judgement["comparison"]
    assert comparison is not None
    local_improvement = (
        judgement["passed"]
        and comparison["success_rate_delta"] > 0
        and comparison["mcnemar_exact_p"] <= 0.05
    )
    total_cost = sum(
        float(row["metrics"]["cost_usd"])
        for row in [*baseline, *candidate]
    )
    total_tokens = sum(_metered_tokens(row) for row in [*baseline, *candidate])
    if (
        total_cost > float(pair["max_cumulative_cost_usd"])
        or total_tokens > int(pair["max_cumulative_metered_tokens"])
    ):
        raise ValidationError("paid plugin evidence exceeds the frozen cumulative authority")
    receipt: dict[str, Any] = {
        "schema": RECEIPT_SCHEMA,
        "quality_evidence": True,
        "protocol_sha256": protocol_sha256,
        "frozen_manifest_sha256": frozen_manifest_sha256,
        "implementation_fingerprint": live_fields["implementation_fingerprint"],
        "path_set_digest": live_fields["path_set_digest"],
        "baseline_sha256": _sha256(baseline_path),
        "candidate_sha256": _sha256(candidate_path),
        "budget_journal_sha256": _sha256(budget_journal_path),
        "pair_count": len(expected),
        "provider_requests_upper_bound": int(pair["rollouts"]),
        "observed_cost_usd": total_cost,
        "observed_metered_tokens": total_tokens,
        "kernel_controls": protocol["kernel_controls"],
        "gate": judgement,
        "release_status": (
            "development_gate_passed" if judgement["passed"] else "candidate_rejected"
        ),
        "local_paired_improvement": (
            "supported" if local_improvement else "not_established"
        ),
        "public_benchmark_claim": "not_permitted",
        "interpretation": pair["interpretation"],
    }
    receipt["content_sha256"] = hashlib.sha256(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return receipt


def _write_new(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", type=Path, default=root / "evals/plugin-v1/protocol.json")
    parser.add_argument(
        "--runtime-binary",
        type=Path,
        required=True,
        help="explicit protocol-pinned ReleaseSmall metacodes artifact",
    )
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--budget-journal", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frozen-manifest", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        receipt = analyze(
            root,
            args.protocol.resolve(),
            args.runtime_binary.expanduser(),
            args.baseline.resolve(),
            args.candidate.resolve(),
            args.budget_journal.expanduser().resolve(),
            frozen_manifest_file=args.frozen_manifest,
        )
        _write_new(args.output.resolve(), receipt)
    except (OSError, ValidationError, PluginGateError) as exc:
        parser.error(str(exc))
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
