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


def _refresh(row: Dict[str, Any], moment: dt.datetime) -> Dict[str, Any]:
    started = data.parse_time(row.get("started_at"))
    if started is not None and row.get("finished_at") is None:
        row["elapsed_s"] = (moment - started).total_seconds()
    return row


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
                results.append(ingest.ingest_root(self.store, root, verify=verify, log=self.log))
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

    def trial_detail(self, job: Any, trial: Any) -> Optional[Dict[str, Any]]:
        if not all(isinstance(v, str) and data.NAME.match(v) for v in (job, trial)):
            return None
        # A trial is keyed by its directory; the page names it by the
        # directory's name. A name repeated in two nested runs resolves like
        # data.Library.trial_dir: the first by path.
        with self.store.read() as tx:
            found = tx.query("SELECT name, detail_json FROM trials WHERE job = ? AND (name = ? OR "
                             "substr(name, length(name) - length(?)) = ?)", (job, trial, trial, "/" + trial))
        if not found:
            return None
        detail = json.loads(min(found)[1])
        _refresh(detail["row"], dt.datetime.now(dt.timezone.utc))
        return detail

    def run_record(self, name: Any) -> Optional[Dict[str, Any]]:
        if not isinstance(name, str) or not data.NAME.match(name):
            return None
        with self.store.read() as tx:
            row = tx.one("SELECT record_json FROM runs WHERE name = ?", (name,))
        return json.loads(row[0]) if row else None

    def batch_records(self) -> List[Dict[str, Any]]:
        with self.store.read() as tx:
            rows = tx.query("SELECT record_json FROM batches")
        return [json.loads(row[0]) for row in rows]

    def run_records(self) -> List[Dict[str, Any]]:
        with self.store.read() as tx:
            rows = tx.query("SELECT record_json FROM runs")
        return [json.loads(row[0]) for row in rows]

    def delete_batch(self, batch_id: str, jobs: List[str], remove_files: Callable[[], None]) -> None:
        with self._sync_lock:
            remove_files()
            with self.store.transaction() as tx:
                for job in jobs:
                    tx.execute("DELETE FROM runs WHERE name = ?", (job,))
                    tx.execute("DELETE FROM jobs WHERE name = ?", (job,))
                tx.execute("DELETE FROM batches WHERE id = ?", (batch_id,))

    def replace_store(self, store: Store) -> Store:
        """Serve from `store` from now on; returns the previous store, which
        the caller closes. A sync in flight finishes on the old one first."""
        with self._sync_lock:
            previous, self.store = self.store, store
            self._last_sync = None
        return previous

    def storage(self) -> Dict[str, Any]:
        return {"jobs_dirs": [str(root) for root in self.roots], "database": self.store.describe()}
