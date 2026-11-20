"""Batches: one frozen metacodes version evaluated on several datasets.

A batch freezes the Linux bundle it was created with: the bundle is copied,
once per content digest, to `<state>/bundles/frozen/<digest>/` and made
read-only, and every dataset of the batch runs that copy. Rebuilding the
configured bundle (`bench setup` overlays a checkout in place) or switching
`workbench.json` to another version never changes a batch already created;
before each launch the copy is checked against its digest.

The datasets run one after another, each as an ordinary workbench run (a
Harbor job) whose record names the batch. The durable state is
`<jobs>/.bench-batches/<id>.json`, rewritten atomically; the scheduler
thread only advances what that file says, so a restarted service resumes a
batch where it stopped. The store ingests the records (`batches` table).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
import shutil
import threading
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from scripts.eval.harbor import suites
from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.store.ingest import BATCHES_DIR
from scripts.eval.harbor.bench import builds, data, executors
from scripts.eval.harbor.bench.runner import ACTIVE, atomic_json, now, settings

MAX_ITEMS = 16
NAME_LIMIT = 80
BATCH_ACTIVE = ("queued", "running", "cancelling")
ITEM_DONE = ("finished", "failed", "cancelled", "interrupted", "skipped")
DEV_NAME = re.compile(r"^metacodes-dev-([0-9a-f]{7,40}|worktree)-")


# ------------------------------------------------------------------ versions


def bundle_label(path: Path, manifest: Dict[str, Any], source: Optional[Dict[str, Any]] = None) -> str:
    """How the page names a metacodes bundle: a release version, or the
    checkout commit a development overlay was built from."""
    release = (manifest.get("release") or {}).get("version") if isinstance(manifest.get("release"), dict) else None
    if isinstance(source, dict) and source.get("kind") == "checkout-overlay":
        base = source.get("base_release") or release
        return f"dev {source.get('commit')}" + (f"（基于 {base}）" if base else "")
    match = DEV_NAME.match(Path(path).name)
    if match:
        return f"dev {match.group(1)}" + (f"（基于 {release}）" if release else "")
    if isinstance(source, dict) and source.get("kind") == "release" and source.get("version"):
        return str(source["version"])
    return str(release or Path(path).name)


def bundle_commit(path: Path, manifest: Dict[str, Any], source: Optional[Dict[str, Any]] = None) -> Optional[str]:
    if isinstance(source, dict) and source.get("commit"):
        return str(source["commit"])
    match = DEV_NAME.match(Path(path).name)
    if match and match.group(1) != "worktree":
        return match.group(1)
    commit = (manifest.get("source") or {}).get("commit") if isinstance(manifest.get("source"), dict) else None
    return str(commit) if commit else None


def bundle_choices(cfg: Dict[str, Any], config_path: Path) -> List[Dict[str, Any]]:
    """The bundles a batch can freeze: the configured one first, then every
    valid bundle under `<state>/bundles/` (never the frozen copies)."""
    choices: List[Dict[str, Any]] = []
    seen = set()

    def add(path: Any, source: Optional[Dict[str, Any]], current: bool) -> None:
        try:
            resolved = Path(path).expanduser().resolve()
        except (OSError, RuntimeError, TypeError):
            return
        if resolved in seen or any(c["id"] == resolved.name for c in choices):
            return
        try:
            manifest = check_bundle(resolved)
        except ValueError:
            return
        if not builds.selectable(resolved, cfg.get("source_repo")):
            return
        seen.add(resolved)
        choices.append({"id": resolved.name, "path": str(resolved), "current": current,
                        "label": bundle_label(resolved, manifest, source),
                        "commit": bundle_commit(resolved, manifest, source),
                        "source": source if isinstance(source, dict) else None})

    if cfg.get("bundle"):
        add(cfg["bundle"], cfg.get("bundle_source"), True)
    root = Path(config_path).parent / "bundles"
    try:
        children = sorted(root.iterdir())
    except OSError:
        children = []
    for child in children:
        if child.is_dir() and not child.is_symlink() and child.name != "frozen" and ".staging" not in child.name \
                and ".tmp-" not in child.name:
            add(child, None, False)
    return choices


def current_metacodes(cfg: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """The configured bundle, unfrozen, as a run record names it."""
    path = cfg.get("bundle")
    if not path:
        return None
    try:
        manifest = check_bundle(Path(path))
    except ValueError:
        return None
    source = cfg.get("bundle_source")
    return {"label": bundle_label(Path(path), manifest, source), "commit": bundle_commit(Path(path), manifest, source),
            "bundle": str(path), "frozen": False}


def bundle_files(root: Path) -> List[str]:
    return executors.tree_files(root)


def frozen_digest(root: Path) -> str:
    return executors.tree_digest(root, bundle_files(root))


def freeze(choice: Dict[str, Any], config_path: Path) -> Dict[str, Any]:
    """Copy a bundle, once per content digest, to an immutable location and
    describe it. The copy is verified before it is published."""
    source_path = Path(choice["path"])
    digest = frozen_digest(source_path)
    root = Path(config_path).parent / "bundles" / "frozen"
    target = root / digest
    marker = root / (digest + ".json")
    if not (marker.is_file() and target.is_dir() and frozen_digest(target) == digest):
        root.mkdir(parents=True, exist_ok=True)
        staging = root / (digest + ".tmp-" + uuid.uuid4().hex[:8])
        try:
            shutil.copytree(source_path, staging, symlinks=True)
            if frozen_digest(staging) != digest:
                raise ValueError("冻结 metacodes 版本时发行包发生了变化，请稍后重试")
            for name in bundle_files(staging):
                path = staging / name
                path.chmod(path.stat().st_mode & ~0o222)
            if target.exists():
                shutil.rmtree(target, ignore_errors=True)
            staging.replace(target)
        finally:
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
    manifest = check_bundle(target)
    binary = target / "bin" / "metacodes"
    info = {"label": choice["label"], "commit": choice.get("commit"), "digest": digest, "bundle": str(target),
            "source_bundle": str(source_path), "release": (manifest.get("release") or {}).get("version")
            if isinstance(manifest.get("release"), dict) else None,
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else None,
            "frozen": True}
    if not marker.is_file():
        atomic_json(marker, {**info, "frozen_at": now()})
    return info


# ------------------------------------------------------------------- batches


def _new_id() -> str:
    return "batch-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]


class BatchManager:
    """Durable batches over a RunManager; one batch advances at a time."""

    def __init__(self, runs):
        self.runs = runs
        self.dir = runs.jobs_dir / BATCHES_DIR
        self.lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: Optional[threading.Thread] = None
        runs.batch_guard = self.active_id

    # ---------------------------------------------------------------- records

    def path(self, batch_id: str) -> Path:
        return self.dir / (batch_id + ".json")

    def save(self, record: Dict[str, Any]) -> None:
        atomic_json(self.path(record["id"]), record)

    def records(self) -> List[Dict[str, Any]]:
        found = []
        try:
            paths = sorted(self.dir.glob("*.json"))
        except OSError:
            return []
        for path in paths:
            value = data.read_json(path)
            if isinstance(value, dict) and value.get("id") == path.stem and data.NAME.fullmatch(path.stem):
                found.append(value)
        return sorted(found, key=lambda r: r.get("created_at", ""), reverse=True)

    def get(self, batch_id: Any) -> Optional[Dict[str, Any]]:
        if not isinstance(batch_id, str) or not data.NAME.fullmatch(batch_id):
            return None
        value = data.read_json(self.path(batch_id))
        return value if isinstance(value, dict) and value.get("id") == batch_id else None

    def active_id(self) -> Optional[str]:
        """The batch that owns the executor now (reads files only, no lock:
        RunManager.launch calls this under its own lock)."""
        active = [r for r in self.records() if r.get("status") in BATCH_ACTIVE]
        return min(active, key=lambda r: r.get("created_at", ""))["id"] if active else None

    # ----------------------------------------------------------------- create

    def create(self, request: Any) -> Dict[str, Any]:
        allowed = {"name", "model", "executor", "attempts", "concurrency", "bundle", "items"}
        if not isinstance(request, dict) or set(request) - allowed:
            raise ValueError("批次只接受 name、model、executor、attempts、concurrency、bundle、items")
        name = request.get("name") or ""
        if not isinstance(name, str) or len(name) > NAME_LIMIT or any(ord(c) < 32 for c in name):
            raise ValueError(f"批次名称最多 {NAME_LIMIT} 个字符")
        items = request.get("items")
        if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
            raise ValueError(f"批次需要 1–{MAX_ITEMS} 个评测集")
        attempts, concurrency = request.get("attempts", 1), request.get("concurrency", 1)
        if type(concurrency) is not int or not 1 <= concurrency <= 16:
            raise ValueError("concurrency 必须是 1–16 的整数")
        seen, planned = set(), []
        for item in items:
            if not isinstance(item, dict) or set(item) - {"suite", "tasks"}:
                raise ValueError("每个评测集只接受 suite 和 tasks")
            suite = suites.resolved(suites.get(item.get("suite")))
            if suite.id in seen:
                raise ValueError("评测集 " + suite.name + " 重复")
            seen.add(suite.id)
            run_request = {"suite": suite.id, "model": request.get("model"), "tasks": item.get("tasks"),
                           "attempts": attempts, "concurrency": min(concurrency, suite.max_concurrency)}
            if "executor" in request:
                run_request["executor"] = request["executor"]
            try:
                checked = self.runs.launch(run_request, dry_run=True)
            except ValueError as exc:
                raise ValueError(f"{suite.name}：{exc}") from None
            run_request.update(tasks=checked["tasks"], executor=checked["executor"])
            # The model's route as of creation (source, imported revision);
            # each item's launch must still resolve to it.
            planned.append({"suite": suite.id, **suites.label(suite.id), "tasks": checked["tasks"],
                            "concurrency": run_request["concurrency"], "request": run_request, "route": checked["route"],
                            "status": "pending", "run": None, "error": None, "started_at": None, "finished_at": None})
        cfg = settings(self.runs.config_path)
        choices = bundle_choices(cfg, self.runs.config_path)
        wanted = request.get("bundle")
        choice = next((c for c in choices if c["id"] == wanted), None) if wanted else \
            next((c for c in choices if c["current"]), None)
        if choice is None:
            raise ValueError("请选择工作台列出的 metacodes 版本" if wanted else "请先配置 metacodes 发行包（bench setup）")
        metacodes = freeze(choice, self.runs.config_path)
        batch_id = _new_id()
        record = {"id": batch_id, "name": name.strip() or None, "status": "queued", "created_at": now(),
                  "started_at": None, "finished_at": None, "model": request.get("model"),
                  "executor": planned[0]["request"]["executor"], "attempts": attempts, "concurrency": concurrency,
                  "metacodes": metacodes, "items": planned, "cancel_requested": False,
                  "url": "/#/batch/" + batch_id}
        with self.lock:
            self.save(record)
        self.wake()
        return record

    def cancel(self, batch_id: Any) -> Dict[str, Any]:
        with self.lock:
            record = self.get(batch_id)
            if record is None:
                raise ValueError("批次不存在")
            if record["status"] in BATCH_ACTIVE:
                record.update(cancel_requested=True, status="cancelling")
                self.save(record)
                running = next((i for i in record["items"] if i["status"] == "running"), None)
                if running and running.get("run"):
                    try:
                        self.runs.cancel(running["run"])
                    except ValueError:
                        pass
        self.wake()
        return {"id": record["id"], "status": record["status"], "cancel_requested": True}

    # -------------------------------------------------------------- scheduler

    def advance(self) -> None:
        """Move the oldest active batch forward by at most one step."""
        with self.lock:
            active = sorted((r for r in self.records() if r.get("status") in BATCH_ACTIVE),
                            key=lambda r: r.get("created_at", ""))
            for record in active:
                self._step(record)
                if record["status"] in BATCH_ACTIVE:
                    return  # this batch holds the executor until it ends

    def _step(self, record: Dict[str, Any]) -> None:
        items = record["items"]
        runs = {r["name"]: r for r in self.runs.runs()}
        current = next((i for i in items if i["status"] == "running"), None)
        if current is not None:
            run = runs.get(current.get("run"))
            if run is not None and run.get("status") in ACTIVE:
                if record.get("cancel_requested") and run["status"] != "cancelling":
                    try:
                        self.runs.cancel(run["name"])
                    except ValueError:
                        pass
                return
            current.update(status=run["status"] if run else "interrupted",
                           error=(run or {}).get("error") or (None if run else "运行记录丢失"),
                           finished_at=(run or {}).get("finished_at") or now())
        if record.get("cancel_requested"):
            for item in items:
                if item["status"] == "pending":
                    item["status"] = "skipped"
            record.update(status="cancelled", finished_at=now())
            self.save(record)
            return
        pending = next((i for i in items if i["status"] == "pending"), None)
        if pending is None:
            record.update(status="finished", finished_at=now())
            self.save(record)
            return
        if any(r.get("status") in ACTIVE for r in runs.values()) or self.runs.setup_running():
            if current is not None:
                self.save(record)
            return
        try:
            if frozen_digest(Path(record["metacodes"]["bundle"])) != record["metacodes"]["digest"]:
                raise ValueError("冻结的 metacodes 发行包已被修改，批次不再运行")
            launched = self.runs.launch(dict(pending["request"]), frozen=record["metacodes"], batch=record["id"],
                                        pinned=pending.get("route"))
            pending.update(status="running", run=launched["name"], started_at=now())
            record["status"] = "running"
            record["started_at"] = record.get("started_at") or now()
        except (ValueError, OSError) as exc:
            pending.update(status="failed", error=str(exc), finished_at=now())
        self.save(record)

    def wake(self) -> None:
        self._wake.set()

    def start(self, interval: float = 2.0) -> None:
        def loop() -> None:
            while not self._stop.is_set():
                try:
                    self.advance()
                except Exception as exc:  # the scheduler must outlive one bad record
                    print(f"bench batches: {type(exc).__name__}: {exc}", flush=True)
                self._wake.wait(interval)
                self._wake.clear()

        self._thread = threading.Thread(target=loop, name="bench-batches", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self.wake()


def public(record: Dict[str, Any]) -> Dict[str, Any]:
    """A batch record without the internal per-item launch requests."""
    value = json.loads(json.dumps(record))
    for item in value.get("items") or []:
        item.pop("request", None)
        item.pop("route", None)
    return value
