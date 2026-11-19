"""Durable, shell-free launch requests for the Bench workbench.

Only server-configured bundles and provider configurations can run. Browser
requests select a model and task names; credentials stay in the server's
environment. Each launch has its own worker so HTTP restarts do not stop jobs.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from scripts.eval.harbor import suites
from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.profiling import route_problem
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.viewer import data, executors
from scripts.eval.harbor.viewer.account import Account

# The launch API's original fixed dataset, still accepted as `dataset`.
DATASET = suites.BY_ID[suites.DEFAULT_SUITE].dataset
SAMPLE_TASKS = list(suites.BY_ID[suites.DEFAULT_SUITE].default_tasks)
TASK = suites.TASK
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
    # A worker rewrites its receipt every two seconds; one older than this
    # belongs to a worker that stopped.
    STALE_AFTER = 30

    def __init__(self, jobs_dir, config_path):
        self.jobs_dir = Path(jobs_dir).expanduser().resolve()
        self.config_path = Path(config_path).expanduser().resolve()
        self.records = self.jobs_dir / ".bench-runs"
        self.lock = threading.Lock()
        self.account_lock = threading.Lock()
        self.account_cache = None
        self.probe_lock = threading.Lock()
        self.probe_cache = {}
        from scripts.eval.harbor.viewer.setup import SetupManager
        # Whether a setup that may restart Docker or Colima is running; the
        # service replaces this with its own SetupManager's view. A launch
        # and such a setup exclude each other under self.lock.
        self.setup_running = SetupManager(self.config_path).mutating

    def executor_facts(self, executor):
        """Probe results per executor, reused for 15 s (an SSH probe is a
        round trip; the page and each launch read the catalog)."""
        key = json.dumps(executor.spec(), sort_keys=True)
        with self.probe_lock:
            cached = self.probe_cache.get(executor.name)
            if cached and cached[0] == key and time.monotonic() - cached[1] < 15:
                return cached[2]
        facts = executors.probe(executor)
        with self.probe_lock:
            self.probe_cache[executor.name] = (key, time.monotonic(), facts)
        return facts

    def executor_states(self, cfg):
        invalid = []
        try:
            configured, default = executors.configured(cfg, invalid)
        except ValueError as exc:
            return [], None, [str(exc)]
        states = []
        for executor in configured:
            facts = self.executor_facts(executor)
            problems = executors.reasons(executor, facts)
            states.append({**executor.public(), "ready": not problems, "reasons": problems,
                           "default": executor.name == default, "harbor": facts.get("harbor") or None})
        # A malformed entry is shown, not ready, without hiding the others.
        for name, problem in invalid:
            states.append({"name": name, "kind": "invalid", "label": name + "（配置无效）", "ready": False,
                           "reasons": [problem], "default": False, "harbor": None})
        return states, default, []

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

    def suite_context(self, cfg=None):
        return suites.Context(settings(self.config_path) if cfg is None else cfg, self.config_path.parent)

    def suite_tasks(self, suite_id):
        suite = suites.resolved(suites.get(suite_id))
        try:
            tasks = suites.task_ids(suite, self.suite_context())
        except suites.Unavailable as exc:
            return {"id": suite.id, "tasks": [], "default_tasks": [], "error": str(exc)}
        known = set(tasks)
        return {"id": suite.id, "tasks": tasks, "default_tasks": [t for t in suite.default_tasks if t in known]}

    def suite_entry(self, suite, ctx, global_reasons, harbor_reasons, states, default_executor,
                    workbench_harbor="unknown"):
        """A suite's catalog entry with its readiness on every executor.

        `executors[name].reasons` is everything that keeps this suite from
        launching there: service-wide reasons, the executor's own readiness
        (Harbor suites only) and the suite's own prerequisites; `reasons` and
        `ready` are those of the default executor.
        """
        entry = suites.public(suite, ctx)
        own = entry["reasons"]
        by_executor = {}
        for state in states:
            if suite.runner == suites.WORKBUDDY:
                combo = [] if state["kind"] == "local" else [
                    "WorkBuddy 评测只能在本机执行器运行（它驱动本机的 WorkBuddy checkout 和 Docker），"
                    "不支持 SSH 执行机器 " + state["name"]]
            else:
                combo = harbor_reasons + state["reasons"]
                if suite.runner == suites.HARBOR_REGISTRY and state["kind"] == "ssh" and not workbench_harbor:
                    combo = combo + [f"工作台本机缺少 Harbor：SSH 执行机器的注册表评测集（{suite.dataset}）"
                                     "先在工作台用 harbor download 下载再发送到执行机器；请在工作台运行 "
                                     "metacodes bench setup，或 uv tool install harbor==0.26.0"]
            problems = global_reasons + combo + own
            by_executor[state["name"]] = {"ready": not problems, "reasons": problems}
        default = by_executor.get(default_executor) or {"reasons": global_reasons + own}
        entry.update(suite_reasons=own, executors=by_executor,
                     reasons=default["reasons"], ready=not default["reasons"])
        return entry

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
        if not models and mode == "provider":
            reasons.append("请配置 --model，第三方网关同时设置 --provider-config")
        elif mode == "provider":
            # Containers only ever hold a placeholder; a route the credential
            # relay cannot forward is refused rather than given the key.
            problem = route_problem({"auth_mode": mode, "provider_config": cfg.get("provider_config"),
                                     "model": model or models[0]["id"]})
            if problem:
                reasons.append(problem)
        states, default_executor, problems = self.executor_states(cfg)
        reasons += problems
        global_reasons = list(reasons)
        # Harbor suites need the Linux bundle; WorkBuddy brings its own
        # Harbor and staged artifacts and checks its own prerequisites.
        harbor_reasons = []
        try:
            check_bundle(Path(cfg.get("bundle") or "/nonexistent-metacodes-bundle"))
        except ValueError:
            harbor_reasons.append("请用 metacodes bench --bundle <Linux发行包目录> 配置评测版本")
        ctx = self.suite_context(cfg)
        # Registry suites on SSH executors are downloaded on this machine.
        local_harbor = executors.workbench_harbor(cfg) if any(s["kind"] == "ssh" for s in states) else None
        catalog_suites = [self.suite_entry(s, ctx, global_reasons, harbor_reasons, states, default_executor,
                                           local_harbor) for s in suites.ALL]
        # Top-level readiness keeps its original meaning: the default suite
        # on the default executor.
        default_entry = next(e for e in catalog_suites if e["id"] == suites.DEFAULT_SUITE)
        reasons = list(default_entry["reasons"])
        return {"service": "metacodes-bench", "schema_version": 1,
                "executors": [{k: v for k, v in s.items() if k != "harbor"} for s in states],
                "default_executor": default_executor, "global_reasons": global_reasons,
                "harbor_reasons": harbor_reasons,
                "login": {"available": mode == "metask" and bool((cfg.get("metacodes") or {}).get("binary")),
                          "signed_in": mode == "metask" and bool(models)},
                "dataset": DATASET, "tasks": SAMPLE_TASKS,
                "default_suite": suites.DEFAULT_SUITE, "categories": suites.categories(),
                "suites": catalog_suites, "models": models,
                "default_model": model or (models[0]["id"] if models else ""),
                "key_env": key_env, "ready": not reasons, "reasons": reasons,
                "authentication": {"kind": mode, "label": "Metask 账号（执行机器已登录）" if mode == "metask" and models else
                                   "Metask 账号（待登录）" if mode == "metask" else "第三方 Provider"},
                "reasoning_effort": effort,
                "warnings": warnings, "account_summary": account_summary,
                "account_groups": account_groups,
                "defaults": {"attempts": 4, "concurrency": 10}, "runs": self.runs()}

    def runs(self):
        result = []
        for path in self.records.glob("*.json"):
            value = data.read_json(path)
            if not isinstance(value, dict) or not data.NAME.fullmatch(value.get("name", "")):
                continue
            if value.get("status") in ACTIVE and time.time() - path.stat().st_mtime > self.STALE_AFTER:
                value = {**value, "status": "interrupted", "error": "执行进程已停止更新，请检查运行日志"}
            result.append(value)
        return sorted(result, key=lambda r: r.get("created_at", ""), reverse=True)

    def launch(self, request):
        allowed = {"model", "tasks", "attempts", "concurrency", "dataset", "suite", "executor"}
        if not isinstance(request, dict) or set(request) - allowed:
            raise ValueError("只接受 model、suite、tasks、attempts、concurrency、dataset、executor")
        # `dataset` is the original API's only choice, kept for older clients.
        if "dataset" in request and request["dataset"] != DATASET:
            raise ValueError("dataset 只接受 " + DATASET + "；其他评测集请用 suite")
        suite_id = request.get("suite", suites.DEFAULT_SUITE)
        if "dataset" in request and suite_id != suites.DEFAULT_SUITE:
            raise ValueError("suite 与 dataset 不一致")
        suite = suites.resolved(suites.get(suite_id))
        if self.setup_running():  # checked again under the lock below
            raise ValueError("一键配置正在进行（可能重启 Docker），请等配置结束再启动评测")
        catalog = self.catalog()
        wanted = request.get("executor", catalog["default_executor"])
        state = next((e for e in catalog["executors"] if e["name"] == wanted), None)
        if state is None:
            raise ValueError("；".join(catalog["global_reasons"]) or "请选择已配置的执行机器")
        entry = next(s for s in catalog["suites"] if s["id"] == suite.id)
        problems = entry["executors"][state["name"]]["reasons"]
        if problems:
            raise ValueError("；".join(problems))
        model = request.get("model")
        if model not in {m["id"] for m in catalog["models"]}:
            raise ValueError("请选择服务已配置的模型")
        if catalog["authentication"]["kind"] == "provider" and suite.runner != suites.WORKBUDDY:
            problem = route_problem({"auth_mode": "provider", "model": model,
                                     "provider_config": settings(self.config_path).get("provider_config")})
            if problem:
                raise ValueError(problem)
        ctx = self.suite_context()
        tasks = suites.validate_tasks(suite, ctx, request.get("tasks"))
        attempts, concurrency = request.get("attempts", 1), request.get("concurrency", 1)
        for name, value, limit in (("attempts", attempts, 5), ("concurrency", concurrency, suite.max_concurrency)):
            if type(value) is not int or not 1 <= value <= limit:
                raise ValueError(f"{name} 必须是 1–{limit} 的整数")
        with self.lock:
            if any(run.get("status") in ACTIVE for run in self.runs()):
                raise ValueError("已有评测正在运行，请等待完成或先停止")
            if self.setup_running():
                raise ValueError("一键配置正在进行（可能重启 Docker），请等配置结束再启动评测")
            cfg = settings(self.config_path)
            executor = executors.find(cfg, state["name"])
            facts = self.executor_facts(executor)
            mode = catalog["authentication"]["kind"]
            account_key_id = self.account_catalog(cfg)["routes"].get(model) if mode == "metask" else None
            if mode == "metask" and account_key_id is None:
                raise ValueError("账号模型目录已变化，请刷新后重试")
            # An LLM-judged suite in Metask authentication: its verifier goes
            # through the run's relay with a judge-only placeholder.
            judge = suites.judge(suite, cfg)
            name = "bench-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
            record = {"name": name, "status": "queued", "created_at": now(), "model": model,
                      **suites.label(suite.id), "runner": suite.runner, "executor": executor.name,
                      "tasks": tasks, "attempts": attempts, "concurrency": concurrency,
                      "url": "/#/run/" + name, "exit_code": None, "error": None}
            shown_judge = suites.judge_label(suite, cfg)
            if shown_judge:
                record["judge"] = shown_judge  # model id and route only
            self.records.mkdir(parents=True, exist_ok=True)
            atomic_json(self.records / (name + ".json"), record)
            spec = {**record, "jobs_dir": str(self.jobs_dir), "bundle": cfg.get("bundle"),
                    "auth_mode": mode, "account_state_dir": cfg.get("account_state_dir") if mode == "metask" else None,
                    "account_gateway": cfg.get("account_gateway") if mode == "metask" else None,
                    "account_key_id": account_key_id,
                    "reasoning_effort": catalog.get("reasoning_effort"),
                    "provider_config": cfg.get("provider_config") if mode == "provider" else None,
                    "key_env": catalog["key_env"],
                    "metrics_enabled": cfg.get("metrics_enabled", True) and suite.runner != suites.WORKBUDDY,
                    "metrics_bind": cfg.get("metrics_bind", "172.17.0.1"),
                    "metrics_host": cfg.get("metrics_host"),
                    "executor": executor.spec(),
                    "store": store_config.for_workbench(cfg, self.config_path).to_json()}
            if suite.runner == suites.WORKBUDDY:
                from scripts.eval.harbor.suites import workbuddy
                spec["workbuddy"] = workbuddy.spec_fields(suite, ctx)
            else:
                spec.update(harbor=facts.get("harbor") if executor.kind == "local" else None,
                            remote_harbor=facts.get("harbor") if executor.kind == "ssh" else None,
                            dataset_args=suites.harbor_dataset_args(suite, ctx),
                            task_filters=suites.task_filters(suite, tasks),
                            # Names only: an SSH executor receives these
                            # values over the run's stdin channel. A judge
                            # routed through the relay needs none of them.
                            forward_env=[] if judge else list(suites.host_env(suite)))
                if judge:
                    spec["judge"] = judge
                if suite.runner == suites.HARBOR_LOCAL and executor.kind == "ssh":
                    # Shipped to the executor, addressed by content digest.
                    spec["local_dataset"] = str(ctx.dataset_dir(suite).resolve())
                if suite.runner == suites.HARBOR_REGISTRY and executor.kind == "ssh":
                    # Downloaded on this machine (cached per reference), then
                    # shipped and run with `-p`, whose task names are bare.
                    spec["registry_download"] = {
                        "ref": suite.dataset, "cache": str(self.config_path.parent / "registry-cache"),
                        "harbor": executors.workbench_harbor(cfg),
                        "tasks": list(suite.tasks) if suite.tasks is not None else None,
                        "filters": list(tasks)}
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
    # Tools installed by `bench setup` (uv tools, Homebrew) are found even
    # when the service started with a minimal PATH; existing entries win.
    env["PATH"] = executors.search_path()
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[4])
    env["PYTHONUNBUFFERED"] = "1"
    return env
