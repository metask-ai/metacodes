"""The Bench runtime as one object: what every presentation reads and asks.

The web page (`viewer/server.py`) and the CLI (`cli.py`) only present what
this returns. A workbench without a RunManager is read-only: it lists jobs
on disk and refuses launches. Names are checked against the jobs on disk,
so no caller can read outside them.
"""
from __future__ import annotations

from typing import Any, Dict, Optional

from scripts.eval.harbor.bench import data

READ_ONLY_CATALOG = {"service": "metacodes-bench", "schema_version": 1, "ready": False,
                     "reasons": ["当前服务为只读模式"], "runs": []}


class Workbench:
    def __init__(self, library: data.Library, manager=None):
        self.library = library
        self.manager = manager

    @property
    def can_launch(self) -> bool:
        return self.manager is not None

    def runs(self):
        return self.manager.runs() if self.manager else []

    def catalog(self) -> Dict[str, Any]:
        return self.manager.catalog() if self.manager else dict(READ_ONLY_CATALOG)

    def job_view(self, path, with_rows=True, runs=None) -> Dict[str, Any]:
        """A job as Harbor wrote it, corrected by its durable worker outcome."""
        view = data.job_view(path)
        run = next((r for r in (self.runs() if runs is None else runs) if r["name"] == path.name), None)
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
        if not with_rows:
            view.pop("rows", None)
        return view

    def jobs(self) -> Dict[str, Any]:
        runs = self.runs()  # one scan of the run records for every job
        jobs = [self.job_view(p, False, runs) for p in self.library.jobs().values()]
        jobs.sort(key=lambda view: view["started_at"] or "", reverse=True)
        return {"jobs": jobs, "runs": runs,
                "summary": data.merge_summaries(j["summary"] for j in jobs),
                "storage": {"jobs_dirs": [str(root) for root in self.library.roots],
                            "records_dir": str(self.manager.records) if self.manager else None,
                            "format": "Harbor JSON / JSONL"}}

    def job(self, name: str) -> Optional[Dict[str, Any]]:
        job_dir = self.library.job_dir(name)
        return None if job_dir is None else self.job_view(job_dir)

    def trial(self, job: str, trial: str) -> Optional[Dict[str, Any]]:
        trial_dir = self.library.trial_dir(job, trial)
        if trial_dir is None:
            return None
        detail = data.trial_detail(trial_dir)
        for row in self.job_view(trial_dir.parent)["rows"]:
            if row["trial"] == trial_dir.name:
                detail["row"] = row
                break
        return detail

    def run(self, name) -> Optional[Dict[str, Any]]:
        record = next((r for r in self.runs() if r["name"] == name), None)
        if not record:
            return None
        return {**record, "log": data.tail(self.manager.records / (record["name"] + ".log"))}

    def launch(self, request) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError("当前服务为只读模式")
        return self.manager.launch(request)

    def cancel(self, name) -> Dict[str, Any]:
        if not self.manager:
            raise ValueError("当前服务为只读模式")
        return self.manager.cancel(name)
