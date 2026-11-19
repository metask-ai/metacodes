"""Durable, shell-free launch requests for the Bench workbench.

Only server-configured bundles, published metacodes releases and provider
configurations can run. Browser requests select a model, task names and
optionally a release version; credentials stay in the server's
environment. Each launch has its own worker so HTTP restarts do not stop jobs.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.viewer import data, releases
from scripts.eval.harbor.viewer.account import Account

DATASET = "terminal-bench/terminal-bench-2-1"
SAMPLE_TASKS = ["kv-store-grpc", "pypi-server", "fix-git", "git-multibranch",
                "log-summary-date-ranges", "cancel-async-tasks", "largest-eigenval",
                "write-compressor", "schemelike-metacircular-eval", "torch-tensor-parallelism"]
TASK = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,160}$")
ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
ACTIVE = {"queued", "starting", "running", "cancelling"}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("x", encoding="utf-8") as output:
            json.dump(value, output, ensure_ascii=False, allow_nan=False)
        tmp.replace(path)
    finally:
        tmp.unlink(missing_ok=True)


def settings(path):
    value = data.read_json(Path(path)) or {}
    return value if isinstance(value, dict) else {}


def provider_models(config):
    """Expose only ids/labels, never native configuration or credentials."""
    native = data.read_json(Path(config)) if config else {}
    result = []
    for provider, spec in ((native or {}).get("custom_providers") or {}).items():
        for model in spec.get("models") or []:
            name = model.get("request_model_id")
            if name:
                result.append({"id": provider + "/" + name,
                               "label": spec.get("display_name", provider) + " / " + name})
    return result


class RunManager:
    def __init__(self, jobs_dir, config_path):
        self.jobs_dir = Path(jobs_dir).expanduser().resolve()
        self.config_path = Path(config_path).expanduser().resolve()
        self.records = self.jobs_dir / ".bench-runs"
        self.release_cache = self.config_path.parent / "releases"
        self.lock = threading.Lock()
        self.account_lock = threading.Lock()
        self.account_cache = None

    def account_catalog(self, cfg):
        account = Account(cfg.get("account_state_dir"), cfg.get("account_gateway"))
        # Re-login or /model changes invalidate the cache immediately. Only
        # directory metadata is cached; workers read the current key afresh.
        identity = account.fingerprint()
        with self.account_lock:
            cached = self.account_cache
            if cached and cached[0] == identity and time.monotonic() - cached[1] < 60:
                return cached[2]
            value = account.catalog()
            # Fetching the account inventory can refresh OAuth on disk.
            self.account_cache = (account.fingerprint(), time.monotonic(), value)
            return value

    def catalog(self):
        cfg = settings(self.config_path)
        mode = cfg.get("auth_mode") or ("provider" if cfg.get("provider_config") else "metask")
        reasons = []
        effort = None
        warnings, account_summary, account_groups = [], None, []
        if mode == "metask":
            models, model = [], ""
            try:
                account = self.account_catalog(cfg)
                models, model = account["models"], account["default_model"]
                effort = account["reasoning_effort"]
                warnings, account_summary = account["warnings"], account["account_summary"]
                account_groups = account["account_groups"]
            except ValueError as exc:
                reasons.append(str(exc))
            key_env = "METASK_API_KEY"
        elif mode == "provider":
            models = provider_models(cfg.get("provider_config"))
            model = cfg.get("model", "")
            if model and not any(m["id"] == model for m in models):
                models.append({"id": model, "label": model})
            key_env = cfg.get("key_env") or "TOKENJOY_API_KEY"
            if not ENV_NAME.fullmatch(key_env) or not os.environ.get(key_env):
                reasons.append("执行服务缺少环境变量 " + key_env + "，设置后重启服务")
        else:
            models, model, key_env = [], "", ""
            reasons.append("auth_mode 必须是 metask 或 provider")
        harbor = shutil.which(cfg.get("harbor", "harbor"))
        if not harbor:
            reasons.append("未找到 Harbor，请在执行机器安装：uv tool install harbor==0.26.0")
        if not shutil.which("docker"):
            reasons.append("未找到 Docker；Harbor 任务需要 Docker 环境")
        # Without a configured bundle, launches must name a release version.
        try:
            bundle_version = releases.bundle_version(check_bundle(Path(cfg.get("bundle") or "/nonexistent-metacodes-bundle")))
            bundle_ready = True
        except ValueError:
            bundle_version, bundle_ready = None, False
        if not models and mode == "provider":
            reasons.append("请配置 --model，第三方网关同时设置 --provider-config")
        return {"service": "metacodes-bench", "schema_version": 1,
                "dataset": DATASET, "tasks": SAMPLE_TASKS, "models": models,
                "default_model": model or (models[0]["id"] if models else ""),
                "key_env": key_env, "ready": not reasons, "reasons": reasons,
                "authentication": {"kind": mode, "label": "Metask 账号（执行机器已登录）" if mode == "metask" and models else
                                   "Metask 账号（待登录）" if mode == "metask" else "第三方 Provider"},
                "reasoning_effort": effort,
                "warnings": warnings, "account_summary": account_summary,
                "account_groups": account_groups,
                "metacodes": {"bundle": bundle_ready, "bundle_version": bundle_version,
                              "cached_versions": releases.cached(self.release_cache)},
                "defaults": {"attempts": 1, "concurrency": 1}, "runs": self.runs()}

    def runs(self):
        result = []
        for path in self.records.glob("*.json"):
            value = data.read_json(path)
            if not isinstance(value, dict) or not data.NAME.fullmatch(value.get("name", "")):
                continue
            if value.get("status") in ACTIVE and time.time() - path.stat().st_mtime > 30:
                value = {**value, "status": "interrupted", "error": "执行进程已停止更新，请检查运行日志"}
            result.append(value)
        return sorted(result, key=lambda r: r.get("created_at", ""), reverse=True)

    def launch(self, request):
        allowed = {"model", "tasks", "attempts", "concurrency", "dataset", "version"}
        if not isinstance(request, dict) or set(request) - allowed:
            raise ValueError("只接受 model、tasks、attempts、concurrency、dataset、version")
        catalog = self.catalog()
        if not catalog["ready"]:
            raise ValueError("；".join(catalog["reasons"]))
        model = request.get("model")
        if model not in {m["id"] for m in catalog["models"]}:
            raise ValueError("请选择服务已配置的模型")
        if request.get("dataset", DATASET) != DATASET:
            raise ValueError("当前支持 Terminal-Bench 2.1")
        tasks = request.get("tasks")
        if not isinstance(tasks, list) or not 1 <= len(tasks) <= 20:
            raise ValueError("请选择 1–20 道任务")
        tasks = [t.removeprefix("terminal-bench/") if isinstance(t, str) else t for t in tasks]
        if any(not isinstance(t, str) or not TASK.fullmatch(t) for t in tasks) or len(set(tasks)) != len(tasks):
            raise ValueError("任务名无效或重复")
        attempts, concurrency = request.get("attempts", 1), request.get("concurrency", 1)
        for name, value, limit in (("attempts", attempts, 5), ("concurrency", concurrency, 3)):
            if type(value) is not int or not 1 <= value <= limit:
                raise ValueError(f"{name} 必须是 1–{limit} 的整数")
        version = request.get("version") or None
        if version is not None:
            releases.check_version(version)
        elif not catalog["metacodes"]["bundle"]:
            raise ValueError("请指定 metacodes 版本，或用 metacodes bench --bundle <Linux发行包目录> 配置默认版本")
        with self.lock:
            if any(run.get("status") in ACTIVE for run in self.runs()):
                raise ValueError("已有评测正在运行，请等待完成或先停止")
            cfg = settings(self.config_path)
            mode = catalog["authentication"]["kind"]
            account_key_id = self.account_catalog(cfg)["routes"].get(model) if mode == "metask" else None
            if mode == "metask" and account_key_id is None:
                raise ValueError("账号模型目录已变化，请刷新后重试")
            name = "bench-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
            record = {"name": name, "status": "queued", "created_at": now(), "model": model,
                      "metacodes_version": version or catalog["metacodes"]["bundle_version"],
                      "tasks": tasks, "attempts": attempts, "concurrency": concurrency,
                      "url": "/#/run/" + name, "exit_code": None, "error": None}
            self.records.mkdir(parents=True, exist_ok=True)
            atomic_json(self.records / (name + ".json"), record)
            spec = {**record, "jobs_dir": str(self.jobs_dir), "bundle": None if version else cfg["bundle"],
                    "version": version, "release_cache": str(self.release_cache),
                    "release_base": cfg.get("release_base"),
                    "auth_mode": mode, "account_state_dir": cfg.get("account_state_dir") if mode == "metask" else None,
                    "account_gateway": cfg.get("account_gateway") if mode == "metask" else None,
                    "account_key_id": account_key_id,
                    "reasoning_effort": catalog.get("reasoning_effort"),
                    "provider_config": cfg.get("provider_config") if mode == "provider" else None,
                    "key_env": catalog["key_env"],
                    "metrics_enabled": cfg.get("metrics_enabled", True),
                    "metrics_bind": cfg.get("metrics_bind", "172.17.0.1"),
                    "harbor": shutil.which(cfg.get("harbor", "harbor")), "dataset": DATASET}
            spec_path = self.records / (name + ".spec")
            atomic_json(spec_path, spec)
            try:
                with (self.records / (name + ".log")).open("wb") as log:
                    process = subprocess.Popen([sys.executable, "-m", "scripts.eval.harbor.viewer.worker", str(spec_path)],
                                               cwd=str(Path(__file__).resolve().parents[4]), env=runtime_env(),
                                               stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
                    threading.Thread(target=process.wait, daemon=True).start()
            except OSError:
                atomic_json(self.records / (name + ".json"), {**record, "status": "failed", "error": "无法启动执行进程"})
                raise ValueError("无法启动执行进程")
            return record

    def cancel(self, name):
        if not isinstance(name, str) or not data.NAME.fullmatch(name):
            raise ValueError("运行不存在")
        record = next((r for r in self.runs() if r["name"] == name), None)
        if not record:
            raise ValueError("运行不存在")
        if record["status"] in ACTIVE:
            (self.records / (name + ".cancel")).touch()
        return {"name": name, "status": record["status"], "cancel_requested": True}


def runtime_env():
    env = dict(os.environ)
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[4])
    env["PYTHONUNBUFFERED"] = "1"
    return env
