"""Profiles: one frozen metacodes version with fixed advanced features.

A profile is what an evaluation tests: the Linux bundle frozen when the
profile was created (copied, once per content digest, to
`<state>/bundles/frozen/<digest>/` and made read-only) and the advanced
features every run of it enables. The profile id is derived from both, so the
same bundle with the same features is always the same profile. Rebuilding the
configured bundle (`bench setup` overlays a checkout in place) or switching
`workbench.json` to another version never changes a profile already created;
before each launch the copy is checked against its digest.

Runs are queued on a profile as often as wanted; each queued dataset becomes
an ordinary workbench run (a Harbor job) whose record names the profile, and
the queued datasets run one after another. A rerun of a task replaces its
earlier result in the profile's view. The durable state is
`<jobs>/.bench-profiles/<id>.json`, rewritten atomically; the scheduler
thread only advances what that file says, so a restarted service resumes the
queue where it stopped. The store ingests the records (`profiles` table).
Batch records of earlier versions (`<jobs>/.bench-batches/`) are merged into
the profiles of their bundle and features once, when the manager starts.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from scripts.eval.harbor import suites
from scripts.eval.harbor.command import ADVANCED_FEATURES, check_bundle
from scripts.eval.harbor.store.ingest import PROFILES_DIR
from scripts.eval.harbor.bench import builds, data, executors
from scripts.eval.harbor.bench.runner import (ACTIVE, DEFAULT_FEATURES, ExecutorUnreachable, atomic_json,
                                              chosen_features, now, settings)

MAX_ITEMS = 16
MAX_MODELS = 8
NAME_LIMIT = 80
PROFILE_ACTIVE = ("queued", "running", "cancelling")
LEGACY_BATCHES_DIR = ".bench-batches"
ITEM_DONE = ("finished", "failed", "cancelled", "interrupted", "skipped")
FINAL_RELEASE = re.compile(r"^v?\d+\.\d+\.\d+$")
DEV_NAME = re.compile(r"^metacodes-dev-([0-9a-f]{7,40}|worktree)-")


# ------------------------------------------------------------------ versions


def bundle_label(path: Path, manifest: Dict[str, Any], source: Optional[Dict[str, Any]] = None) -> str:
    """How the page names a metacodes bundle: a release version, or the
    checkout commit a development overlay was built from."""
    release = (manifest.get("release") or {}).get("version") if isinstance(manifest.get("release"), dict) else None
    info = builds.build_info(Path(path)) if builds.is_git_unit(path) else None
    if info and info.get("commit"):
        at = (info.get("committed_at") or "")[:16].replace("T", " ")
        return f"git {info['commit'][:8]}" + (f" · {at}" if at else "") + (f"（{release}）" if release else "")
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
    """The bundles a profile can freeze: the configured one first, then every
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
        if builds.is_git_unit(resolved):
            source = None
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


def current_metacodes(cfg: Dict[str, Any], used: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """The bundle a run uses, unfrozen, as its record names it."""
    path = used or cfg.get("bundle")
    if not path:
        return None
    resolved = Path(path).expanduser().resolve()
    try:
        manifest = check_bundle(resolved)
    except ValueError:
        return None
    source = None if builds.is_git_unit(resolved) else cfg.get("bundle_source")
    return {"label": bundle_label(resolved, manifest, source), "commit": bundle_commit(resolved, manifest, source),
            "bundle": str(resolved), "frozen": False}


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


# ------------------------------------------------------------------ profiles


def checked_name(value: Any) -> Optional[str]:
    name = value or ""
    if not isinstance(name, str) or len(name) > NAME_LIMIT or any(ord(c) < 32 for c in name):
        raise ValueError(f"评测配置名称最多 {NAME_LIMIT} 个字符")
    return name.strip() or None


def checked_models(request: Dict[str, Any]) -> List[Any]:
    """The models one queue request runs every dataset with, in order."""
    if "models" not in request:
        return [request.get("model")]
    models = request["models"]
    if "model" in request or not isinstance(models, list) or not 1 <= len(models) <= MAX_MODELS:
        raise ValueError(f"models 需要 1–{MAX_MODELS} 个模型，并且不能和 model 同时使用")
    if len(set(map(str, models))) != len(models):
        raise ValueError("models 里有重复的模型")
    return models


def run_features(features: List[str], suite_id: str) -> List[str]:
    """The profile's features a dataset runs with: none for a WorkBuddy
    suite, whose overlay launches metacodes itself."""
    return [] if suites.get(suite_id).runner == suites.WORKBUDDY else list(features)


def profile_id(digest: str, features: List[str]) -> str:
    key = digest + "|" + ",".join(features)
    return "profile-" + hashlib.sha256(key.encode()).hexdigest()[:12]


def default_name(record: Dict[str, Any]) -> str:
    """How the page names a profile nobody named: `profile-<version>-<bits>`,
    one bit per advanced feature in the order the page lists them."""
    metacodes = record.get("metacodes") or {}
    release, label = str(metacodes.get("release") or ""), str(metacodes.get("label") or "")
    commit = metacodes.get("commit") or (release.split("+", 1)[1] if "+" in release else None)
    development = not FINAL_RELEASE.match(release) or label.startswith(("dev ", "git "))
    if development and commit:
        version = str(commit)[:8]
    else:
        version = release or label or str(metacodes.get("digest") or "")[:8]
    features = record.get("features") or []
    bits = "".join("1" if name in features else "0" for name in ADVANCED_FEATURES)
    return f"profile-{version}-{bits}"


class ProfileManager:
    """Durable profiles over a RunManager; one profile's queue advances at a
    time, the one whose oldest waiting dataset was queued first."""

    # How long a dataset waits for an SSH executor that does not answer.
    UNREACHABLE_WAIT = 1800

    def __init__(self, runs):
        self.runs = runs
        self.dir = runs.jobs_dir / PROFILES_DIR
        self.lock = threading.Lock()
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: Optional[threading.Thread] = None
        runs.profile_guard = self.active_id
        self.merge_batches()

    # ---------------------------------------------------------------- records

    def path(self, profile: str) -> Path:
        return self.dir / (profile + ".json")

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

    def get(self, profile: Any) -> Optional[Dict[str, Any]]:
        if not isinstance(profile, str) or not data.NAME.fullmatch(profile):
            return None
        value = data.read_json(self.path(profile))
        return value if isinstance(value, dict) and value.get("id") == profile else None

    def active_id(self) -> Optional[str]:
        """The profile that owns the executor now (reads files only, no lock:
        RunManager.launch calls this under its own lock)."""
        active = [r for r in self.records() if r.get("status") in PROFILE_ACTIVE]
        return min(active, key=queued_since)["id"] if active else None

    # ------------------------------------------------------------------ queue

    def queue(self, request: Any) -> Dict[str, Any]:
        """Queue datasets on a profile: an existing one (`profile`), or the
        one of a listed bundle and `features`, created when first used.
        Each dataset is queued once per model (`model`, or several `models`)."""
        allowed = {"profile", "name", "model", "models", "executor", "attempts", "concurrency", "bundle", "items",
                   "features"}
        if not isinstance(request, dict) or set(request) - allowed:
            raise ValueError("只接受 profile、name、model、models、executor、attempts、concurrency、bundle、items、features")
        models = checked_models(request)
        items = request.get("items")
        if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
            raise ValueError(f"每次需要 1–{MAX_ITEMS} 个评测集")
        name = checked_name(request.get("name"))
        concurrency = request.get("concurrency", 1)
        if type(concurrency) is not int or concurrency < 1:
            raise ValueError("concurrency 必须是正整数")
        target = self.target(request)
        seen, planned = set(), []
        for item in items:
            if not isinstance(item, dict) or set(item) - {"suite", "tasks"}:
                raise ValueError("每个评测集只接受 suite 和 tasks")
            suite = suites.resolved(suites.get(item.get("suite")))
            if suite.id in seen:
                raise ValueError("评测集 " + suite.name + " 重复")
            seen.add(suite.id)
            for model in models:
                run_request = {"suite": suite.id, "model": model, "tasks": item.get("tasks"),
                               "attempts": request.get("attempts", 1),
                               "concurrency": suites.capped_concurrency(suite, concurrency)}
                label = suite.name if len(models) == 1 else f"{suite.name} · {model}"
                planned.append(self.planned(target, run_request, request.get("executor"), label))
        return self.append(target, name, planned)

    def launch_now(self, request: Any) -> Dict[str, Any]:
        """One dataset started at once, on the profile of the configured
        bundle and the request's features (the CLI's `bench run`)."""
        if not isinstance(request, dict):
            raise ValueError("请求必须是对象")
        if self.runs.setup_running():
            raise ValueError("一键配置正在进行（可能重启 Docker），请等配置结束再启动评测")
        run_request = {k: v for k, v in request.items() if k not in ("features", "executor")}
        target = self.target({"features": request.get("features", DEFAULT_FEATURES)})
        suite_name = suites.resolved(suites.get(run_request.get("suite", suites.DEFAULT_SUITE))).name
        planned = self.planned(target, run_request, request.get("executor"), suite_name)
        with self.lock:
            self._advance()
            if any(r.get("status") in ACTIVE for r in self.runs.runs()):
                raise ValueError("已有评测正在运行，请等待完成或先停止")
            owner = self.active_id()
            if owner:
                raise ValueError("评测配置 " + owner + " 的队列正在运行，请等它结束或先停止")
            record = self._append(target, None, [planned])
            self._step(record)
            item = record["items"][-1]
            if item["status"] == "pending":  # `bench run` does not wait for an executor
                item.update(status="failed", error=item.pop("waiting")["reason"], finished_at=now())
            if item["status"] == "failed":
                self._step(record)
        if item["status"] == "failed":
            raise ValueError(item["error"])
        return next(r for r in self.runs.runs() if r["name"] == item["run"])

    def target(self, request: Dict[str, Any]) -> Dict[str, Any]:
        """The profile a request runs on: its record, or what creating it
        needs (the bundle choice and the features)."""
        if request.get("profile") is not None:
            if "bundle" in request or "features" in request:
                raise ValueError("已有评测配置的版本和高级功能不能更改")
            record = self.get(request["profile"])
            if record is None:
                raise ValueError("评测配置不存在")
            return {"id": record["id"], "metacodes": record["metacodes"], "features": record.get("features") or []}
        features = chosen_features(request.get("features"))
        cfg = settings(self.runs.config_path)
        choices = bundle_choices(cfg, self.runs.config_path)
        wanted = request.get("bundle")
        choice = next((c for c in choices if c["id"] == wanted), None) if wanted else \
            next((c for c in choices if c["current"]), None)
        if choice is None:
            raise ValueError("请选择工作台列出的 metacodes 版本" if wanted else
                             self.runs.run_bundle(cfg, None, None)[1] or "请先配置 metacodes 发行包（bench setup）")
        return {"id": None, "choice": choice, "features": features}

    def planned(self, target, run_request, executor, suite_name) -> Dict[str, Any]:
        """A dataset checked by a dry run on the profile's bundle, ready to
        queue with the model route it resolved to."""
        if executor is not None:
            run_request["executor"] = executor
        features = run_features(target["features"], run_request.get("suite", suites.DEFAULT_SUITE))
        run_request["features"] = features
        try:
            if target["id"]:
                checked = self.runs.launch(run_request, dry_run=True, frozen=target["metacodes"])
            else:
                checked = self.runs.launch(run_request, dry_run=True, bundle=target["choice"]["path"])
        except ValueError as exc:
            raise ValueError(f"{suite_name}：{exc}") from None
        run_request.update(suite=checked["suite"], tasks=checked["tasks"], executor=checked["executor"],
                           attempts=checked["attempts"], concurrency=checked["concurrency"])
        run_request.pop("features")
        return {"suite": checked["suite"], **suites.label(checked["suite"]), "tasks": checked["tasks"],
                "model": run_request["model"], "attempts": checked["attempts"],
                "concurrency": checked["concurrency"], "executor": checked["executor"], "features": features,
                "request": run_request, "route": checked["route"], "status": "pending", "run": None,
                "error": None, "queued_at": None, "started_at": None, "finished_at": None}

    def append(self, target, name, planned) -> Dict[str, Any]:
        with self.lock:
            record = self._append(target, name, planned)
        self.wake()
        return record

    def _append(self, target, name, planned) -> Dict[str, Any]:
        if target["id"] is None:
            metacodes = freeze(target["choice"], self.runs.config_path)
            git = builds.provenance(target["choice"]["path"])
            if git:
                metacodes["git"] = git
            target = {"id": profile_id(metacodes["digest"], target["features"]), "metacodes": metacodes,
                      "features": target["features"]}
        record = self.get(target["id"])
        if record is None:
            record = {"id": target["id"], "name": name, "status": "finished", "created_at": now(),
                      "started_at": None, "finished_at": None, "metacodes": target["metacodes"],
                      "features": target["features"], "items": [], "cancel_requested": False,
                      "url": "/#/profile/" + target["id"]}
        elif record["status"] == "cancelling":
            raise ValueError("评测配置正在停止，请等它停止后再运行")
        if name and not record.get("name"):
            record["name"] = name
        if record["status"] not in PROFILE_ACTIVE:
            record.update(status="queued", cancel_requested=False, finished_at=None)
        queued = now()
        for item in planned:
            record["items"].append({**item, "queued_at": queued})
        self.save(record)
        return record

    def rename(self, profile: Any, name: Any) -> Dict[str, Any]:
        name = checked_name(name)
        with self.lock:
            record = self.get(profile)
            if record is None:
                raise ValueError("评测配置不存在")
            record["name"] = name
            self.save(record)
        return {"id": record["id"], "name": name}

    def set_concurrency(self, profile: Any, concurrency: Any) -> Dict[str, Any]:
        if type(concurrency) is not int or concurrency < 1:
            raise ValueError("concurrency 必须是正整数")
        with self.lock:
            record = self.get(profile)
            if record is None:
                raise ValueError("评测配置不存在")
            if record["status"] not in PROFILE_ACTIVE:
                raise ValueError("评测配置没有正在运行或排队的评测集")
            active = {r["name"] for r in self.runs.runs() if r.get("status") in ACTIVE}
            for item in record["items"]:
                if item["status"] not in ("pending", "running"):
                    continue
                applied = suites.capped_concurrency(suites.resolved(suites.get(item["suite"])), concurrency)
                if item["status"] == "running" and item.get("run") in active:
                    self.runs.set_concurrency(item["run"], applied)
                item["concurrency"] = applied
                if isinstance(item.get("request"), dict):
                    item["request"]["concurrency"] = applied
            self.save(record)
        return {"id": record["id"], "concurrency": concurrency}

    def cancel(self, profile: Any) -> Dict[str, Any]:
        with self.lock:
            record = self.get(profile)
            if record is None:
                raise ValueError("评测配置不存在")
            if record["status"] in PROFILE_ACTIVE:
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
        """Move the active profile queued first forward by at most one step."""
        with self.lock:
            self._advance()

    def _advance(self) -> None:
        active = sorted((r for r in self.records() if r.get("status") in PROFILE_ACTIVE), key=queued_since)
        for record in active:
            self._step(record)
            if record["status"] in PROFILE_ACTIVE:
                return  # this profile holds the executor until its queue ends

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
                raise ValueError("冻结的 metacodes 发行包已被修改，这个评测配置不再运行")
            request = dict(pending["request"])
            features = run_features(record.get("features") or [], request.get("suite", suites.DEFAULT_SUITE))
            if features:
                request["features"] = features
            launched = self.runs.launch(request, frozen=record["metacodes"], profile=record["id"],
                                        pinned=pending.get("route"))
            pending.pop("waiting", None)
            pending.update(status="running", run=launched["name"], started_at=now())
            record["status"] = "running"
            record["started_at"] = record.get("started_at") or now()
        except ExecutorUnreachable as exc:
            waiting = pending.setdefault("waiting", {"since": time.time()})
            waiting["reason"] = str(exc)
            if time.time() - waiting["since"] > self.UNREACHABLE_WAIT:
                pending.update(status="failed", finished_at=now(),
                               error=f"执行机器 {self.UNREACHABLE_WAIT // 60} 分钟内一直连不上：{exc}")
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
                    print(f"bench profiles: {type(exc).__name__}: {exc}", flush=True)
                self._wake.wait(interval)
                self._wake.clear()

        self._thread = threading.Thread(target=loop, name="bench-profiles", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self.wake()

    # -------------------------------------------------------------- migration

    def merge_batches(self) -> None:
        """Fold every batch record of an earlier version into the profile of
        its frozen bundle and features, then remove the batch record."""
        legacy = self.runs.jobs_dir / LEGACY_BATCHES_DIR
        try:
            paths = sorted(legacy.glob("*.json"))
        except OSError:
            return
        batches = [(p, b) for p, b in ((p, data.read_json(p)) for p in paths)
                   if isinstance(b, dict) and isinstance(b.get("metacodes"), dict) and b["metacodes"].get("digest")]
        with self.lock:
            for path, batch in sorted(batches, key=lambda pair: pair[1].get("created_at") or ""):
                features = batch.get("features") or []
                pid = profile_id(batch["metacodes"]["digest"], features)
                record = self.get(pid) or {
                    "id": pid, "name": batch.get("name"), "status": "finished", "created_at": batch.get("created_at"),
                    "started_at": None, "finished_at": None, "metacodes": batch["metacodes"], "features": features,
                    "items": [], "cancel_requested": False, "url": "/#/profile/" + pid, "batches": []}
                record.setdefault("batches", [])
                if batch["id"] not in record["batches"]:
                    record["batches"].append(batch["id"])
                    for item in batch.get("items") or []:
                        record["items"].append({**item, "model": batch.get("model"), "attempts": batch.get("attempts"),
                                                "executor": batch.get("executor"), "queued_at": batch.get("created_at")})
                    record["started_at"] = record.get("started_at") or batch.get("started_at")
                    record["finished_at"] = max(filter(None, (record.get("finished_at"), batch.get("finished_at"))),
                                                default=None)
                    if batch.get("status") in PROFILE_ACTIVE:
                        record.update(status=batch["status"], cancel_requested=bool(batch.get("cancel_requested")))
                    elif record["status"] not in PROFILE_ACTIVE:
                        record["status"] = batch.get("status") or "finished"
                    self.save(record)
                path.unlink(missing_ok=True)
        try:
            legacy.rmdir()
        except OSError:
            pass


def queued_since(record: Dict[str, Any]) -> str:
    waiting = [i.get("queued_at") or "" for i in record.get("items") or [] if i.get("status") in ("pending", "running")]
    return min(waiting, default=record.get("created_at") or "")


def runs_of(record: Dict[str, Any], receipts: List[Dict[str, Any]]) -> List[str]:
    """Every run a profile owns: its queued datasets, and any receipt that
    names it (or one of the batches merged into it)."""
    owners = {record["id"], *(record.get("batches") or [])}
    names = {item.get("run") for item in record.get("items") or []}
    names |= {r.get("name") for r in receipts if r.get("profile") in owners or r.get("batch") in owners}
    return sorted(n for n in names if isinstance(n, str) and data.NAME.fullmatch(n))


def public(record: Dict[str, Any]) -> Dict[str, Any]:
    """A profile record without the internal per-item launch requests."""
    value = json.loads(json.dumps(record))
    value["default_name"] = default_name(record)
    for item in value.get("items") or []:
        item.pop("request", None)
        item.pop("route", None)
    return value
