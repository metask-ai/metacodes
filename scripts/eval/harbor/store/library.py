"""The viewer's read path: job views, trial details and run records from the
store, kept current with the jobs directories the service watches.

Views are assembled by scripts/eval/harbor/bench/data.py from stored trial
rows; only elapsed times of still-running trials and jobs are refreshed at
read time, exactly as a file read at that moment would compute them.
"""
from __future__ import annotations

import datetime as dt
import json
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

from scripts.eval.harbor.store import ingest
from scripts.eval.harbor.store.backend import Store
from scripts.eval.harbor.bench import data

HIDDEN_WORKER_JOBS = ".hidden-worker-jobs"


def _refresh(row: Dict[str, Any], moment: dt.datetime) -> Dict[str, Any]:
    return data.refresh_running(row, moment)


class StoreLibrary:
    """Jobs, trials and runs addressed by validated names, read from a store."""

    def __init__(self, store: Store, roots: Iterable[Path] = (), *, owns_store: bool = False,
                 min_sync_interval: float = 2.0, log: Callable[[str], None] = ingest.stderr_log):
        self.store = store
        self.roots = [Path(root).expanduser().resolve() for root in roots]
        self.owns_store = owns_store
        self.min_sync_interval = min_sync_interval
        self.log = log
        self._sync_lock = threading.Lock()
        self._last_sync: Optional[float] = None
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None

    # ------------------------------------------------------------------- sync

    def sync(self, *, verify: bool = False) -> List[ingest.RootResult]:
        """Ingest every watched jobs directory, then refresh stale projections."""
        with self._sync_lock:
            return self._sync(verify)

    def _sync(self, verify: bool) -> List[ingest.RootResult]:
        results = []
        for root in self.roots:
            try:
                results.append(ingest.ingest_root(self.store, root, verify=verify, wait=False, log=self.log))
            except ValueError as exc:
                self.log("bench store: " + str(exc))
        ingest.refresh_projections(self.store, self.log)
        self._last_sync = time.monotonic()
        return results

    def maybe_sync(self) -> None:
        """Before a read: sync unless one ran moments ago or is running now."""
        if self._last_sync is not None and time.monotonic() - self._last_sync < self.min_sync_interval:
            return
        if not self._sync_lock.acquire(blocking=False):
            return
        try:
            self._sync(False)
        except Exception as exc:
            self.log(f"bench store: sync failed: {type(exc).__name__}: {exc}")
        finally:
            self._sync_lock.release()

    def start_background(self, interval: float = 10.0) -> None:
        """Sync now and every `interval` seconds on a daemon thread."""

        def loop() -> None:
            while True:
                try:
                    self.sync()
                except Exception as exc:
                    self.log(f"bench store: sync failed: {type(exc).__name__}: {exc}")
                if self._stop.wait(interval):
                    return

        self._thread = threading.Thread(target=loop, name="bench-store-sync", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        if self.owns_store:
            # A sync in flight finishes first; it owns pooled connections.
            with self._sync_lock:
                self.store.close()

    # ------------------------------------------------------------------- read

    def job_names(self) -> List[str]:
        with self.store.read() as tx:
            return sorted(row[0] for row in tx.query("SELECT name FROM jobs"))

    def _views(self, names: Optional[List[str]], with_rows: bool) -> Dict[str, Dict[str, Any]]:
        moment = dt.datetime.now(dt.timezone.utc)
        with self.store.read() as tx:
            if names is None:
                headers = tx.query("SELECT name, header_json FROM jobs")
                trials = tx.query("SELECT job, name, row_json FROM trials")
            else:
                headers, trials = [], []
                for name in names:
                    headers += tx.query("SELECT name, header_json FROM jobs WHERE name = ?", (name,))
                    trials += tx.query("SELECT job, name, row_json FROM trials WHERE job = ?", (name,))
        rows: Dict[str, List[Tuple[str, Dict[str, Any]]]] = {}
        for job, key, row_json in trials:
            rows.setdefault(job, []).append((key, _refresh(json.loads(row_json), moment)))
        views = {}
        for name, header_json in headers:
            # data.trial_dirs' order: by name, then by path (the key).
            job_rows = [row for _, row in sorted(rows.get(name, []), key=lambda item: (item[1]["trial"], item[0]))]
            views[name] = data.assemble_view(json.loads(header_json), job_rows, with_rows)
        return views

    def job_view(self, name: Any, with_rows: bool = True) -> Optional[Dict[str, Any]]:
        if not isinstance(name, str) or not data.NAME.match(name):
            return None
        return self._views([name], with_rows).get(name)

    def overview(self) -> List[Dict[str, Any]]:
        views = list(self._views(None, False).values())
        return sorted(views, key=lambda view: view["started_at"] or "", reverse=True)

    def trial_record(self, job: Any, trial: Any) -> Optional[Tuple[str, str, str]]:
        if not all(isinstance(v, str) and data.NAME.match(v) for v in (job, trial)):
            return None
        with self.store.read() as tx:
            found = tx.query("SELECT name, projection, detail_json FROM trials WHERE job = ? AND (name = ? OR "
                             "substr(name, length(name) - length(?)) = ?)", (job, trial, trial, "/" + trial))
        return min(found) if found else None

    def trial_detail(self, job: Any, trial: Any) -> Optional[Dict[str, Any]]:
        found = self.trial_record(job, trial)
        if not found:
            return None
        detail = json.loads(found[2])
        _refresh(detail["row"], dt.datetime.now(dt.timezone.utc))
        return detail

    def trial_view(self, name, trial):
        detail = self.trial_detail(name, trial)
        if detail:
            view = self.job_view(name)
            for row in view["rows"] if view else ():
                if row["trial"] == trial:
                    detail["row"] = row
                    break
        return detail

    def worker_only(self, name=None):
        query = ("SELECT w.job, j.source_dir FROM worker_jobs w JOIN jobs j ON j.name = w.job "
                 "WHERE NOT EXISTS (SELECT 1 FROM runs WHERE name = w.job)")
        args = []
        if name is not None:
            query += " AND w.job = ?"
            args.append(name)
        with self.store.read() as tx:
            rows = tx.query(query, args)
        hidden = set()
        for job, source in rows:
            path = Path(source)
            if (path.name != job or path.parent not in self.roots or not ingest.is_job_dir(path)
                    or (path.parent / ".bench-runs" / HIDDEN_WORKER_JOBS / job).exists()):
                hidden.add(job)
        return hidden

    def _protected_jobs(self, jobs, receipts):
        with self.store.read() as tx:
            return set(receipts).union(job for job in jobs if tx.one("SELECT 1 FROM worker_jobs WHERE job = ?", (job,)))

    def run_record(self, name: Any) -> Optional[Dict[str, Any]]:
        if not isinstance(name, str) or not data.NAME.match(name):
            return None
        with self.store.read() as tx:
            row = tx.one("SELECT record_json FROM runs WHERE name = ?", (name,))
        return json.loads(row[0]) if row else None

    def profile_records(self) -> List[Dict[str, Any]]:
        with self.store.read() as tx:
            rows = tx.query("SELECT record_json FROM profiles")
        return [json.loads(row[0]) for row in rows]

    def run_records(self) -> List[Dict[str, Any]]:
        with self.store.read() as tx:
            rows = tx.query("SELECT record_json FROM runs")
        return [json.loads(row[0]) for row in rows]

    def delete_profile(self, profile: str, jobs: List[str], jobs_dir: Path, manifest: Path,
                       remove_files: Callable[[set], None], worker_jobs=()) -> None:
        """Delete a profile this jobs directory owns: its job files, then its
        rows, then its manifest, so a failure at any step leaves a profile
        that a retry finds and finishes."""
        jobs_dir = Path(jobs_dir).resolve()
        with self._sync_lock, ingest.root_lock(jobs_dir, wait=False):
            worker_jobs = self._protected_jobs(jobs, worker_jobs)
            owners = [("profiles", "id", profile, jobs_dir / ingest.PROFILES_DIR)] + _job_owners(jobs, jobs_dir, worker_jobs)
            sources = self._owned_sources(owners, f"评测配置 {profile}")
            if sources[("profiles", profile)] is None and not manifest.exists():
                raise ValueError("评测配置不存在")
            remove_files(worker_jobs)
            with self.store.transaction() as tx:
                _delete_job_rows(tx, jobs, worker_jobs)
                tx.execute("DELETE FROM profiles WHERE id = ?", (profile,))
            try:
                manifest.unlink(missing_ok=True)
            except OSError as exc:
                raise ValueError(f"删除评测配置清单失败（{exc}），可以重试") from None

    def delete_job(self, job: str, jobs_dir: Path, remove_files: Callable[[set], None], worker_jobs=()) -> None:
        """Delete one job this jobs directory owns: its files (`remove_files`
        also unlinks it from the profile manifests), then in one transaction
        its rows and its links from this directory's profile rows, so a
        failure leaves a job that a retry finds and finishes."""
        jobs_dir = Path(jobs_dir).resolve()
        with self._sync_lock, ingest.root_lock(jobs_dir, wait=False):
            worker_jobs = self._protected_jobs([job], worker_jobs)
            sources = self._owned_sources(_job_owners([job], jobs_dir, worker_jobs), f"作业 {job}")
            owner = "runs" if job in worker_jobs else "jobs"
            if sources[(owner, job)] is None:
                raise ValueError("作业不存在")
            remove_files(worker_jobs)
            with self.store.transaction() as tx:
                _delete_job_rows(tx, [job], worker_jobs)
                profiles = tx.query("SELECT id, record_json FROM profiles WHERE source_dir = ?",
                                    (str(jobs_dir / ingest.PROFILES_DIR),))
                for profile, record_json in profiles:
                    record = json.loads(record_json)
                    changed = False
                    for item in record.get("items") or []:
                        if item.get("run") == job:
                            item["run"] = None
                            changed = True
                        for field in ("resumed_runs", "previous_runs"):
                            values = item.get(field)
                            if isinstance(values, list) and job in values:
                                kept = [entry for entry in values if entry != job]
                                if kept:
                                    item[field] = kept
                                else:
                                    item.pop(field, None)
                                changed = True
                    if changed:
                        tx.execute("UPDATE profiles SET record_json = ? WHERE id = ?", (ingest._json(record), profile))

    def _owned_sources(self, owners, label: str):
        with self.store.read() as tx:
            sources = {(table, value): tx.one(f"SELECT source_dir FROM {table} WHERE {key} = ?", (value,))
                       for table, key, value, _ in owners}
        for table, _, value, source in owners:
            row = sources[(table, value)]
            if row and row[0] != str(source):
                raise ValueError(f"{label} 的数据来自 {Path(row[0]).parent}，请在那个 jobs 目录的工作台删除")
        return sources

    def replace_store(self, store: Store) -> Store:
        """Serve from `store` from now on; returns the previous store, which
        the caller closes. A sync in flight finishes on the old one first."""
        with self._sync_lock:
            previous, self.store = self.store, store
            self._last_sync = None
        return previous

    def storage(self) -> Dict[str, Any]:
        return {"jobs_dirs": [str(root) for root in self.roots], "database": self.store.describe()}


def _job_owners(jobs: List[str], jobs_dir: Path, worker_jobs):
    owners = []
    for job in jobs:
        owners.append(("runs", "name", job, jobs_dir / ".bench-runs"))
        if job not in worker_jobs:
            owners.append(("jobs", "name", job, jobs_dir / job))
    return owners


def _delete_job_rows(tx, jobs: List[str], worker_jobs=()) -> None:
    digests: List[str] = []
    for job in jobs:
        digests += [d for row in tx.query("SELECT spec_sha256, log_sha256 FROM runs WHERE name = ?", (job,)) for d in row]
        tx.execute("DELETE FROM runs WHERE name = ?", (job,))
        if job not in worker_jobs:
            digests += [d for row in tx.query("SELECT sha256, tail_sha256 FROM files WHERE job = ?", (job,)) for d in row]
            tx.execute("DELETE FROM jobs WHERE name = ? AND NOT EXISTS (SELECT 1 FROM worker_jobs WHERE job = ?)", (job, job))
    ingest.collect_garbage(tx, digests)
