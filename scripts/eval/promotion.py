"""Authoritative calibration evidence for staged multi-arm experiments."""

from __future__ import annotations

import hashlib
import math
import stat
from pathlib import Path
from typing import Any, Dict, Mapping, Tuple

from .analysis import validate_release_contract
from .e2e_adapter import grounding_fingerprints
from .experiment import (
    ARM_IDS,
    PROMOTION_RECEIPT_SCHEMA_VERSION,
    experiment_fingerprint,
    fixed_rollout_budget,
    validate_experiment,
    validate_promotion_receipt,
)
from .model import (
    ValidationError,
    load_json,
    load_rollouts,
    safe_posix_relative_path,
)


TOKEN_METRICS = (
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
)
MAX_CHECKPOINT_BYTES = 64 * 1024 * 1024


def calibration_checkpoint_paths(directory: Path) -> Dict[str, Path]:
    """Return the canonical three checkpoint names below one evidence directory."""
    try:
        directory_stat = directory.lstat()
    except OSError as exc:
        raise ValidationError(f"cannot inspect calibration directory {directory}: {exc}") from exc
    if not stat.S_ISDIR(directory_stat.st_mode) or directory.is_symlink():
        raise ValidationError("calibration evidence path must be a real directory")
    return {arm_id: directory / f"{arm_id}.jsonl" for arm_id in ARM_IDS}


def _sha256_regular_file(path: Path) -> str:
    try:
        file_stat = path.lstat()
        if path.is_symlink() or not stat.S_ISREG(file_stat.st_mode):
            raise OSError("not a regular file")
        if file_stat.st_size > MAX_CHECKPOINT_BYTES:
            raise OSError(f"exceeds {MAX_CHECKPOINT_BYTES} byte limit")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as exc:
        raise ValidationError(f"cannot hash calibration checkpoint {path}: {exc}") from exc


def validate_multi_arm_evidence(
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    repo_root: Path,
    paths: Mapping[str, Path],
) -> Tuple[Dict[str, Any], Dict[str, list[Dict[str, Any]]], Dict[str, str]]:
    """Re-read and validate one complete three-arm checkpoint set."""
    validate_experiment(experiment, repo_root, suite)
    if set(paths) != set(ARM_IDS):
        raise ValidationError("multi-arm evidence must provide exactly three checkpoints")
    before_sha256 = {
        arm_id: _sha256_regular_file(paths[arm_id]) for arm_id in ARM_IDS
    }
    rollouts_by_arm = {
        arm_id: load_rollouts(paths[arm_id]) for arm_id in ARM_IDS
    }
    after_sha256 = {
        arm_id: _sha256_regular_file(paths[arm_id]) for arm_id in ARM_IDS
    }
    if before_sha256 != after_sha256:
        raise ValidationError("multi-arm checkpoints changed while being validated")

    invalid = {
        arm_id: [
            (rollout["task_id"], rollout["trial"])
            for rollout in rollouts
            if not rollout["judgement"]["valid_for_scoring"]
        ]
        for arm_id, rollouts in rollouts_by_arm.items()
    }
    invalid = {arm_id: rows for arm_id, rows in invalid.items() if rows}
    if invalid:
        raise ValidationError(
            f"multi-arm stage rejects invalid rollouts per abort policy: {invalid}"
        )

    grounding = {
        task["id"]: grounding_fingerprints(task, repo_root)
        for task in suite["tasks"]
    }
    task_ids = sorted(grounding)
    contracts: Dict[str, Any] = {}
    metacodes_sha256s = set()
    tinykg_sha256s = set()
    formal_kernel_fingerprints = set()
    revisions = set()
    fingerprint = experiment_fingerprint(experiment, suite)
    fixed = fixed_rollout_budget(experiment["budget"], required=True)
    assert fixed is not None
    fixed_rollout_cost, fixed_rollout_tokens = fixed
    for arm_id, rollouts in rollouts_by_arm.items():
        contract = validate_release_contract(
            rollouts,
            label=arm_id,
            suite_id=suite["suite_id"],
            task_ids=task_ids,
            trials=experiment["trials"],
            model_provider=experiment["model"]["provider"],
            model_id=experiment["model"]["id"],
            grounding=grounding,
        )
        prefix = f"{experiment['experiment_id']}:{arm_id}:{fingerprint}:"
        config_id = contract["harness_config_id"]
        suffix = config_id[len(prefix) :] if config_id.startswith(prefix) else ""
        parts = suffix.split(":")
        if (
            len(parts) != 3
            or not parts[0].startswith("mc-")
            or not parts[1].startswith("kg-")
            or not parts[2].startswith("fk-")
        ):
            raise ValidationError(
                f"{arm_id} harness config is not bound to all experiment artifacts"
            )
        hashes = (parts[0][3:], parts[1][3:], parts[2][3:])
        if any(
            len(value) != 64
            or any(char not in "0123456789abcdef" for char in value)
            for value in hashes
        ):
            raise ValidationError(
                f"{arm_id} harness config contains an invalid artifact digest"
            )
        metacodes_sha256s.add(hashes[0])
        tinykg_sha256s.add(hashes[1])
        formal_kernel_fingerprints.add(hashes[2])
        revisions.add(contract["harness_revision"])
        for rollout in rollouts:
            runtime_budget = rollout.get("harness", {}).get("runtime_budget")
            expected_runtime_budget = {
                "max_metered_tokens": fixed_rollout_tokens,
                "max_cost_usd": fixed_rollout_cost,
            }
            if runtime_budget != expected_runtime_budget:
                raise ValidationError(
                    f"{arm_id} checkpoint runtime budget is not the frozen "
                    "per-rollout contract"
                )
            observed_cost = rollout.get("metrics", {}).get("cost_usd")
            token_values = [
                rollout.get("metrics", {}).get(key) for key in TOKEN_METRICS
            ]
            if observed_cost is None or any(value is None for value in token_values):
                raise ValidationError(
                    f"{arm_id} checkpoint is missing fixed-budget telemetry"
                )
            observed_tokens = sum(int(value) for value in token_values)
            if (
                not math.isfinite(float(observed_cost))
                or float(observed_cost) > fixed_rollout_cost
                or observed_tokens > fixed_rollout_tokens
            ):
                raise ValidationError(
                    f"{arm_id} checkpoint exceeded its frozen per-rollout budget"
                )
        contracts[arm_id] = contract
    if len(metacodes_sha256s) != 1:
        raise ValidationError("multi-arm evidence mixes metacodes binary identities")
    if len(tinykg_sha256s) != 1:
        raise ValidationError("multi-arm evidence mixes TinyKG dependency identities")
    if len(formal_kernel_fingerprints) != 1:
        raise ValidationError("multi-arm evidence mixes formal kernel artifact identities")
    if len(revisions) != 1:
        raise ValidationError("multi-arm evidence mixes metacodes revisions")

    metadata = {
        "experiment_id": experiment["experiment_id"],
        "experiment_fingerprint": fingerprint,
        "metacodes_sha256": next(iter(metacodes_sha256s)),
        "tinykg_sha256": next(iter(tinykg_sha256s)),
        "formal_kernel_fingerprint": next(iter(formal_kernel_fingerprints)),
        "harness_revision": next(iter(revisions)),
        "contracts": contracts,
    }
    return metadata, rollouts_by_arm, after_sha256


def build_promotion_receipt(
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    repo_root: Path,
    paths: Mapping[str, Path],
) -> Dict[str, Any]:
    """Derive a receipt only from a complete authoritative calibration set."""
    if experiment.get("stage", {}).get("id") != "calibration":
        raise ValidationError("promotion receipts can only be built from calibration")
    metadata, rollouts_by_arm, checkpoint_sha256 = validate_multi_arm_evidence(
        experiment, suite, repo_root, paths
    )
    rollouts = [row for arm_id in ARM_IDS for row in rollouts_by_arm[arm_id]]
    gate = experiment["promotion"]["gate"]
    required = gate["required_valid_rollouts"]
    cost_rows = [row for row in rollouts if row["metrics"].get("cost_usd") is not None]
    token_rows = [
        row
        for row in rollouts
        if all(row["metrics"].get(key) is not None for key in TOKEN_METRICS)
    ]
    if (
        len(rollouts) != required
        or len(cost_rows) != required
        or len(token_rows) != required
    ):
        raise ValidationError(
            "calibration promotion requires a complete telemetry-covered schedule"
        )
    cost = sum(float(row["metrics"]["cost_usd"]) for row in rollouts)
    tokens = sum(
        int(row["metrics"][key]) for row in rollouts for key in TOKEN_METRICS
    )
    if (
        not math.isfinite(cost)
        or cost >= float(experiment["budget"]["max_stage_cost_usd"])
        or tokens >= int(experiment["budget"]["max_stage_tokens"])
    ):
        raise ValidationError("calibration usage reached its stage budget; promotion denied")
    return {
        "schema_version": PROMOTION_RECEIPT_SCHEMA_VERSION,
        "program_id": experiment["program_id"],
        "source_experiment_id": experiment["experiment_id"],
        "source_experiment_fingerprint": metadata["experiment_fingerprint"],
        "stage": "calibration",
        "eligible": True,
        "gate": {
            "required_valid_rollouts": required,
            "valid_rollouts": len(rollouts),
            "invalid_rollouts": 0,
            "complete_schedule": True,
            "cost_telemetry_rollouts": len(cost_rows),
            "token_telemetry_rollouts": len(token_rows),
        },
        "usage": {"cost_usd": cost, "tokens": tokens},
        "source_budget": {
            "max_stage_cost_usd": experiment["budget"]["max_stage_cost_usd"],
            "max_stage_tokens": experiment["budget"]["max_stage_tokens"],
        },
        "identity": {
            "metacodes_sha256": metadata["metacodes_sha256"],
            "tinykg_sha256": metadata["tinykg_sha256"],
            "formal_kernel_fingerprint": metadata["formal_kernel_fingerprint"],
            "harness_revision": metadata["harness_revision"],
        },
        "checkpoint_sha256": checkpoint_sha256,
    }


def _load_source_experiment(
    confirmatory_experiment: Mapping[str, Any], repo_root: Path
) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    promotion = confirmatory_experiment["promotion"]
    relative = safe_posix_relative_path(
        promotion["source_experiment"],
        "experiment.promotion.source_experiment",
    )
    source_path = (repo_root / Path(*relative.parts)).resolve()
    try:
        source_path.relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ValidationError("calibration source experiment escapes repository root") from exc
    if source_path.is_symlink() or not source_path.is_file():
        raise ValidationError("calibration source experiment must be a regular file")
    source_experiment = load_json(source_path)
    suite_relative = safe_posix_relative_path(
        source_experiment.get("suite"), "calibration experiment suite"
    )
    suite_path = (repo_root / Path(*suite_relative.parts)).resolve()
    try:
        suite_path.relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ValidationError("calibration source suite escapes repository root") from exc
    if suite_path.is_symlink() or not suite_path.is_file():
        raise ValidationError("calibration source suite must be a regular file")
    source_suite = load_json(suite_path)
    validate_experiment(source_experiment, repo_root, source_suite)
    return source_experiment, source_suite


def validate_calibration_bundle(
    receipt: Mapping[str, Any],
    confirmatory_experiment: Mapping[str, Any],
    repo_root: Path,
    checkpoint_paths: Mapping[str, Path],
    *,
    metacodes_sha256: str,
    tinykg_sha256: str,
    formal_kernel_fingerprint: str,
    revision: str,
) -> Tuple[float, int]:
    """Authorize confirmatory work from source checkpoints, never receipt alone."""
    source_experiment, source_suite = _load_source_experiment(
        confirmatory_experiment, repo_root
    )
    source_fingerprint = experiment_fingerprint(source_experiment, source_suite)
    promotion = confirmatory_experiment["promotion"]
    if (
        source_experiment["program_id"] != confirmatory_experiment["program_id"]
        or source_experiment["experiment_id"] != promotion["source_experiment_id"]
        or source_fingerprint != promotion["source_experiment_fingerprint"]
    ):
        raise ValidationError(
            "calibration source manifest does not match the frozen confirmatory contract"
        )
    expected_receipt = build_promotion_receipt(
        source_experiment, source_suite, repo_root, checkpoint_paths
    )
    if dict(receipt) != expected_receipt:
        raise ValidationError(
            "promotion receipt does not match authoritative calibration checkpoints"
        )
    return validate_promotion_receipt(
        receipt,
        confirmatory_experiment,
        metacodes_sha256=metacodes_sha256,
        tinykg_sha256=tinykg_sha256,
        formal_kernel_fingerprint=formal_kernel_fingerprint,
        revision=revision,
        source_experiment_fingerprint=source_fingerprint,
    )
