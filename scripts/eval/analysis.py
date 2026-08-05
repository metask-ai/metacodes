"""Aggregate, compare, and gate normalized metacodes rollouts."""

from __future__ import annotations

from collections import Counter
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import hashlib

from .model import ValidationError, stable_json
from .statistics import (
    exact_mcnemar,
    mean,
    mean_confidence_interval_95,
    percentile,
    sample_variance,
    wilson_interval,
)


LATENCY_COMPONENTS = (
    "model_request_time_ms",
    "tool_stage_time_ms",
    "harness_time_ms",
)

DIAGNOSTIC_METRICS = (
    "tool_time_ms",
    "tool_parallelism_factor",
    "network_errors",
    "retries",
)
LONG_HORIZON_ARM_IDS = ("codex_style", "claude_style", "tinykg")


def _rate(successes: int, total: int) -> Optional[float]:
    return successes / total if total else None


def _total_tokens(rollout: Dict[str, Any]) -> int:
    metrics = rollout["metrics"]
    return sum(
        int(metrics.get(field) or 0)
        for field in (
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
        )
    )


def summarize(rollouts: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    total = len(rollouts)
    valid = [item for item in rollouts if item["judgement"]["valid_for_scoring"]]
    invalid = [item for item in rollouts if not item["judgement"]["valid_for_scoring"]]
    scored = [item for item in valid if item["outcome"]["status"] in {"pass", "fail"}]
    outcome_passes = sum(item["outcome"]["status"] == "pass" for item in scored)
    trustworthy_passes = sum(
        bool(item["judgement"]["trustworthy_success"]) for item in scored
    )
    outcome_ci = wilson_interval(outcome_passes, len(scored))
    trustworthy_ci = wilson_interval(trustworthy_passes, len(scored))

    attribution = Counter()
    for rollout in rollouts:
        for item in rollout["attribution"]:
            attribution[(item["source"], item["code"])] += int(item.get("count", 1))

    unique_tasks = {item["task_id"]: item for item in rollouts}
    layer_coverage = Counter()
    for item in unique_tasks.values():
        for layer in item.get("layers", []):
            layer_coverage[layer] += 1

    numeric_metrics: Dict[str, List[float]] = {
        "total_tokens": [],
        "cost_usd": [],
        "wall_time_ms": [],
        "model_request_time_ms": [],
        "tool_stage_time_ms": [],
        "tool_time_ms": [],
        "tool_parallelism_factor": [],
        "harness_time_ms": [],
        "tool_calls": [],
        "turns": [],
        "retries": [],
    }
    policy_coverage = 0
    policy_violations = 0
    for rollout in valid:
        numeric_metrics["total_tokens"].append(float(_total_tokens(rollout)))
        for key in (
            "cost_usd",
            "wall_time_ms",
            *LATENCY_COMPONENTS,
            "tool_time_ms",
            "tool_parallelism_factor",
            "tool_calls",
            "turns",
            "retries",
        ):
            value = rollout["metrics"].get(key)
            if value is not None:
                numeric_metrics[key].append(float(value))
        violations = rollout["metrics"].get("policy_violations")
        if violations is not None:
            policy_coverage += 1
            policy_violations += int(violations)

    metric_summary = {}
    for key, values in numeric_metrics.items():
        metric_summary[key] = {
            "count": len(values),
            "mean": mean(values),
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
            "total": sum(values) if values else None,
        }

    warnings = []
    if any(item["model"]["id"] == "unknown" for item in rollouts):
        warnings.append("model id is unknown for one or more rollouts")
    if any(item["harness"]["config_id"].endswith(":unknown") for item in rollouts):
        warnings.append("harness config id is unknown for one or more rollouts")
    if any(item["harness"].get("revision") == "unknown" for item in rollouts):
        warnings.append("harness revision is unknown for one or more rollouts")
    if metric_summary["cost_usd"]["count"] < len(valid):
        warnings.append("cost is missing for some valid rollouts")
    if metric_summary["wall_time_ms"]["count"] < len(valid):
        warnings.append("wall-clock latency is missing for some valid rollouts")
    latency_attribution_coverage = sum(
        all(item["metrics"].get(key) is not None for key in LATENCY_COMPONENTS)
        for item in valid
    )
    if latency_attribution_coverage < len(valid):
        warnings.append("model/tool-stage/harness latency attribution is missing for some valid rollouts")
    if policy_coverage < len(valid):
        warnings.append("policy-violation telemetry is missing for some valid rollouts")
    if any(
        item.get("task_fingerprint_provenance") != "recorded_at_execution"
        for item in rollouts
    ):
        warnings.append("task fingerprint was inferred from the current suite for legacy rollouts")

    task_rows = []
    for item in sorted(rollouts, key=lambda rollout: (rollout["task_id"], rollout["trial"])):
        task_rows.append(
            {
                "task_id": item["task_id"],
                "trial": item["trial"],
                "execution": item["execution"]["status"],
                "outcome": item["outcome"]["status"],
                "trajectory": item["trajectory"]["status"],
                "evaluator": item["evaluator"]["status"],
                "trustworthy_success": item["judgement"]["trustworthy_success"],
                "tokens": _total_tokens(item),
                "tool_calls": item["metrics"].get("tool_calls"),
                "wall_time_ms": item["metrics"].get("wall_time_ms"),
                "model_request_time_ms": item["metrics"].get("model_request_time_ms"),
                "tool_stage_time_ms": item["metrics"].get("tool_stage_time_ms"),
                "harness_time_ms": item["metrics"].get("harness_time_ms"),
            }
        )

    return {
        "rollouts": total,
        "valid_rollouts": len(valid),
        "invalid_rollouts": len(invalid),
        "invalid_rate": _rate(len(invalid), total),
        "scored_rollouts": len(scored),
        "unscored_rollouts": len(valid) - len(scored),
        "outcome_successes": outcome_passes,
        "outcome_success_rate": _rate(outcome_passes, len(scored)),
        "outcome_success_wilson_95": outcome_ci,
        "trustworthy_successes": trustworthy_passes,
        "trustworthy_success_rate": _rate(trustworthy_passes, len(scored)),
        "trustworthy_success_wilson_95": trustworthy_ci,
        "trajectory_failures": sum(
            item["trajectory"]["status"] == "fail" for item in valid
        ),
        "evaluator_failures": sum(
            item["evaluator"]["status"] == "invalid" for item in rollouts
        ),
        "policy_telemetry_coverage": policy_coverage,
        "latency_attribution_coverage": latency_attribution_coverage,
        "policy_violations": policy_violations,
        "metrics": metric_summary,
        "attribution": [
            {"source": source, "code": code, "count": count}
            for (source, code), count in sorted(
                attribution.items(), key=lambda pair: (-pair[1], pair[0])
            )
        ],
        "layer_coverage": dict(sorted(layer_coverage.items())),
        "warnings": warnings,
        "tasks": task_rows,
    }


def _fmt_rate(value: Optional[float]) -> str:
    return "n/a" if value is None else f"{value:.1%}"


def _fmt_num(value: Optional[float], digits: int = 1) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def render_summary_markdown(summary: Dict[str, Any], title: str = "metacodes 评估报告") -> str:
    outcome_ci = summary["outcome_success_wilson_95"]
    trustworthy_ci = summary["trustworthy_success_wilson_95"]
    lines = [
        f"# {title}",
        "",
        "## 总览",
        "",
        f"- Rollout: {summary['rollouts']}（有效 {summary['valid_rollouts']}，invalid {summary['invalid_rollouts']}，未评分 {summary['unscored_rollouts']}）",
        f"- Outcome success: {summary['outcome_successes']}/{summary['scored_rollouts']} = {_fmt_rate(summary['outcome_success_rate'])}（Wilson 95% CI {_fmt_rate(outcome_ci[0])}–{_fmt_rate(outcome_ci[1])}）",
        f"- Trustworthy success: {summary['trustworthy_successes']}/{summary['scored_rollouts']} = {_fmt_rate(summary['trustworthy_success_rate'])}（Wilson 95% CI {_fmt_rate(trustworthy_ci[0])}–{_fmt_rate(trustworthy_ci[1])}）",
        f"- 轨迹失败: {summary['trajectory_failures']}；评估器无效: {summary['evaluator_failures']}；已观测策略违规: {summary['policy_violations']}",
        "",
        "> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。",
        "",
        "## 质量–成本–延迟",
        "",
        "| 指标 | 样本 | 均值 | P50 | P95 | 总计 |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    labels = {
        "total_tokens": "Token",
        "cost_usd": "成本 USD",
        "wall_time_ms": "壁钟 ms",
        "tool_calls": "工具调用",
        "turns": "Turn",
        "retries": "重试",
    }
    for key, label in labels.items():
        metric = summary["metrics"][key]
        lines.append(
            f"| {label} | {metric['count']} | {_fmt_num(metric['mean'])} | {_fmt_num(metric['p50'])} | {_fmt_num(metric['p95'])} | {_fmt_num(metric['total'])} |"
        )

    lines.extend(
        [
            "",
            "## Rollout 明细",
            "",
            "| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |",
            "|---|---:|---|---|---|---|---|---:|---:|",
        ]
    )
    for item in summary["tasks"]:
        lines.append(
            "| {task_id} | {trial} | {execution} | {outcome} | {trajectory} | "
            "{evaluator} | {trustworthy} | {tokens} | {tool_calls} |".format(
                **item,
                trustworthy="✓" if item["trustworthy_success"] else "—",
            )
        )

    lines.extend(["", "## ETCLOVG 覆盖", ""])
    lines.append(
        ", ".join(
            f"{layer}={count}" for layer, count in summary["layer_coverage"].items()
        )
        or "无"
    )
    lines.extend(["", "## 故障归因", ""])
    if summary["attribution"]:
        lines.extend(["| 来源 | 代码 | 次数 |", "|---|---|---:|"])
        for item in summary["attribution"]:
            lines.append(f"| {item['source']} | {item['code']} | {item['count']} |")
    else:
        lines.append("无已归因故障。")
    if summary["warnings"]:
        lines.extend(["", "## 测量完整性警告", ""])
        lines.extend(f"- {warning}" for warning in summary["warnings"])
    lines.append("")
    return "\n".join(lines)


def _pair_map(rollouts: Sequence[Dict[str, Any]]) -> Dict[Tuple[str, int], Dict[str, Any]]:
    result = {}
    for rollout in rollouts:
        key = (rollout["task_id"], rollout["trial"])
        if key in result:
            raise ValidationError(f"duplicate rollout pair key: {key}")
        result[key] = rollout
    return result


def validate_release_contract(
    rollouts: Sequence[Dict[str, Any]],
    *,
    label: str,
    suite_id: str,
    task_ids: Sequence[str],
    trials: int,
    model_provider: str,
    model_id: str,
    grounding: Dict[str, Dict[str, str]],
) -> Dict[str, Any]:
    """Fail closed unless a rollout set is the complete declared experiment."""
    if trials <= 0:
        raise ValidationError("release contract trials must be > 0")
    declared_tasks = list(task_ids)
    if not declared_tasks or len(set(declared_tasks)) != len(declared_tasks):
        raise ValidationError("release contract task_ids must be non-empty and unique")
    if set(declared_tasks) != set(grounding):
        raise ValidationError(
            "release contract task_ids do not match the grounded suite tasks"
        )
    pair_map = _pair_map(rollouts)
    expected_pairs = {
        (task_id, trial)
        for task_id in declared_tasks
        for trial in range(trials)
    }
    if set(pair_map) != expected_pairs:
        missing = sorted(expected_pairs - set(pair_map))
        extra = sorted(set(pair_map) - expected_pairs)
        raise ValidationError(
            f"{label} violates release suite/trial contract; "
            f"missing={missing}, extra={extra}"
        )

    expected_model_fingerprint = hashlib.sha256(
        stable_json({"provider": model_provider, "id": model_id}).encode("utf-8")
    ).hexdigest()[:16]
    run_ids = set()
    config_ids = set()
    revisions = set()
    harness_fingerprints: Dict[str, set[str]] = {
        task_id: set() for task_id in declared_tasks
    }
    for key, rollout in pair_map.items():
        task_id, _trial = key
        expected = grounding[task_id]
        mismatches = []
        if rollout.get("suite_id") != suite_id:
            mismatches.append("suite_id")
        if rollout.get("task_fingerprint_provenance") != "recorded_at_execution":
            mismatches.append("task_fingerprint_provenance")
        if rollout.get("task_fingerprint") != expected["task_fingerprint"]:
            mismatches.append("task_fingerprint")
        if rollout.get("evaluator", {}).get("fingerprint") != expected["grader_fingerprint"]:
            mismatches.append("grader_fingerprint")
        model = rollout.get("model", {})
        if model.get("provider") != model_provider:
            mismatches.append("model.provider")
        if model.get("id") != model_id:
            mismatches.append("model.id")
        if model.get("fingerprint") != expected_model_fingerprint:
            mismatches.append("model.fingerprint")
        harness = rollout.get("harness", {})
        if harness.get("environment_fingerprint") != expected["environment_fingerprint"]:
            mismatches.append("environment_fingerprint")
        if harness.get("permission_mode") != expected["permission_mode"]:
            mismatches.append("permission_mode")
        harness_fingerprint = harness.get("fingerprint")
        if not isinstance(harness_fingerprint, str) or not harness_fingerprint:
            mismatches.append("harness.fingerprint")
        else:
            harness_fingerprints[task_id].add(harness_fingerprint)
        config_id = harness.get("config_id")
        revision = harness.get("revision")
        if not isinstance(config_id, str) or not config_id or config_id.endswith(":unknown"):
            mismatches.append("harness.config_id")
        else:
            config_ids.add(config_id)
        if not isinstance(revision, str) or not revision or revision == "unknown":
            mismatches.append("harness.revision")
        else:
            revisions.add(revision)
        run_id = rollout.get("run_id")
        if not isinstance(run_id, str) or not run_id or run_id in run_ids:
            mismatches.append("run_id")
        else:
            run_ids.add(run_id)
        if mismatches:
            raise ValidationError(
                f"{label} rollout {key!r} release identity mismatch: {sorted(mismatches)}"
            )
    if len(config_ids) != 1 or len(revisions) != 1:
        raise ValidationError(
            f"{label} mixes harness configurations or revisions: "
            f"config_ids={sorted(config_ids)}, revisions={sorted(revisions)}"
        )
    unstable_harness = sorted(
        task_id
        for task_id, fingerprints in harness_fingerprints.items()
        if len(fingerprints) != 1
    )
    if unstable_harness:
        raise ValidationError(
            f"{label} harness fingerprint changed across trials for tasks: {unstable_harness}"
        )
    return {
        "suite_id": suite_id,
        "tasks": len(declared_tasks),
        "trials": trials,
        "pairs": len(expected_pairs),
        "model_provider": model_provider,
        "model_id": model_id,
        "harness_config_id": next(iter(config_ids)),
        "harness_revision": next(iter(revisions)),
    }


def compare(
    baseline: Sequence[Dict[str, Any]],
    candidate: Sequence[Dict[str, Any]],
    factor: str,
) -> Dict[str, Any]:
    if factor not in {"harness", "model", "joint"}:
        raise ValidationError("comparison factor must be harness, model, or joint")
    base_map = _pair_map(baseline)
    candidate_map = _pair_map(candidate)
    if set(base_map) != set(candidate_map):
        missing_from_candidate = sorted(set(base_map) - set(candidate_map))
        missing_from_baseline = sorted(set(candidate_map) - set(base_map))
        raise ValidationError(
            "baseline and candidate must contain identical task/trial pairs; "
            f"missing_from_candidate={missing_from_candidate}, "
            f"missing_from_baseline={missing_from_baseline}"
        )
    keys = sorted(set(base_map) & set(candidate_map))
    if not keys:
        raise ValidationError("baseline and candidate have no paired task/trial rollouts")

    eligible = []
    excluded = []
    for key in keys:
        before, after = base_map[key], candidate_map[key]
        if before["suite_id"] != after["suite_id"]:
            raise ValidationError(f"{key}: suite changed; comparison would be confounded")
        if (
            before.get("task_fingerprint_provenance") != "recorded_at_execution"
            or after.get("task_fingerprint_provenance") != "recorded_at_execution"
        ):
            raise ValidationError(
                f"{key}: task grounding fingerprint was not recorded at execution time"
            )
        if before["task_fingerprint"] != after["task_fingerprint"]:
            raise ValidationError(f"{key}: task grounding changed; comparison would be confounded")
        if before["evaluator"]["fingerprint"] != after["evaluator"]["fingerprint"]:
            raise ValidationError(f"{key}: evaluator changed; comparison would be confounded")
        before_environment = before["harness"].get("environment_fingerprint")
        after_environment = after["harness"].get("environment_fingerprint")
        if (
            not before_environment
            or not after_environment
            or before_environment != after_environment
        ):
            raise ValidationError(
                f"{key}: execution environment changed or is unknown; comparison would be confounded"
            )
        if factor == "harness":
            before_model = before["model"].get("fingerprint")
            after_model = after["model"].get("fingerprint")
            if not before_model or not after_model or before_model != after_model:
                raise ValidationError(f"{key}: harness comparison requires the same known model")
        elif factor == "model":
            before_harness = before["harness"].get("fingerprint")
            after_harness = after["harness"].get("fingerprint")
            if not before_harness or not after_harness:
                raise ValidationError(f"{key}: model comparison requires a known harness")
            if before_harness != after_harness:
                raise ValidationError(f"{key}: model comparison requires the same harness")
        if not (
            before["judgement"]["valid_for_scoring"]
            and after["judgement"]["valid_for_scoring"]
            and before["outcome"]["status"] in {"pass", "fail"}
            and after["outcome"]["status"] in {"pass", "fail"}
        ):
            excluded.append({"task_id": key[0], "trial": key[1], "reason": "invalid_or_unscored"})
            continue
        eligible.append((key, before, after))
    if not eligible:
        raise ValidationError("no valid scored rollout pairs remain after filtering")

    regressions = 0
    improvements = 0
    base_successes = 0
    candidate_successes = 0
    token_deltas = []
    tool_call_deltas = []
    model_tool_error_deltas = []
    cost_deltas = []
    latency_deltas = []
    latency_component_deltas: Dict[str, List[float]] = {
        key: [] for key in LATENCY_COMPONENTS
    }
    diagnostic_deltas: Dict[str, List[float]] = {
        key: [] for key in DIAGNOSTIC_METRICS
    }
    task_trial_contributions = []
    for pair_key, before, after in eligible:
        base_success = bool(before["judgement"]["trustworthy_success"])
        candidate_success = bool(after["judgement"]["trustworthy_success"])
        base_successes += base_success
        candidate_successes += candidate_success
        regressions += base_success and not candidate_success
        improvements += candidate_success and not base_success
        token_deltas.append(_total_tokens(after) - _total_tokens(before))
        tool_call_deltas.append(
            int(after["metrics"].get("tool_calls") or 0)
            - int(before["metrics"].get("tool_calls") or 0)
        )
        model_tool_error_deltas.append(
            int(after["metrics"].get("model_tool_errors") or 0)
            - int(before["metrics"].get("model_tool_errors") or 0)
        )
        before_cost, after_cost = before["metrics"].get("cost_usd"), after["metrics"].get("cost_usd")
        if before_cost is None or after_cost is None:
            raise ValidationError(f"{pair_key}: paired comparison requires cost_usd telemetry")
        cost_delta_value = float(after_cost) - float(before_cost)
        cost_deltas.append(cost_delta_value)
        before_latency = before["metrics"].get("wall_time_ms")
        after_latency = after["metrics"].get("wall_time_ms")
        if before_latency is None or after_latency is None:
            raise ValidationError(f"{pair_key}: paired comparison requires wall_time_ms telemetry")
        latency_delta_value = float(after_latency) - float(before_latency)
        latency_deltas.append(latency_delta_value)
        component_row: Dict[str, Optional[float]] = {}
        for metric in LATENCY_COMPONENTS:
            before_value = before["metrics"].get(metric)
            after_value = after["metrics"].get(metric)
            delta = (
                float(after_value) - float(before_value)
                if before_value is not None and after_value is not None
                else None
            )
            component_row[metric] = delta
            if delta is not None:
                latency_component_deltas[metric].append(delta)
        diagnostic_row: Dict[str, Optional[float]] = {}
        for metric in DIAGNOSTIC_METRICS:
            before_value = before["metrics"].get(metric)
            after_value = after["metrics"].get(metric)
            delta = (
                float(after_value) - float(before_value)
                if before_value is not None and after_value is not None
                else None
            )
            diagnostic_row[metric] = delta
            if delta is not None:
                diagnostic_deltas[metric].append(delta)
        task_trial_contributions.append(
            {
                "task_id": pair_key[0],
                "trial": pair_key[1],
                "baseline_trustworthy_success": base_success,
                "candidate_trustworthy_success": candidate_success,
                "total_tokens": token_deltas[-1],
                "tool_calls": tool_call_deltas[-1],
                "model_tool_errors": model_tool_error_deltas[-1],
                "cost_usd": cost_delta_value,
                "wall_time_ms": latency_delta_value,
                **component_row,
                **diagnostic_row,
            }
        )

    total = len(eligible)
    deltas = {
        "total_tokens": token_deltas,
        "tool_calls": tool_call_deltas,
        "model_tool_errors": model_tool_error_deltas,
        "cost_usd": cost_deltas,
        "wall_time_ms": latency_deltas,
        **latency_component_deltas,
        **diagnostic_deltas,
    }
    paired_delta = {
        key: {
            "mean": mean(values),
            "variance": sample_variance(values),
            "ci95": mean_confidence_interval_95(values),
            "p50": percentile(values, 0.50),
            "p95": percentile(values, 0.95),
        }
        for key, values in deltas.items()
    }
    quality_delta = (candidate_successes - base_successes) / total
    cost_delta = paired_delta["cost_usd"]["mean"]
    latency_delta = paired_delta["wall_time_ms"]["mean"]
    assert cost_delta is not None and latency_delta is not None
    no_worse = quality_delta >= 0 and cost_delta <= 0 and latency_delta <= 0
    strictly_better = quality_delta > 0 or cost_delta < 0 or latency_delta < 0
    no_better = quality_delta <= 0 and cost_delta >= 0 and latency_delta >= 0
    strictly_worse = quality_delta < 0 or cost_delta > 0 or latency_delta > 0
    risk_frontier = (
        "candidate_dominates"
        if no_worse and strictly_better
        else "candidate_dominated"
        if no_better and strictly_worse
        else "equivalent"
        if quality_delta == 0 and cost_delta == 0 and latency_delta == 0
        else "tradeoff"
    )
    task_trial_contributions.sort(
        key=lambda row: abs(float(row["wall_time_ms"])), reverse=True
    )
    task_contributions = []
    for task_id in sorted({row["task_id"] for row in task_trial_contributions}):
        rows = [row for row in task_trial_contributions if row["task_id"] == task_id]

        def row_mean(field: str) -> Optional[float]:
            return mean(
                [float(row[field]) for row in rows if row.get(field) is not None]
            )

        task_contributions.append(
            {
                "task_id": task_id,
                "pairs": len(rows),
                "trustworthy_regressions": sum(
                    row["baseline_trustworthy_success"]
                    and not row["candidate_trustworthy_success"]
                    for row in rows
                ),
                "trustworthy_improvements": sum(
                    row["candidate_trustworthy_success"]
                    and not row["baseline_trustworthy_success"]
                    for row in rows
                ),
                **{
                    metric: row_mean(metric)
                    for metric in (
                        "total_tokens",
                        "tool_calls",
                        "model_tool_errors",
                        "cost_usd",
                        "wall_time_ms",
                        *LATENCY_COMPONENTS,
                        *DIAGNOSTIC_METRICS,
                    )
                },
            }
        )
    latency_attribution_pairs = sum(
        all(row.get(metric) is not None for metric in LATENCY_COMPONENTS)
        for row in task_trial_contributions
    )
    return {
        "factor": factor,
        "paired_rollouts": total,
        "excluded_pairs": excluded,
        "baseline_successes": base_successes,
        "candidate_successes": candidate_successes,
        "baseline_success_rate": base_successes / total,
        "candidate_success_rate": candidate_successes / total,
        "success_rate_delta": quality_delta,
        "discordant_regressions": regressions,
        "discordant_improvements": improvements,
        "mcnemar_exact_p": exact_mcnemar(regressions, improvements),
        "mean_paired_delta": {
            key: stats["mean"] for key, stats in paired_delta.items()
        },
        "paired_delta": paired_delta,
        "latency_attribution_pairs": latency_attribution_pairs,
        "task_trial_contributions": task_trial_contributions,
        "task_contributions": task_contributions,
        "risk_frontier": risk_frontier,
        "causal_warning": None
        if factor != "joint"
        else "model and harness both changed; the delta cannot be attributed to either factor",
    }


def render_comparison_markdown(result: Dict[str, Any]) -> str:
    lines = [
        "# metacodes 配对评估比较",
        "",
        f"- 实验因子: `{result['factor']}`",
        f"- 有效配对: {result['paired_rollouts']}；排除: {len(result['excluded_pairs'])}",
        f"- Trustworthy success: {_fmt_rate(result['baseline_success_rate'])} → {_fmt_rate(result['candidate_success_rate'])}（Δ {result['success_rate_delta']:+.1%}）",
        f"- 不一致配对: 回归 {result['discordant_regressions']}，改善 {result['discordant_improvements']}；McNemar exact p={result['mcnemar_exact_p']:.4f}",
        f"- 质量–成本–延迟前沿: `{result['risk_frontier']}`",
        "",
        "| 成本指标 | Candidate - Baseline（配对均值） |",
        "|---|---:|",
    ]
    for key, value in result["mean_paired_delta"].items():
        ci = result["paired_delta"][key]["ci95"]
        ci_text = "n/a" if ci[0] is None else f"[{ci[0]:.3f}, {ci[1]:.3f}]"
        lines.append(f"| {key} | {_fmt_num(value, 3)} · 95% CI {ci_text} |")
    if result["causal_warning"]:
        lines.extend(["", f"> 警告：{result['causal_warning']}"])
    lines.extend(
        [
            "",
            f"## 延迟归因覆盖（{result['latency_attribution_pairs']}/{result['paired_rollouts']} 配对）",
            "",
            "| Task | Pairs | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms |",
            "|---|---:|---:|---:|---:|---:|",
        ]
    )
    for row in result["task_contributions"]:
        lines.append(
            f"| {row['task_id']} | {row['pairs']} | {_fmt_num(row['wall_time_ms'])} | "
            f"{_fmt_num(row['model_request_time_ms'])} | {_fmt_num(row['tool_stage_time_ms'])} | "
            f"{_fmt_num(row['harness_time_ms'])} |"
        )
    lines.extend(
        [
            "",
            "## Task / trial 长尾贡献（按 |Δ wall| 降序）",
            "",
            "| Task | Trial | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms | Δ tokens | Δ cost |",
            "|---|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for row in result["task_trial_contributions"]:
        lines.append(
            f"| {row['task_id']} | {row['trial']} | {_fmt_num(row['wall_time_ms'])} | "
            f"{_fmt_num(row['model_request_time_ms'])} | {_fmt_num(row['tool_stage_time_ms'])} | "
            f"{_fmt_num(row['harness_time_ms'])} | {_fmt_num(row['total_tokens'], 0)} | "
            f"{_fmt_num(row['cost_usd'], 4)} |"
        )
    lines.append("")
    return "\n".join(lines)


def compare_multi_arm(
    rollouts_by_arm: Mapping[str, Sequence[Dict[str, Any]]]
) -> Dict[str, Any]:
    """One report for all three arms, backed by the same paired comparator."""
    if set(rollouts_by_arm) != set(LONG_HORIZON_ARM_IDS):
        raise ValidationError(
            f"multi-arm report requires exactly {LONG_HORIZON_ARM_IDS}"
        )
    pair_ids = (
        ("codex_style", "claude_style"),
        ("codex_style", "tinykg"),
        ("claude_style", "tinykg"),
    )
    return {
        "arms": {
            arm_id: summarize(rollouts_by_arm[arm_id])
            for arm_id in LONG_HORIZON_ARM_IDS
        },
        "pairwise": [
            {
                "baseline": baseline,
                "candidate": candidate,
                "comparison": compare(
                    rollouts_by_arm[baseline], rollouts_by_arm[candidate], "harness"
                ),
            }
            for baseline, candidate in pair_ids
        ],
    }


def render_multi_arm_markdown(result: Dict[str, Any]) -> str:
    lines = ["# metacodes 三臂长程评估", ""]
    identity_keys = (
        "harness_revision",
        "metacodes_sha256",
        "tinykg_sha256",
        "formal_kernel_fingerprint",
    )
    if all(result.get(key) for key in identity_keys):
        lines.extend(
            [
                "## 冻结执行身份",
                "",
                f"- metacodes revision: `{result['harness_revision']}`",
                f"- metacodes SHA-256: `{result['metacodes_sha256']}`",
                f"- TinyKG SHA-256: `{result['tinykg_sha256']}`",
                f"- Lean artifact fingerprint: `{result['formal_kernel_fingerprint']}`",
                "",
            ]
        )
    lines.extend([
        "## Arm 总览",
        "",
        "| Arm | Rollout | Invalid | Trustworthy success | Token 总计 | 成本 USD | 壁钟 ms |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ])
    for arm_id in LONG_HORIZON_ARM_IDS:
        summary = result["arms"][arm_id]
        lines.append(
            f"| {arm_id} | {summary['rollouts']} | {summary['invalid_rollouts']} | "
            f"{_fmt_rate(summary['trustworthy_success_rate'])} | "
            f"{_fmt_num(summary['metrics']['total_tokens']['total'], 0)} | "
            f"{_fmt_num(summary['metrics']['cost_usd']['total'], 4)} | "
            f"{_fmt_num(summary['metrics']['wall_time_ms']['total'], 0)} |"
        )
    lines.extend(
        [
            "",
            "## 配对比较",
            "",
            "| Baseline → Candidate | 有效配对 | Δ trustworthy | McNemar p | Δ cost | Δ wall ms | 前沿 |",
            "|---|---:|---:|---:|---:|---:|---|",
        ]
    )
    for row in result["pairwise"]:
        comparison = row["comparison"]
        lines.append(
            f"| {row['baseline']} → {row['candidate']} | "
            f"{comparison['paired_rollouts']} | {comparison['success_rate_delta']:+.1%} | "
            f"{comparison['mcnemar_exact_p']:.4f} | "
            f"{_fmt_num(comparison['mean_paired_delta']['cost_usd'], 4)} | "
            f"{_fmt_num(comparison['mean_paired_delta']['wall_time_ms'])} | "
            f"{comparison['risk_frontier']} |"
        )
    lines.extend(
        [
            "",
            "> `report-multi` 对任何 invalid rollout fail closed；正式结论还必须同时检查完整实验契约与原始 artifacts。",
            "",
        ]
    )
    return "\n".join(lines)


def gate(
    candidate: Sequence[Dict[str, Any]],
    baseline: Optional[Sequence[Dict[str, Any]]] = None,
    max_invalid_rate: float = 0.0,
    min_outcome_success: float = 0.0,
    min_trustworthy_success: float = 0.0,
    max_policy_violations: Optional[int] = 0,
    max_success_regression: float = 0.0,
    max_cost_increase_usd: float = 0.0,
    max_latency_increase_ms: float = 0.0,
    max_model_tool_error_increase: float = 0.0,
    min_latency_attribution_coverage: float = 1.0,
    factor: str = "harness",
) -> Dict[str, Any]:
    candidate_summary = summarize(candidate)
    checks = []

    def add(name: str, passed: bool, actual: Any, limit: Any) -> None:
        checks.append({"name": name, "passed": passed, "actual": actual, "limit": limit})

    invalid_rate = candidate_summary["invalid_rate"] or 0.0
    add("invalid_rate", invalid_rate <= max_invalid_rate, invalid_rate, f"<= {max_invalid_rate}")
    outcome_rate = candidate_summary["outcome_success_rate"]
    add(
        "outcome_success_rate",
        outcome_rate is not None and outcome_rate >= min_outcome_success,
        outcome_rate,
        f">= {min_outcome_success}",
    )
    trustworthy_rate = candidate_summary["trustworthy_success_rate"]
    add(
        "trustworthy_success_rate",
        trustworthy_rate is not None and trustworthy_rate >= min_trustworthy_success,
        trustworthy_rate,
        f">= {min_trustworthy_success}",
    )
    if max_policy_violations is not None:
        has_full_policy_telemetry = (
            candidate_summary["policy_telemetry_coverage"]
            == candidate_summary["valid_rollouts"]
        )
        add(
            "policy_violations",
            has_full_policy_telemetry
            and candidate_summary["policy_violations"] <= max_policy_violations,
            candidate_summary["policy_violations"]
            if has_full_policy_telemetry
            else "telemetry_missing",
            f"<= {max_policy_violations}",
        )
    comparison = None
    if baseline is not None:
        comparison = compare(baseline, candidate, factor)
        regression = -comparison["success_rate_delta"]
        add(
            "trustworthy_success_regression",
            regression <= max_success_regression,
            regression,
            f"<= {max_success_regression}",
        )
        mean_deltas = comparison["mean_paired_delta"]
        add(
            "paired_cost_increase_usd",
            mean_deltas["cost_usd"] <= max_cost_increase_usd,
            mean_deltas["cost_usd"],
            f"<= {max_cost_increase_usd}",
        )
        add(
            "paired_latency_increase_ms",
            mean_deltas["wall_time_ms"] <= max_latency_increase_ms,
            mean_deltas["wall_time_ms"],
            f"<= {max_latency_increase_ms}",
        )
        add(
            "paired_model_tool_error_increase",
            mean_deltas["model_tool_errors"] <= max_model_tool_error_increase,
            mean_deltas["model_tool_errors"],
            f"<= {max_model_tool_error_increase}",
        )
        attribution_rate = comparison["latency_attribution_pairs"] / comparison["paired_rollouts"]
        add(
            "latency_attribution_coverage",
            attribution_rate >= min_latency_attribution_coverage,
            attribution_rate,
            f">= {min_latency_attribution_coverage}",
        )
    else:
        valid_rollouts = candidate_summary["valid_rollouts"]
        attribution_rate = (
            candidate_summary["latency_attribution_coverage"] / valid_rollouts
            if valid_rollouts
            else 0.0
        )
        add(
            "latency_attribution_coverage",
            attribution_rate >= min_latency_attribution_coverage,
            attribution_rate,
            f">= {min_latency_attribution_coverage}",
        )
    return {
        "passed": all(item["passed"] for item in checks),
        "checks": checks,
        "candidate_summary": candidate_summary,
        "comparison": comparison,
    }
