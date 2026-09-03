"""Read-only reanalysis for a paid memory run that failed after execution.

This module never starts metacodes, TinyKG, a provider client, or a subprocess.
It reopens the immutable failed-run checkpoint, recomputes query-plan verdicts
from source-bound provider cassettes, derives evaluator-invalid observations,
and publishes a separate analysis-only bundle.  It cannot create a canonical
runtime receipt or promotion evidence.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import random
import stat
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, List, Mapping, MutableMapping, Sequence, Tuple

from .memory_benchmark import render_memory_markdown, summarize_memory
from .memory_budget_journal import validate_checkpoint_payload
from .memory_query_plan import (
    MULTIPLE_DISTINCT_SEED_PLANS_REASON,
    QUERY_PLAN_INVALID_PREFIX,
    SIDECAR_NAME,
    build_query_plan_trace,
    project_query_variants,
    quality_scoreable_with_pre_search_rejections,
    summarize_query_plan_traces,
)
from .memory_replay import (
    _FAILED_RUN_QUERY_PLAN_REANALYSIS,
    _artifact_tree_digest,
    load_manifest,
    load_observations,
    replay_observations,
    summarize_warm_context_cache,
    validate_runtime_artifacts,
    validate_runtime_receipt,
)
from .model import ValidationError, stable_json, O_BINARY, fsync_directory, mode_violation, open_nofollow
from .statistics import exact_mcnemar, percentile


SCHEMA_VERSION = "metacodes-memory-failed-run-reanalysis-v1"
FAILED_VALIDATION_DIAGNOSTIC = "failed-validation-diagnostic.json"
FAILED_RUN_DIAGNOSTIC = "failed-run-diagnostic.json"
MAX_JSON_BYTES = 512 * 1024 * 1024
BOOTSTRAP_REPLICATES = 10_000
BOOTSTRAP_SEED = 20260810
OUTPUT_DIGEST_FILES = {
    "reanalysis_observations_sha256": "reanalysis-observations.jsonl",
    "reanalysis_rows_sha256": "reanalysis-rows.jsonl",
    "derived_runtime_view_sha256": "derived-runtime-view.json",
    "reanalysis_summary_sha256": "reanalysis-summary.json",
    "reanalysis_report_sha256": "reanalysis-report.json",
    "reanalysis_markdown_sha256": "reanalysis-report.md",
}
INPUT_DIGEST_FIELDS = frozenset(
    {
        "manifest_sha256",
        "dataset_source_sha256",
        "failed_validation_diagnostic_sha256",
        "failed_run_diagnostic_sha256",
        "original_observations_sha256",
        "runtime_candidate_file_sha256",
        "failed_run_budget_checkpoint_sha256",
        "final_rollout_checkpoint_sha256",
        "live_budget_journal_sha256",
        "runtime_artifact_tree_sha256",
    }
)
ANALYSIS_SOURCE_FILES = frozenset(
    {
        "memory_failed_run_analysis.py",
        "memory_query_plan.py",
        "memory_replay.py",
        "memory_benchmark.py",
    }
)
EXPECTED_BUNDLE_FILES = frozenset(
    {"reanalysis-receipt.json", *OUTPUT_DIGEST_FILES.values()}
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_sha256(value: Any) -> str:
    return _sha256_bytes(stable_json(value).encode("utf-8"))


def _analysis_source_hashes() -> Mapping[str, str]:
    root = Path(__file__).parent
    return {
        name: _sha256_bytes(
            _private_regular(root / name, f"analysis source {name}")
        )
        for name in sorted(ANALYSIS_SOURCE_FILES)
    }


def _private_regular(path: Path, where: str, *, maximum: int = MAX_JSON_BYTES) -> bytes:
    fd = -1
    try:
        flags = os.O_RDONLY
        fd = open_nofollow(path, flags)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            _fail(where, "expected one non-symlink, non-hardlinked regular file")
        if before.st_size <= 0 or before.st_size > maximum:
            _fail(where, "file size is empty or exceeds the analysis limit")
        chunks: List[bytes] = []
        remaining = before.st_size
        while remaining:
            chunk = os.read(fd, min(remaining, 1024 * 1024))
            if not chunk:
                _fail(where, "file was truncated while being read")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(fd, 1):
            _fail(where, "file grew while being read")
        after = os.fstat(fd)
        path_after = path.lstat()
        identity_before = (
            before.st_dev,
            before.st_ino,
            before.st_mode,
            before.st_nlink,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        )
        identity_after = (
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
        if identity_after != identity_before or (
            path_after.st_dev,
            path_after.st_ino,
        ) != (before.st_dev, before.st_ino):
            _fail(where, "file identity changed while being read")
        return b"".join(chunks)
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError(f"{where}: cannot read file: {exc}") from exc
    finally:
        if fd >= 0:
            os.close(fd)


def _canonical_json(path: Path, where: str) -> Mapping[str, Any]:
    raw = _private_regular(path, where)
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"{where}: invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    if raw != (stable_json(value) + "\n").encode("utf-8"):
        _fail(where, "expected canonical JSON with one trailing newline")
    return value


def _resolve_run_directory(path: Path) -> Path:
    try:
        resolved = path.expanduser().resolve(strict=True)
        info = resolved.lstat()
    except OSError as exc:
        raise ValidationError(f"failed run directory is unavailable: {exc}") from exc
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        _fail("failed run directory", "expected a non-symlink directory")
    return resolved


def _prepare_output_directory(path: Path, run_dir: Path) -> Path:
    resolved = path.expanduser().absolute()
    try:
        resolved = resolved.resolve(strict=False)
        if resolved == run_dir or resolved in run_dir.parents or run_dir in resolved.parents:
            _fail("reanalysis output", "must not overlap the immutable failed run")
        if resolved.exists() or resolved.is_symlink():
            _fail("reanalysis output", "must not already exist")
        parent = resolved.parent.resolve(strict=True)
        parent_info = parent.stat()
        if not stat.S_ISDIR(parent_info.st_mode):
            _fail("reanalysis output parent", "expected a directory")
        if hasattr(os, "geteuid") and parent_info.st_uid != os.geteuid():
            _fail("reanalysis output parent", "must be owned by the current user")
        if mode_violation(parent_info.st_mode, 0o022):
            _fail("reanalysis output parent", "must not be group/world writable")
        resolved.mkdir(mode=0o700)
    except ValidationError:
        raise
    except OSError as exc:
        raise ValidationError(f"reanalysis output: cannot create private directory: {exc}") from exc
    return resolved


def _write_private(path: Path, payload: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = -1
    try:
        fd = os.open(path, flags, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            _fail(str(path), "output identity changed while writing")
    finally:
        if fd >= 0:
            os.close(fd)


def _sync_directory(path: Path) -> None:
    fsync_directory(path)


def verify_reanalysis_bundle(output_dir: Path) -> Mapping[str, Any]:
    try:
        root = output_dir.expanduser().resolve(strict=True)
        root_info = root.lstat()
    except OSError as exc:
        raise ValidationError(f"reanalysis bundle: cannot open directory: {exc}") from exc
    if not stat.S_ISDIR(root_info.st_mode) or stat.S_ISLNK(root_info.st_mode):
        _fail("reanalysis bundle", "expected a non-symlink directory")
    if mode_violation(root_info.st_mode, 0o077):
        _fail("reanalysis bundle", "directory permissions must be 0700 or stricter")
    try:
        observed_files = frozenset(path.name for path in root.iterdir())
    except OSError as exc:
        raise ValidationError(f"reanalysis bundle: cannot enumerate directory: {exc}") from exc
    if observed_files != EXPECTED_BUNDLE_FILES:
        _fail(
            "reanalysis bundle",
            "file set differs from the analysis-only allowlist",
        )
    receipt = _canonical_json(root / "reanalysis-receipt.json", "reanalysis receipt")
    if mode_violation((root / "reanalysis-receipt.json").stat().st_mode, 0o077):
        _fail("reanalysis receipt", "permissions must be 0600 or stricter")
    if set(receipt) != {
        "schema_version",
        "status",
        "quality_evidence",
        "promotion",
        "provider_requests_during_reanalysis",
        "paid_retry_performed",
        "inputs",
        "analysis_sources",
        "outputs",
        "changed_sequences",
        "newly_invalid_sequences",
        "reprojected_invalid_sequences",
        "query_plan_invalid_sequences",
    }:
        _fail("reanalysis receipt", "field set is incomplete or contains unknown claims")
    if (
        receipt.get("schema_version") != SCHEMA_VERSION
        or receipt.get("status") != "analysis_only"
        or receipt.get("quality_evidence") is not False
        or receipt.get("promotion") is not False
        or receipt.get("provider_requests_during_reanalysis") != 0
        or receipt.get("paid_retry_performed") is not False
    ):
        _fail("reanalysis receipt", "claim boundary is invalid")
    for field, expected_fields in (
        ("inputs", INPUT_DIGEST_FIELDS),
        ("analysis_sources", ANALYSIS_SOURCE_FILES),
    ):
        values = receipt.get(field)
        if not isinstance(values, dict) or set(values) != set(expected_fields):
            _fail(f"reanalysis receipt.{field}", "digest set is incomplete")
        if any(
            not isinstance(digest, str)
            or len(digest) != 64
            or any(char not in "0123456789abcdef" for char in digest)
            for digest in values.values()
        ):
            _fail(f"reanalysis receipt.{field}", "contains an invalid SHA-256")
    for field in (
        "changed_sequences",
        "newly_invalid_sequences",
        "reprojected_invalid_sequences",
        "query_plan_invalid_sequences",
    ):
        sequences = receipt.get(field)
        if (
            not isinstance(sequences, list)
            or any(not isinstance(item, int) or isinstance(item, bool) or item < 0 for item in sequences)
            or sequences != sorted(set(sequences))
        ):
            _fail(f"reanalysis receipt.{field}", "expected sorted unique sequence ids")
    outputs = receipt.get("outputs")
    if not isinstance(outputs, dict) or set(outputs) != set(OUTPUT_DIGEST_FILES):
        _fail("reanalysis receipt.outputs", "output digest set is incomplete")
    for field, name in OUTPUT_DIGEST_FILES.items():
        path = root / name
        payload = _private_regular(path, f"reanalysis output {name}")
        if mode_violation(path.stat().st_mode, 0o077):
            _fail(f"reanalysis output {name}", "permissions must be 0600 or stricter")
        if _sha256_bytes(payload) != outputs[field]:
            _fail(f"reanalysis output {name}", "SHA-256 does not match receipt")
    report = _canonical_json(root / "reanalysis-report.json", "reanalysis report")
    if (
        report.get("schema_version") != SCHEMA_VERSION
        or report.get("status") != "analysis_only"
        or report.get("quality_evidence") is not False
        or report.get("promotion") is not False
        or report.get("provider_requests_during_reanalysis") != 0
        or report.get("paid_retry_performed") is not False
        or report.get("changed_sequences") != receipt.get("changed_sequences")
        or report.get("newly_invalid_sequences") != receipt.get("newly_invalid_sequences")
        or report.get("reprojected_invalid_sequences")
        != receipt.get("reprojected_invalid_sequences")
        or report.get("query_plan_invalid_sequences")
        != receipt.get("query_plan_invalid_sequences")
    ):
        _fail("reanalysis report", "does not match the receipt claim boundary")
    derived = _canonical_json(
        root / "derived-runtime-view.json",
        "derived runtime view",
    )
    if (
        derived.get("schema_version") != SCHEMA_VERSION
        or derived.get("status") != "analysis_only"
        or derived.get("canonical_runtime_receipt") is not False
        or set(derived)
        != {
            "schema_version",
            "status",
            "canonical_runtime_receipt",
            "source_candidate_sha256",
            "derived_runtime_view",
        }
        or not isinstance(derived.get("source_candidate_sha256"), str)
        or len(derived["source_candidate_sha256"]) != 64
        or any(
            char not in "0123456789abcdef"
            for char in derived["source_candidate_sha256"]
        )
        or not isinstance(derived.get("derived_runtime_view"), dict)
    ):
        _fail("derived runtime view", "could masquerade as a canonical receipt")
    return receipt


def _budget_snapshot(state: Mapping[str, Any]) -> Mapping[str, Any]:
    committed_cost = 0
    committed_tokens = 0
    maximum_cost = 0
    maximum_tokens = 0
    states: Counter[str] = Counter()
    transactions = state.get("transactions")
    if not isinstance(transactions, dict):
        _fail("budget checkpoint", "transactions are unavailable")
    for transaction in transactions.values():
        if not isinstance(transaction, dict):
            _fail("budget checkpoint", "transaction is malformed")
        status = str(transaction.get("state"))
        states[status] += 1
        identity = transaction.get("identity")
        if not isinstance(identity, dict):
            _fail("budget checkpoint", "transaction identity is malformed")
        if status == "committed":
            committed_cost += int(transaction["actual_cost_microusd"])
            committed_tokens += int(transaction["actual_metered_tokens"])
        elif status in {"reserved", "request_authorized"}:
            maximum_cost += int(identity["max_cost_microusd"])
            maximum_tokens += int(identity["max_metered_tokens"])
    return {
        "schema_version": 1,
        "journal_id": state["journal_id"],
        "authority": state["authority"],
        "revision": state["revision"],
        "head_sha256": state["head_sha256"],
        "committed_cost_microusd": committed_cost,
        "committed_metered_tokens": committed_tokens,
        "unsettled_max_cost_microusd": maximum_cost,
        "unsettled_max_metered_tokens": maximum_tokens,
        "exposure_cost_microusd": committed_cost + maximum_cost,
        "exposure_metered_tokens": committed_tokens + maximum_tokens,
        "transaction_states": dict(sorted(states.items())),
    }


def _load_failed_candidate(
    run_dir: Path,
) -> Tuple[
    List[Mapping[str, Any]],
    Mapping[str, Any],
    Mapping[str, Any],
    Mapping[str, str],
]:
    diagnostic = _canonical_json(
        run_dir / FAILED_VALIDATION_DIAGNOSTIC,
        "failed-validation diagnostic",
    )
    if (
        diagnostic.get("schema_version") != "metacodes-memory-runtime-validation-failure-v1"
        or diagnostic.get("status") != "invalid"
        or diagnostic.get("classification") != "post-run-runtime-receipt-validation"
    ):
        _fail("failed-validation diagnostic", "unsupported failure checkpoint")
    observations_name = diagnostic.get("observations_file")
    candidate_name = diagnostic.get("runtime_candidate_file")
    if observations_name != "failed-validation-observations.jsonl" or candidate_name != "failed-validation-runtime-candidate.json":
        _fail("failed-validation diagnostic", "unexpected checkpoint filenames")
    observations_path = run_dir / observations_name
    candidate_path = run_dir / candidate_name
    observations_raw = _private_regular(observations_path, "failed observations")
    candidate_raw = _private_regular(candidate_path, "failed runtime candidate")
    if _sha256_bytes(observations_raw) != diagnostic.get("observations_sha256"):
        _fail("failed observations", "SHA-256 does not match its diagnostic")
    if _sha256_bytes(candidate_raw) != diagnostic.get("runtime_candidate_sha256"):
        _fail("failed runtime candidate", "SHA-256 does not match its diagnostic")
    wrapper = _canonical_json(candidate_path, "failed runtime candidate")
    if any(wrapper.get(key) != diagnostic.get(key) for key in ("schema_version", "status", "classification", "error_type", "error_sha256")):
        _fail("failed runtime candidate", "failure identity does not match its diagnostic")
    receipt = wrapper.get("candidate_runtime_receipt")
    if not isinstance(receipt, dict) or receipt.get("quality_evidence") is not False:
        _fail("failed runtime candidate", "candidate is missing or claims quality evidence")
    observations = load_observations(observations_path)

    failed_run = _canonical_json(run_dir / FAILED_RUN_DIAGNOSTIC, "failed-run diagnostic")
    if failed_run.get("automatic_retry_forbidden") is not True:
        _fail("failed-run diagnostic", "must forbid automatic retry")
    budget_name = failed_run.get("budget_checkpoint_file")
    if budget_name != "failed-run-budget-checkpoint.json":
        _fail("failed-run diagnostic", "unexpected budget checkpoint filename")
    budget_payload = _private_regular(run_dir / budget_name, "failed-run budget checkpoint")
    if _sha256_bytes(budget_payload) != failed_run.get("budget_checkpoint_sha256"):
        _fail("failed-run budget checkpoint", "SHA-256 does not match its diagnostic")
    checkpoint_state = validate_checkpoint_payload(budget_payload)
    snapshot = _budget_snapshot(checkpoint_state)
    if snapshot != failed_run.get("budget_snapshot"):
        _fail("failed-run budget checkpoint", "replayed state does not match diagnostic")
    candidate_budget = receipt.get("budget_journal")
    if not isinstance(candidate_budget, dict):
        _fail("failed runtime candidate", "budget journal receipt is missing")
    expected_candidate_budget = {
        **snapshot,
        "checkpoint_path": candidate_budget.get("checkpoint_path"),
        "checkpoint_sha256": candidate_budget.get("checkpoint_sha256"),
    }
    if candidate_budget != expected_candidate_budget:
        _fail("failed runtime candidate", "budget receipt does not match failed checkpoint")
    checkpoint_relative = candidate_budget["checkpoint_path"]
    expected_checkpoint = f"rollout-budget-checkpoint-r{int(snapshot['revision']):08d}.json"
    if checkpoint_relative != expected_checkpoint:
        _fail("failed runtime candidate", "unexpected final checkpoint path")
    final_checkpoint = _private_regular(run_dir / checkpoint_relative, "final rollout checkpoint")
    if _sha256_bytes(final_checkpoint) != candidate_budget["checkpoint_sha256"]:
        _fail("final rollout checkpoint", "SHA-256 does not match runtime candidate")
    if validate_checkpoint_payload(final_checkpoint) != checkpoint_state:
        _fail("final rollout checkpoint", "does not reproduce failed-run budget state")
    live_journal_path = run_dir.parent / "state" / "budget-journal.json"
    live_journal = _private_regular(live_journal_path, "live budget journal")
    if validate_checkpoint_payload(live_journal) != checkpoint_state:
        _fail("live budget journal", "does not reproduce the failed-run checkpoint")
    return observations, receipt, diagnostic, {
        "failed_run_budget_checkpoint_sha256": _sha256_bytes(budget_payload),
        "final_rollout_checkpoint_sha256": _sha256_bytes(final_checkpoint),
        "live_budget_journal_sha256": _sha256_bytes(live_journal),
    }


def _host_recall_observed(rollout: Mapping[str, Any]) -> bool:
    scoped = rollout.get("scoped_recall")
    return bool(
        isinstance(scoped, dict)
        and scoped.get("status") in {"injected", "no_hits"}
    )


def repair_observations(
    observations: Sequence[Mapping[str, Any]],
    rollouts: Sequence[Mapping[str, Any]],
    traces: Sequence[Mapping[str, Any]],
) -> Tuple[List[Mapping[str, Any]], List[Mapping[str, Any]], List[bool]]:
    if not (len(observations) == len(rollouts) == len(traces)):
        _fail("failed-run reanalysis", "observation, rollout, and trace counts differ")
    repaired = [copy.deepcopy(row) for row in observations]
    changes: List[Mapping[str, Any]] = []
    host_satisfied: List[bool] = []
    for sequence, (row, rollout, trace) in enumerate(zip(repaired, rollouts, traces)):
        host_observed = _host_recall_observed(rollout)
        host_satisfied.append(host_observed)
        host_covers_gap = bool(
            host_observed
            and trace.get("invalid_reasons") == ["TinyKG backend executed no KgRecall"]
        )
        if (
            trace["status"] != "invalid"
            or host_covers_gap
            or quality_scoreable_with_pre_search_rejections(
                trace,
                host_recall_satisfied=host_observed,
            )
        ):
            continue
        evaluator = row.get("evaluator")
        retrieval = row.get("retrieval")
        if not isinstance(evaluator, dict) or not isinstance(retrieval, dict):
            _fail(f"failed observations[{sequence}]", "missing evaluator or retrieval")
        prior_evaluator_status = evaluator.get("status")
        reason = QUERY_PLAN_INVALID_PREFIX + "; ".join(
            str(item) for item in trace["invalid_reasons"]
        )
        variants = project_query_variants(trace)
        successful_seed_queries = {
            " ".join(str(call["query"]).casefold().split())
            for call in trace["calls"]
            if call["stage"] == "seed"
        }
        if len(successful_seed_queries) > 1 and sum(
            variant["kind"] == "exact" for variant in variants
        ) < 2:
            _fail(f"failed observations[{sequence}]", "multiple seed violation was not preserved")
        before_sha = _canonical_sha256(row)
        evaluator["status"] = "invalid"
        evaluator["invalid_reason"] = reason
        evaluator["deterministic_success"] = None
        if variants:
            retrieval["query_variants"] = variants
        after_sha = _canonical_sha256(row)
        if after_sha != before_sha:
            changes.append(
                {
                    "sequence": sequence,
                    "classification": (
                        "newly_invalid"
                        if prior_evaluator_status == "ready"
                        else "existing_invalid_reprojected"
                    ),
                    "run_id": rollout["run_id"],
                    "case_id": rollout["case_id"],
                    "arm": rollout["arm"],
                    "before_observation_sha256": before_sha,
                    "after_observation_sha256": after_sha,
                    "trace_sha256": _canonical_sha256(trace),
                    "invalid_reasons": list(trace["invalid_reasons"]),
                    "projected_query_variants": variants,
                }
            )
    return repaired, changes, host_satisfied


def rebind_runtime_receipt(
    receipt: Mapping[str, Any],
    observations: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    rebound = copy.deepcopy(receipt)
    rollouts = rebound.get("rollouts")
    if not isinstance(rollouts, list) or len(rollouts) != len(observations):
        _fail("failed runtime candidate", "rollout count does not match observations")
    rebound["observations_sha256"] = _canonical_sha256(list(observations))
    for rollout, observation in zip(rollouts, observations):
        rollout["observation_sha256"] = _canonical_sha256(observation)
    return rebound


def _paired_offline_comparison(
    rows: Sequence[Mapping[str, Any]],
    receipt: Mapping[str, Any],
    family_by_case: Mapping[str, str],
    *,
    baseline_arm: str,
    candidate_arm: str,
) -> Mapping[str, Any]:
    indexed = {
        (row["case_id"], row["trial"], row["arm"]): row
        for row in rows
        if row["benchmark"] == "procedural_transfer" and row["split"] == "offline"
    }
    rollout_by_sequence = {
        int(item["sequence"]): item for item in receipt["rollouts"]
    }
    keys = sorted({(case_id, trial) for case_id, trial, _arm in indexed})
    pairs: List[Mapping[str, Any]] = []
    excluded: List[Mapping[str, Any]] = []
    by_family: MutableMapping[str, List[float]] = defaultdict(list)
    regressions = 0
    improvements = 0
    for case_id, trial in keys:
        baseline = indexed.get((case_id, trial, baseline_arm))
        candidate = indexed.get((case_id, trial, candidate_arm))
        if baseline is None or candidate is None:
            continue
        if any(
            row["execution"]["status"] != "completed"
            or row["evaluator"]["status"] != "ready"
            for row in (baseline, candidate)
        ):
            excluded.append(
                {
                    "case_id": case_id,
                    "trial": trial,
                    "baseline_evaluator": baseline["evaluator"]["status"],
                    "candidate_evaluator": candidate["evaluator"]["status"],
                }
            )
            continue
        base_success = bool(baseline["outcome"]["success"])
        candidate_success = bool(candidate["outcome"]["success"])
        delta = float(candidate_success) - float(base_success)
        regressions += base_success and not candidate_success
        improvements += candidate_success and not base_success
        base_rollout = rollout_by_sequence[int(baseline["sequence"])]
        candidate_rollout = rollout_by_sequence[int(candidate["sequence"])]
        family = family_by_case[case_id]
        by_family[family].append(delta)
        pairs.append(
            {
                "case_id": case_id,
                "family_id": family,
                "trial": trial,
                "baseline_success": base_success,
                "candidate_success": candidate_success,
                "success_delta": delta,
                "cost_usd_delta": float(candidate["cost"]["cost_usd"])
                - float(baseline["cost"]["cost_usd"]),
                "wall_time_ms_delta": float(candidate["cost"]["wall_time_ms"])
                - float(baseline["cost"]["wall_time_ms"]),
                "metered_tokens_delta": int(candidate_rollout["metered_tokens"])
                - int(base_rollout["metered_tokens"]),
            }
        )
    families = sorted(by_family)
    bootstrap: List[float] = []
    if families:
        rng = random.Random(BOOTSTRAP_SEED)
        for _ in range(BOOTSTRAP_REPLICATES):
            sampled = [rng.choice(families) for _ in families]
            deltas = [delta for family in sampled for delta in by_family[family]]
            bootstrap.append(sum(deltas) / len(deltas))
    def mean(key: str) -> float | None:
        return sum(float(pair[key]) for pair in pairs) / len(pairs) if pairs else None
    return {
        "baseline_arm": baseline_arm,
        "candidate_arm": candidate_arm,
        "paired_rows": len(pairs),
        "excluded_rows": excluded,
        "discordant_regressions": regressions,
        "discordant_improvements": improvements,
        "mcnemar_exact_p": exact_mcnemar(regressions, improvements),
        "mean_success_delta": mean("success_delta"),
        "cluster_bootstrap": {
            "cluster_key": "family_id",
            "clusters": len(families),
            "replicates": BOOTSTRAP_REPLICATES,
            "seed": BOOTSTRAP_SEED,
            "success_delta_ci95": [percentile(bootstrap, 0.025), percentile(bootstrap, 0.975)],
        },
        "mean_cost_usd_delta": mean("cost_usd_delta"),
        "mean_wall_time_ms_delta": mean("wall_time_ms_delta"),
        "mean_metered_tokens_delta": mean("metered_tokens_delta"),
    }


def _markdown_report(report: Mapping[str, Any], memory_summary: Mapping[str, Any]) -> str:
    lines = [
        "# v20 paid memory pilot — analysis-only reanalysis",
        "",
        "This bundle is pilot/negative evidence only. It is not a canonical runtime receipt, quality evidence, or promotion evidence.",
        "",
        f"- Provider requests during reanalysis: {report['provider_requests_during_reanalysis']}",
        f"- Paid retry performed: {str(report['paid_retry_performed']).lower()}",
        f"- Newly discovered evaluator-invalid rows: {report['newly_invalid_sequences']}",
        f"- Existing invalid rows with repaired audit projection: {report['reprojected_invalid_sequences']}",
        f"- Budget: journal committed ${report['budget']['journal_committed_cost_usd']:.6f}; runtime estimate ${report['budget']['estimated_cost_usd']:.6f}; {report['budget']['metered_tokens']} metered tokens; journal revision {report['budget']['journal_revision']}",
        "",
        "## Query-plan status",
        "",
        "```json",
        json.dumps(
            {
                "protocol": report["query_plans"]["protocol_status_counts"],
                "quality_eligibility": report["query_plans"][
                    "quality_eligibility_counts"
                ],
            },
            indent=2,
            sort_keys=True,
        ),
        "```",
        "",
        "## Offline paired comparisons",
        "",
        "```json",
        json.dumps(report["paired_offline"], indent=2, sort_keys=True),
        "```",
        "",
        "## Cache/context observations",
        "",
        "```json",
        json.dumps(
            {
                "receipt_gate": report["context_cache_summary"],
                "warm_request_diagnostic": report["warm_context_cache_diagnostic"],
            },
            indent=2,
            sort_keys=True,
        ),
        "```",
        "",
        "## Memory summary",
        "",
        render_memory_markdown(memory_summary, "v20 analysis-only memory summary"),
    ]
    return "\n".join(lines).rstrip() + "\n"


def analyze_failed_run(
    *,
    run_dir: Path,
    manifest_path: Path,
    dataset_source: Path,
    output_dir: Path,
) -> Mapping[str, Any]:
    resolved_run = _resolve_run_directory(run_dir)
    source_tree_before = _artifact_tree_digest(
        resolved_run,
        "failed-run analysis source tree before reanalysis",
    )
    manifest_file = manifest_path.expanduser().resolve(strict=True)
    manifest_bytes = _private_regular(manifest_file, "memory manifest")
    manifest = load_manifest(manifest_file)
    source_path = dataset_source.expanduser().resolve(strict=True)
    source_bytes = _private_regular(source_path, "memory dataset source")
    analysis_sources = _analysis_source_hashes()
    observations, candidate, failure_diagnostic, budget_evidence = _load_failed_candidate(
        resolved_run
    )

    validate_runtime_receipt(
        candidate,
        manifest,
        observations,
        _sha256_bytes(source_bytes),
        "failed runtime candidate",
    )
    validate_runtime_artifacts(
        candidate,
        resolved_run,
        "failed runtime artifacts",
        _query_plan_reanalysis=_FAILED_RUN_QUERY_PLAN_REANALYSIS,
    )

    rollouts = candidate["rollouts"]
    traces: List[Mapping[str, Any]] = []
    trace_evidence: List[Mapping[str, Any]] = []
    for rollout in rollouts:
        cassette = resolved_run / rollout["artifact_paths"]["cassette"]
        trace = build_query_plan_trace(
            cassette,
            run_id=str(rollout["run_id"]),
            arm=str(rollout["arm"]),
            memory_backend=str(rollout["memory_backend"]),
            where=f"failed-run query plan sequence {rollout['sequence']}",
        )
        traces.append(trace)
        sidecar = cassette / SIDECAR_NAME
        trace_evidence.append(
            {
                "sequence": rollout["sequence"],
                "run_id": rollout["run_id"],
                "historical_sidecar_sha256": _sha256_bytes(
                    _private_regular(sidecar, f"sequence {rollout['sequence']} historical sidecar")
                ),
                "recomputed_trace_sha256": _canonical_sha256(trace),
                "status": trace["status"],
                "invalid_reasons": trace["invalid_reasons"],
            }
        )
    repaired, changes, host_satisfied = repair_observations(observations, rollouts, traces)
    rebound = rebind_runtime_receipt(candidate, repaired)
    rows = replay_observations(
        manifest,
        repaired,
        dataset_source=source_path,
        runtime_receipt=rebound,
        runtime_artifact_root=resolved_run,
        _query_plan_reanalysis=_FAILED_RUN_QUERY_PLAN_REANALYSIS,
    )
    memory_summary = summarize_memory(rows)
    warm_cache_diagnostic = summarize_warm_context_cache(
        candidate,
        resolved_run,
        runtime_receipt_sha256=_canonical_sha256(candidate),
    )
    query_summary = summarize_query_plan_traces(
        traces,
        host_recall_satisfied=host_satisfied,
    )
    family_by_case = {
        str(case["id"]): str(case["family_id"])
        for case in manifest["cases"]
        if case["benchmark"] == "procedural_transfer"
    }
    paired = {
        "tinykg_vs_no_memory": _paired_offline_comparison(
            rows,
            rebound,
            family_by_case,
            baseline_arm="no_memory",
            candidate_arm="tinykg_lexical",
        ),
        "markdown_vs_no_memory": _paired_offline_comparison(
            rows,
            rebound,
            family_by_case,
            baseline_arm="no_memory",
            candidate_arm="markdown_memory",
        ),
        "tinykg_vs_markdown": _paired_offline_comparison(
            rows,
            rebound,
            family_by_case,
            baseline_arm="markdown_memory",
            candidate_arm="tinykg_lexical",
        ),
    }
    readiness: Dict[str, Mapping[str, int]] = {}
    for arm in sorted({str(row["arm"]) for row in rows}):
        arm_rows = [row for row in rows if row["arm"] == arm]
        readiness[arm] = {
            "rows": len(arm_rows),
            "evaluator_ready": sum(row["evaluator"]["status"] == "ready" for row in arm_rows),
            "evaluator_invalid": sum(row["evaluator"]["status"] == "invalid" for row in arm_rows),
            "scored": sum(row["outcome"]["status"] in {"pass", "fail"} for row in arm_rows),
        }
    report: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "status": "analysis_only",
        "quality_evidence": False,
        "promotion": False,
        "provider_requests_during_reanalysis": 0,
        "paid_retry_performed": False,
        "source_failure": {
            "error_type": failure_diagnostic["error_type"],
            "error_sha256": failure_diagnostic["error_sha256"],
        },
        "changed_sequences": [int(change["sequence"]) for change in changes],
        "newly_invalid_sequences": [
            int(change["sequence"])
            for change in changes
            if change["classification"] == "newly_invalid"
        ],
        "reprojected_invalid_sequences": [
            int(change["sequence"])
            for change in changes
            if change["classification"] == "existing_invalid_reprojected"
        ],
        "query_plan_invalid_sequences": [
            int(item["sequence"])
            for item in trace_evidence
            if item["status"] == "invalid"
            and not host_satisfied[int(item["sequence"])]
        ],
        "changes": changes,
        "readiness": readiness,
        "query_plans": query_summary,
        "query_plan_evidence": trace_evidence,
        "paired_offline": paired,
        "budget": {
            "estimated_cost_usd": float(candidate["estimated_cost_usd"]),
            "journal_committed_cost_usd": (
                int(candidate["budget_journal"]["committed_cost_microusd"])
                / 1_000_000
            ),
            "metered_tokens": int(candidate["metered_tokens"]),
            "journal_revision": int(candidate["budget_journal"]["revision"]),
            "journal_head_sha256": candidate["budget_journal"]["head_sha256"],
            "transaction_states": candidate["budget_journal"]["transaction_states"],
        },
        "context_cache_summary": candidate["context_cache_summary"],
        "warm_context_cache_diagnostic": warm_cache_diagnostic,
        "claim_boundary": {
            "paired_results_are_exploratory": True,
            "invalid_rows_are_not_missing_at_random": True,
            "unconditional_memory_claim_eligible": False,
            "canonical_runtime_receipt_published": False,
        },
    }

    source_tree_after = _artifact_tree_digest(
        resolved_run,
        "failed-run analysis source tree after reanalysis",
    )
    if source_tree_after != source_tree_before:
        _fail("failed-run reanalysis", "source artifact tree changed during analysis")
    if _private_regular(manifest_file, "memory manifest re-observation") != manifest_bytes:
        _fail("failed-run reanalysis", "manifest changed during analysis")
    if _private_regular(source_path, "dataset source re-observation") != source_bytes:
        _fail("failed-run reanalysis", "dataset source changed during analysis")
    if _analysis_source_hashes() != analysis_sources:
        _fail("failed-run reanalysis", "analysis implementation changed during execution")
    live_journal_path = resolved_run.parent / "state" / "budget-journal.json"
    if _sha256_bytes(
        _private_regular(live_journal_path, "live budget journal re-observation")
    ) != budget_evidence["live_budget_journal_sha256"]:
        _fail("failed-run reanalysis", "budget journal changed during analysis")

    output = _prepare_output_directory(output_dir, resolved_run)
    observations_payload = b"".join(
        (stable_json(row) + "\n").encode("utf-8") for row in repaired
    )
    rows_payload = b"".join(
        (stable_json(row) + "\n").encode("utf-8") for row in rows
    )
    derived_runtime_payload = (
        stable_json(
            {
                "schema_version": SCHEMA_VERSION,
                "status": "analysis_only",
                "canonical_runtime_receipt": False,
                "source_candidate_sha256": _canonical_sha256(candidate),
                "derived_runtime_view": rebound,
            }
        )
        + "\n"
    ).encode("utf-8")
    summary_payload = (stable_json(memory_summary) + "\n").encode("utf-8")
    report_payload = (stable_json(report) + "\n").encode("utf-8")
    markdown_payload = _markdown_report(report, memory_summary).encode("utf-8")
    observations_path = output / "reanalysis-observations.jsonl"
    rows_path = output / "reanalysis-rows.jsonl"
    derived_runtime_path = output / "derived-runtime-view.json"
    summary_path = output / "reanalysis-summary.json"
    report_path = output / "reanalysis-report.json"
    markdown_path = output / "reanalysis-report.md"
    _write_private(observations_path, observations_payload)
    _write_private(rows_path, rows_payload)
    _write_private(derived_runtime_path, derived_runtime_payload)
    _write_private(summary_path, summary_payload)
    _write_private(report_path, report_payload)
    _write_private(markdown_path, markdown_payload)
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "status": "analysis_only",
        "quality_evidence": False,
        "promotion": False,
        "provider_requests_during_reanalysis": 0,
        "paid_retry_performed": False,
        "inputs": {
            "manifest_sha256": _sha256_bytes(manifest_bytes),
            "dataset_source_sha256": _sha256_bytes(source_bytes),
            "failed_validation_diagnostic_sha256": _sha256_bytes(
                _private_regular(resolved_run / FAILED_VALIDATION_DIAGNOSTIC, "failed-validation diagnostic")
            ),
            "failed_run_diagnostic_sha256": _sha256_bytes(
                _private_regular(resolved_run / FAILED_RUN_DIAGNOSTIC, "failed-run diagnostic")
            ),
            "original_observations_sha256": failure_diagnostic["observations_sha256"],
            "runtime_candidate_file_sha256": failure_diagnostic["runtime_candidate_sha256"],
            **budget_evidence,
            "runtime_artifact_tree_sha256": source_tree_after,
        },
        "analysis_sources": analysis_sources,
        "outputs": {
            "reanalysis_observations_sha256": _sha256_bytes(observations_payload),
            "reanalysis_rows_sha256": _sha256_bytes(rows_payload),
            "derived_runtime_view_sha256": _sha256_bytes(derived_runtime_payload),
            "reanalysis_summary_sha256": _sha256_bytes(summary_payload),
            "reanalysis_report_sha256": _sha256_bytes(report_payload),
            "reanalysis_markdown_sha256": _sha256_bytes(markdown_payload),
        },
        "changed_sequences": report["changed_sequences"],
        "newly_invalid_sequences": report["newly_invalid_sequences"],
        "reprojected_invalid_sequences": report["reprojected_invalid_sequences"],
        "query_plan_invalid_sequences": report["query_plan_invalid_sequences"],
    }
    _write_private(
        output / "reanalysis-receipt.json",
        (stable_json(receipt) + "\n").encode("utf-8"),
    )
    _sync_directory(output)
    return verify_reanalysis_bundle(output)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Reanalyze an immutable failed paid-memory run without provider calls",
    )
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--dataset-source", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--verify-bundle", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.verify_bundle is not None:
            if any(
                value is not None
                for value in (
                    args.run_dir,
                    args.manifest,
                    args.dataset_source,
                    args.output_dir,
                )
            ):
                parser.error("--verify-bundle cannot be combined with reanalysis inputs")
            receipt = verify_reanalysis_bundle(args.verify_bundle)
        else:
            missing = [
                name
                for name, value in (
                    ("--run-dir", args.run_dir),
                    ("--manifest", args.manifest),
                    ("--dataset-source", args.dataset_source),
                    ("--output-dir", args.output_dir),
                )
                if value is None
            ]
            if missing:
                parser.error("reanalysis requires " + ", ".join(missing))
            receipt = analyze_failed_run(
                run_dir=args.run_dir,
                manifest_path=args.manifest,
                dataset_source=args.dataset_source,
                output_dir=args.output_dir,
            )
    except ValidationError as exc:
        print(f"error: {exc}", file=os.sys.stderr)
        return 2
    print(
        stable_json(
            {
                "status": receipt["status"],
                "changed_sequences": receipt["changed_sequences"],
                "provider_requests_during_reanalysis": 0,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
