from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from scripts.eval.harbor.bench import data, executors, prices
from scripts.eval.harbor.store import config, ingest
from scripts.eval.harbor.store.backend import Store, now
from scripts.eval.harbor.store.library import StoreLibrary


TOKEN_BUCKET_FIELDS = frozenset((
    "uncached",
    "output",
    "cache_read",
    "cache_write",
    "trials",
    "fallback_cost",
    "fallback_trials",
))


class WorkerUnavailable(ValueError):
    pass


def _empty_token_bucket():
    return {
        "uncached": 0.0,
        "output": 0.0,
        "cache_read": 0.0,
        "cache_write": 0.0,
        "trials": 0,
        "fallback_cost": 0.0,
        "fallback_trials": 0,
    }


def _tokens_by_status(rows):
    buckets = {status: _empty_token_bucket() for status in data.STATUSES}
    for row in rows:
        bucket = buckets[row["status"]]
        tb = prices.token_bucket(
            row.get("input_tokens"),
            row.get("output_tokens"),
            row.get("cache_tokens"),
            row.get("cache_creation_tokens"),
        )
        if tb is not None:
            bucket["uncached"] += tb["uncached"]
            bucket["output"] += tb["output"]
            bucket["cache_read"] += tb["cache_read"]
            bucket["cache_write"] += tb["cache_write"]
            bucket["trials"] += 1
        elif row.get("cost_usd") is not None:
            bucket["fallback_cost"] += float(row["cost_usd"])
            bucket["fallback_trials"] += 1
    return buckets


def _valid_tokens_by_status(value):
    return (
        isinstance(value, dict)
        and set(value) == set(data.STATUSES)
        and all(isinstance(bucket, dict) and set(bucket) == TOKEN_BUCKET_FIELDS for bucket in value.values())
    )


def task_summaries(rows):
    tasks = {}
    for row in rows:
        tasks.setdefault(row["task"], []).append(row)
    return {task: aggregate(attempts) for task, attempts in tasks.items()}


def aggregate(rows):
    summary = data.summarize(rows)
    summary.update(data.ttft_distribution(summary.pop("ttft_samples_ms")))
    scored = [r["reward"] for r in rows if r["status"] in data.VALID and r.get("reward") is not None]
    summary["reward_sum"] = sum(scored)
    summary["reward_count"] = len(scored)
    costs = [r["cost_usd"] for r in rows if r["status"] != "running" and r.get("cost_usd") is not None]
    summary["finished_cost_mean"] = sum(costs) / len(costs) if costs else None
    summary["tokens_by_status"] = _tokens_by_status(rows)
    return summary


def check_snapshot(snapshot, name):
    header = {"name", "agent", "model", "dataset", "attempts", "concurrency", "planned", "started_at", "finished_at",
              "running", "wall_s", "summary"}
    fields = set(aggregate([]))
    legacy_fields = fields - {"tokens_by_status"}
    valid = isinstance(snapshot, dict) and set(snapshot) == {"store_id", "source", "view", "tasks"}
    if valid:
        view, groups = snapshot["view"], snapshot["tasks"]
        valid = (isinstance(snapshot["store_id"], str) and re.fullmatch("[0-9a-f]{32}", snapshot["store_id"])
                 and isinstance(snapshot["source"], str) and isinstance(view, dict) and set(view) == header
                 and view["name"] == name and isinstance(groups, dict)
                 and all(
                     isinstance(group, dict)
                     and (
                         (set(group) == fields and _valid_tokens_by_status(group["tokens_by_status"]))
                         or set(group) == legacy_fields
                     )
                     for group in [view["summary"], *groups.values()]
                 ))
    if not valid:
        raise ValueError("worker 返回了不兼容的作业汇总")


def stopped_summary(summary):
    counts = summary["counts"]
    running = counts["running"]
    if not running:
        return summary
    causes = dict(summary["invalid_causes"])
    causes["execution"] = causes.get("execution", 0) + running
    updated = {**summary, "counts": {**counts, "running": 0, "invalid": counts["invalid"] + running},
               "invalid_causes": causes, "first_invalid": summary["first_invalid"] + summary["first_pending"],
               "first_pending": 0}
    tbs = summary.get("tokens_by_status")
    if isinstance(tbs, dict) and "running" in tbs and "invalid" in tbs:
        merged_tbs = {status: dict(bucket) for status, bucket in tbs.items()}
        run_bucket = merged_tbs["running"]
        inv_bucket = merged_tbs["invalid"]
        for key in run_bucket:
            inv_bucket[key] = inv_bucket.get(key, 0) + run_bucket[key]
        merged_tbs["running"] = _empty_token_bucket()
        updated["tokens_by_status"] = merged_tbs
    return updated


def stored_log(store, name):
    with store.read() as tx:
        row = tx.one("SELECT log_tail FROM worker_jobs WHERE job = ?", (name,))
        return row[0] if row else ""


def worker_result(node, operation, directory, trial=None):
    from scripts.eval.harbor.bench.remote import HARBOR_LOG
    directory = Path(directory).expanduser()
    name = directory.name
    if not data.NAME.fullmatch(name) or directory.is_symlink() or directory.parent.name != "jobs":
        raise ValueError("作业路径无效")
    run_dir = directory.parent.parent / "runs" / name
    log = run_dir / HARBOR_LOG
    if operation == "log":
        return data.tail(log) if not run_dir.is_symlink() and not log.is_symlink() else ""
    store_path = run_dir / "result-store.json"
    if store_path.is_file():
        store_config = config.parse(json.loads(store_path.read_text(encoding="utf-8")), node.root)
    else:
        store_config = config.for_workbench(node.cfg, node.root / "workbench.json")
    store = Store(store_config)
    library = StoreLibrary(store)
    try:
        if operation in ("summary", "final"):
            if not ingest.is_job_dir(directory):
                return None
            with ingest.root_lock(directory.parent):
                result = ingest.ingest_job(store, directory, verify=operation == "final")
                if result.outcome == "skipped" or result.trials_failed:
                    raise ValueError("作业数据尚未完整写入 worker 数据库")
                with store.transaction() as tx:
                    tx.execute("INSERT INTO worker_jobs (job, log_tail, ingested_at) VALUES (?, ?, ?) "
                               "ON CONFLICT (job) DO UPDATE SET log_tail = excluded.log_tail, ingested_at = excluded.ingested_at "
                               "WHERE worker_jobs.log_tail <> excluded.log_tail",
                               (name, data.tail(log) if not run_dir.is_symlink() and not log.is_symlink() else "", now()))
            view = library.job_view(name)
            rows = view.pop("rows")
            view["summary"] = aggregate(rows)
            return {"view": view, "tasks": task_summaries(rows), "store_id": store.identity(),
                    "source": str(directory.resolve())}
        with store.read() as tx:
            source = tx.one("SELECT source_dir, projection FROM jobs WHERE name = ?", (name,))
        if not source or source[0] != str(directory.resolve()):
            return None
        if operation == "job":
            with store.read() as tx:
                stale_trials = tx.one("SELECT 1 FROM trials WHERE job = ? AND projection <> ? LIMIT 1",
                                      (name, ingest.PROJECTION))
            if source[1] != ingest.PROJECTION or stale_trials:
                with ingest.root_lock(directory.parent):
                    ingest.refresh_job_projection(store, name, ingest.stderr_log)
            return library.job_view(name)
        if operation == "trial" and isinstance(trial, str) and data.NAME.fullmatch(trial):
            target = library.trial_record(name, trial)
            if target and (source[1] != ingest.PROJECTION or target[1] != ingest.PROJECTION):
                with ingest.root_lock(directory.parent):
                    with store.read() as tx:
                        source = tx.one("SELECT source_dir, projection FROM jobs WHERE name = ?", (name,))
                    if not source or source[0] != str(directory.resolve()):
                        return None
                    target = library.trial_record(name, trial)
                    if target:
                        if source[1] != ingest.PROJECTION:
                            ingest.refresh_job_header(store, name)
                        if target[1] != ingest.PROJECTION:
                            ingest.refresh_trial_projection(store, name, target[0], ingest.stderr_log)
            return library.trial_view(name, trial)
        raise ValueError("未知的作业查询")
    finally:
        store.close()


def request(executor, name, operation, trial=None, *, binary=None, runner=subprocess.run, timeout=120):
    if not data.NAME.fullmatch(name) or trial is not None and not data.NAME.fullmatch(trial):
        raise ValueError("作业或 trial 名称无效")
    args = [operation, executor.remote("jobs", name)]
    if trial is not None:
        args.append(trial)
    try:
        reply = runner(executors.node_argv(executor, "results", *args, binary=binary), stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=timeout)
        if reply.returncode == 0:
            return json.loads(reply.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    raise WorkerUnavailable(f"无法读取 worker {executor.name} 上的作业 {name}，请检查节点连接和版本")
