"""The Bench runtime as one object: what every presentation reads and asks.

The web page (`viewer/server.py`) and the CLI (`cli.py`) only present what
this returns. Jobs are read from the evaluation store, which follows the jobs
directories. A workbench without a RunManager is read-only: it lists jobs
and refuses launches. Names are looked up in the store, never used as paths.
"""
from __future__ import annotations

import datetime as dt
import os
import shutil
from pathlib import Path
from typing import Any, Dict, Optional

from scripts.eval.harbor import suites
from scripts.eval.harbor.bench import builds, data, executors
from scripts.eval.harbor.bench.batches import BATCH_ACTIVE, BatchManager, public as public_batch
from scripts.eval.harbor.bench.runner import ACTIVE, atomic_json, runtime_env, settings
from scripts.eval.harbor.bench.setup import LoginManager, SetupManager
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store import ingest
from scripts.eval.harbor.store import migrate as migration
from scripts.eval.harbor.store.backend import Store, open_ephemeral
from scripts.eval.harbor.store.library import StoreLibrary

RUNTIME_ROOT = Path(__file__).resolve().parents[4]
READ_ONLY = "当前服务为只读模式"
READ_ONLY_CATALOG = {"service": "metacodes-bench", "schema_version": 1, "ready": False,
                     "reasons": [READ_ONLY], "runs": []}
ATTEMPT_FIELDS = ("trial", "status", "cause", "reward", "attempt_number", "first_attempt", "total_tokens",
                  "initial_input_tokens", "input_tokens", "output_tokens", "elapsed_s", "turns", "tool_calls", "tests")


def _mean(values):
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def task_groups(view, item):
    """A job's trials grouped by task, attempts in order, for a batch."""
    groups = {}
    for row in view.get("rows") or []:
        group = groups.setdefault(row["task"], {"task": row["task"], "job": view["name"], "suite": item["suite"],
                                                "suite_name": item.get("suite_name"), "attempts": []})
        group["attempts"].append({k: row.get(k) for k in ATTEMPT_FIELDS})
    for group in groups.values():
        attempts = sorted(group["attempts"], key=lambda a: a.get("attempt_number") or 0)
        group["attempts"] = attempts
        group["first_status"] = attempts[0]["status"] if attempts else None
        group["passed"] = sum(a["status"] == "pass" for a in attempts)
        group["valid"] = sum(a["status"] in data.VALID for a in attempts)
        for key in ("total_tokens", "initial_input_tokens", "elapsed_s", "turns", "tool_calls"):
            group["mean_" + key] = _mean(a.get(key) for a in attempts)
    return sorted(groups.values(), key=lambda g: g["task"])


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
        if manager is not None:
            manager.setup_running = self.setups.mutating
            if getattr(manager, "batches", None) is None:
                manager.batches = BatchManager(manager)
        self.batches = manager.batches if manager is not None else None

    @property
    def can_launch(self) -> bool:
        return self.manager is not None

    def start_batches(self) -> None:
        """Batches advance on their own: a dataset ends, the next one starts."""
        if self.batches is not None:
            self.batches.start()

    def sync_in_background(self) -> None:
        """Historical imports can take a while; a service serves meanwhile."""
        self.library.start_background()

    def close(self) -> None:
        if self.batches is not None:
            self.batches.stop()
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

    def job_view(self, name, with_rows=True, runs=None) -> Optional[Dict[str, Any]]:
        """A stored job, labelled by its launch and corrected by its durable worker outcome."""
        view = self.library.job_view(name)
        if view is None:
            return None
        run = next((r for r in (self.runs() if runs is None else runs) if r["name"] == name), None)
        run = run or self.library.run_record(name)
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
            for row in view["rows"]:
                if row["status"] == "running":
                    row.update(status="invalid", cause="execution: " + run["status"])
            view["summary"] = data.summarize(view["rows"])
            started, finished = data.parse_time(view.get("started_at")), data.parse_time(run.get("finished_at"))
            if finished:
                view["finished_at"] = finished.isoformat()
                view["wall_s"] = (finished - started).total_seconds() if started else None
        view["batch"] = (run or {}).get("batch")
        view["metacodes"] = (run or {}).get("metacodes")
        if not with_rows:
            view.pop("rows", None)
        return view

    def batch_records(self):
        found = {r["id"]: r for r in self.library.batch_records() if isinstance(r, dict) and r.get("id")}
        if self.batches is not None:
            found.update((r["id"], r) for r in self.batches.records())
        return sorted(found.values(), key=lambda r: r.get("created_at") or "", reverse=True)

    def batch_summary(self, record, views) -> Dict[str, Any]:
        """A batch's card: its record, each dataset's job, the pooled summary."""
        value = public_batch(record)
        summaries, done, planned = [], 0, 0
        for item in value["items"]:
            view = views.get(item.get("run")) if item.get("run") else None
            planned += len(item.get("tasks") or []) * int(record.get("attempts") or 1)
            if view is not None:
                summaries.append(view["summary"])
                done += view["summary"]["trials"] - view["summary"]["counts"]["running"]
                item["job"] = {k: view.get(k) for k in ("name", "planned", "running", "wall_s", "started_at",
                                                        "finished_at", "dataset", "execution_status")}
                item["job"]["summary"] = {k: v for k, v in view["summary"].items() if k != "ttft_samples_ms"}
        value["summary"] = data.merge_summaries(summaries)
        value["progress"] = {"done": done, "planned": planned}
        started, finished = data.parse_time(record.get("started_at")), data.parse_time(record.get("finished_at"))
        value["wall_s"] = ((finished or dt.datetime.now(dt.timezone.utc)) - started).total_seconds() \
            if started else None
        return value

    def jobs(self, scope="all") -> Dict[str, Any]:
        """Every job, newest first; `scope` is a batch id, "none" or "all"."""
        self.library.maybe_sync()
        runs = self.runs()  # one scan of the run records for every job
        jobs = [view for view in (self.job_view(name, False, runs) for name in self.library.job_names()) if view]
        jobs.sort(key=lambda view: view["started_at"] or "", reverse=True)
        views = {view["name"]: view for view in jobs}
        batches = [self.batch_summary(record, views) for record in self.batch_records()]
        if scope == "none":
            shown = [j for j in jobs if not j.get("batch")]
        elif scope != "all":
            shown = [j for j in jobs if j.get("batch") == scope]
        else:
            shown = jobs
        storage = self.library.storage()
        return {"jobs": shown, "job_total": len(jobs), "scope": scope, "batches": batches, "runs": runs,
                "summary": data.merge_summaries(j["summary"] for j in shown),
                "storage": {**storage,
                            "records_dir": str(self.manager.records) if self.manager else None,
                            "format": storage["database"]["format"]}}

    def overview(self):
        """Every stored job, newest first, as Harbor wrote it."""
        self.library.maybe_sync()
        return self.library.overview()

    def job(self, name) -> Optional[Dict[str, Any]]:
        self.library.maybe_sync()
        return self.job_view(name)

    def trial(self, job, trial) -> Optional[Dict[str, Any]]:
        self.library.maybe_sync()
        detail = self.library.trial_detail(job, trial)
        if detail is None:
            return None
        view = self.job_view(job)
        for row in view["rows"] if view else []:
            if row["trial"] == trial:
                detail["row"] = row
                break
        return detail

    def batch(self, batch_id) -> Optional[Dict[str, Any]]:
        """A batch with every dataset's tasks and their attempts."""
        self.library.maybe_sync()
        record = next((r for r in self.batch_records() if r["id"] == batch_id), None)
        if record is None:
            return None
        full = {}
        for item in record["items"]:
            view = self.job_view(item["run"]) if item.get("run") else None
            if view is not None:
                full[view["name"]] = view
        value = self.batch_summary(record, full)
        tasks = []
        for item in value["items"]:
            view = full.get(item.get("run"))
            if view is not None:
                tasks += task_groups(view, item)
            else:
                tasks += [{"task": t, "job": None, "suite": item["suite"], "suite_name": item.get("suite_name"),
                           "attempts": [], "first_status": None, "passed": 0, "valid": 0}
                          for t in item.get("tasks") or []]
        value["tasks"] = tasks
        return value

    def run(self, name) -> Optional[Dict[str, Any]]:
        record = next((r for r in self.runs() if r["name"] == name), None)
        if not record:
            return None
        return {**record, "log": data.tail(self.manager.records / (record["name"] + ".log"))}

    def launch(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.launch(request)

    def cancel(self, name) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.manager.cancel(name)

    def create_batch(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return public_batch(self.batches.create(request))

    def cancel_batch(self, batch_id) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        return self.batches.cancel(batch_id)

    def rename_batch(self, batch_id, name) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError(READ_ONLY)
        if self.batches.get(batch_id) is None and any(r["id"] == batch_id for r in self.batch_records()):
            raise ValueError(f"批次 {batch_id} 来自共用数据库里的其他 jobs 目录，请在那个 jobs 目录的工作台重命名")
        return self.batches.rename(batch_id, name)

    def delete_batch(self, batch_id) -> Dict[str, Any]:
        manager = self.manager
        if not manager:
            raise ValueError(READ_ONLY)
        if not isinstance(batch_id, str) or not data.NAME.fullmatch(batch_id):
            raise ValueError("批次不存在")
        with self.batches.lock, manager.lock:
            record = next((r for r in self.batch_records() if r["id"] == batch_id), None)
            if record is None:
                raise ValueError("批次不存在")
            receipts = manager.runs()
            names = {item.get("run") for item in record["items"]} | set(self.library.batch_runs(batch_id))
            names |= {r["name"] for r in receipts if r.get("batch") == batch_id}
            runs = sorted(n for n in names if isinstance(n, str) and data.NAME.fullmatch(n))
            running = {r["name"] for r in receipts if r.get("status") in ACTIVE}
            if record["status"] in BATCH_ACTIVE or running.intersection(runs):
                raise ValueError("批次还在运行，请先取消，结束后再删除")
            self.library.delete_batch(batch_id, runs, manager.jobs_dir, self.batches.path(batch_id),
                                      lambda: self._remove_run_files(runs))
        return {"id": batch_id, "deleted": True, "runs": runs}

    def _remove_run_files(self, runs) -> None:
        manager = self.manager
        try:
            try:
                receipts = [manager.records / name for name in os.listdir(manager.records)
                            if name.rpartition(".")[0] in runs]
            except FileNotFoundError:
                receipts = []
            for run in runs:
                try:
                    shutil.rmtree(manager.jobs_dir / run)
                except FileNotFoundError:
                    pass
            for path in sorted(receipts, key=lambda path: path.suffix == ".json"):
                path.unlink(missing_ok=True)
        except OSError as exc:
            raise ValueError(f"删除文件失败（{exc}），批次已保留，处理后可以重试") from None

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
        with manager.lock:
            if any(run.get("status") in ACTIVE for run in manager.runs()) or (
                    self.batches is not None and self.batches.active_id()):
                raise ValueError("有评测或批次正在运行，结束后再切换数据库")
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
