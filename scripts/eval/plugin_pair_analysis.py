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
    from scripts.eval.memory_budget_journal import (  # type: ignore
        MAX_JOURNAL_BYTES,
        BudgetAuthority,
        _transaction_receipt_from_state,
        usd_to_microusd,
        usd_to_microusd_ceiling,
        validate_checkpoint_payload,
    )
    from scripts.eval.model import ValidationError, parse_rollouts  # type: ignore
    from scripts.eval.paired_runner import _validate_checkpoint_rows  # type: ignore
    from scripts.eval.plugin_pair_runner import (  # type: ignore
        TOKEN_METRICS,
        _Observation,
        _authority_manifest,
        _canonical_sha256,
        _config_ids,
        _metered_tokens,
        _observe,
        _pair_fields,
        _read_private_json,
        _require_receipt_bound,
        _revision,
        _transaction,
        rollout_evidence_sha256,
        verify_frozen_manifest,
    )
    from scripts.eval.plugin_release_gate import PluginGateError  # type: ignore
else:
    from .analysis import gate
    from .memory_budget_journal import (
        MAX_JOURNAL_BYTES,
        BudgetAuthority,
        _transaction_receipt_from_state,
        usd_to_microusd,
        usd_to_microusd_ceiling,
        validate_checkpoint_payload,
    )
    from .model import ValidationError, parse_rollouts
    from .paired_runner import _validate_checkpoint_rows
    from .plugin_pair_runner import (
        TOKEN_METRICS,
        _Observation,
        _authority_manifest,
        _canonical_sha256,
        _config_ids,
        _metered_tokens,
        _observe,
        _pair_fields,
        _read_private_json,
        _require_receipt_bound,
        _revision,
        _transaction,
        rollout_evidence_sha256,
        verify_frozen_manifest,
    )
    from .plugin_release_gate import PluginGateError


RECEIPT_SCHEMA = "metacodes.plugin-paid-quality-receipt/v1"


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


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


def _read_journal(path: Path) -> tuple[bytes, Mapping[str, Any]]:
    """One read: the replayed state and the hash the receipt carries come
    from the same bytes, and a file that does not replay as a budget journal
    is refused here rather than hashed into a receipt as "provenance"."""
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ValidationError(f"cannot read budget journal: {exc}") from exc
    if not payload or len(payload) > MAX_JOURNAL_BYTES:
        raise ValidationError("budget journal size is empty or exceeds the safety limit")
    return payload, validate_checkpoint_payload(payload)


def _read_rollouts(path: Path) -> tuple[bytes, list[dict[str, Any]]]:
    try:
        payload = path.read_bytes()
    except OSError as exc:
        raise ValidationError(f"cannot read rollout JSONL {path}: {exc}") from exc
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError(f"{path}: invalid UTF-8: {exc}") from exc
    return payload, parse_rollouts(text, str(path))


def verify_journal_authority(
    state: Mapping[str, Any],
    observation: _Observation,
    *,
    frozen_manifest_sha256: str,
) -> BudgetAuthority:
    """The journal must be *this* frozen run's journal.

    Its authority hash is rebuilt from the tree, the frozen manifest and the
    totals the journal itself records, and those totals must sit inside the
    protocol's cumulative ceiling. This binds consistency, not intent: the
    journal is unsigned, so what is established is that the evidence, the
    journal and the freeze describe one run - not that a user authorized it
    (that file is the runner's gate, not the analysis's input)."""
    pair = observation.protocol["coding_pair"]
    authority = state["authority"]
    expected = _authority_manifest(
        observation,
        frozen_manifest_sha256=frozen_manifest_sha256,
        authorized_cost_microusd=int(authority["total_cost_microusd"]),
        authorized_metered_tokens=int(authority["total_metered_tokens"]),
    )
    if authority["manifest_sha256"] != _canonical_sha256(expected):
        raise ValidationError("budget journal authority does not bind this frozen run")
    model = pair["model"]
    if (
        authority["model_fingerprint"] != _canonical_sha256(model)
        or authority["provider_identity"] != f"{model['provider']}:{model['id']}"
    ):
        raise ValidationError("budget journal authority names another model")
    rollout_cost, rollout_tokens, total_cost, total_tokens = _pair_fields(observation.protocol)
    if (
        int(authority["total_cost_microusd"]) > usd_to_microusd(total_cost)
        or int(authority["total_metered_tokens"]) > int(total_tokens)
    ):
        raise ValidationError("budget journal authority exceeds the frozen cumulative ceiling")
    # Mirror of the runner's admission rule: an authority that could not cover
    # every rollout's maximum reservation is one the runner would have refused,
    # so a journal claiming it did not come from a paid run of this schedule.
    rollouts = int(pair["rollouts"])
    if (
        int(authority["total_cost_microusd"]) < usd_to_microusd(rollout_cost) * rollouts
        or int(authority["total_metered_tokens"]) < int(rollout_tokens) * rollouts
    ):
        raise ValidationError("budget journal authority cannot cover the complete frozen schedule")
    return BudgetAuthority(**authority)


def bind_row_to_journal(
    row: Mapping[str, Any],
    state: Mapping[str, Any],
    observation: _Observation,
    authority: BudgetAuthority,
    *,
    arm: str,
) -> str:
    """Match one rollout's receipt to the journal transaction it names -
    the same receipt-binding rule resume applies - and its body to the
    digest the journal sealed at commit. Returns the transaction id so the
    caller can find journal transactions no rollout accounts for."""
    receipt = row["budget_transaction"]
    transaction_id = receipt.get("transaction_id")
    if not isinstance(transaction_id, str) or transaction_id not in state["transactions"]:
        raise ValidationError(
            "paid plugin row names a transaction the budget journal does not contain"
        )
    rollout_cost, rollout_tokens, _, _ = _pair_fields(observation.protocol)
    expected = _transaction(
        authority=authority,
        protocol_sha256=observation.protocol_sha256,
        task=observation.tasks[str(row["task_id"])],
        arm=arm,
        trial=int(row["trial"]),
        revision=_revision(observation.fields),
        config_id=_config_ids(observation.protocol)[arm],
        wrapper_sha256=observation.wrapper_hashes[arm],
        runtime_sha256=observation.runtime_sha256,
        inventory_sha256=observation.inventory_hashes[arm],
        max_cost_usd=rollout_cost,
        max_metered_tokens=rollout_tokens,
    )
    _require_receipt_bound(receipt, _transaction_receipt_from_state(state, transaction_id), expected)
    # The journal sealed a digest of the rollout body at commit. A receipt
    # transplanted onto another body, or a body edited after the run, does
    # not match it; a transaction committed without one is not this runner's.
    sealed = state["transactions"][transaction_id].get("evidence_sha256")
    if sealed is None or sealed != rollout_evidence_sha256(row):
        raise ValidationError(
            "paid plugin row body does not match the evidence sealed in the journal"
        )
    return transaction_id


def _require_no_orphan_transactions(state: Mapping[str, Any], claimed: set[str]) -> None:
    """Same rule as the runner's resume guard: every journal transaction that
    was authorized - let alone committed - must be accounted for by exactly
    one rollout; only a pre-request abort leaves no evidence behind."""
    for transaction_id, transaction in state["transactions"].items():
        if transaction["state"] == "aborted_pre_request":
            continue
        if transaction_id not in claimed:
            raise ValidationError(
                "budget journal contains an authorized, reserved, or committed "
                "transaction without a matching rollout"
            )


def analyze(
    root: Path,
    protocol_path: Path,
    runtime_binary: Path,
    baseline_path: Path,
    candidate_path: Path,
    budget_journal_path: Path,
    frozen_manifest_file: Path,
) -> dict[str, Any]:
    # The evidence is judged against the same frozen manifest the run was
    # authorized under, re-verified against the tree as it is now - before
    # the journal, before any rollout is read.
    observation = _observe(root, protocol_path, runtime_binary)
    frozen_manifest_sha256 = verify_frozen_manifest(
        _read_private_json(frozen_manifest_file.expanduser().resolve(), "frozen-run manifest"),
        observation.fields,
    )
    protocol = observation.protocol
    protocol_sha256 = observation.protocol_sha256
    journal_payload, journal = _read_journal(budget_journal_path)
    authority = verify_journal_authority(
        journal, observation, frozen_manifest_sha256=frozen_manifest_sha256
    )
    baseline_payload, baseline = _read_rollouts(baseline_path)
    candidate_payload, candidate = _read_rollouts(candidate_path)
    pair = protocol["coding_pair"]
    # The grounded-identity validation resume applies to a checkpoint: every
    # fingerprint must be the one this suite, wrapper, model and revision
    # produce - not merely consistent between the two arms.
    for arm, rows in (("baseline", baseline), ("candidate", candidate)):
        _validate_checkpoint_rows(
            rows,
            variant=arm,
            suite=observation.suite,
            repo_root=root,
            binary=observation.wrappers[arm],
            trials=int(pair["trials"]),
            expected_tasks=observation.tasks,
            model_provider=pair["model"]["provider"],
            model_id=pair["model"]["id"],
            harness_revision=_revision(observation.fields),
            harness_config_id=_config_ids(protocol)[arm],
            require_runtime_budget=True,
        )
    expected = _expected_keys(protocol)
    for arm, rows in (("baseline", baseline), ("candidate", candidate)):
        observed = {(str(row["task_id"]), int(row["trial"])) for row in rows}
        if observed != expected or len(rows) != len(expected):
            raise ValidationError(f"{arm} evidence is not the complete frozen pair")
    claimed: set[str] = set()
    for arm, rows in (("baseline", baseline), ("candidate", candidate)):
        for row in rows:
            validate_paid_row(
                row,
                protocol=protocol,
                protocol_sha256=protocol_sha256,
                frozen_manifest_sha256=frozen_manifest_sha256,
                arm=arm,
                inventory_sha256=observation.inventory_hashes[arm],
            )
            transaction_id = bind_row_to_journal(row, journal, observation, authority, arm=arm)
            if transaction_id in claimed:
                raise ValidationError("two paid plugin rows claim the same budget transaction")
            claimed.add(transaction_id)
    _require_no_orphan_transactions(journal, claimed)

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
        "implementation_fingerprint": observation.fields["implementation_fingerprint"],
        "path_set_digest": observation.fields["path_set_digest"],
        "baseline_sha256": _sha256_bytes(baseline_payload),
        "candidate_sha256": _sha256_bytes(candidate_payload),
        "budget_journal_sha256": _sha256_bytes(journal_payload),
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
