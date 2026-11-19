"""Read-only projections of Harbor job directories for the bench viewer.

A Harbor jobs directory holds one directory per job (`config.json`,
`result.json`) and, inside it, one directory per trial (`result.json`,
`agent/`, `verifier/`).  Everything here only reads those files; nothing
is written and no process is started.  Python 3.9, stdlib only.

Outcome doctrine (doc/BENCHMARKS.md): a trial that failed for an
infrastructure reason is `invalid`, not `fail`, and stays out of the pass
rate.  The statuses:

- `pass`, `partial`, `fail`: the verifier scored the trial (reward 1, between
  0 and 1, 0);
- `timeout`: the agent ran out of time; scored as a failure, it is the
  agent's outcome;
- `invalid`: the verifier timed out, the provider or the environment failed,
  or no reward exists; `cause` says which;
- `running`: no final result yet.
"""

from __future__ import annotations

import csv
import datetime as dt
import io
import json
import math
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from scripts.eval.harbor.profiling import CONTEXT_PARTS, usage_values

VALID = ("pass", "partial", "fail", "timeout")
STATUSES = VALID + ("invalid", "running")

# Harbor exception types (harbor/agents/installed/base.py) that mean the model
# provider, not the agent, failed the trial.
PROVIDER_EXCEPTIONS = frozenset(
    {
        "ApiError",
        "ApiRateLimitError",
        "ApiUsageLimitError",
        "ApiInternalServerError",
        "ApiOverloadedError",
        "ApiConnectionClosedError",
        "ApiResponseStalledError",
        "UnknownApiError",
        "ApiProviderResourceNotFoundError",
        "AgentAuthenticationError",
        "ModelNotFoundError",
        "UnsupportedModelParametersError",
        "NetworkConnectionError",
    }
)
AGENT_TIMEOUT_EXCEPTIONS = frozenset({"AgentTimeoutError"})

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]*$")
MAX_JSON_BYTES = 64 * 1024 * 1024
TEXT_LIMIT = 4000
TAIL_BYTES = 8000


# ---------------------------------------------------------------- reading


def read_json(path: Path) -> Optional[Any]:
    """The JSON document at `path`, or None when absent, oversized or partial."""

    try:
        if path.stat().st_size > MAX_JSON_BYTES:
            return None
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None


def tail(path: Path, limit: int = TAIL_BYTES) -> str:
    """The last `limit` bytes of a text file, decoded leniently."""

    try:
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - limit))
            data = handle.read()
    except OSError:
        return ""
    text = data.decode("utf-8", errors="replace")
    return ("…" + text) if size > limit else text


def clip(value: Any, limit: int = TEXT_LIMIT) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + f"… [{len(text) - limit} more chars]"


def parse_time(value: Any) -> Optional[dt.datetime]:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


def seconds(span: Any) -> Optional[float]:
    """Duration of a Harbor `{started_at, finished_at}` span."""

    if not isinstance(span, dict):
        return None
    start, end = parse_time(span.get("started_at")), parse_time(span.get("finished_at"))
    if start is None or end is None:
        return None
    return max(0.0, (end - start).total_seconds())


def number(value: Any) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        value = float(value)
    except OverflowError:
        return None
    return value if math.isfinite(value) else None


def json_lines(path):
    try:
        if path.stat().st_size > MAX_JSON_BYTES:
            return
        with path.open(encoding="utf-8", errors="replace") as source:
            for line in source:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    yield row
    except OSError:
        return


def composition_tokens(composition, input_tokens):
    """A request's input tokens apportioned over its context parts by their
    byte shares (the relay records sizes only), or None without both."""
    if not isinstance(composition, dict) or input_tokens is None:
        return None
    sizes = {part: number(composition.get(part)) or 0 for part in CONTEXT_PARTS}
    total = sum(sizes.values())
    if total <= 0:
        return None
    return {part: input_tokens * size / total for part, size in sizes.items()}


def tool_events(trial_dir):
    """Per tool call id: name, error flag and execution time, from the
    metacodes event stream (tool_start / tool_result)."""
    calls = {}
    for event in json_lines(trial_dir / "agent" / "metacodes-output.jsonl"):
        kind = event.get("type")
        if kind not in ("tool_start", "tool_result") or not isinstance(event.get("id"), str):
            continue
        call = calls.setdefault(event["id"], {"name": str(event.get("name") or "?"), "elapsed_ms": None, "is_error": False})
        if kind == "tool_result":
            call["elapsed_ms"] = number(event.get("elapsed_ms"))
            call["is_error"] = bool(event.get("is_error"))
    return calls


def execution_metrics(trial_dir):
    events = json_lines(trial_dir / "agent" / "metacodes-output.jsonl")
    first, totals, result, first_seen = None, {}, {}, False
    for event in events:
        if event.get("type") == "usage":
            usage = usage_values(event)
            if not first_seen:
                first = usage.get("input_tokens")
                first_seen = True
            for key, value in usage.items():
                totals[key] = totals.get(key, 0) + value
        elif event.get("type") == "result":
            result = event
    requests = request_rows(trial_dir)
    composition = None
    if requests:
        first = number(requests[0].get("input_tokens"))
        composition = composition_tokens(requests[0].get("composition"), first)
        if not totals:
            for request in requests:
                for key in ("input_tokens", "output_tokens", "cache_tokens", "cache_creation_tokens"):
                    value = number(request.get(key))
                    if value is not None:
                        totals[key] = totals.get(key, 0) + value
    ttfts = [number(r.get("ttft_ms")) for r in requests if r.get("complete") is True]
    ttfts = [t for t in ttfts if t is not None and t >= 0]
    speed = [r for r in requests if r.get("complete") is True and number(r.get("generation_ms"))
             and number(r.get("generation_ms")) > 0 and number(r.get("output_tokens")) is not None]
    return {"result": result, "usage": totals, "initial_input_tokens": first, "initial_composition": composition,
            "requests": len(requests), "ttft_samples_ms": ttfts,
            "tps_output_tokens": sum(r["output_tokens"] for r in speed),
            "tps_generation_ms": sum(r["generation_ms"] for r in speed),
            "profiled_requests": len(speed)}


def request_rows(trial_dir):
    rows = list(json_lines(trial_dir.parent / ".bench-metrics" / (trial_dir.name + ".jsonl")))
    rows.sort(key=lambda r: (number(r.get("request")) or 0, str(r.get("started_at", ""))))
    return rows


def percentile(values, quantile):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * quantile
    lower = int(position)
    upper = min(lower + 1, len(values) - 1)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def performance_fields(ttfts, output, generation_ms):
    return {"ttft_ms": sum(ttfts) / len(ttfts) if ttfts else None,
            "ttft_p50_ms": percentile(ttfts, .5), "ttft_p95_ms": percentile(ttfts, .95),
            "tps": output * 1000 / generation_ms if generation_ms > 0 else None}


def trial_order(row):
    return parse_time(row.get("started_at")) or dt.datetime.max.replace(tzinfo=dt.timezone.utc), row["trial"]


def metacodes_result(agent_dir: Path) -> Dict[str, Any]:
    """The `result` event metacodes printed last, or {} (another agent, or killed)."""

    output = agent_dir / "metacodes-output.jsonl"
    found: Dict[str, Any] = {}
    try:
        if output.stat().st_size > MAX_JSON_BYTES:
            return {}
        for line in output.read_text(encoding="utf-8", errors="replace").splitlines():
            if '"result"' not in line:  # cheap prefilter; the parse below decides
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict) and event.get("type") == "result":
                found = event
    except OSError:
        return {}
    return found


def test_summary(verifier_dir: Path) -> Optional[Dict[str, Any]]:
    """Per-test results from the verifier's CTRF report, when it wrote one."""

    report = read_json(verifier_dir / "ctrf.json")
    if not isinstance(report, dict):
        return None
    results = report.get("results") or {}
    tests = results.get("tests") if isinstance(results, dict) else None
    if not isinstance(tests, list):
        return None
    rows = []
    for test in tests:
        if not isinstance(test, dict):
            continue
        rows.append(
            {
                "name": str(test.get("name") or ""),
                "status": str(test.get("status") or ""),
                "message": clip(test.get("message") or "", 600),
            }
        )
    return {
        "total": len(rows),
        "passed": sum(1 for row in rows if row["status"] == "passed"),
        "failed": sum(1 for row in rows if row["status"] == "failed"),
        "tests": rows,
    }


# ---------------------------------------------------------- classification


def classify(result: Optional[Dict[str, Any]], stop_reason: Optional[str]) -> Tuple[str, Optional[str]]:
    """(status, cause) of one trial from its Harbor result and metacodes' stop reason."""

    if not isinstance(result, dict) or not result.get("finished_at"):
        return "running", None
    exception = result.get("exception_info") or {}
    exc = exception.get("exception_type") if isinstance(exception, dict) else None
    rewards = (result.get("verifier_result") or {}).get("rewards") or {}
    reward = number(rewards.get("reward")) if isinstance(rewards, dict) else None

    if exc and exc not in AGENT_TIMEOUT_EXCEPTIONS:
        if exc.startswith("Verifier"):
            return "invalid", f"verifier: {exc}"
        if exc in PROVIDER_EXCEPTIONS or stop_reason == "api_error":
            return "invalid", f"provider: {exc}"
        if "Environment" in exc or "Docker" in exc or "Build" in exc:
            return "invalid", f"environment: {exc}"
        return "invalid", exc
    if reward is None:
        if exc in AGENT_TIMEOUT_EXCEPTIONS:
            return "timeout", exc
        return "invalid", "no reward"
    if exc in AGENT_TIMEOUT_EXCEPTIONS and reward <= 0:
        return "timeout", exc
    if reward >= 1:
        return "pass", None
    if reward > 0:
        return "partial", None
    return "fail", None


# ------------------------------------------------------------------ trials


def trial_row(trial_dir: Path) -> Dict[str, Any]:
    """One trial's summary row (no trajectory)."""

    result = read_json(trial_dir / "result.json")
    measured = execution_metrics(trial_dir)
    agent = measured["result"]
    status, cause = classify(result, agent.get("stop_reason"))
    result = result if isinstance(result, dict) else {}
    agent_result = result.get("agent_result") or {}
    rewards = (result.get("verifier_result") or {}).get("rewards") or {}
    task = str(result.get("task_name") or trial_dir.name.split("__")[0])
    started = parse_time(result.get("started_at"))
    if started is None:
        try:
            started = dt.datetime.fromtimestamp((trial_dir / "config.json").stat().st_mtime, dt.timezone.utc)
        except OSError:
            started = None
    finished = parse_time(result.get("finished_at"))
    exception = result.get("exception_info") or {}
    tests = test_summary(trial_dir / "verifier")
    input_tokens = number(agent_result.get("n_input_tokens"))
    cache_tokens = number(agent_result.get("n_cache_tokens"))
    output_tokens = number(agent_result.get("n_output_tokens"))
    partial = not agent and ((trial_dir / "agent" / "metacodes-output.jsonl").exists() or bool(measured["requests"]))
    if partial:
        input_tokens, cache_tokens, output_tokens = (measured["usage"].get(k) for k in ("input_tokens", "cache_tokens", "output_tokens"))
    else:
        fallback = usage_values(agent)
        input_tokens = input_tokens if input_tokens is not None else fallback.get("input_tokens", measured["usage"].get("input_tokens"))
        cache_tokens = cache_tokens if cache_tokens is not None else fallback.get("cache_tokens", measured["usage"].get("cache_tokens"))
        output_tokens = output_tokens if output_tokens is not None else fallback.get("output_tokens", measured["usage"].get("output_tokens"))
    total_tokens = input_tokens + output_tokens if input_tokens is not None and output_tokens is not None else None
    cost = number(agent_result.get("cost_usd"))
    if cost is None:
        cost = number(agent.get("cost_usd"))
    if cost == 0 and (total_tokens is None or total_tokens > 0):
        cost = None  # an unknown price is not a free model
    return {
        "trial": trial_dir.name,
        "task": task.split("/", 1)[1] if "/" in task else task,
        "status": status,
        "cause": cause,
        "reward": number(rewards.get("reward")) if isinstance(rewards, dict) else None,
        "exception": exception.get("exception_type") if isinstance(exception, dict) else None,
        "stop_reason": agent.get("stop_reason"),
        # metacodes ended on a reply with no text and no tool call: it took
        # an empty answer as final, a harness signal worth seeing per task.
        "empty_final": agent.get("stop_reason") == "end_turn" and not (agent.get("text") or "").strip(),
        "turns": agent.get("turns"),
        "tool_calls": agent.get("tool_calls"),
        "input_tokens": input_tokens,
        "initial_input_tokens": measured["initial_input_tokens"],
        "initial_composition": measured["initial_composition"],
        "total_tokens": total_tokens,
        "tokens_partial": partial,
        "cache_tokens": cache_tokens,
        "output_tokens": output_tokens,
        "cache_ratio": (cache_tokens / input_tokens) if input_tokens and cache_tokens is not None else None,
        "cost_usd": cost,
        "cost_source": "metacodes_catalog_estimate" if cost is not None else "unavailable",
        **{k: measured[k] for k in ("requests", "profiled_requests", "ttft_samples_ms", "tps_output_tokens", "tps_generation_ms")},
        **performance_fields(measured["ttft_samples_ms"], measured["tps_output_tokens"], measured["tps_generation_ms"]),
        "started_at": started.isoformat() if started else None,
        "finished_at": finished.isoformat() if finished else None,
        "elapsed_s": (
            ((finished or dt.datetime.now(dt.timezone.utc)) - started).total_seconds() if started else None
        ),
        "phases": {
            "environment": seconds(result.get("environment_setup")),
            "setup": seconds(result.get("agent_setup")),
            "agent": seconds(result.get("agent_execution")),
            "verifier": seconds(result.get("verifier")),
        },
        "tests": {"passed": tests["passed"], "failed": tests["failed"], "total": tests["total"]} if tests else None,
    }


def trial_detail(trial_dir: Path) -> Dict[str, Any]:
    """Everything the trial page shows: the row, the trajectory, tests and logs."""

    row = trial_row(trial_dir)
    result = read_json(trial_dir / "result.json") or {}
    exception = result.get("exception_info") or {}
    trajectory = read_json(trial_dir / "agent" / "trajectory.json") or {}
    calls_by_id = tool_events(trial_dir)
    steps = []
    tools: Dict[str, int] = {}
    for step in trajectory.get("steps") or []:
        if not isinstance(step, dict):
            continue
        calls = []
        for call in step.get("tool_calls") or []:
            if not isinstance(call, dict):
                continue
            name = str(call.get("function_name") or "?")
            tools[name] = tools.get(name, 0) + 1
            calls.append(
                {
                    "id": call.get("tool_call_id"),
                    "name": name,
                    "arguments": clip(call.get("arguments") or {}, 3000),
                    "elapsed_ms": (calls_by_id.get(call.get("tool_call_id")) or {}).get("elapsed_ms"),
                }
            )
        observation = step.get("observation")
        items = (observation.get("results") or []) if isinstance(observation, dict) else []
        results = []
        for item in items:
            if not isinstance(item, dict):
                continue
            extra = item.get("extra") or {}
            results.append(
                {
                    "call": item.get("source_call_id"),
                    "content": clip(item.get("content") or ""),
                    "is_error": bool(extra.get("is_error")) if isinstance(extra, dict) else False,
                }
            )
        steps.append(
            {
                "id": step.get("step_id"),
                "source": step.get("source"),
                "message": clip(step.get("message") or ""),
                "reasoning": clip(step.get("reasoning_content") or "", 2000) or None,
                "tool_calls": calls,
                "observations": results,
            }
        )
    return {
        "row": row,
        "agent": result.get("agent_info"),
        "exception_message": clip(exception.get("exception_message") or "", 2000)
        if isinstance(exception, dict)
        else "",
        "steps": steps,
        "tools": sorted(tools.items(), key=lambda item: (-item[1], item[0])),
        "tests": test_summary(trial_dir / "verifier"),
        "verifier_output": tail(trial_dir / "verifier" / "test-stdout.txt"),
        "stderr": tail(trial_dir / "agent" / "metacodes-stderr.log"),
        "final_metrics": trajectory.get("final_metrics"),
        "requests": request_timeline(trial_dir),
        "tool_timing": tool_timing(calls_by_id),
        "time_split": time_split(row, trial_dir, calls_by_id),
    }


def request_timeline(trial_dir: Path) -> List[Dict[str, Any]]:
    """Each model request in order: when it started (seconds after the
    first), its timing and token usage, and its context split by part."""
    rows = request_rows(trial_dir)
    origin = parse_time(rows[0].get("started_at")) if rows else None
    timeline = []
    for index, request in enumerate(rows, 1):
        started = parse_time(request.get("started_at"))
        input_tokens = number(request.get("input_tokens"))
        composition = request.get("composition")
        timeline.append({
            "seq": index,
            "offset_s": (started - origin).total_seconds() if started and origin else None,
            "http_status": number(request.get("http_status")),
            "complete": request.get("complete") is True,
            **{key: number(request.get(key)) for key in ("duration_ms", "ttft_ms", "generation_ms", "output_tokens",
                                                          "cache_tokens", "cache_creation_tokens")},
            "input_tokens": input_tokens,
            "composition": composition_tokens(composition, input_tokens),
            "tool_count": number(composition.get("tool_count")) if isinstance(composition, dict) else None,
            "messages": number(composition.get("messages")) if isinstance(composition, dict) else None,
        })
    return timeline


def tool_timing(calls: Dict[str, Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Per tool: calls, errors, and total / mean / max execution time."""
    by_name: Dict[str, Dict[str, Any]] = {}
    for call in calls.values():
        entry = by_name.setdefault(call["name"], {"name": call["name"], "calls": 0, "errors": 0, "timed": 0,
                                                  "total_ms": 0.0, "max_ms": None})
        entry["calls"] += 1
        entry["errors"] += int(call["is_error"])
        if call["elapsed_ms"] is not None:
            entry["timed"] += 1
            entry["total_ms"] += call["elapsed_ms"]
            entry["max_ms"] = max(entry["max_ms"] or 0.0, call["elapsed_ms"])
    for entry in by_name.values():
        entry["mean_ms"] = entry["total_ms"] / entry["timed"] if entry["timed"] else None
        if not entry["timed"]:
            entry["total_ms"] = None
    return sorted(by_name.values(), key=lambda e: (-(e["total_ms"] or 0), -e["calls"], e["name"]))


def time_split(row: Dict[str, Any], trial_dir: Path, calls: Dict[str, Dict[str, Any]]) -> Dict[str, Any]:
    """Where the agent phase went: waiting on the model (request durations),
    running tools (their measured execution), and the rest (harness, I/O)."""
    durations = [number(r.get("duration_ms")) for r in request_rows(trial_dir)]
    durations = [d for d in durations if d is not None]
    model_s = sum(durations) / 1000 if durations else None
    timed = [c["elapsed_ms"] for c in calls.values() if c["elapsed_ms"] is not None]
    tool_s = sum(timed) / 1000 if timed else None
    agent_s = row["phases"].get("agent")
    other_s = None
    if agent_s is not None and (model_s is not None or tool_s is not None):
        other_s = max(0.0, agent_s - (model_s or 0) - (tool_s or 0))
    return {"agent_s": agent_s, "model_s": model_s, "tool_s": tool_s, "other_s": other_s,
            "requests": len(durations), "tool_calls": len(calls)}


# -------------------------------------------------------------------- jobs


# A runner that drives Harbor itself (WorkBuddy) leaves Harbor's own run
# directories under <job>/<NESTED_RUNS>/<run>/<trial>; their trials belong to
# the workbench job.
NESTED_RUNS = "workbuddy"


def trial_dirs(job_dir: Path) -> List[Path]:
    def trials(parent: Path) -> List[Path]:
        return [child for child in parent.iterdir()
                if child.is_dir() and not child.is_symlink() and "__" in child.name
                and (child / "config.json").is_file()]

    found = trials(job_dir)
    nested = job_dir / NESTED_RUNS
    if nested.is_dir() and not nested.is_symlink():
        for run in sorted(nested.iterdir()):
            if run.is_dir() and not run.is_symlink():
                found += trials(run)
    return sorted(found, key=lambda path: (path.name, str(path)))


def job_identity(job_dir: Path) -> Dict[str, Any]:
    config = read_json(job_dir / "config.json") or {}
    agents = config.get("agents") or [{}]
    agent = agents[0] if isinstance(agents, list) and agents and isinstance(agents[0], dict) else {}
    datasets = config.get("datasets") or []
    dataset = datasets[0].get("name") if datasets and isinstance(datasets[0], dict) else None
    if dataset is None and isinstance(config.get("tasks"), list) and config["tasks"]:
        first = config["tasks"][0]
        dataset = first.get("path") if isinstance(first, dict) else None
    agent_name = str(agent.get("import_path") or agent.get("name") or "")
    return {
        "agent": agent_name.rsplit(":", 1)[-1] if ":" in agent_name else agent_name,
        "model": agent.get("model_name"),
        "dataset": dataset,
        "attempts": config.get("n_attempts"),
        "concurrency": config.get("n_concurrent_trials"),
    }


def summarize(rows: Iterable[Dict[str, Any]]) -> Dict[str, Any]:
    rows = list(rows)
    counts = {status: 0 for status in STATUSES}
    causes: Dict[str, int] = {}
    empty_final = sum(1 for row in rows if row.get("empty_final"))
    for row in rows:
        counts[row["status"]] += 1
        if row["status"] == "invalid":
            key = (row["cause"] or "unknown").split(":")[0]
            causes[key] = causes.get(key, 0) + 1
    valid = sum(counts[status] for status in VALID)
    rewards = [row["reward"] for row in rows if row["status"] in VALID and row["reward"] is not None]

    def total(key: str) -> Optional[float]:
        values = [row[key] for row in rows if row.get(key) is not None]
        return sum(values) if values else None

    first = {}
    for row in sorted(rows, key=trial_order):
        first.setdefault(row["task"], row)
    first_valid = [r for r in first.values() if r["status"] in VALID]
    first_passed = sum(r["status"] == "pass" for r in first_valid)
    ttfts = [value for row in rows for value in row.get("ttft_samples_ms", [])]
    tps_output = total("tps_output_tokens") or 0
    tps_generation = total("tps_generation_ms") or 0
    initials = [r["initial_input_tokens"] for r in rows if r.get("initial_input_tokens") is not None]
    compositions = [r["initial_composition"] for r in rows if r.get("initial_composition")]

    return {
        "trials": len(rows),
        "counts": counts,
        "invalid_causes": causes,
        "empty_final": empty_final,
        "valid": valid,
        "pass_rate": counts["pass"] / valid if valid else None,
        "one_shot_pass_rate": counts["pass"] / valid if valid else None,
        "mean_reward": sum(rewards) / len(rewards) if rewards else None,
        "first_tasks": len(first), "first_valid": len(first_valid), "first_passed": first_passed,
        "first_invalid": sum(r["status"] == "invalid" for r in first.values()),
        "first_pending": sum(r["status"] == "running" for r in first.values()),
        "first_pass_rate": first_passed / len(first_valid) if first_valid else None,
        "total_tokens": total("total_tokens"),
        "token_trials": sum(r.get("total_tokens") is not None for r in rows),
        "partial_token_trials": sum(bool(r.get("tokens_partial")) for r in rows),
        "initial_input_tokens": sum(initials) if initials else None,
        "initial_token_trials": len(initials),
        "initial_input_tokens_mean": sum(initials) / len(initials) if initials else None,
        **composition_fields({part: sum(c.get(part) or 0 for c in compositions) for part in CONTEXT_PARTS}
                             if compositions else None, len(compositions)),
        "input_tokens": total("input_tokens"),
        "cache_tokens": total("cache_tokens"),
        "output_tokens": total("output_tokens"),
        "cost_usd": total("cost_usd"),
        "cost_trials": sum(r.get("cost_usd") is not None for r in rows),
        "requests": total("requests") or 0,
        "profiled_requests": total("profiled_requests") or 0,
        "ttft_samples_ms": ttfts,
        "tps_output_tokens": tps_output, "tps_generation_ms": tps_generation,
        **performance_fields(ttfts, tps_output, tps_generation),
        "agent_seconds": sum(
            row["phases"]["agent"] for row in rows if row["phases"].get("agent") is not None
        ),
    }


def composition_fields(total: Optional[Dict[str, float]], trials: int) -> Dict[str, Any]:
    """Initial-context composition of a set of trials: the per-part sum, the
    number of trials that recorded one, and the per-part mean."""
    return {"initial_composition_sum": total, "initial_composition_trials": trials,
            "initial_composition_mean": {k: v / trials for k, v in total.items()} if total and trials else None}


def merge_summaries(summaries):
    """Pool jobs as separate evaluations; never deduplicate tasks across models."""
    summaries = list(summaries)
    fields = ("trials", "valid", "empty_final", "first_tasks", "first_valid", "first_passed", "first_invalid", "first_pending",
              "total_tokens", "token_trials", "partial_token_trials", "initial_input_tokens", "initial_token_trials",
              "input_tokens", "cache_tokens", "output_tokens", "cost_usd", "cost_trials", "agent_seconds",
              "requests", "profiled_requests", "tps_output_tokens", "tps_generation_ms")
    result = {}
    for field in fields:
        values = [s[field] for s in summaries if s.get(field) is not None]
        result[field] = sum(values) if values else None
    result["counts"] = {status: sum(s["counts"][status] for s in summaries) for status in STATUSES}
    result["pass_rate"] = result["counts"]["pass"] / result["valid"] if result["valid"] else None
    result["one_shot_pass_rate"] = result["pass_rate"]
    result["first_pass_rate"] = result["first_passed"] / result["first_valid"] if result["first_valid"] else None
    result["initial_input_tokens_mean"] = result["initial_input_tokens"] / result["initial_token_trials"] if result["initial_token_trials"] else None
    compositions = [s for s in summaries if s.get("initial_composition_sum")]
    result.update(composition_fields(
        {part: sum(s["initial_composition_sum"].get(part) or 0 for s in compositions) for part in CONTEXT_PARTS}
        if compositions else None, sum(s.get("initial_composition_trials") or 0 for s in compositions)))
    ttfts = [t for s in summaries for t in s.get("ttft_samples_ms", [])]
    result["ttft_samples_ms"] = ttfts
    result.update(performance_fields(ttfts, result["tps_output_tokens"] or 0, result["tps_generation_ms"] or 0))
    return result


def job_header(job_dir: Path) -> Dict[str, Any]:
    """The job-level fields of a view, from the job's own config and result."""

    result = read_json(job_dir / "result.json") or {}
    started = parse_time(result.get("started_at"))
    finished = parse_time(result.get("finished_at"))
    return {
        "name": job_dir.name,
        **job_identity(job_dir),
        "planned": result.get("n_total_trials"),
        "started_at": started.isoformat() if started else None,
        "finished_at": finished.isoformat() if finished else None,
    }


def assemble_view(header: Dict[str, Any], rows: List[Dict[str, Any]], with_rows: bool = True) -> Dict[str, Any]:
    """A job view from its header and trial rows (from files or the store)."""

    attempts = {}
    for row in sorted(rows, key=trial_order):
        attempts[row["task"]] = attempts.get(row["task"], 0) + 1
        row["attempt_number"] = attempts[row["task"]]
        row["first_attempt"] = row["attempt_number"] == 1
    planned = header.get("planned")
    started = parse_time(header.get("started_at"))
    finished = parse_time(header.get("finished_at"))
    view = {
        **header,
        "planned": planned if isinstance(planned, int) else len(rows),
        "running": finished is None,
        "wall_s": ((finished or dt.datetime.now(dt.timezone.utc)) - started).total_seconds() if started else None,
        "summary": summarize(rows),
    }
    if with_rows:
        view["rows"] = rows
    return view


def job_view(job_dir: Path, with_rows: bool = True) -> Dict[str, Any]:
    return assemble_view(job_header(job_dir), [trial_row(path) for path in trial_dirs(job_dir)], with_rows)


class Library:
    """The jobs under one or more Harbor jobs directories, addressed by name."""

    def __init__(self, roots: Iterable[Path]):
        self.roots = [Path(root).expanduser().resolve() for root in roots]

    def jobs(self) -> Dict[str, Path]:
        found: Dict[str, Path] = {}
        for root in self.roots:
            try:
                children = sorted(root.iterdir())
            except OSError:
                continue
            for child in children:
                if (
                    child.is_dir()
                    and not child.is_symlink()
                    and NAME.match(child.name)
                    and (child / "config.json").is_file()
                    and (child / "result.json").is_file()
                ):
                    found.setdefault(child.name, child)
        return found

    def job_dir(self, name: str) -> Optional[Path]:
        if not isinstance(name, str) or not NAME.match(name):
            return None
        return self.jobs().get(name)

    def trial_dir(self, job: str, trial: str) -> Optional[Path]:
        job_dir = self.job_dir(job)
        if job_dir is None or not isinstance(trial, str) or not NAME.match(trial):
            return None
        # Only a trial this job actually lists, never a constructed path.
        return next((path for path in trial_dirs(job_dir) if path.name == trial), None)

    def overview(self) -> List[Dict[str, Any]]:
        views = [job_view(path, with_rows=False) for path in self.jobs().values()]
        return sorted(views, key=lambda view: view["started_at"] or "", reverse=True)


CSV_FIELDS = (
    "task", "trial", "status", "cause", "reward", "tests_passed", "tests_total",
    "stop_reason", "empty_final", "turns", "tool_calls", "input_tokens", "cache_tokens",
    "output_tokens", "total_tokens", "initial_input_tokens", "tokens_partial", "tps", "ttft_ms", "ttft_p95_ms",
    "requests", "profiled_requests", "cost_usd", "cost_source", "agent_s", "verifier_s", "elapsed_s", "attempt_number", "first_attempt",
)


def job_csv(view: Dict[str, Any]) -> str:
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(("job", "model") + CSV_FIELDS)
    for row in view.get("rows") or []:
        tests = row.get("tests") or {}
        values = {
            **row,
            "tests_passed": tests.get("passed"),
            "tests_total": tests.get("total"),
            "agent_s": row["phases"].get("agent"),
            "verifier_s": row["phases"].get("verifier"),
        }
        writer.writerow([view["name"], view.get("model")] + ["" if values.get(f) is None else values.get(f) for f in CSV_FIELDS])
    return out.getvalue()
