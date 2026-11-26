from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

from scripts.eval.harbor.bench import data, executors
from scripts.eval.harbor.store import config, ingest
from scripts.eval.harbor.store.backend import Store, now
from scripts.eval.harbor.store.library import StoreLibrary


class WorkerUnavailable(ValueError):
    pass


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
    return summary


def check_snapshot(snapshot, name):
    header = {"name", "agent", "model", "dataset", "attempts", "concurrency", "planned", "started_at", "finished_at",
              "running", "wall_s", "summary"}
    fields = set(aggregate([]))
    valid = isinstance(snapshot, dict) and set(snapshot) == {"store_id", "source", "view", "tasks"}
    if valid:
        view, groups = snapshot["view"], snapshot["tasks"]
        valid = (isinstance(snapshot["store_id"], str) and re.fullmatch("[0-9a-f]{32}", snapshot["store_id"])
                 and isinstance(snapshot["source"], str) and isinstance(view, dict) and set(view) == header
                 and view["name"] == name and isinstance(groups, dict)
                 and all(isinstance(group, dict) and set(group) == fields for group in [view["summary"], *groups.values()]))
    if not valid:
        raise ValueError("worker 返回了不兼容的作业汇总")


def stopped_summary(summary):
    counts = summary["counts"]
    running = counts["running"]
    if not running:
        return summary
    causes = dict(summary["invalid_causes"])
    causes["execution"] = causes.get("execution", 0) + running
    return {**summary, "counts": {**counts, "running": 0, "invalid": counts["invalid"] + running},
            "invalid_causes": causes, "first_invalid": summary["first_invalid"] + summary["first_pending"],
            "first_pending": 0}


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
            stale_trials = tx.one("SELECT 1 FROM trials WHERE job = ? AND projection <> ? LIMIT 1",
                                  (name, ingest.PROJECTION))
        if not source or source[0] != str(directory.resolve()):
            return None
        if source[1] != ingest.PROJECTION or stale_trials:
            with ingest.root_lock(directory.parent):
                ingest.refresh_job_projection(store, name, ingest.stderr_log)
        if operation == "job":
            return library.job_view(name)
        if operation == "trial" and isinstance(trial, str) and data.NAME.fullmatch(trial):
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
