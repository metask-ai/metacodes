#!/usr/bin/env python3
"""CLI for the metacodes task-to-feedback evaluation lifecycle."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional, Sequence

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.analysis import (  # type: ignore
        compare,
        compare_multi_arm,
        gate,
        render_comparison_markdown,
        render_multi_arm_markdown,
        render_summary_markdown,
        summarize,
        validate_release_contract,
    )
    from scripts.eval.e2e_adapter import (  # type: ignore
        EVALUATION_CONTRACT_VERSION,
        grounding_fingerprints,
        finalize_evaluation_fd,
        import_run,
        prepare_runtime_metadata,
    )
    from scripts.eval.experiment import (  # type: ignore
        build_dry_run_plan,
        validate_experiment,
    )
    from scripts.eval.model import (  # type: ignore
        ValidationError,
        load_json,
        load_rollouts,
        stable_json,
        validate_suite,
        write_rollouts,
    )
    from scripts.eval.memory_benchmark import (  # type: ignore
        load_memory_rows,
        render_memory_markdown,
        summarize_memory,
        write_memory_rows,
    )
    from scripts.eval.memory_replay import (  # type: ignore
        load_manifest as load_memory_manifest,
        load_observations as load_memory_observations,
        load_runtime_receipt as load_memory_runtime_receipt,
        replay_observations,
    )
    from scripts.eval.paired_runner import run_multi_arm, run_paired  # type: ignore
    from scripts.eval.promotion import (  # type: ignore
        build_promotion_receipt,
        calibration_checkpoint_paths,
        validate_calibration_bundle,
        validate_multi_arm_evidence,
    )
else:
    from .analysis import (
        compare,
        compare_multi_arm,
        gate,
        render_comparison_markdown,
        render_multi_arm_markdown,
        render_summary_markdown,
        summarize,
        validate_release_contract,
    )
    from .e2e_adapter import (
        EVALUATION_CONTRACT_VERSION,
        grounding_fingerprints,
        finalize_evaluation_fd,
        import_run,
        prepare_runtime_metadata,
    )
    from .experiment import (
        build_dry_run_plan,
        validate_experiment,
    )
    from .model import (
        ValidationError,
        load_json,
        load_rollouts,
        stable_json,
        validate_suite,
        write_rollouts,
    )
    from .memory_benchmark import (
        load_memory_rows,
        render_memory_markdown,
        summarize_memory,
        write_memory_rows,
    )
    from .memory_replay import (
        load_manifest as load_memory_manifest,
        load_observations as load_memory_observations,
        load_runtime_receipt as load_memory_runtime_receipt,
        replay_observations,
    )
    from .paired_runner import run_multi_arm, run_paired
    from .promotion import (
        build_promotion_receipt,
        calibration_checkpoint_paths,
        validate_calibration_bundle,
        validate_multi_arm_evidence,
    )


REPO_ROOT = Path(__file__).resolve().parents[2]


def _write(path: Optional[str], text: str) -> None:
    if path:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temp_path: Optional[Path] = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=target.parent,
                prefix=f".{target.name}.",
                suffix=".tmp",
                delete=False,
            ) as handle:
                temp_path = Path(handle.name)
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, target)
            temp_path = None
        finally:
            if temp_path is not None:
                try:
                    temp_path.unlink()
                except FileNotFoundError:
                    pass
    else:
        print(text, end="" if text.endswith("\n") else "\n")


def _write_json(path: Optional[str], value: Dict[str, Any]) -> None:
    text = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    _write(path, text)


def cmd_validate_suite(args: argparse.Namespace) -> int:
    suite = load_json(Path(args.suite))
    warnings = validate_suite(suite, REPO_ROOT)
    print(f"suite {suite['suite_id']}: valid ({len(suite['tasks'])} tasks)")
    for warning in warnings:
        print(f"warning: {warning}")
    return 0


def cmd_validate_rollouts(args: argparse.Namespace) -> int:
    rollouts = load_rollouts(Path(args.rollouts))
    print(f"rollouts: valid ({len(rollouts)} records)")
    return 0


def cmd_validate_memory(args: argparse.Namespace) -> int:
    rows = load_memory_rows(Path(args.results))
    print(f"memory results: valid ({len(rows)} records)")
    return 0


def cmd_report_memory(args: argparse.Namespace) -> int:
    rows = load_memory_rows(Path(args.results))
    summary = summarize_memory(rows, base_arm=args.base_arm)
    _write(args.markdown, render_memory_markdown(summary, args.title))
    if args.json:
        _write_json(args.json, summary)
    return 0


def cmd_replay_memory(args: argparse.Namespace) -> int:
    input_paths = {
        Path(args.manifest).resolve(),
        Path(args.observations).resolve(),
        Path(args.dataset_source).resolve(),
        Path(args.runtime_receipt).resolve(),
    }
    output_paths = [
        Path(value).resolve()
        for value in (args.output, args.markdown, args.json)
        if value
    ]
    if len(set(output_paths)) != len(output_paths):
        raise ValidationError("memory replay output paths must be distinct")
    overlap = input_paths.intersection(output_paths)
    if overlap:
        raise ValidationError(
            f"memory replay output would overwrite an input artifact: {sorted(map(str, overlap))}"
        )
    manifest = load_memory_manifest(Path(args.manifest))
    observations = load_memory_observations(Path(args.observations))
    runtime_receipt = load_memory_runtime_receipt(Path(args.runtime_receipt))
    rows = replay_observations(
        manifest,
        observations,
        dataset_source=Path(args.dataset_source),
        runtime_receipt=runtime_receipt,
    )
    write_memory_rows(Path(args.output), rows)
    if args.markdown or args.json:
        summary = summarize_memory(rows, base_arm=args.base_arm)
        if args.markdown:
            _write(args.markdown, render_memory_markdown(summary, args.title))
        if args.json:
            _write_json(args.json, summary)
    print(
        f"memory replay complete: rows={len(rows)} "
        f"manifest={hashlib.sha256(stable_json(manifest).encode('utf-8')).hexdigest()[:16]}"
    )
    return 0


def _load_experiment_and_suite(path: Path) -> tuple[Dict[str, Any], Dict[str, Any], Path]:
    experiment = load_json(path)
    suite_value = experiment.get("suite")
    if not isinstance(suite_value, str) or not suite_value.strip():
        raise ValidationError("experiment.suite: expected non-empty string")
    suite_path = (REPO_ROOT / suite_value).resolve()
    try:
        suite_path.relative_to(REPO_ROOT.resolve())
    except ValueError as exc:
        raise ValidationError("experiment.suite escapes repository root") from exc
    if not suite_path.is_file():
        raise ValidationError(f"experiment.suite does not exist: {suite_value}")
    suite = load_json(suite_path)
    validate_experiment(experiment, REPO_ROOT, suite)
    return experiment, suite, suite_path


def cmd_validate_experiment(args: argparse.Namespace) -> int:
    experiment, suite, _suite_path = _load_experiment_and_suite(Path(args.experiment))
    plan = build_dry_run_plan(
        experiment,
        suite,
        binary=Path(args.binary),
        tinykg_binary=Path(args.tinykg_binary),
        formal_kernel=Path(args.formal_kernel),
        revision=args.revision,
    )
    print(
        f"experiment {experiment['experiment_id']}: valid "
        f"({len(suite['tasks'])} tasks, {plan['rollout_count']} planned rollouts, "
        f"plan={plan['plan_fingerprint']})"
    )
    return 0


def cmd_run_multi(args: argparse.Namespace) -> int:
    experiment, suite, suite_path = _load_experiment_and_suite(Path(args.experiment))
    if args.dry_run:
        plan = build_dry_run_plan(
            experiment,
            suite,
            binary=Path(args.binary),
            tinykg_binary=Path(args.tinykg_binary),
            formal_kernel=Path(args.formal_kernel),
            revision=args.revision,
            budget_used_cost_usd=args.budget_used_cost_usd,
            budget_used_tokens=args.budget_used_tokens,
        )
        _write_json(args.plan_output, plan)
        print(
            f"multi-arm dry-run complete: rollouts={plan['rollout_count']} "
            f"plan={plan['plan_fingerprint']} paid=0",
            file=sys.stderr if args.plan_output is None else sys.stdout,
        )
        return 0
    collected = run_multi_arm(
        experiment,
        suite,
        REPO_ROOT,
        Path(args.binary),
        tinykg_binary=Path(args.tinykg_binary),
        formal_kernel=Path(args.formal_kernel),
        revision=args.revision,
        output_dir=Path(args.output_dir),
        suite_path=suite_path,
        allow_paid_rollouts=args.allow_paid_rollouts,
        promotion_receipt=(
            load_json(Path(args.promotion_receipt))
            if args.promotion_receipt
            else None
        ),
        calibration_checkpoints=(
            calibration_checkpoint_paths(Path(args.calibration_dir))
            if args.calibration_dir
            else None
        ),
        budget_used_cost_usd=args.budget_used_cost_usd,
        budget_used_tokens=args.budget_used_tokens,
    )
    print(
        "multi-arm E2E complete: "
        + " ".join(f"{arm}={len(rows)}" for arm, rows in collected.items())
    )
    return 0


def cmd_import_e2e(args: argparse.Namespace) -> int:
    suite = load_json(Path(args.suite))
    warnings = validate_suite(suite, REPO_ROOT)
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    config = load_json(Path(args.config)) if args.config else None
    rollouts = import_run(suite, REPO_ROOT, Path(args.run), config)
    write_rollouts(Path(args.output), rollouts)
    print(f"wrote {len(rollouts)} normalized rollouts to {args.output}")
    return 0


def cmd_prepare_e2e(args: argparse.Namespace) -> int:
    suite = load_json(Path(args.suite))
    validate_suite(suite, REPO_ROOT)
    metadata = prepare_runtime_metadata(
        suite,
        REPO_ROOT,
        args.task,
        output=Path(args.output),
        events_path=args.events,
        run_id=args.run_id,
        trial=args.trial,
        model_provider=args.model_provider,
        model_id=args.model_id,
        harness_config_id=args.harness_config_id,
        harness_revision=args.harness_revision,
        permission_mode=args.permission_mode,
        binary_path=Path(args.binary),
        max_metered_tokens=args.max_metered_tokens,
        max_cost_usd=args.max_cost_usd,
    )
    if metadata is None:
        print(f"task {args.task}: not in scored suite; native evaluation disabled")
    else:
        print(f"task {args.task}: froze evaluation metadata at {args.output}")
    return 0


def cmd_finalize_e2e(args: argparse.Namespace) -> int:
    finalize_evaluation_fd(args.fd, Path(args.output))
    print(f"finalized native evaluation events at {args.output}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    rollouts = load_rollouts(Path(args.rollouts))
    result = summarize(rollouts)
    markdown = render_summary_markdown(result, args.title)
    _write(args.markdown, markdown)
    if args.json:
        _write_json(args.json, result)
    return 0


def cmd_run_paired(args: argparse.Namespace) -> int:
    suite = load_json(Path(args.suite))
    validate_suite(suite, REPO_ROOT)
    baseline, candidate = run_paired(
        suite,
        REPO_ROOT,
        Path(args.baseline_binary),
        Path(args.candidate_binary),
        trials=args.trials,
        scenario_glob=args.scenarios,
        model_provider=args.model_provider,
        model_id=args.model_id,
        baseline_output=Path(args.baseline_output),
        candidate_output=Path(args.candidate_output),
        baseline_revision=args.baseline_revision,
        candidate_revision=args.candidate_revision,
        suite_path=Path(args.suite),
        budget_used_cost_usd=args.budget_used_cost_usd,
        budget_used_tokens=args.budget_used_tokens,
        max_cumulative_cost_usd=args.max_cumulative_cost_usd,
        max_cumulative_tokens=args.max_cumulative_tokens,
    )
    print(
        f"paired E2E complete: baseline={len(baseline)} candidate={len(candidate)} "
        f"trials={args.trials}"
    )
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    baseline = load_rollouts(Path(args.baseline))
    candidate = load_rollouts(Path(args.candidate))
    result = compare(baseline, candidate, args.factor)
    markdown = render_comparison_markdown(result)
    _write(args.markdown, markdown)
    if args.json:
        _write_json(args.json, result)
    return 0


def _validated_multi_arm_outputs(
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    paths: Dict[str, Path],
    *,
    tinykg_binary: Path,
) -> tuple[Dict[str, Any], Dict[str, list[Dict[str, Any]]]]:
    metadata, rollouts_by_arm, _checkpoint_sha256 = validate_multi_arm_evidence(
        experiment,
        suite,
        REPO_ROOT,
        paths,
        tinykg_binary=tinykg_binary,
    )
    result = compare_multi_arm(rollouts_by_arm)
    result.update(metadata)
    return result, rollouts_by_arm


def cmd_report_multi(args: argparse.Namespace) -> int:
    experiment, suite, _suite_path = _load_experiment_and_suite(Path(args.experiment))
    if experiment["stage"]["scoring"] != "confirmatory":
        raise ValidationError(
            "report-multi only accepts the held-out confirmatory stage; "
            "use promote-multi for calibration"
        )
    paths = {
        "codex_style": Path(args.codex_style),
        "claude_style": Path(args.claude_style),
        "tinykg": Path(args.tinykg),
    }
    result, _rollouts_by_arm = _validated_multi_arm_outputs(
        experiment,
        suite,
        paths,
        tinykg_binary=Path(args.tinykg_binary),
    )
    receipt = load_json(Path(args.promotion_receipt))
    calibration_cost, calibration_tokens = validate_calibration_bundle(
        receipt,
        experiment,
        REPO_ROOT,
        calibration_checkpoint_paths(Path(args.calibration_dir)),
        tinykg_binary=Path(args.tinykg_binary),
        metacodes_sha256=result["metacodes_sha256"],
        tinykg_sha256=result["tinykg_sha256"],
        formal_kernel_fingerprint=result["formal_kernel_fingerprint"],
        revision=result["harness_revision"],
    )
    result["promotion"] = {
        "source_experiment_id": receipt["source_experiment_id"],
        "source_experiment_fingerprint": receipt["source_experiment_fingerprint"],
        "calibration_cost_usd": calibration_cost,
        "calibration_tokens": calibration_tokens,
    }
    _write(args.markdown, render_multi_arm_markdown(result))
    if args.json:
        _write_json(args.json, result)
    return 0


def cmd_promote_multi(args: argparse.Namespace) -> int:
    experiment, suite, _suite_path = _load_experiment_and_suite(Path(args.experiment))
    if experiment["stage"]["id"] != "calibration":
        raise ValidationError("promote-multi only accepts the calibration stage")
    paths = {
        "codex_style": Path(args.codex_style),
        "claude_style": Path(args.claude_style),
        "tinykg": Path(args.tinykg),
    }
    receipt = build_promotion_receipt(
        experiment,
        suite,
        REPO_ROOT,
        paths,
        tinykg_binary=Path(args.tinykg_binary),
    )
    _write_json(args.output, receipt)
    return 0


def cmd_gate(args: argparse.Namespace) -> int:
    candidate = load_rollouts(Path(args.candidate))
    baseline = load_rollouts(Path(args.baseline)) if args.baseline else None
    thresholds = {
        "max_invalid_rate": 0.0,
        "min_outcome_success": 0.0,
        "min_trustworthy_success": 0.0,
        "max_policy_violations": 0,
        "max_success_regression": 0.0,
        "max_cost_increase_usd": 0.0,
        "max_latency_increase_ms": 0.0,
        "max_model_tool_error_increase": 0.0,
        "min_latency_attribution_coverage": 1.0,
    }
    release_contract = None
    calibration = None
    if args.thresholds:
        config = load_json(Path(args.thresholds))
        if config.get("schema_version") != 1 or not isinstance(config.get("thresholds"), dict):
            raise ValidationError("gate threshold config requires schema_version=1 and thresholds object")
        unknown_top_level = sorted(
            set(config)
            - {"schema_version", "name", "calibration", "release_contract", "thresholds"}
        )
        if unknown_top_level:
            raise ValidationError(
                f"gate threshold config has unknown top-level fields: {unknown_top_level}"
            )
        unknown = sorted(set(config["thresholds"]) - set(thresholds))
        if unknown:
            raise ValidationError(f"gate threshold config has unknown fields: {unknown}")
        thresholds.update(config["thresholds"])
        release_contract = config.get("release_contract")
        calibration = config.get("calibration")
        if not isinstance(release_contract, dict) or not isinstance(
            release_contract.get("suites"), list
        ):
            raise ValidationError(
                "versioned gate config requires release_contract.suites"
            )
        if (
            not isinstance(calibration, dict)
            or calibration.get("status") != "production"
            or not isinstance(calibration.get("id"), str)
            or not calibration.get("id")
            or not isinstance(calibration.get("version"), int)
            or isinstance(calibration.get("version"), bool)
            or calibration.get("version", 0) <= 0
            or not isinstance(calibration.get("basis"), str)
            or not calibration.get("basis")
            or not isinstance(calibration.get("thresholds_fingerprint"), str)
            or not isinstance(calibration.get("release_contract_fingerprint"), str)
            or calibration.get("evaluation_contract_version")
            != EVALUATION_CONTRACT_VERSION
        ):
            raise ValidationError(
                "versioned release gate requires machine-readable production calibration "
                "with id, version, status, basis, and the current evaluation contract"
            )
        actual_thresholds_fingerprint = hashlib.sha256(
            stable_json(config["thresholds"]).encode("utf-8")
        ).hexdigest()[:16]
        actual_contract_fingerprint = hashlib.sha256(
            stable_json(release_contract).encode("utf-8")
        ).hexdigest()[:16]
        if calibration["thresholds_fingerprint"] != actual_thresholds_fingerprint:
            raise ValidationError(
                "calibration does not match the configured release thresholds"
            )
        if calibration["release_contract_fingerprint"] != actual_contract_fingerprint:
            raise ValidationError(
                "calibration does not match the configured release contract"
            )
    supplied_overrides = [
        key for key in thresholds if getattr(args, key) is not None
    ]
    if release_contract is not None and supplied_overrides:
        raise ValidationError(
            "production release gate forbids uncalibrated threshold overrides: "
            f"{supplied_overrides}"
        )
    if release_contract is not None and args.ignore_policy_telemetry:
        raise ValidationError(
            "production release gate cannot ignore policy telemetry"
        )
    if release_contract is not None and baseline is None:
        raise ValidationError(
            "production release gate requires --baseline so calibrated regression "
            "thresholds cannot be silently skipped"
        )
    for key in thresholds:
        override = getattr(args, key)
        if override is not None:
            thresholds[key] = override
    if args.ignore_policy_telemetry:
        thresholds["max_policy_violations"] = None
    for key, value in thresholds.items():
        if key == "max_policy_violations":
            if value is not None and (
                not isinstance(value, int) or isinstance(value, bool) or value < 0
            ):
                raise ValidationError(f"gate threshold {key} must be an integer >= 0")
            continue
        if (
            not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(float(value))
        ):
            raise ValidationError(f"gate threshold {key} must be numeric")
        if value < 0:
            raise ValidationError(f"gate threshold {key} must be >= 0")
        if key in {
            "max_invalid_rate",
            "min_outcome_success",
            "min_trustworthy_success",
            "max_success_regression",
            "min_latency_attribution_coverage",
        } and value > 1:
            raise ValidationError(f"gate threshold {key} must be <= 1")
    contract_evidence = None
    if release_contract is not None:
        if not args.suite:
            raise ValidationError("versioned release gate requires every contracted --suite")
        suites_by_id: Dict[str, Dict[str, Any]] = {}
        for suite_arg in args.suite:
            suite = load_json(Path(suite_arg))
            validate_suite(suite, REPO_ROOT)
            suite_id = suite["suite_id"]
            if suite_id in suites_by_id:
                raise ValidationError(f"duplicate --suite for {suite_id!r}")
            suites_by_id[suite_id] = suite
        declared_suites = release_contract["suites"]
        declared_ids = [
            item.get("suite_id") for item in declared_suites if isinstance(item, dict)
        ]
        if (
            len(declared_ids) != len(declared_suites)
            or not all(isinstance(item, str) and item for item in declared_ids)
            or len(set(declared_ids)) != len(declared_ids)
        ):
            raise ValidationError("release contract suite ids must be non-empty and unique")
        if set(suites_by_id) != set(declared_ids):
            raise ValidationError(
                "production release gate requires exactly all contracted suites; "
                f"expected={sorted(declared_ids)}, supplied={sorted(suites_by_id)}"
            )
        expected_suite_ids = set(declared_ids)
        for label, rollouts in (("candidate", candidate), ("baseline", baseline or [])):
            observed_suite_ids = {item["suite_id"] for item in rollouts}
            if observed_suite_ids != expected_suite_ids:
                raise ValidationError(
                    f"{label} rollout set must contain exactly all contracted suites; "
                    f"expected={sorted(expected_suite_ids)}, observed={sorted(observed_suite_ids)}"
                )
            run_ids = [item["run_id"] for item in rollouts]
            if len(run_ids) != len(set(run_ids)):
                raise ValidationError(f"{label} rollout set has duplicate run_id values")
        all_task_ids = []
        for declared in declared_suites:
            declared_task_ids = declared.get("task_ids")
            if not isinstance(declared_task_ids, list) or not all(
                isinstance(task_id, str) and task_id for task_id in declared_task_ids
            ):
                raise ValidationError(
                    f"malformed release contract task_ids for {declared['suite_id']}"
                )
            all_task_ids.extend(declared_task_ids)
        if len(all_task_ids) != len(set(all_task_ids)):
            raise ValidationError(
                "release contract task ids must be globally unique across suites"
            )
        contract_evidence = {
            "calibration": {
                "id": calibration["id"],
                "version": calibration["version"],
                "status": calibration["status"],
            },
            "suites": [],
        }
        for declared in declared_suites:
            suite_id = declared["suite_id"]
            suite = suites_by_id[suite_id]
            task_ids = declared.get("task_ids")
            trials = declared.get("trials")
            model = declared.get("model")
            declared_suite_fingerprint = declared.get("suite_fingerprint")
            if (
                not isinstance(task_ids, list)
                or not all(isinstance(item, str) and item for item in task_ids)
                or not isinstance(trials, int)
                or isinstance(trials, bool)
                or trials <= 0
                or not isinstance(model, dict)
                or not isinstance(model.get("provider"), str)
                or not model.get("provider")
                or not isinstance(model.get("id"), str)
                or not model.get("id")
                or not isinstance(declared_suite_fingerprint, str)
                or not declared_suite_fingerprint
            ):
                raise ValidationError(f"malformed release contract for {suite_id}")
            grounded_task_ids = [item["id"] for item in suite["tasks"]]
            if task_ids != grounded_task_ids:
                raise ValidationError(
                    "release contract task_ids must exactly match suite task order"
                )
            if args.expected_trials is not None and args.expected_trials != trials:
                raise ValidationError(
                    f"--expected-trials={args.expected_trials} conflicts with calibrated trials={trials}"
                )
            grounding = {
                task["id"]: grounding_fingerprints(task, REPO_ROOT)
                for task in suite["tasks"]
            }
            actual_suite_fingerprint = hashlib.sha256(
                stable_json(
                    {
                        "suite_id": suite_id,
                        "tasks": [
                            {
                                "id": task_id,
                                "task_fingerprint": grounding[task_id]["task_fingerprint"],
                                "grader_fingerprint": grounding[task_id]["grader_fingerprint"],
                            }
                            for task_id in task_ids
                        ],
                    }
                ).encode("utf-8")
            ).hexdigest()[:16]
            if declared_suite_fingerprint != actual_suite_fingerprint:
                raise ValidationError(
                    "calibrated release contract does not match the current suite grounding: "
                    f"suite={suite_id!r}, declared={declared_suite_fingerprint!r}, "
                    f"actual={actual_suite_fingerprint!r}"
                )
            candidate_suite = [
                item for item in candidate if item["suite_id"] == suite_id
            ]
            baseline_suite = [
                item for item in (baseline or []) if item["suite_id"] == suite_id
            ]
            suite_evidence = {
                "suite_id": suite_id,
                "candidate": validate_release_contract(
                    candidate_suite,
                    label=f"candidate:{suite_id}",
                    suite_id=suite_id,
                    task_ids=task_ids,
                    trials=trials,
                    model_provider=model["provider"],
                    model_id=model["id"],
                    grounding=grounding,
                ),
            }
            if baseline is not None:
                suite_evidence["baseline"] = validate_release_contract(
                    baseline_suite,
                    label=f"baseline:{suite_id}",
                    suite_id=suite_id,
                    task_ids=task_ids,
                    trials=trials,
                    model_provider=model["provider"],
                    model_id=model["id"],
                    grounding=grounding,
                )
            contract_evidence["suites"].append(suite_evidence)
        for label in ("candidate", "baseline"):
            if label == "baseline" and baseline is None:
                continue
            identities = {
                (
                    suite_evidence[label]["harness_config_id"],
                    suite_evidence[label]["harness_revision"],
                )
                for suite_evidence in contract_evidence["suites"]
            }
            if len(identities) != 1:
                raise ValidationError(
                    f"{label} mixes harness identities across contracted suites: "
                    f"{sorted(identities)}"
                )
    result = gate(
        candidate,
        baseline=baseline,
        **thresholds,
        factor=args.factor,
    )
    if contract_evidence is not None:
        result["release_contract"] = contract_evidence
    for check in result["checks"]:
        mark = "PASS" if check["passed"] else "FAIL"
        print(f"[{mark}] {check['name']}: actual={check['actual']} limit={check['limit']}")
    if args.json:
        _write_json(args.json, result)
    return 0 if result["passed"] else 1


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        description="metacodes harness evaluation: grounding → readiness → rollout → judgement → feedback"
    )
    commands = root.add_subparsers(dest="command", required=True)

    validate_suite_parser = commands.add_parser(
        "validate-suite", help="validate task grounding and deterministic graders"
    )
    validate_suite_parser.add_argument("suite")
    validate_suite_parser.set_defaults(func=cmd_validate_suite)

    validate_rollouts_parser = commands.add_parser(
        "validate-rollouts", help="validate normalized rollout JSONL"
    )
    validate_rollouts_parser.add_argument("rollouts")
    validate_rollouts_parser.set_defaults(func=cmd_validate_rollouts)

    validate_experiment_parser = commands.add_parser(
        "validate-experiment",
        help="validate the frozen three-arm long-horizon contract and dry-run identity",
    )
    validate_experiment_parser.add_argument("experiment")
    validate_experiment_parser.add_argument("--binary", required=True)
    validate_experiment_parser.add_argument("--tinykg-binary", required=True)
    validate_experiment_parser.add_argument("--formal-kernel", required=True)
    validate_experiment_parser.add_argument("--revision", required=True)
    validate_experiment_parser.set_defaults(func=cmd_validate_experiment)

    import_parser = commands.add_parser(
        "import-e2e", help="normalize an existing tests/e2e run directory"
    )
    import_parser.add_argument("--suite", required=True)
    import_parser.add_argument("--run", required=True)
    import_parser.add_argument("--config", help="known model/harness metadata JSON")
    import_parser.add_argument("--output", required=True)
    import_parser.set_defaults(func=cmd_import_e2e)

    prepare_parser = commands.add_parser(
        "prepare-e2e", help="freeze task/model/harness/grader identities before a rollout"
    )
    prepare_parser.add_argument("--suite", required=True)
    prepare_parser.add_argument("--task", required=True)
    prepare_parser.add_argument("--output", required=True)
    prepare_parser.add_argument("--events", required=True)
    prepare_parser.add_argument("--run-id", required=True)
    prepare_parser.add_argument("--trial", type=int, default=0)
    prepare_parser.add_argument("--model-provider", required=True)
    prepare_parser.add_argument("--model-id", required=True)
    prepare_parser.add_argument("--harness-config-id", required=True)
    prepare_parser.add_argument("--harness-revision", required=True)
    prepare_parser.add_argument("--permission-mode", required=True)
    prepare_parser.add_argument("--binary", required=True)
    prepare_parser.add_argument("--max-metered-tokens", type=int)
    prepare_parser.add_argument("--max-cost-usd", type=float)
    prepare_parser.set_defaults(func=cmd_prepare_e2e)

    finalize_parser = commands.add_parser(
        "finalize-e2e", help="materialize a runner-owned anonymous event fd after rollout"
    )
    finalize_parser.add_argument("--fd", type=int, required=True)
    finalize_parser.add_argument("--output", required=True)
    finalize_parser.set_defaults(func=cmd_finalize_e2e)

    report_parser = commands.add_parser("report", help="aggregate rollout JSONL")
    report_parser.add_argument("rollouts")
    report_parser.add_argument("--title", default="metacodes 评估报告")
    report_parser.add_argument("--markdown")
    report_parser.add_argument("--json")
    report_parser.set_defaults(func=cmd_report)

    validate_memory_parser = commands.add_parser(
        "validate-memory",
        help="validate memory-maturation-v1 result JSONL without scoring",
    )
    validate_memory_parser.add_argument("results")
    validate_memory_parser.set_defaults(func=cmd_validate_memory)

    memory_report_parser = commands.add_parser(
        "report-memory",
        help="score episodic, multi-hop, and procedural memory result JSONL",
    )
    memory_report_parser.add_argument("results")
    memory_report_parser.add_argument("--base-arm", default="no_memory")
    memory_report_parser.add_argument("--title", default="metacodes memory maturation")
    memory_report_parser.add_argument("--markdown")
    memory_report_parser.add_argument("--json")
    memory_report_parser.set_defaults(func=cmd_report_memory)

    memory_replay_parser = commands.add_parser(
        "replay-memory",
        help="join a frozen memory case manifest with host-owned observations",
    )
    memory_replay_parser.add_argument("--manifest", required=True)
    memory_replay_parser.add_argument("--observations", required=True)
    memory_replay_parser.add_argument("--dataset-source", required=True)
    memory_replay_parser.add_argument("--runtime-receipt", required=True)
    memory_replay_parser.add_argument("--output", required=True)
    memory_replay_parser.add_argument("--base-arm", default="no_memory")
    memory_replay_parser.add_argument("--title", default="metacodes memory maturation")
    memory_replay_parser.add_argument("--markdown")
    memory_replay_parser.add_argument("--json")
    memory_replay_parser.set_defaults(func=cmd_replay_memory)

    paired_parser = commands.add_parser(
        "run-paired", help="run repeated order-balanced baseline/candidate native E2E"
    )
    paired_parser.add_argument("--suite", default="evals/suites/core-e2e.json")
    paired_parser.add_argument("--baseline-binary", required=True)
    paired_parser.add_argument("--candidate-binary", required=True)
    paired_parser.add_argument("--baseline-revision", required=True)
    paired_parser.add_argument("--candidate-revision", required=True)
    paired_parser.add_argument("--trials", type=int, required=True)
    paired_parser.add_argument("--scenarios", default="*")
    paired_parser.add_argument("--model-provider", default="anthropic")
    paired_parser.add_argument("--model-id", default="claude-sonnet-4-20250514")
    paired_parser.add_argument("--baseline-output", required=True)
    paired_parser.add_argument("--candidate-output", required=True)
    paired_parser.add_argument("--budget-used-cost-usd", type=float, default=0.0)
    paired_parser.add_argument("--budget-used-tokens", type=int, default=0)
    paired_parser.add_argument("--max-cumulative-cost-usd", type=float)
    paired_parser.add_argument("--max-cumulative-tokens", type=int)
    paired_parser.set_defaults(func=cmd_run_paired)

    multi_parser = commands.add_parser(
        "run-multi",
        help="dry-run or execute the resumable three-arm long-horizon experiment",
    )
    multi_parser.add_argument("--experiment", required=True)
    multi_parser.add_argument("--binary", required=True)
    multi_parser.add_argument("--tinykg-binary", required=True)
    multi_parser.add_argument("--formal-kernel", required=True)
    multi_parser.add_argument("--revision", required=True)
    multi_parser.add_argument("--output-dir", required=True)
    multi_parser.add_argument("--dry-run", action="store_true")
    multi_parser.add_argument("--plan-output")
    multi_parser.add_argument("--allow-paid-rollouts", action="store_true")
    multi_parser.add_argument(
        "--promotion-receipt",
        help="calibration receipt required by the confirmatory stage",
    )
    multi_parser.add_argument(
        "--calibration-dir",
        help="authoritative calibration directory containing the three JSONL checkpoints",
    )
    multi_parser.add_argument(
        "--budget-used-cost-usd",
        type=float,
        default=0.0,
        help="paid cost from earlier attempts of this same stage; counts against stage and aggregate caps",
    )
    multi_parser.add_argument(
        "--budget-used-tokens",
        type=int,
        default=0,
        help="metered tokens from earlier attempts of this same stage; counts against stage and aggregate caps",
    )
    multi_parser.set_defaults(func=cmd_run_multi)

    compare_parser = commands.add_parser(
        "compare", help="paired comparison with exact McNemar significance"
    )
    compare_parser.add_argument("baseline")
    compare_parser.add_argument("candidate")
    compare_parser.add_argument(
        "--factor", choices=("harness", "model", "joint"), default="harness"
    )
    compare_parser.add_argument("--markdown")
    compare_parser.add_argument("--json")
    compare_parser.set_defaults(func=cmd_compare)

    multi_report_parser = commands.add_parser(
        "report-multi",
        help="validate and render one unified report for the three long-horizon arms",
    )
    multi_report_parser.add_argument("--experiment", required=True)
    multi_report_parser.add_argument("--codex-style", required=True)
    multi_report_parser.add_argument("--claude-style", required=True)
    multi_report_parser.add_argument("--tinykg", required=True)
    multi_report_parser.add_argument("--promotion-receipt", required=True)
    multi_report_parser.add_argument("--calibration-dir", required=True)
    multi_report_parser.add_argument("--tinykg-binary", required=True)
    multi_report_parser.add_argument("--markdown")
    multi_report_parser.add_argument("--json")
    multi_report_parser.set_defaults(func=cmd_report_multi)

    promote_parser = commands.add_parser(
        "promote-multi",
        help="validate a complete non-scoring calibration stage and issue its receipt",
    )
    promote_parser.add_argument("--experiment", required=True)
    promote_parser.add_argument("--codex-style", required=True)
    promote_parser.add_argument("--claude-style", required=True)
    promote_parser.add_argument("--tinykg", required=True)
    promote_parser.add_argument("--tinykg-binary", required=True)
    promote_parser.add_argument("--output", required=True)
    promote_parser.set_defaults(func=cmd_promote_multi)

    gate_parser = commands.add_parser("gate", help="enforce deployment/regression thresholds")
    gate_parser.add_argument("candidate")
    gate_parser.add_argument("--baseline")
    gate_parser.add_argument(
        "--factor", choices=("harness", "model", "joint"), default="harness"
    )
    gate_parser.add_argument("--thresholds", help="versioned JSON threshold configuration")
    gate_parser.add_argument(
        "--suite",
        action="append",
        help="grounded suite bound by the release contract; repeat for every contracted suite",
    )
    gate_parser.add_argument(
        "--expected-trials",
        type=int,
        help="must equal the calibrated release-contract trial count",
    )
    gate_parser.add_argument("--max-invalid-rate", type=float)
    gate_parser.add_argument("--min-outcome-success", type=float)
    gate_parser.add_argument("--min-trustworthy-success", type=float)
    gate_parser.add_argument("--max-policy-violations", type=int)
    gate_parser.add_argument("--ignore-policy-telemetry", action="store_true")
    gate_parser.add_argument("--max-success-regression", type=float)
    gate_parser.add_argument("--max-cost-increase-usd", type=float)
    gate_parser.add_argument("--max-latency-increase-ms", type=float)
    gate_parser.add_argument("--max-model-tool-error-increase", type=float)
    gate_parser.add_argument("--min-latency-attribution-coverage", type=float)
    gate_parser.add_argument("--json")
    gate_parser.set_defaults(func=cmd_gate)
    return root


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parser().parse_args(argv)
    try:
        return int(args.func(args))
    except ValidationError as exc:
        print(f"evaluation error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
