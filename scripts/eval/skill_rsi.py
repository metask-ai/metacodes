"""Offline procedural-skill evolution and independent ridge routing.

The product only loads policy.json. This host owns train/validation execution,
optimizer calls, selection and the development ledger. Adapter commands speak
one JSON request/response over stdin/stdout and must run fresh, isolated tasks
through the normal harness and its native scorer. No provider is selected here.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import re
import subprocess
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .memory_budget_journal import BudgetAuthority, BudgetJournal, BudgetTransaction, usd_to_microusd

FEATURE_SCHEMA = "metacodes-skill-text-v1"
CALL_SCHEMA = "metacodes-skill-rsi-call-v1"
MAX_INSTRUCTION_BYTES = 4096
MAX_POLICY_BYTES = 65536
PREFIX = "<procedural-skill>\n"
SUFFIX = "\n</procedural-skill>"
OBJECTIVE = (
    "Propose ONE short reusable procedural instruction from TRAIN evidence. "
    "Use previous candidates' successful and failed executions to improve it. "
    "Preserve native task requirements, tools, permissions, sandbox, budgets, "
    "observations, necessary verification and scoring. Reduce repeated work, "
    "not completion criteria. Return a complete replacement instruction, at most "
    "180 words and 4096 UTF-8 bytes. Do not include task-specific answers, task-ID "
    "conditionals or executable code. Cite at least two distinct supplied TRAIN "
    "task IDs in supporting_task_ids. Return an empty instruction to abstain. "
    "Validation and test data are unavailable."
)
Call = Callable[[dict[str, Any]], Mapping[str, Any]]


class RSIError(ValueError):
    pass


def stable(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def strict_json(raw: str | bytes) -> Any:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RSIError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid(value):
        raise RSIError(f"non-finite JSON number: {value}")

    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)


def features(prompt: str) -> list[float]:
    words = [word.lower() for word in re.findall(r"[A-Za-z0-9_]+", prompt)]
    word_set = set(words)
    return [
        len(prompt.encode("utf-8")) / 4096.0,
        len(words) / 512.0,
        float(any(c in prompt for c in "\"'“”")),
        float(bool(word_set & {"before", "after", "between", "within", "left", "right", "above", "below"})),
        float(bool(word_set & {"count", "calculate", "number", "total", "sum", "many", "much"})
              or any(cue in prompt for cue in ("多少", "几个", "总数"))),
    ]


def instruction(value: Any, *, proposal: bool = False) -> str:
    if not isinstance(value, str) or "\0" in value or PREFIX in value or SUFFIX in value:
        raise RSIError("invalid instruction text")
    if len(value.encode("utf-8")) > MAX_INSTRUCTION_BYTES or (proposal and len(value.split()) > 180):
        raise RSIError("instruction exceeds its frozen size limit")
    return value


def candidate(text: str, router=None) -> dict:
    instruction(text)
    return {"instruction": text, "sha256": digest(text.encode("utf-8")), "router": router}


def route(item: dict, prompt: str, enabled: bool) -> str:
    if not enabled:
        return item["instruction"]
    head = item["router"]
    if head is None:
        return ""
    x = features(prompt)
    if any(value < lo or value > hi for value, lo, hi in zip(x, head["minimum"], head["maximum"])):
        return ""
    score = head["intercept"] + sum(w * value for w, value in zip(head["weights"], x))
    active = score >= head["threshold"] or math.isclose(score, head["threshold"], rel_tol=0, abs_tol=1e-12)
    return item["instruction"] if active else ""


def _solve(matrix: list[list[float]], target: list[float]) -> list[float]:
    rows = [row[:] + [value] for row, value in zip(matrix, target)]
    size = len(rows)
    for col in range(size):
        pivot = max(range(col, size), key=lambda index: abs(rows[index][col]))
        if abs(rows[pivot][col]) < 1e-14:
            raise RSIError("singular ridge fit")
        rows[col], rows[pivot] = rows[pivot], rows[col]
        scale = rows[col][col]
        rows[col] = [value / scale for value in rows[col]]
        for index in range(size):
            if index != col:
                scale = rows[index][col]
                rows[index] = [a - scale * b for a, b in zip(rows[index], rows[col])]
    return [row[-1] for row in rows]


def _ridge(rows: Sequence[dict], ridge: float) -> list[float]:
    matrix = [[0.0] * 6 for _ in range(6)]
    target = [0.0] * 6
    for row in rows:
        x = [1.0, *row["features"]]
        for i in range(6):
            target[i] += x[i] * row["utility"]
            for j in range(6):
                matrix[i][j] += x[i] * x[j]
    for i in range(1, 6):
        matrix[i][i] += ridge
    result = _solve(matrix, target)
    if not all(math.isfinite(value) for value in result):
        raise RSIError("non-finite ridge fit")
    return result


def _utility(before: dict, after: dict) -> float:
    saving = (before["tokens"] - after["tokens"]) / max(1, before["tokens"])
    return ((after["score"] - before["score"]) + max(-1.0, min(1.0, saving))) / 2.0


def fit_router(tasks: Sequence[dict], baseline: dict, observed: dict, text: str,
               *, folds: int = 2, ridge: float = 1.0, minimum_support: int = 2) -> tuple[dict | None, dict]:
    """Fit each candidate independently; threshold selection uses grouped OOF predictions."""
    if type(folds) is not int or folds < 2 or not math.isfinite(ridge) or ridge <= 0:
        raise RSIError("routing needs >=2 folds and positive finite ridge")
    if type(minimum_support) is not int or minimum_support < 2:
        raise RSIError("routing needs >=2 independent supported units")
    grouped = defaultdict(list)
    for task in tasks:
        grouped[task["unit_id"]].append(task)
    if len(grouped) < max(folds, minimum_support):
        return None, {"status": "insufficient_independent_units"}
    rows = []
    for unit, members in sorted(grouped.items()):
        xs = [features(task["prompt"]) for task in members]
        rows.append({
            "unit": unit,
            "features": [sum(values) / len(xs) for values in zip(*xs)],
            "utility": sum(_utility(baseline[t["id"]], observed[t["id"]]) for t in members) / len(members),
            "harmful": any(observed[t["id"]]["score"] < baseline[t["id"]]["score"] for t in members),
        })
    ordered = sorted(rows, key=lambda row: digest(row["unit"].encode("utf-8")))
    assignments = {row["unit"]: i % folds for i, row in enumerate(ordered)}
    oof = []
    for fold in range(folds):
        weights = _ridge([row for row in rows if assignments[row["unit"]] != fold], ridge)
        for row in rows:
            if assignments[row["unit"]] == fold:
                oof.append({**row, "prediction": weights[0] + sum(w * x for w, x in zip(weights[1:], row["features"]))})
    thresholds = []
    for threshold in sorted({row["prediction"] for row in oof}):
        selected = [row for row in oof if row["prediction"] >= threshold]
        if len(selected) >= minimum_support and not any(row["harmful"] for row in selected):
            gain = sum(row["utility"] for row in selected) / len(selected)
            if gain > 0:
                thresholds.append((gain, threshold, len(selected)))
    if not thresholds:
        return None, {"status": "no_supported_positive_oof_advantage", "units": len(rows)}
    gain, threshold, support = max(thresholds)
    weights = _ridge(rows, ridge)
    xs = [features(task["prompt"]) for task in tasks]
    head = {
        "instruction_sha256": digest(text.encode("utf-8")),
        "intercept": weights[0], "weights": weights[1:], "threshold": threshold,
        "minimum": [min(column) for column in zip(*xs)],
        "maximum": [max(column) for column in zip(*xs)],
    }
    return head, {"status": "admitted", "oof_mean_utility": gain, "oof_support": support,
                  "folds": folds, "ridge": ridge, "units": len(rows)}


@dataclass(frozen=True)
class Settings:
    evolution: bool = False
    routing: bool = False
    rounds: int = 2
    folds: int = 2
    ridge: float = 1.0
    minimum_support: int = 2

    def validate(self):
        if type(self.rounds) is not int or not 1 <= self.rounds <= 32:
            raise RSIError("rounds must be in 1..32")
        if type(self.folds) is not int or self.folds < 2 or not math.isfinite(self.ridge) or self.ridge <= 0:
            raise RSIError("invalid ridge/fold settings")
        if type(self.minimum_support) is not int or self.minimum_support < 2:
            raise RSIError("minimum_support must be >=2")


def _tasks(manifest: dict) -> tuple[list[dict], list[dict]]:
    train, validation = [], []
    ids, units = set(), set()
    for phase, destination in (("train", train), ("validation", validation)):
        rows = manifest.get(phase)
        if not isinstance(rows, list) or not rows:
            raise RSIError(f"{phase} must be a nonempty task list")
        phase_units = set()
        for task in rows:
            if not isinstance(task, dict) or set(task) != {"id", "unit_id", "prompt"}:
                raise RSIError("tasks need exactly id, unit_id, prompt")
            if not all(isinstance(value, str) and value.strip() for value in task.values()):
                raise RSIError("task fields must be nonempty text")
            if task["id"] in ids or (phase == "validation" and task["unit_id"] in units):
                raise RSIError("task IDs and independent units must be split-disjoint")
            ids.add(task["id"])
            phase_units.add(task["unit_id"])
            destination.append(dict(task))
        units.update(phase_units)
    if "test" in manifest:
        raise RSIError("the trainer must not receive TEST data")
    return train, validation


def run_rsi(manifest: dict, call: Call, settings: Settings = Settings()) -> tuple[dict, dict]:
    settings.validate()
    model = manifest.get("model")
    if not isinstance(model, str) or not model.strip():
        raise RSIError("manifest needs an exact actor model identity")
    seed = candidate(instruction(manifest.get("seed_instruction", "")))
    policy = {"schema_version": 1, "feature_schema": FEATURE_SCHEMA, "model": model, "seed": seed, "evolved": None}
    report = {"schema": "metacodes-skill-rsi-report-v1", "settings": vars(settings),
              "calls": [], "candidates": [], "selected_sha256": None}
    if not (settings.evolution or settings.routing):
        report["status"] = "disabled"
        return policy, report
    train, validation = _tasks(manifest)

    def invoke(payload: dict) -> dict:
        request = {"schema": CALL_SCHEMA, "model": model, "call_index": len(report["calls"]), **payload}
        response = dict(call(copy.deepcopy(request)))
        # Account every completed call before interpreting its semantic result.
        incoming, outgoing, cost = (response.get(key) for key in ("input_tokens", "output_tokens", "cost_microusd"))
        if any(type(value) is not int or value < 0 for value in (incoming, outgoing, cost)):
            raise RSIError("adapter must report measured input/output tokens and cost_microusd")
        if response.get("model") != model:
            raise RSIError("adapter model identity differs from the frozen actor")
        report["calls"].append({"request": request, "response": response})
        return response

    def evaluate(tasks: list[dict], item: dict, phase: str, *, routed: bool) -> dict:
        results = {}
        for task in tasks:
            effective = route(item, task["prompt"], routed)
            response = invoke({"kind": "evaluate", "phase": phase, "task": task,
                               "instruction": effective, "instruction_sha256": digest(effective.encode("utf-8"))})
            score = response.get("score")
            if type(score) not in (int, float) or not math.isfinite(score) or not 0 <= score <= 1:
                raise RSIError("native scorer must supply an actual finite score in [0,1]")
            results[task["id"]] = {"score": float(score),
                "tokens": response["input_tokens"] + response["output_tokens"],
                "feedback": response.get("feedback", ""), "instruction_applied": bool(effective)}
        return results

    baseline_item = candidate("")
    baseline = evaluate(train, baseline_item, "train", routed=False)
    evidence, bank = [], []

    def measure(item: dict):
        observed = evaluate(train, item, "train", routed=False)
        head, fit = (fit_router(train, baseline, observed, item["instruction"], folds=settings.folds,
                               ridge=settings.ridge, minimum_support=settings.minimum_support)
                     if settings.routing else (None, {"status": "routing_disabled"}))
        item["router"] = head
        bank.append(item)
        evidence.append({"instruction": item["instruction"], "sha256": item["sha256"], "results": observed})
        report["candidates"].append({"instruction": item["instruction"], "sha256": item["sha256"],
                                     "router": copy.deepcopy(head), "fit": fit})

    if seed["instruction"]:
        measure(seed)
    if settings.evolution:
        for iteration in range(settings.rounds):
            response = invoke({"kind": "propose", "phase": "train", "iteration": iteration,
                               "objective": OBJECTIVE, "tasks": train, "baseline": baseline,
                               "previous_candidates": copy.deepcopy(evidence)})
            proposed = instruction(response.get("instruction"), proposal=True)
            if not proposed:
                continue
            support = response.get("supporting_task_ids")
            if not isinstance(support, list) or not all(isinstance(value, str) for value in support):
                raise RSIError("proposal needs supporting TRAIN task IDs")
            if len(set(support)) < 2 or len(support) != len(set(support)) or not set(support) <= set(baseline):
                raise RSIError("proposal must cite at least two distinct supplied TRAIN tasks")
            item = candidate(proposed)
            if not any(existing["sha256"] == item["sha256"] for existing in bank):
                measure(item)

    # No optimizer calls or refits occur below this point. All validation arms
    # use frozen training-derived instructions and routing parameters.
    reference = evaluate(validation, baseline_item, "validation", routed=False)
    reference_score = sum(row["score"] for row in reference.values())
    reference_tokens = sum(row["tokens"] for row in reference.values())
    best, best_key = baseline_item, (reference_score, -reference_tokens)
    for item in bank:
        if settings.routing and item["router"] is None:
            continue
        rows = evaluate(validation, item, "validation", routed=settings.routing)
        score, tokens = sum(row["score"] for row in rows.values()), sum(row["tokens"] for row in rows.values())
        applied = any(row["instruction_applied"] for row in rows.values())
        accepted = applied and score >= reference_score and (score, -tokens) > best_key
        for record in report["candidates"]:
            if record["sha256"] == item["sha256"]:
                record["validation"] = {"score_sum": score, "tokens": tokens, "instruction_applied": applied}
        if accepted:
            best, best_key = item, (score, -tokens)
    if settings.evolution:
        policy["evolved"] = copy.deepcopy(best)  # an empty winner explicitly retains the baseline
    elif best is baseline_item:
        policy["seed"]["router"] = None
    report.update(status="frozen", selected_sha256=best["sha256"],
                  baseline_validation={"score_sum": reference_score, "tokens": reference_tokens},
                  deployment_policy_sha256=digest(stable(policy)))
    if len(stable(policy)) > MAX_POLICY_BYTES:
        raise RSIError("deployment policy exceeds product size limit")
    return policy, report


class CommandAdapter:
    """Every network-capable child is authorized durably before it starts.

    Crashes, timeouts and malformed responses leave the reservation unsettled;
    rerunning an already-authorized call under the same journal is forbidden.
    """
    def __init__(self, manifest: dict, journal: BudgetJournal, manifest_sha: str,
                 max_cost: int, max_tokens: int, timeout: float):
        self.manifest, self.journal, self.manifest_sha = manifest, journal, manifest_sha
        self.max_cost, self.max_tokens, self.timeout = max_cost, max_tokens, timeout

    def __call__(self, request: dict) -> dict:
        command = self.manifest.get("proposer_command" if request["kind"] == "propose" else "evaluator_command")
        if not isinstance(command, list) or not command or not all(isinstance(value, str) and value for value in command):
            raise RSIError("adapter command must be an explicit nonempty argv list")
        transaction = BudgetTransaction(
            run_id=f"skill-rsi:{request['call_index']}", manifest_sha256=self.manifest_sha,
            model_fingerprint=digest(request["model"].encode("utf-8")),
            harness_fingerprint=digest(stable(request)), provider_identity="skill-rsi-explicit-adapter-v1",
            max_cost_microusd=self.max_cost, max_metered_tokens=self.max_tokens)
        reserved = self.journal.reserve(transaction)
        self.journal.authorize_request(reserved["transaction_id"], expected_revision=reserved["journal_revision"],
                                       expected_head_sha256=reserved["journal_head_sha256"])
        wire_request = {**request, "budget_authorization": {
            "transaction_id": reserved["transaction_id"],
            "max_cost_microusd": self.max_cost, "max_metered_tokens": self.max_tokens,
        }}
        completed = subprocess.run(command, input=stable(wire_request), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=self.timeout, check=True)
        if len(completed.stdout) > MAX_POLICY_BYTES:
            raise RSIError("adapter response too large")
        response = strict_json(completed.stdout)
        if not isinstance(response, dict):
            raise RSIError("adapter response must be an object")
        usage = [response.get(key) for key in ("input_tokens", "output_tokens", "cost_microusd")]
        if any(type(value) is not int or value < 0 for value in usage):
            raise RSIError("adapter usage is incomplete; reservation remains unsettled")
        self.journal.commit(reserved["transaction_id"], actual_cost_microusd=usage[2],
                            actual_metered_tokens=usage[0] + usage[1],
                            evidence_sha256=digest(stable({"request": request, "response": response})))
        return response


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True, help="new private run directory")
    parser.add_argument("--evolution", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--routing", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--folds", type=int, default=2)
    parser.add_argument("--ridge", type=float, default=1.0)
    parser.add_argument("--max-cost-usd", help="explicit total provider authorization")
    parser.add_argument("--max-tokens", type=int)
    parser.add_argument("--call-max-cost-usd")
    parser.add_argument("--call-max-tokens", type=int)
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args(argv)
    try:
        manifest = strict_json(args.manifest.read_bytes())
        settings = Settings(args.evolution, args.routing, args.rounds, args.folds, args.ridge)
        settings.validate()
        if not isinstance(manifest, dict):
            raise RSIError("manifest must be an object")
        enabled = settings.evolution or settings.routing
        if enabled:
            _tasks(manifest)
            if not isinstance(manifest.get("model"), str) or not manifest["model"].strip():
                raise RSIError("manifest needs an exact actor model identity")
            instruction(manifest.get("seed_instruction", ""))
            for key in (["evaluator_command", "proposer_command"] if settings.evolution else ["evaluator_command"]):
                command = manifest.get(key)
                if not isinstance(command, list) or not command or not all(isinstance(v, str) and v for v in command):
                    raise RSIError(f"{key} must be an explicit nonempty argv list")
            if not all(value is not None for value in (
                args.max_cost_usd, args.max_tokens, args.call_max_cost_usd, args.call_max_tokens)):
                raise RSIError("enabled training requires explicit total/per-call dollar and token caps")
            total_cost, call_cost = usd_to_microusd(args.max_cost_usd), usd_to_microusd(args.call_max_cost_usd)
            if call_cost <= 0 or call_cost > total_cost or not 0 < args.call_max_tokens <= args.max_tokens:
                raise RSIError("invalid per-call budget bounds")
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise RSIError("timeout must be positive and finite")
        args.output_dir.mkdir(mode=0o700, parents=False, exist_ok=False)
        if enabled:
            manifest_sha = digest(stable({"manifest": manifest, "settings": vars(settings)}))
            authority = BudgetAuthority(manifest_sha, digest(manifest["model"].encode("utf-8")),
                                        "skill-rsi-explicit-adapter-v1", total_cost, args.max_tokens)
            with BudgetJournal(args.output_dir / "budget.json", authority) as journal:
                adapter = CommandAdapter(manifest, journal, manifest_sha, call_cost, args.call_max_tokens, args.timeout)
                policy, report = run_rsi(manifest, adapter, settings)
                report["budget_checkpoint"] = strict_json(journal.checkpoint_payload())
        else:
            policy, report = run_rsi(manifest, lambda _: (_ for _ in ()).throw(RSIError("disabled callback")), settings)
        for name, value in (("report.json", report), ("policy.json", policy)):
            pending = args.output_dir / (name + ".tmp")
            with pending.open("xb") as stream:
                stream.write(stable(value) + b"\n")
                stream.flush()
                os.fsync(stream.fileno())
            # Publish a complete file without replacing an existing artifact.
            os.link(pending, args.output_dir / name)
            pending.unlink()
        if os.name != "nt":
            fd = os.open(args.output_dir, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        parser.exit(2, f"skill RSI: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
