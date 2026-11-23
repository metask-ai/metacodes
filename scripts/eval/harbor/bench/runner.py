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
from scripts.eval.harbor.command import ADVANCED_FEATURES, TEAMWORK, TEAMWORK_TIMEOUT_MULTIPLIER, check_bundle
from scripts.eval.harbor.profiling import route_problem
from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.bench import builds, data, executors
from scripts.eval.harbor.bench.account import Account
from scripts.eval.harbor.bench.providers import KEY_ENV as PROVIDER_KEY_ENV, Providers, loopback, write_config

# The launch API's original fixed dataset, still accepted as `dataset`.
DATASET = suites.BY_ID[suites.DEFAULT_SUITE].dataset
MAX_OUTPUT_TOKENS = 131072
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


def metacodes_config(cfg):
    if os.environ.get("METACODES_CONFIG_FILE"):
        return Path(os.environ["METACODES_CONFIG_FILE"])
    state_root = cfg.get("account_state_dir") or os.environ.get("METACODES_HOME")
    return (Path(state_root) if state_root else Path.home() / ".metacodes") / "config.json"


def provider_config(cfg):
    if cfg.get("provider_config"):
        return cfg["provider_config"]
    if cfg.get("auth_mode") != "provider":
        return None
    path = metacodes_config(cfg)
    native = data.read_json(path)
    if isinstance(native, dict) and native.get("custom_providers"):
        return str(path)
    return None


def provider_key_env(cfg, config, model):
    if cfg.get("key_env"):
        return cfg["key_env"]
    native = data.read_json(Path(config)) if config else None
    spec = ((native or {}).get("custom_providers") or {}).get(model.split("/", 1)[0]) if isinstance(native, dict) else None
    aliases = [a for a in (spec or {}).get("env_aliases") or []
               if isinstance(a, dict) and a.get("kind", "api_key") == "api_key"]
    chosen = next((a for a in aliases if a.get("canonical")), aliases[0] if aliases else {})
    return chosen.get("name") or ""


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


def ssh_loopback_problem(kind, executor_name, provider_id, base_url):
    """Why an imported route cannot run on this executor, or None. The
    workbench imported and probed the address; an SSH executor's relay
    would read one that reaches the workbench itself (loopback, localhost,
    an alias resolving there) as its own machine and send the requests and
    the key to whatever listens there."""
    if kind == "ssh" and loopback(base_url):
        return (f"导入的 Provider {provider_id} 的地址指向工作台本机（回环地址或解析到回环的主机名），"
                f"SSH 执行机器 {executor_name} 会把它当成自己的地址；请改用两台机器都能访问到同一网关的地址"
                "重新导入，或选本机执行器")
    return None


def configured_provider_ids(cfg):
    """Provider ids the catalog already lists models under (the
    --provider-config setup); an imported provider may not reuse them."""
    config = provider_config(cfg)
    native = data.read_json(Path(config)) if config else None
    providers = (native or {}).get("custom_providers") if isinstance(native, dict) else None
    return set(providers) if isinstance(providers, dict) else set()


def key_env_problems(key_env, model):
    if not key_env:
        return [f"模型 {model} 的 Provider 没有配置 env_aliases，请用 --key-env 指定 API Key 的环境变量"]
    if not ENV_NAME.fullmatch(key_env) or not os.environ.get(key_env):
        return ["执行服务缺少环境变量 " + key_env + "，设置后重启服务"]
    return []


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
        # Providers imported by URL and key (`bench provider`, the page).
        self.providers = Providers(self.config_path.parent)
        from scripts.eval.harbor.bench.setup import SetupManager
        # Whether a setup that may restart Docker or Colima is running; the
        # service replaces this with its own SetupManager's view. A launch
        # and such a setup exclude each other under self.lock.
        self.setup_running = SetupManager(self.config_path).mutating
        # The id of the profile whose queue owns the executor, or None; a
        # ProfileManager installs its view. A single launch waits for it.
        self.profile_guard = lambda: None

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
            node = facts.get("node") if isinstance(facts.get("node"), dict) else None
            public = executor.public()
            if node:
                public["label"] += f" · metacodes {node.get('version')}"
            states.append({**public, "ready": not problems, "reasons": problems,
                           "default": executor.name == default, "harbor": facts.get("harbor") or None,
                           "node": {k: node.get(k) for k in ("version", "host")} if node else None,
                           "node_reach": executors.reach_reasons(executor, facts)
                           if isinstance(executor, executors.SshExecutor) else [],
                           "node_workbuddy": (node or {}).get("workbuddy") or {}})
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

    def node_tasks(self, suite, executor_name):
        """A WorkBuddy suite's task ids on an SSH executor, as its node
        reports them; None for this machine (or a Harbor suite)."""
        if suite.runner != suites.WORKBUDDY:
            return None
        try:
            executor = executors.find(settings(self.config_path), executor_name)
        except ValueError:
            return None
        if executor.kind != "ssh":
            return None
        facts = self.executor_facts(executor)
        entry = ((facts.get("node") or {}).get("workbuddy") or {}).get(suite.id) or {}
        if not entry.get("tasks"):
            reasons = entry.get("reasons") or [executors.node_problem(executor, facts) or "执行机器未报告任务"]
            raise suites.Unavailable(f"{executor.name}：" + "；".join(reasons))
        return list(entry["tasks"])

    def staged_metacodes_problem(self, suite, executor_name, bundle):
        """Why an SSH WorkBuddy run would not run the metacodes its record
        names (the run's bundle): an executable the node staged differs."""
        if suite.runner != suites.WORKBUDDY or not bundle:
            return None
        executor = executors.find(settings(self.config_path), executor_name)
        if executor.kind != "ssh":
            return None
        from scripts.eval.harbor.suites import workbuddy
        staged = (self.executor_facts(executor).get("node") or {}).get("workbuddy_executables")
        different = workbuddy.executable_mismatch(staged, workbuddy.bundle_executables(bundle))
        if not different:
            return None
        return (f"{executor.name} 上 WorkBuddy 暂存的制品不是本次选择的 metacodes 版本（{'、'.join(different)} 不同）："
                "请在该机器上用这个发行包重新运行 scripts.eval.workbuddy.stage_artifacts，或选择与暂存制品一致的版本")

    def suite_tasks(self, suite_id, executor=None):
        suite = suites.resolved(suites.get(suite_id))
        try:
            tasks = self.node_tasks(suite, executor)
            if tasks is None:
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
            here = own
            if suite.runner == suites.WORKBUDDY:
                combo = []
                if state["kind"] == "ssh":
                    # Prepared on the node itself: its own checkout, Docker
                    # and task list; this machine adds only its sign-in mode.
                    combo = state["node_reach"] + (state["node_workbuddy"].get(suite.id) or {}).get("reasons", [])
                    here = [] if ctx.auth_mode() == "metask" else ["WorkBuddy 评测目前只支持 Metask 账号模式（--auth metask）"]
            else:
                combo = harbor_reasons + state["reasons"]
                if suite.runner == suites.HARBOR_REGISTRY and state["kind"] == "ssh" and not workbench_harbor:
                    combo = combo + [f"工作台本机缺少 Harbor：SSH 执行机器的注册表评测集（{suite.dataset}）"
                                     "先在工作台用 harbor download 下载再发送到执行机器；请在工作台运行 "
                                     "metacodes bench setup，或 uv tool install harbor==0.26.0"]
            problems = global_reasons + combo + here
            by_executor[state["name"]] = {"ready": not problems, "reasons": problems}
        default = by_executor.get(default_executor) or {"reasons": global_reasons + own}
        entry.update(suite_reasons=own, executors=by_executor,
                     reasons=default["reasons"], ready=not default["reasons"])
        return entry

    def catalog(self, bundle_supplied=False):
        from scripts.eval.harbor.bench.profiles import bundle_choices
        cfg = settings(self.config_path)
        mode = cfg.get("auth_mode") or ("provider" if cfg.get("provider_config") else "metask")
        reasons = []
        effort = None
        warnings, account_summary, account_groups = [], None, []
        imported = self.providers.models()
        if mode == "metask":
            models, model = [], ""
            try:
                account = self.account_catalog(cfg)
                models, model = account["models"], account["default_model"]
                effort = account["reasoning_effort"]
                warnings, account_summary = account["warnings"], account["account_summary"]
                account_groups = account["account_groups"]
            except ValueError as exc:
                # Imported providers still run without an account login.
                (warnings if imported else reasons).append(str(exc))
            key_env = "METASK_API_KEY"
        elif mode == "provider":
            config = provider_config(cfg)
            models = provider_models(config)
            model = cfg.get("model", "")
            if model and not any(m["id"] == model for m in models):
                models.append({"id": model, "label": model})
            legacy = []
            key_env = ""
            if not models:
                legacy.append("没有可用的 custom_providers 模型：用 metacodes providers 添加到 MetaCodes 配置，"
                              "或用 --provider-config 指定配置")
            else:
                key_env = provider_key_env(cfg, config, model or models[0]["id"])
                legacy += key_env_problems(key_env, model or models[0]["id"])
                # Containers only ever hold a placeholder; a route the credential
                # relay cannot forward is refused rather than given the key.
                problem = route_problem({"auth_mode": mode, "provider_config": config,
                                         "model": model or models[0]["id"]})
                if problem:
                    legacy.append(problem)
            if legacy and imported:
                # Imported providers carry their own keys and routes; the
                # broken --provider-config route is left out, not blocking.
                warnings.extend(legacy)
                models, model = [], ""
            else:
                reasons.extend(legacy)
        else:
            models, model, key_env = [], "", ""
            reasons.append("auth_mode 必须是 metask 或 provider")
        signed_in = mode == "metask" and bool(models)
        known = {m["id"] for m in models}
        # An import refuses these ids; a clash appears only when the
        # --provider-config changes later. One id never names two routes.
        shadowing = sorted({m["provider"] for m in imported if m["id"] in known})
        for provider in shadowing:
            warnings.append(f"导入的 Provider {provider} 与 --provider-config 中的同名 Provider 冲突，"
                            "它的模型已隐藏；请删除后换一个标识重新导入")
        models = models + [m for m in imported if m["provider"] not in shadowing]
        states, default_executor, problems = self.executor_states(cfg)
        reasons += problems
        global_reasons = list(reasons)
        # Harbor suites need the Linux bundle; WorkBuddy brings its own
        # Harbor and staged artifacts and checks its own prerequisites.
        choices = bundle_choices(cfg, self.config_path)
        default_problem = None if choices or bundle_supplied else self.run_bundle(cfg, None, None)[1]
        harbor_reasons = [default_problem] if default_problem else []
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
                "executors": [{k: v for k, v in s.items() if k not in ("harbor", "node_reach", "node_workbuddy")} for s in states],
                "default_executor": default_executor, "global_reasons": global_reasons,
                "harbor_reasons": harbor_reasons,
                "login": {"available": mode == "metask" and bool((cfg.get("metacodes") or {}).get("binary")),
                          "signed_in": signed_in},
                "dataset": DATASET, "tasks": SAMPLE_TASKS,
                "default_suite": suites.DEFAULT_SUITE, "categories": suites.categories(),
                "suites": catalog_suites, "models": models,
                "default_model": model or (models[0]["id"] if models else ""),
                "key_env": key_env, "ready": not reasons, "reasons": reasons,
                "authentication": {"kind": mode, "label": "Metask 账号（执行机器已登录）" if signed_in else
                                   "Metask 账号（待登录）" if mode == "metask" else "第三方 Provider"},
                "reasoning_effort": effort,
                "warnings": warnings, "account_summary": account_summary,
                "account_groups": account_groups,
                "providers": {"count": len({m["provider"] for m in imported}), "models": len(imported)},
                "defaults": {"attempts": 4, "concurrency": 10}, "runs": self.runs(),
                "features": [{"id": name, "group": entry["group"], "label": entry["label"]}
                             for name, entry in ADVANCED_FEATURES.items()],
                "default_features": DEFAULT_FEATURES,
                "bundles": [{k: v for k, v in b.items() if k != "source"} for b in choices]}

    def add_provider(self, request):
        return self.providers.add(request, reserved=configured_provider_ids(settings(self.config_path)))

    @staticmethod
    def imported_route_problem(route):
        """route_problem for an imported provider's generated config."""
        import tempfile
        with tempfile.TemporaryDirectory(prefix="bench-provider-") as directory:
            path = write_config(Path(directory) / "provider.json", route["config"])
            return route_problem({"auth_mode": "provider", "model": route["model"], "provider_config": path})

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

    def bundle_problem(self, path, cfg):
        try:
            check_bundle(Path(path or "/nonexistent-metacodes-bundle"))
        except ValueError:
            return "请用 metacodes bench --bundle <Linux发行包目录> 配置评测版本"
        if not builds.selectable(path, cfg.get("source_repo")):
            return (f"metacodes 包 {Path(path).name} 由 Git 构建，当前 source_repo 没有验证它；"
                    "请用 metacodes bench build --ref 重新验证，或换一个版本")
        return None

    def run_bundle(self, cfg, frozen, bundle):
        if frozen:
            return frozen["bundle"], builds.frozen_problem(frozen, cfg.get("source_repo"))
        path = bundle or cfg.get("bundle")
        resolved = str(Path(path).expanduser().resolve()) if path else None
        return resolved, self.bundle_problem(resolved, cfg)

    def launch(self, request, *, dry_run=False, frozen=None, profile=None, pinned=None, bundle=None):
        """Start one run. `dry_run` only validates (a profile checks every
        dataset before it queues them); `frozen` is a profile's frozen
        bundle, which replaces the configured one, and `profile` names that
        profile. `pinned` is the model route a queued run was checked with
        (the `route` of its dry run); a run whose model now resolves
        elsewhere — another source, or an imported provider at another
        revision — is refused, so one queued run never records an upstream
        other than the one it was checked against."""
        allowed = {"model", "tasks", "attempts", "concurrency", "dataset", "suite", "executor", "features", "max_tokens"}
        if not isinstance(request, dict) or set(request) - allowed:
            raise ValueError("只接受 model、suite、tasks、attempts、concurrency、dataset、executor、features、max_tokens")
        # `dataset` is the original API's only choice, kept for older clients.
        if "dataset" in request and request["dataset"] != DATASET:
            raise ValueError("dataset 只接受 " + DATASET + "；其他评测集请用 suite")
        suite_id = request.get("suite", suites.DEFAULT_SUITE)
        if "dataset" in request and suite_id != suites.DEFAULT_SUITE:
            raise ValueError("suite 与 dataset 不一致")
        suite = suites.resolved(suites.get(suite_id))
        features = chosen_features(request.get("features"))
        if features and suite.runner == suites.WORKBUDDY:
            raise ValueError("WorkBuddy 评测暂不支持选择高级功能，请选择 Harbor 评测集")
        if self.setup_running():  # checked again under the lock below
            raise ValueError("一键配置正在进行（可能重启 Docker），请等配置结束再启动评测")
        catalog = self.catalog(bundle_supplied=frozen is not None or bundle is not None)
        wanted = request.get("executor", catalog["default_executor"])
        state = next((e for e in catalog["executors"] if e["name"] == wanted), None)
        if state is None:
            raise ValueError("；".join(catalog["global_reasons"]) or "请选择已配置的执行机器")
        entry = next(s for s in catalog["suites"] if s["id"] == suite.id)
        problems = entry["executors"][state["name"]]["reasons"]
        if problems:
            raise ValueError("；".join(problems))
        if TEAMWORK in features and not (state["kind"] == "ssh" and state.get("teamwork_privileged")):
            raise ValueError("Teamwork 评测只能在开启了 teamwork_privileged 的 SSH 执行机器上运行：任务容器要放开 bubblewrap "
                             "需要的权限，接近 privileged 容器，只适合用完即弃、没有凭证的专用节点")
        model = request.get("model")
        chosen = next((m for m in catalog["models"] if m["id"] == model), None)
        if chosen is None:
            raise ValueError("请选择服务已配置的模型")
        # A model of a provider imported by URL and key: its own route.
        imported = chosen.get("provider") if chosen.get("source") == "provider" else None
        route = ({"source": "imported", "provider": imported, "revision": self.providers.run_route(model)["revision"]}
                 if imported else {"source": catalog["authentication"]["kind"]})
        if pinned is not None and pinned != route:
            raise ValueError(f"模型 {model} 的来源在排队后已变化（导入的 Provider 被修改、删除或与配置重名），"
                             "本项不再运行；请重新运行")
        if imported:
            if suite.runner == suites.WORKBUDDY:
                raise ValueError("导入的 Provider 暂不支持 WorkBuddy 评测，请选择 Harbor 评测集")
            # In Metask authentication the judge goes through the run's relay,
            # which forwards to the imported upstream instead; in provider
            # authentication it reads the execution host's variables, which
            # do not depend on the agent's model, and stays allowed.
            if suites.judge(suite, settings(self.config_path)):
                raise ValueError(suite.id + " 的 LLM 评委经 Metask 账号转发，Metask 认证下导入的 Provider 不能运行带评委的评测集")
            problem = self.imported_route_problem(self.providers.run_route(model))
            if problem:
                raise ValueError(problem)
            problem = ssh_loopback_problem(state["kind"], state["name"], imported,
                                           self.providers.find(imported)["base_url"])
            if problem:
                raise ValueError(problem)
        elif catalog["authentication"]["kind"] == "provider" and suite.runner != suites.WORKBUDDY:
            cfg = settings(self.config_path)
            config = provider_config(cfg)
            problems = key_env_problems(provider_key_env(cfg, config, model), model)
            problem = "；".join(problems) or route_problem({"auth_mode": "provider", "model": model,
                                                            "provider_config": config})
            if problem:
                raise ValueError(problem)
        ctx = self.suite_context()
        tasks = suites.validate_tasks(suite, ctx, request.get("tasks"), known=self.node_tasks(suite, state["name"]))
        problem = self.staged_metacodes_problem(suite, state["name"],
                                                self.run_bundle(settings(self.config_path), frozen, bundle)[0])
        if problem:
            raise ValueError(problem)
        attempts, concurrency = request.get("attempts", 1), request.get("concurrency", 1)
        for name, value, limit in (("attempts", attempts, 5), ("concurrency", concurrency, suite.max_concurrency)):
            if type(value) is not int or not 1 <= value <= limit:
                raise ValueError(f"{name} 必须是 1–{limit} 的整数")
        max_tokens = request.get("max_tokens")
        if max_tokens is not None and (type(max_tokens) is not int or not 1024 <= max_tokens <= MAX_OUTPUT_TOKENS):
            raise ValueError(f"max_tokens 必须是 1024–{MAX_OUTPUT_TOKENS} 的整数")
        if dry_run:
            if suite.runner != suites.WORKBUDDY:
                problem = self.run_bundle(settings(self.config_path), frozen, bundle)[1]
                if problem:
                    raise ValueError(problem)
            return {"suite": suite.id, "tasks": tasks, "attempts": attempts, "concurrency": concurrency, "route": route,
                    "executor": state["name"], "features": features, "max_tokens": max_tokens}
        with self.lock:
            if any(run.get("status") in ACTIVE for run in self.runs()):
                raise ValueError("已有评测正在运行，请等待完成或先停止")
            owner = self.profile_guard() if profile is None else None
            if owner:
                raise ValueError("评测配置 " + owner + " 的队列正在运行，请等它结束或先停止")
            if self.setup_running():
                raise ValueError("一键配置正在进行（可能重启 Docker），请等配置结束再启动评测")
            cfg = settings(self.config_path)
            used_bundle = frozen["bundle"] if frozen else cfg.get("bundle")
            if suite.runner != suites.WORKBUDDY:
                used_bundle, problem = self.run_bundle(cfg, frozen, None)
                if problem:
                    raise ValueError(problem)
            executor = executors.find(cfg, state["name"])
            facts = self.executor_facts(executor)
            mode = "provider" if imported else catalog["authentication"]["kind"]
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
            if max_tokens is not None:
                record["max_tokens"] = max_tokens
            shown_judge = suites.judge_label(suite, cfg)
            if shown_judge:
                record["judge"] = shown_judge  # model id and route only
            from scripts.eval.harbor.bench.profiles import current_metacodes
            metacodes = ({k: frozen.get(k) for k in ("label", "commit", "digest", "release", "frozen")}
                         if frozen else current_metacodes(cfg, used_bundle))
            if metacodes:
                record["metacodes"] = metacodes
            if profile:
                record["profile"] = profile
            if features:
                record["features"] = features
            if TEAMWORK in features:
                record["agent_timeout_multiplier"] = TEAMWORK_TIMEOUT_MULTIPLIER
            route = None
            if imported:
                # The run's own config (endpoint, model names, key variable)
                # and the revision it came from; the worker takes the key
                # from the private store only while that revision is current.
                # Resolved before the receipt, so a refusal leaves no run.
                route = self.providers.run_route(model)
                if pinned is not None and route["revision"] != pinned.get("revision"):
                    raise ValueError(f"导入的 Provider {imported} 在排队后被修改，本项不再运行；请重新运行")
                # Again on the snapshot the spec is written from, with the
                # executor it names (both were read anew since validation).
                problem = self.imported_route_problem(route) or ssh_loopback_problem(
                    executor.kind, executor.name, imported, route["base_url"])
                if problem:
                    raise ValueError(problem)
            self.records.mkdir(parents=True, exist_ok=True)
            atomic_json(self.records / (name + ".json"), record)
            config = provider_config(cfg) if mode == "provider" and not imported else None
            if config and not cfg.get("provider_config"):
                native = data.read_json(Path(config)) or {}
                config = write_config(self.records / (name + ".provider"),
                                      {"custom_providers": native.get("custom_providers") or {}})
            spec = {**record, "jobs_dir": str(self.jobs_dir), "bundle": used_bundle,
                    "auth_mode": mode, "account_state_dir": cfg.get("account_state_dir") if mode == "metask" else None,
                    "account_gateway": cfg.get("account_gateway") if mode == "metask" else None,
                    "account_key_id": account_key_id,
                    "reasoning_effort": catalog.get("reasoning_effort"),
                    "provider_config": config,
                    "key_env": provider_key_env(cfg, config, model) if config else catalog["key_env"],
                    "metrics_enabled": cfg.get("metrics_enabled", True) and suite.runner != suites.WORKBUDDY,
                    "metrics_bind": cfg.get("metrics_bind", "172.17.0.1"),
                    "metrics_host": cfg.get("metrics_host"),
                    "executor": executor.spec(),
                    "store": store_config.for_workbench(cfg, self.config_path).to_json()}
            if suite.runner == suites.WORKBUDDY:
                from scripts.eval.harbor.suites import workbuddy
                # On an SSH executor the node resolves its own checkout and tools.
                spec["workbuddy"] = (workbuddy.spec_fields(suite, ctx) if executor.kind == "local"
                                     else {"subset": suite.subset})
                spec["workbuddy_judge"] = workbuddy.judge_model(suite, cfg)
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
            if route:
                spec.update(provider_config=write_config(self.records / (name + ".provider"), route["config"]),
                            model=route["model"], key_env=PROVIDER_KEY_ENV, imported_provider=imported,
                            imported_revision=route["revision"], providers_root=str(self.providers.root))
            spec_path = self.records / (name + ".spec")
            atomic_json(spec_path, spec)
            try:
                with (self.records / (name + ".log")).open("wb") as log:
                    process = subprocess.Popen([sys.executable, "-m", "scripts.eval.harbor.bench.worker", str(spec_path)],
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


DEFAULT_FEATURES = [name for name, entry in ADVANCED_FEATURES.items() if entry["group"] == "formal"]


def chosen_features(value):
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(name, str) for name in value):
        raise ValueError("features 必须是高级功能名称的列表")
    unknown = [name for name in value if name not in ADVANCED_FEATURES]
    if unknown:
        raise ValueError("未知的高级功能：" + "、".join(unknown))
    if TEAMWORK in value and len(set(value)) > 1:
        raise ValueError("Teamwork 只能单独开启：teamwork run 不接受其他高级功能的开关")
    return [name for name in ADVANCED_FEATURES if name in value]


def runtime_env():
    env = dict(os.environ)
    # Tools installed by `bench setup` (uv tools, Homebrew) are found even
    # when the service started with a minimal PATH; existing entries win.
    env["PATH"] = executors.search_path()
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[4])
    env["PYTHONUNBUFFERED"] = "1"
    return env
