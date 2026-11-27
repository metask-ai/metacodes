"""The Bench runtime as one object: what every presentation reads and asks.

The web page (`viewer/server.py`) and the CLI (`cli.py`) only present what
this returns. Jobs are read from the evaluation store, which follows the jobs
directories. A workbench without a RunManager is read-only: it lists jobs
and refuses launches. Names are looked up in the store, never used as paths.
"""
from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any, Dict, Optional

from scripts.eval.harbor import suites
from scripts.eval.harbor.suites import leaderboards
from scripts.eval.harbor.bench import builds, data, executors, monitor, prices, results
from scripts.eval.harbor.bench.profiles import PROFILE_ACTIVE, ProfileManager, public as public_profile, runs_of
from scripts.eval.harbor.bench.runner import ACTIVE, atomic_json, runtime_env, settings
from scripts.eval.harbor.bench.setup import LoginManager, SetupManager
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store import ingest
from scripts.eval.harbor.store import migrate as migration
from scripts.eval.harbor.store.backend import Store, open_ephemeral
from scripts.eval.harbor.store.library import HIDDEN_WORKER_JOBS, StoreLibrary

RUNTIME_ROOT = Path(__file__).resolve().parents[4]
READ_ONLY = "当前服务为只读模式"
READ_ONLY_CATALOG = {"service": "metacodes-bench", "schema_version": 1, "ready": False,
                     "reasons": [READ_ONLY], "runs": []}
RANKED_COVERAGE = 0.8
ATTEMPT_FIELDS = ("trial", "status", "cause", "reward", "attempt_number", "first_attempt", "total_tokens",
                  "initial_input_tokens", "input_tokens", "output_tokens", "elapsed_s", "turns", "tool_calls", "tests")


def _mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def _reprice_row(row, rate, schedule):
    if schedule == prices.RECORDED:
        return row
    if rate is not None:
        cost = prices.compute_cost(
            rate,
            row.get("input_tokens"),
            row.get("output_tokens"),
            row.get("cache_tokens"),
            row.get("cache_creation_tokens"),
        )
        if cost is not None:
            return {**row, "cost_usd": cost, "cost_source": schedule}
    if schedule == prices.BASETEN:
        return {**row, "cost_usd": None, "cost_source": "unavailable"}
    return row


def _clear_summary_costs(group):
    updated = dict(group)
    updated["cost_usd"] = None
    updated["cost_trials"] = 0
    if "finished_cost_mean" in updated:
        updated["finished_cost_mean"] = None
    updated["task_cost_sum"] = 0.0
    updated["task_pass_sum"] = 0.0
    updated["task_cost_tasks"] = 0
    updated["cost_by_status"] = {st: 0.0 for st in data.VALID}
    updated.update(data.outcome_fields(updated))
    return updated


def _reprice_task_summary(group, rate, schedule):
    if schedule == prices.RECORDED:
        return group
    tbs = group.get("tokens_by_status")
    if not isinstance(tbs, dict) or rate is None:
        return _clear_summary_costs(group) if schedule == prices.BASETEN else group
    status_cost = {}
    status_trials = {}
    for st in data.STATUSES:
        bucket = tbs.get(st) or {}
        priced_trials = int(bucket.get("trials") or 0)
        cost = prices.compute_bucket_cost(rate, bucket) if priced_trials > 0 else 0.0
        if schedule == prices.OPENROUTER:
            fallback_trials = int(bucket.get("fallback_trials") or 0)
            fallback_cost = float(bucket.get("fallback_cost") or 0.0)
        else:
            fallback_trials = 0
            fallback_cost = 0.0
        status_trials[st] = priced_trials + fallback_trials
        status_cost[st] = (cost or 0.0) + fallback_cost
    updated = dict(group)
    all_trials = sum(status_trials.values())
    updated["cost_usd"] = sum(status_cost.values()) if all_trials else None
    updated["cost_trials"] = all_trials
    if "finished_cost_mean" in updated:
        finished_statuses = [st for st in data.STATUSES if st != "running"]
        finished_trials = sum(status_trials[st] for st in finished_statuses)
        updated["finished_cost_mean"] = (
            sum(status_cost[st] for st in finished_statuses) / finished_trials if finished_trials else None
        )
    valid_trials = sum(status_trials[st] for st in data.VALID)
    updated["cost_by_status"] = {st: status_cost[st] for st in data.VALID}
    if valid_trials > 0:
        updated["task_cost_sum"] = sum(status_cost[st] for st in data.VALID) / valid_trials
        updated["task_pass_sum"] = status_trials["pass"] / valid_trials
        updated["task_cost_tasks"] = 1
    else:
        updated["task_cost_sum"] = 0.0
        updated["task_pass_sum"] = 0.0
        updated["task_cost_tasks"] = 0
    updated.update(data.outcome_fields(updated))
    return updated


def _reprice_view(view, run, schedule, openrouter_models):
    model = (run or {}).get("model") or view.get("model")
    recorded_price = (run or {}).get("model_price")
    rate = prices.rate_for(model, schedule, openrouter_models, recorded_price)
    updated = dict(view)
    if "rows" in view:
        rows = [_reprice_row(row, rate, schedule) for row in view["rows"]]
        updated["rows"] = rows
        updated["summary"] = data.summarize(rows)
    elif "task_summaries" in view:
        groups = {
            task: _reprice_task_summary(group, rate, schedule)
            for task, group in view["task_summaries"].items()
        }
        updated["task_summaries"] = groups
        updated["summary"] = group_summary(groups)
    elif schedule == prices.BASETEN:
        updated["summary"] = _clear_summary_costs(view["summary"])
    updated["pricing"] = {
        "schedule": schedule,
        "label": prices.SCHEDULE_LABELS[schedule],
        "rate": rate,
    }
    return updated


def _schedule_summary_entry(schedule, summary, rate=None):
    entry = {
        "schedule": schedule,
        "label": prices.SCHEDULE_LABELS[schedule],
        "cost_usd": summary.get("cost_usd"),
        "cost_per_task": summary.get("cost_per_task"),
        "cost_per_pass": summary.get("cost_per_pass"),
        "task_cost_tasks": summary.get("task_cost_tasks"),
    }
    if rate is not None:
        entry["rate"] = rate
    return entry


def task_group(task, rows, item, job):
    """One task's attempts in one run, in order, for a profile."""
    attempts = sorted(({k: row.get(k) for k in ATTEMPT_FIELDS} for row in rows),
                      key=lambda a: a.get("attempt_number") or 0)
    group = {"task": task, "job": job, "suite": item["suite"], "suite_name": item.get("suite_name"),
             "model": item.get("model"), "attempts": attempts,
             "first_status": attempts[0]["status"] if attempts else None,
             "passed": sum(a["status"] == "pass" for a in attempts),
             "valid": sum(a["status"] in data.VALID for a in attempts)}
    for key in ("total_tokens", "initial_input_tokens", "elapsed_s", "turns", "tool_calls"):
        group["mean_" + key] = _mean(a.get(key) for a in attempts)
    return group


def latest_results(record, views):
    """Per (suite, model, task), the rows of the last run that has them: a
    rerun replaces the earlier result, which stays in `history` (job names,
    oldest first). A run that stopped (cancelled, interrupted, failed) with
    only invalid attempts of a task leaves that task's earlier result."""
    latest, history = {}, {}
    for item in record.get("items") or []:
        view = views.get(item.get("run")) if item.get("run") else None
        if view is None:
            continue
        stopped = item["status"] in ("cancelled", "interrupted", "failed")
        by_task = {}
        for row in view.get("rows") or []:
            by_task.setdefault(row["task"], []).append(row)
        by_task.update(view.get("task_summaries") or {})
        for task, rows in by_task.items():
            key = (item["suite"], item.get("model"), task)
            invalid = rows["counts"]["invalid"] == rows["trials"] if isinstance(rows, dict) else all(
                row["status"] == "invalid" for row in rows)
            if key in latest and stopped and invalid:
                continue
            if key in latest:
                history.setdefault(key, []).append(latest[key][1])
            latest[key] = (item, view["name"], rows)
    return latest, history


def _profile_lookup(records):
    by_id, by_job = {}, {}
    for record in records:
        pub = public_profile(record)
        meta = {
            "profile": pub["id"],
            "profile_name": pub.get("name") or pub.get("default_name") or pub["id"],
            "profile_version": (pub.get("metacodes") or {}).get("label"),
            "profile_features": list(pub.get("features") or []),
        }
        by_id[pub["id"]] = meta
        for item in pub.get("items") or []:
            if item.get("run"):
                by_job[item["run"]] = meta
    return by_id, by_job


def _attach_profile(entry, by_id, by_job):
    meta = by_job.get(entry.get("name")) or by_id.get(entry.get("profile"))
    if meta:
        entry.update(meta)
    return entry


def _latest_ranked_per_profile(jobs):
    ranked_by_key = {}
    standalone_ranked = []
    unranked = []
    for job in jobs:
        if not job.get("ranked"):
            unranked.append(job)
            continue
        if not job.get("profile"):
            standalone_ranked.append(job)
            continue
        key = (job["profile"], job.get("model") or "")
        prev = ranked_by_key.get(key)
        if prev is None or (job.get("started_at") or "", job["name"]) > (prev.get("started_at") or "", prev["name"]):
            ranked_by_key[key] = job
    return sorted([*ranked_by_key.values(), *standalone_ranked, *unranked],
                  key=lambda job: (job["score"], job.get("started_at") or ""), reverse=True)


def board_job(view, tasks):
    """A finished job on a published board's tasks (None: all of them): the
    mean reward of its finished trials, an invalid trial counting 0, and the
    mean over tasks of each task's mean priced cost."""
    if "task_summaries" in view:
        groups = [group for task, group in view["task_summaries"].items() if (tasks is None or task in tasks)
                  and group["trials"] > group["counts"]["running"]]
        finished = sum(g["trials"] - g["counts"]["running"] for g in groups)
        if not finished:
            return None
        return {"name": view["name"], "model": view.get("model"), "profile": view.get("profile"),
                "started_at": view.get("started_at"), "trials": finished, "tasks": len(groups),
                "score": sum(g["reward_sum"] for g in groups) / finished,
                "cost_per_task": _mean([g["finished_cost_mean"] for g in groups])}
    rows = [r for r in view["rows"] if r["status"] != "running" and (tasks is None or r["task"] in tasks)]
    if not rows:
        return None
    costs: Dict[str, list] = {}
    for row in rows:
        if row.get("cost_usd") is not None:
            costs.setdefault(row["task"], []).append(row["cost_usd"])
    return {"name": view["name"], "model": view.get("model"), "profile": view.get("profile"),
            "started_at": view.get("started_at"), "trials": len(rows), "tasks": len({r["task"] for r in rows}),
            "score": sum(0 if r["status"] == "invalid" else r.get("reward") or 0 for r in rows) / len(rows),
            "cost_per_task": _mean([sum(c) / len(c) for c in costs.values()])}


def group_summary(groups):
    if not any(isinstance(group, dict) for group in groups.values()):
        return data.summarize([{**row, "task": key} for key, group in groups.items() for row in group])
    summaries = [group if isinstance(group, dict) else results.aggregate(group) for group in groups.values()]
    summary = data.merge_summaries(summaries)
    causes = {}
    for group in summaries:
        for cause, n in group["invalid_causes"].items():
            causes[cause] = causes.get(cause, 0) + n
    rewards = sum(s["reward_count"] for s in summaries)
    summary.update(invalid_causes=causes, mean_reward=sum(s["reward_sum"] for s in summaries) / rewards if rewards else None)
    return summary


def model_comparison(latest):
    """Each model's latest results: over every task it ran, and, when the
    models ran different tasks, over the tasks all of them ran."""
    by_model = {}
    for (suite, model, task), (_, _, rows) in latest.items():
        by_model.setdefault(model, {})[(suite, task)] = rows

    def summary(rows):
        return {k: v for k, v in group_summary(rows).items() if k not in ("ttft_samples_ms", "ttft_histogram")}

    task_sets = [set(tasks) for tasks in by_model.values()]
    common = set.intersection(*task_sets) if len(task_sets) > 1 and len({frozenset(t) for t in task_sets}) > 1 else None
    result = []
    for model, tasks in sorted(by_model.items(), key=lambda pair: pair[0] or ""):
        entry = {"model": model, "tasks": len(tasks), "summary": summary(tasks)}
        if common is not None:
            entry["common_summary"] = summary({key: tasks[key] for key in common})
        result.append(entry)
    return result, (len(common) if common is not None else None)


def library_for(roots, manager=None) -> StoreLibrary:
    """The store a service reads: the workbench's configured store, or a
    private temporary one for a read-only viewer without a workbench."""
    if manager is not None:
        store = Store(store_config.for_workbench(settings(manager.config_path), manager.config_path))
    else:
        store = open_ephemeral()
    return StoreLibrary(store, roots, owns_store=True)


def open_local(store, jobs_dir, manager=None) -> "Workbench":
    """This machine's workbench without a service: its store, synced now."""
    library = StoreLibrary(Store(store), [jobs_dir] if jobs_dir.is_dir() else [], owns_store=True)
    try:
        library.sync()
    except BaseException:
        library.close()
        raise
    return Workbench(library, manager)


class Workbench:
    def __init__(self, library, manager=None):
        """`library` is a StoreLibrary, or a data.Library whose roots are then
        served through the workbench's store."""
        if isinstance(library, data.Library):
            library = library_for(library.roots, manager)
        self.library = library
        self.manager = manager
        self.setups = SetupManager(manager.config_path) if manager else None
        self.logins = LoginManager(manager.config_path) if manager else None
        self.builds = builds.BuildManager(manager.config_path) if manager else None
        self.monitors = monitor.Monitor() if manager else None
        if manager is not None:
            manager.setup_running = self.setups.mutating
            if getattr(manager, "profiles", None) is None:
                manager.profiles = ProfileManager(manager)
        self.profiles = manager.profiles if manager is not None else None

    @property
    def can_launch(self) -> bool:
        return self.manager is not None

    def start_profiles(self) -> None:
        """Profile queues advance on their own: a dataset ends, the next one starts."""
        if self.profiles is not None:
            self.profiles.start()

    def sync_in_background(self) -> None:
        """Historical imports can take a while; a service serves meanwhile."""
        self.library.start_background()

    def close(self) -> None:
        if self.profiles is not None:
            self.profiles.stop()
        self.library.close()

    def runs(self):
        return self.manager.runs() if self.manager else []

    def catalog(self) -> Dict[str, Any]:
        if not self.manager:
            return dict(READ_ONLY_CATALOG)
        return {**self.manager.catalog(), "config_path": str(self.manager.config_path)}

    def suite_tasks(self, suite_id, executor=None) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.suite_tasks(suite_id, executor)

    def result_records(self):
        records = {r["name"]: r for r in self.library.run_records()}
        records.update((r["name"], r) for r in self.runs())
        return records

    def _openrouter_models(self):
        if not self.manager:
            return {}
        cfg = settings(self.manager.config_path)
        state_dir = self.manager.config_path.parent
        if cfg.get("model_prices", prices.OPENROUTER) != prices.OPENROUTER:
            return prices.cached_catalog(state_dir)
        return prices.catalog(state_dir)

    def worker_read(self, run, operation, trial=None):
        snapshot = run.get("worker_summary") or {}
        name = run["name"]
        if not snapshot and operation != "log":
            return None
        store = self.library.store
        if snapshot and snapshot["store_id"] == store.identity():
            with store.read() as tx:
                source = tx.one("SELECT source_dir FROM jobs WHERE name = ?", (name,))
            if source and source[0] == snapshot["source"]:
                if operation == "log":
                    return results.stored_log(store, name)
                value = self.library.job_view(name) if operation == "job" else self.library.trial_view(name, trial)
                return {**value, "detail_source": "database"} if value else None
        if not self.manager:
            raise results.WorkerUnavailable(f"请通过作业所属的工作台访问 worker {run['result_owner']}")
        spec = settings(self.manager.records / (name + ".spec"))
        entry = spec.get("executor") or {}
        if entry.get("kind") != "ssh" or entry.get("name") != run["result_owner"] or spec.get("name") != name:
            raise results.WorkerUnavailable(f"找不到作业 {name} 所属的 worker {run['result_owner']}")
        executor = executors.parse({k: v for k, v in entry.items() if v is not None})
        value = results.request(executor, name, operation, trial)
        if operation == "log" or value is None:
            return value
        return {**value, "detail_source": "worker"}

    def job_view(self, name, with_rows=True, runs=None, *, aggregate=False, price=prices.RECORDED, openrouter_models=None) -> Optional[Dict[str, Any]]:
        if not isinstance(name, str) or not data.NAME.fullmatch(name):
            return None
        if isinstance(runs, dict):
            run = runs.get(name)
        else:
            run = next((r for r in (self.runs() if runs is None else runs) if r["name"] == name), None)
            run = run or self.library.run_record(name)
        if run and run.get("result_owner"):
            if aggregate:
                snapshot = run.get("worker_summary") or {}
                if not snapshot.get("view"):
                    return None
                view = {**snapshot["view"], "task_summaries": snapshot["tasks"]}
            else:
                view = self.worker_read(run, "job")
            if view is not None:
                view["result_owner"] = run["result_owner"]
        elif not run and self.library.worker_only(name):
            return None
        else:
            view = self.library.job_view(name)
        if view is None:
            return None
        # Suite/category: the launch record, else inferred from Harbor's dataset.
        view.update(suites.label((run or {}).get("suite")) or suites.label(suites.infer(view.get("dataset"))))
        judge = (run or {}).get("judge")
        if isinstance(judge, dict) and isinstance(judge.get("model"), str):
            # Which LLM judge scored the run (model id and route, no secret).
            view["judge"] = {"model": judge["model"], "via": judge.get("via")}
        if run and run["status"] in {"failed", "cancelled", "interrupted"} and view["running"]:
            # Harbor may be interrupted before it writes a final result.
            # Preserve those files, and display the durable worker outcome.
            view["running"] = False
            view["execution_status"] = run["status"]
            for row in view.get("rows", []):
                if row["status"] == "running":
                    row.update(status="invalid", cause="execution: " + run["status"])
            if "rows" in view:
                view["summary"] = data.summarize(view["rows"])
            else:
                view["summary"] = results.stopped_summary(view["summary"])
                view["task_summaries"] = {t: results.stopped_summary(g) for t, g in view["task_summaries"].items()}
            started, finished = data.parse_time(view.get("started_at")), data.parse_time(run.get("finished_at"))
            if finished:
                view["finished_at"] = finished.isoformat()
                view["wall_s"] = (finished - started).total_seconds() if started else None
        view["profile"] = (run or {}).get("profile")
        view["metacodes"] = (run or {}).get("metacodes")
        if price != prices.RECORDED:
            models = self._openrouter_models() if openrouter_models is None else openrouter_models
            view = _reprice_view(view, run, price, models)
        else:
            view["pricing"] = {"schedule": prices.RECORDED, "label": prices.SCHEDULE_LABELS[prices.RECORDED], "rate": None}
        if not with_rows:
            view.pop("rows", None)
        return view

    def profile_records(self):
        found = {r["id"]: r for r in self.library.profile_records() if isinstance(r, dict) and r.get("id")}
        if self.profiles is not None:
            found.update((r["id"], r) for r in self.profiles.records())
        return sorted(found.values(), key=lambda r: r.get("created_at") or "", reverse=True)

    def profile_summary(self, record, views) -> Dict[str, Any]:
        """A profile's card: its record, each queued dataset's job, and the
        summary of every task's latest result. `views` carry their rows."""
        value = public_profile(record)
        done, planned = 0, 0
        for item in value["items"]:
            view = views.get(item.get("run")) if item.get("run") else None
            waiting = item["status"] in ("pending", "running")
            if waiting:
                planned += len(item.get("tasks") or []) * int(item.get("attempts") or 1)
            if view is not None:
                if waiting:
                    done += view["summary"]["trials"] - view["summary"]["counts"]["running"]
                item["job"] = {k: view.get(k) for k in ("name", "planned", "running", "wall_s", "started_at",
                                                        "finished_at", "dataset", "execution_status")}
                item["job"]["summary"] = {k: v for k, v in view["summary"].items() if k != "ttft_samples_ms"}
        latest, _ = latest_results(record, views)
        value["summary"] = group_summary({key: group for key, (_, _, group) in latest.items()})
        value["by_model"], value["common_tasks"] = model_comparison(latest)
        value["progress"] = {"done": done, "planned": planned} if planned else None
        value["models"] = sorted({i.get("model") for i in value["items"] if i.get("model")})
        value["suites"] = sorted({i["suite"] for i in value["items"]})
        value["last_run_at"] = max((i.get("started_at") or "" for i in value["items"]), default="") or None
        return value

    def _profile_costs_by_schedule(self, record, base_views, receipts, openrouter_models):
        out = {}
        for entry in prices.SCHEDULES:
            sid = entry["id"]
            repriced = {
                name: _reprice_view(view, receipts.get(name), sid, openrouter_models)
                for name, view in base_views.items()
            }
            latest, _ = latest_results(record, repriced)
            summary = group_summary({key: group for key, (_, _, group) in latest.items()})
            out[sid] = _schedule_summary_entry(sid, summary)
        return out

    def jobs(self, scope="all", price=None) -> Dict[str, Any]:
        """Every job, newest first; `scope` is a profile id or "all"."""
        schedule = prices.parse_schedule(price)
        self.library.maybe_sync()
        runs = self.runs()
        receipts = {r["name"]: r for r in self.library.run_records()}
        receipts.update((r["name"], r) for r in runs)
        openrouter_models = self._openrouter_models()
        names = set(self.library.job_names()).union(n for n, r in receipts.items() if r.get("worker_summary"))
        base_jobs = [view for view in (self.job_view(name, True, receipts, aggregate=True, price=prices.RECORDED) for name in sorted(names)) if view]
        base_views = {view["name"]: view for view in base_jobs}
        jobs = [_reprice_view(view, receipts.get(view["name"]), schedule, openrouter_models) for view in base_jobs]
        jobs.sort(key=lambda view: view["started_at"] or "", reverse=True)
        views = {view["name"]: view for view in jobs}
        records = self.profile_records()
        profiles = []
        for record in records:
            card = self.profile_summary(record, views)
            card["costs_by_schedule"] = self._profile_costs_by_schedule(record, base_views, receipts, openrouter_models)
            profiles.append(card)
        for view in jobs:
            view.pop("rows", None)
            view.pop("task_summaries", None)
        if scope != "all":
            record = next((r for r in records if r["id"] == scope), None)
            owned = set(runs_of(record, runs)) if record else set()
            shown = [j for j in jobs if j["name"] in owned]
        else:
            shown = jobs
        storage = self.library.storage()
        return {"jobs": shown, "job_total": len(jobs), "scope": scope, "profiles": profiles, "runs": runs,
                "summary": data.merge_summaries(j["summary"] for j in shown),
                "pricing": {"schedule": schedule, "label": prices.SCHEDULE_LABELS[schedule],
                            "schedules": list(prices.SCHEDULES)},
                "storage": {**storage,
                            "records_dir": str(self.manager.records) if self.manager else None,
                            "format": storage["database"]["format"]}}

    def overview(self):
        """Every stored job, newest first, as Harbor wrote it."""
        self.library.maybe_sync()
        records = self.result_records()
        hidden = self.library.worker_only()
        summaries = {name: r["worker_summary"]["view"] for name, r in records.items() if r.get("worker_summary")}
        views = []
        for name in sorted(set(self.library.job_names()).union(summaries) - hidden):
            view = summaries.get(name) or self.library.job_view(name, with_rows=False)
            if view:
                views.append(view)
        return sorted(views, key=lambda view: view["started_at"] or "", reverse=True)

    def leaderboard(self, suite_id=None, price=None) -> Optional[Dict[str, Any]]:
        """Published boards of one suite (default: the first that has any) and
        this workbench's finished jobs on each. A job scores the mean reward
        of its finished trials on the board's tasks, an invalid trial counting
        0; it is ranked when it covers at least RANKED_COVERAGE of them."""
        requested = prices.parse_schedule(price, allow_auto=True)
        published = leaderboards.boards()
        listed = [s.id for s in suites.ALL if any(s.id in b["suites"] for b in published)]
        suite_id = suite_id or (listed[0] if listed else None)
        if suite_id not in listed:
            return None
        suite = suites.resolved(suites.BY_ID[suite_id])
        task_count = len(suite.tasks) if suite.tasks else suite.max_tasks
        self.library.maybe_sync()
        runs = self.result_records()
        openrouter_models = self._openrouter_models()
        names = set(self.library.job_names()).union(n for n, r in runs.items() if r.get("worker_summary"))
        base_views = [
            view
            for view in (self.job_view(name, True, runs, aggregate=True, price=prices.RECORDED) for name in sorted(names))
            if view and view.get("suite") == suite_id and not view["running"]
        ]
        by_schedule = {
            entry["id"]: [
                _reprice_view(view, runs.get(view["name"]), entry["id"], openrouter_models)
                for view in base_views
            ]
            for entry in prices.SCHEDULES
        }
        by_id, by_job = _profile_lookup(self.profile_records())
        boards, ranked_anywhere, ranked_profiles = [], set(), set()
        for board in (b for b in published if suite_id in b["suites"]):
            board_pricing = board.get("pricing") if isinstance(board.get("pricing"), dict) else {}
            board_default = prices.parse_schedule(board_pricing.get("schedule"))
            effective = board_default if requested == prices.AUTO else requested
            tasks = set(board["tasks"]) if board.get("tasks") else None
            needed = RANKED_COVERAGE * (len(tasks) if tasks else task_count)
            per_schedule_costs = {}
            for entry in prices.SCHEDULES:
                sid = entry["id"]
                for view in by_schedule[sid]:
                    entry_job = board_job(view, tasks)
                    if entry_job:
                        per_schedule_costs.setdefault(entry_job["name"], {})[sid] = entry_job["cost_per_task"]
            jobs = [_attach_profile(job, by_id, by_job) for job in (board_job(view, tasks) for view in by_schedule[effective]) if job]
            for job in jobs:
                job["ranked"] = job["tasks"] >= needed
                job["costs_by_schedule"] = per_schedule_costs.get(job["name"], {})
                job["price_schedule"] = effective
                if job["ranked"]:
                    ranked_anywhere.add(job["name"])
                    if job.get("profile"):
                        ranked_profiles.add((job["profile"], job.get("model") or ""))
            boards.append({
                **board,
                "pricing": {
                    "schedule": requested,
                    "default_schedule": board_default,
                    "effective_schedule": effective,
                    "label": prices.SCHEDULE_LABELS[effective],
                    "default_label": prices.SCHEDULE_LABELS[board_default],
                    "aligned": effective == board_default,
                    "source": board_pricing.get("source"),
                },
                "jobs": _latest_ranked_per_profile(jobs),
            })
        unranked_schedule = (boards[0]["pricing"]["effective_schedule"] if boards else prices.OPENROUTER)
        unranked = []
        for view in by_schedule[unranked_schedule]:
            job = board_job(view, None)
            if not job or job["name"] in ranked_anywhere:
                continue
            _attach_profile(job, by_id, by_job)
            if job.get("profile") and (job["profile"], job.get("model") or "") in ranked_profiles:
                continue
            unranked.append(job)
        return {"suites": [suites.label(s) for s in listed], **suites.label(suite_id), "description": suite.description,
                "task_count": task_count,
                "pricing": {"schedule": requested, "label": prices.SCHEDULE_LABELS[requested],
                            "schedules": list(prices.LEADERBOARD_SCHEDULES)},
                "ranked_coverage": RANKED_COVERAGE, "boards": boards, "unranked": unranked}

    def job(self, name, price=None) -> Optional[Dict[str, Any]]:
        schedule = prices.parse_schedule(price)
        self.library.maybe_sync()
        receipts = self.result_records()
        base = self.job_view(name, runs=receipts, price=prices.RECORDED)
        if base is None:
            return None
        openrouter_models = self._openrouter_models()
        run = receipts.get(name)
        view = _reprice_view(base, run, schedule, openrouter_models)
        view["pricing"] = {
            **view["pricing"],
            "schedules": list(prices.SCHEDULES),
        }
        view["costs_by_schedule"] = {
            entry["id"]: _schedule_summary_entry(
                entry["id"],
                repriced["summary"],
                repriced["pricing"].get("rate"),
            )
            for entry in prices.SCHEDULES
            for repriced in [_reprice_view(base, run, entry["id"], openrouter_models)]
        }
        by_id, by_job = _profile_lookup(self.profile_records())
        return _attach_profile(view, by_id, by_job)

    def trial(self, job, trial, price=None) -> Optional[Dict[str, Any]]:
        schedule = prices.parse_schedule(price)
        self.library.maybe_sync()
        if not all(isinstance(n, str) and data.NAME.fullmatch(n) for n in (job, trial)):
            return None
        receipts = self.result_records()
        run = receipts.get(job)
        openrouter_models = self._openrouter_models()
        if run and run.get("result_owner"):
            detail = self.worker_read(run, "trial", trial)
            if detail and detail["row"]["status"] == "running" and run["status"] in {"failed", "cancelled", "interrupted"}:
                detail["row"].update(status="invalid", cause="execution: " + run["status"])
            if not detail:
                return None
            model = run.get("model")
            detail = {**detail, "result_owner": run["result_owner"]}
        else:
            if not run and self.library.worker_only(job):
                return None
            detail = self.library.trial_detail(job, trial)
            if detail is None:
                return None
            view = self.job_view(job, runs=receipts, price=prices.RECORDED)
            model = (run or {}).get("model") or (view or {}).get("model")
            for row in view["rows"] if view else []:
                if row["trial"] == trial:
                    detail["row"] = row
                    break
        recorded_price = (run or {}).get("model_price")
        base_row = detail["row"]
        rate = prices.rate_for(model, schedule, openrouter_models, recorded_price)
        detail["row"] = _reprice_row(base_row, rate, schedule)
        detail["pricing"] = {
            "schedule": schedule,
            "label": prices.SCHEDULE_LABELS[schedule],
            "rate": rate,
            "schedules": list(prices.SCHEDULES),
        }
        detail["costs_by_schedule"] = {}
        for entry in prices.SCHEDULES:
            sid = entry["id"]
            s_rate = prices.rate_for(model, sid, openrouter_models, recorded_price)
            s_row = _reprice_row(base_row, s_rate, sid)
            detail["costs_by_schedule"][sid] = {
                "schedule": sid,
                "label": entry["label"],
                "cost_usd": s_row.get("cost_usd"),
                "rate": s_rate,
            }
        return detail

    def profile(self, profile, price=None) -> Optional[Dict[str, Any]]:
        """A profile with every task's latest attempts and earlier runs."""
        schedule = prices.parse_schedule(price)
        self.library.maybe_sync()
        record = next((r for r in self.profile_records() if r["id"] == profile), None)
        if record is None:
            return None
        runs = self.runs()
        receipts = self.result_records()
        local_names = {r["name"] for r in runs}
        openrouter_models = self._openrouter_models()
        base_full = {}
        for item in record["items"]:
            view = self.job_view(item["run"], runs=receipts, price=prices.RECORDED) if item.get("run") else None
            if view is not None:
                base_full[view["name"]] = view
        full = {
            name: _reprice_view(view, receipts.get(name), schedule, openrouter_models)
            for name, view in base_full.items()
        }
        value = self.profile_summary(record, full)
        value["pricing"] = {
            "schedule": schedule,
            "label": prices.SCHEDULE_LABELS[schedule],
            "schedules": list(prices.SCHEDULES),
        }
        value["costs_by_schedule"] = self._profile_costs_by_schedule(record, base_full, receipts, openrouter_models)
        latest, history = latest_results(record, full)
        tasks = [{**task_group(task, rows, item, job), "history": history.get(key, [])}
                 for key, (item, job, rows) in latest.items() for task in [key[2]]]
        for item in value["items"]:
            item["local_run"] = item.get("run") in local_names
            if item["status"] in ("pending", "running") and item.get("run") not in full:
                tasks += [{"task": t, "job": None, "suite": item["suite"], "suite_name": item.get("suite_name"),
                           "model": item.get("model"), "attempts": [], "first_status": None, "passed": 0,
                           "valid": 0, "history": []}
                          for t in item.get("tasks") or [] if (item["suite"], item.get("model"), t) not in latest]
        value["tasks"] = sorted(tasks, key=lambda t: (t["suite"], t["model"] or "", t["task"]))
        return value

    def run(self, name, *, worker_log=False) -> Optional[Dict[str, Any]]:
        record = next((r for r in self.runs() if r["name"] == name), None)
        if not record:
            return None
        log = data.tail(self.manager.records / (record["name"] + ".log"))
        if worker_log and record.get("result_owner"):
            try:
                log += "\n" + (self.worker_read(record, "log") or "")
            except results.WorkerUnavailable as exc:
                return {**record, "log": log, "log_error": str(exc)}
        return {**record, "log": log}

    def launch(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.profiles.launch_now(request)

    def cancel(self, name) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.cancel(name)

    def queue_profile(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return public_profile(self.profiles.queue(request))

    def cancel_profile(self, profile) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.profiles.cancel(profile)

    def submission_action(self, profile, submission, action):
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.profiles.submission_action(profile, submission, action)

    def profile_item(self, profile, index, action) -> Dict[str, Any]:
        """Act on one queued dataset: `cancel` a waiting one, `stop` the running
        one, `resume` a stopped one with the tasks it has not finished, `run`
        an ended one again with all its tasks."""
        if not self.manager:
            raise ValueError(READ_ONLY)
        if action == "cancel":
            return self.profiles.cancel_item(profile, index)
        if action == "stop":
            return self.profiles.stop_item(profile, index)
        if action not in ("resume", "run"):
            raise ValueError("action 只能是 cancel、stop、resume 或 run")
        _, item = self.profiles.record_item(profile, index)
        tasks = item.get("tasks") or []
        if action == "resume":
            view = self.job_view(item["run"]) if item.get("run") else None
            finished = {}
            for row in view["rows"] if view else []:
                if row["status"] not in ("running", "invalid"):
                    finished[row["task"]] = finished.get(row["task"], 0) + 1
            tasks = [t for t in tasks if finished.get(t, 0) < (item.get("attempts") or 1)]
        return self.profiles.requeue_item(profile, index, tasks)

    def set_profile_concurrency(self, profile, concurrency) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.profiles.set_concurrency(profile, concurrency)

    def set_profile_auto_rerun(self, profile, enabled) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.profiles.set_auto_rerun(profile, enabled)

    def rename_profile(self, profile, name) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        if self.profiles.get(profile) is None and any(r["id"] == profile for r in self.profile_records()):
            raise ValueError(f"评测配置 {profile} 来自共用数据库里的其他 jobs 目录，请在那个 jobs 目录的工作台重命名")
        return self.profiles.rename(profile, name)

    def delete_profile(self, profile) -> Dict[str, Any]:
        manager = self.manager
        if not manager:
            raise ValueError(READ_ONLY)
        if not isinstance(profile, str) or not data.NAME.fullmatch(profile):
            raise ValueError("评测配置不存在")
        self.profiles.advance()
        with self.profiles.lock, manager.lock:
            record = next((r for r in self.profile_records() if r["id"] == profile), None)
            if record is None:
                raise ValueError("评测配置不存在")
            receipts = manager.runs()
            runs = runs_of(record, receipts + self.library.run_records())
            running = {r["name"] for r in receipts if r.get("status") in ACTIVE}
            if record["status"] in PROFILE_ACTIVE or running.intersection(runs):
                raise ValueError("评测配置还在运行，请先停止，结束后再删除")
            worker_jobs = {r["name"] for r in receipts + self.library.run_records() if r.get("result_owner")}
            self.library.delete_profile(profile, runs, manager.jobs_dir, self.profiles.path(profile),
                                        lambda protected: self._remove_run_files(runs, protected), worker_jobs)
        return {"id": profile, "deleted": True, "runs": runs}

    def delete_job(self, name) -> Dict[str, Any]:
        manager = self.manager
        if not manager:
            raise ValueError(READ_ONLY)
        if not isinstance(name, str) or not data.NAME.fullmatch(name):
            raise ValueError("作业不存在")
        self.profiles.advance()
        with self.profiles.lock, manager.lock:
            receipts = manager.runs()
            view = self.job_view(name, True, receipts, aggregate=True)
            if (view and view["running"]) or any(r["name"] == name and r.get("status") in ACTIVE for r in receipts):
                raise ValueError("作业还在运行，请先停止，结束后再删除")
            record = next((r for r in receipts if r["name"] == name), None) or self.library.run_record(name)
            worker_jobs = {name} if (record or {}).get("result_owner") else set()
            self.library.delete_job(name, manager.jobs_dir, lambda protected: self._forget_run(name, protected), worker_jobs)
        return {"name": name, "deleted": True}

    def _forget_run(self, name, worker_jobs) -> None:
        for record in self.profiles.records():
            items = [item for item in record["items"] if item.get("run") == name]
            for item in items:
                item["run"] = None
            if items:
                self.profiles.save(record)
        self._remove_run_files([name], worker_jobs)

    def _remove_run_files(self, runs, worker_jobs=()) -> None:
        manager = self.manager
        try:
            try:
                receipts = [manager.records / name for name in os.listdir(manager.records)
                            if name.rpartition(".")[0] in runs]
            except FileNotFoundError:
                receipts = []
            for run in runs:
                if run in worker_jobs:
                    hidden = manager.records / HIDDEN_WORKER_JOBS
                    hidden.mkdir(parents=True, exist_ok=True)
                    (hidden / run).touch()
                    continue
                try:
                    shutil.rmtree(manager.jobs_dir / run)
                except FileNotFoundError:
                    pass
            for path in sorted(receipts, key=lambda path: path.suffix == ".json"):
                path.unlink(missing_ok=True)
        except OSError as exc:
            raise ValueError(f"删除文件失败（{exc}），记录已保留，处理后可以重试") from None

    def monitor(self, executor=None) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        value = self.monitors.snapshot(settings(self.manager.config_path), executor or None,
                                       self.manager.config_path.parent, self.manager.jobs_dir)
        return {**value, "busy": any(run.get("status") in ACTIVE for run in self.manager.runs()),
                "setup_running": self.setups.mutating()}

    def save_mirrors(self, payload) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        with self.manager.lock:
            if self.setups.mutating():
                raise ValueError("一键配置正在进行，结束后再保存")
            name = monitor.save_mirrors(self.manager.config_path, payload)
        return self.monitor(name)

    def start_setup(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        # Under the launch lock: a launch and a setup that may restart
        # Docker never start at the same time.
        with self.manager.lock:
            busy = any(run.get("status") in ACTIVE for run in self.manager.runs())
            return self.setups.start(request, runtime_env(), str(RUNTIME_ROOT), busy=busy)

    def setup_status(self) -> Dict[str, Any]:
        return {"setup": self.setups.latest() if self.setups else None}

    def commits(self, query) -> Dict[str, Any]:
        """A branch's commits by time, each with the bundle already built from it."""
        if not self.manager:
            raise ValueError(READ_ONLY)
        cfg = settings(self.manager.config_path)
        bench_dir = self.manager.config_path.parent
        ref = query.get("ref") or "main"
        until = query.get("until") or None
        try:
            limit = int(query.get("limit") or builds.COMMIT_PAGE)
        except ValueError:
            raise ValueError("limit 应为整数") from None
        repo = cfg.get("source_repo")
        found = builds.commits(bench_dir / "git", repo, ref, until, limit)
        for entry in found:
            unit = builds.unit_path(bench_dir, entry["commit"])
            entry["bundle"] = unit.name if unit.is_dir() and builds.selectable(unit, repo) else None
        return {"ref": ref, "until": until, "commits": found}

    def start_build(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        if not isinstance(request, dict):
            raise ValueError("请求应为对象")
        executor = executors.find(settings(self.manager.config_path), request.get("executor"))
        return self.builds.start(request, executor.name, runtime_env(), str(RUNTIME_ROOT))

    def build_status(self) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return {"build": self.builds.latest()}

    def cancel_build(self) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.builds.cancel()

    def start_login(self) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.logins.start(runtime_env())

    def login_status(self) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.logins.status()

    def providers(self) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.providers.listing()

    def add_provider(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        probe = isinstance(request, dict) and request.get("probe") is True
        added = self.manager.add_provider(request)
        if probe and added["models"]:
            added["probe"] = self.manager.providers.probe(added["id"], added["models"][0]["name"])
        return added

    def remove_provider(self, provider_id) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.providers.remove(provider_id)

    def probe_provider(self, provider_id, model) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.providers.probe(provider_id, model)

    def store_status(self, can_edit) -> Dict[str, Any]:
        store = self.library.store
        with store.read() as tx:
            stale = int(tx.one("SELECT COUNT(*) FROM trials WHERE projection <> ?", (ingest.PROJECTION,))[0])
            latest = tx.one("SELECT MAX(ingested_at) FROM jobs")[0]
        try:
            import psycopg  # noqa: F401 - optional, PostgreSQL only
            psycopg_ready = True
        except ImportError:
            psycopg_ready = False
        manager = self.manager
        root = manager.config_path.parent if manager else None
        return {"database": store.describe(), "counts": store.counts(), "stale_projections": stale,
                "last_ingested_at": latest, "jobs_dirs": [str(r) for r in self.library.roots],
                "records_dir": str(manager.records) if manager else None,
                "configured": settings(manager.config_path).get("store") if manager else None,
                "default_sqlite": str(root / store_config.DEFAULT_SQLITE_NAME) if root else None,
                "config_path": str(manager.config_path) if manager else None,
                "psycopg": psycopg_ready, "can_edit": bool(manager) and can_edit}

    def store_action(self, payload) -> Dict[str, Any]:
        """Test a database, or switch the workbench to it (optionally migrating)."""
        manager, library = self.manager, self.library
        if manager is None:
            raise ValueError(READ_ONLY)
        if not isinstance(payload, dict) or set(payload) - {"action", "store", "migrate"}:
            raise ValueError("只接受 action、store、migrate")
        action = payload.get("action")
        if action not in ("test", "apply"):
            raise ValueError("action 必须是 test 或 apply")
        target = store_config.parse(payload.get("store"), manager.config_path.parent)
        if action == "test":
            if target.backend == "sqlite" and not target.path.exists():
                parent = next((p for p in [target.path.parent, *target.path.parent.parents] if p.exists()), None)
                if parent is None or not os.access(parent, os.W_OK):
                    raise ValueError("无法在该位置创建 SQLite 文件：" + str(target.path.parent))
                return {"ok": True, "exists": False, "database": target.describe(),
                        "message": "文件尚不存在，切换时新建"}
            probe = Store(target)
            try:
                return {"ok": True, "exists": True, "database": probe.describe(), "counts": probe.counts(),
                        "same": probe.same_database(library.store)}
            finally:
                probe.close()
        if self.profiles is not None:
            self.profiles.advance()
        with manager.lock:
            if any(run.get("status") in ACTIVE for run in manager.runs()) or (
                    self.profiles is not None and self.profiles.active_id()):
                raise ValueError("有评测正在运行，结束后再切换数据库")
            fresh = Store(target)
            try:
                if fresh.same_database(library.store):
                    fresh.close()
                    return {"switched": False, "unchanged": True, "database": fresh.describe()}
                report = migration.migrate(library.store, fresh) if payload.get("migrate") else None
                atomic_json(manager.config_path, {**settings(manager.config_path), "store": target.to_json()})
            except BaseException:
                fresh.close()
                raise
            previous = library.replace_store(fresh)
            previous.close()
        library.maybe_sync()
        return {"switched": True, "database": fresh.describe(), "migrated": report.to_json() if report else None}
