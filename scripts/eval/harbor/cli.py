"""Implementation of `metacodes bench`; extracted with the binary's assets.

The terminal presentation of the Bench runtime: it parses arguments, asks a
local `Workbench` or a running service (`Client`) and prints the answer.
Running trials belongs to `scripts.eval.harbor.bench`, the page to `viewer`.

Python 3.9+ suffices to open/read the workbench. Harbor and Docker are needed
only on the machine executing trials. No repository checkout is required.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import webbrowser
from pathlib import Path

from scripts.eval.harbor import suites
from scripts.eval.harbor.bench.client import Client
from scripts.eval.harbor.bench.runner import ACTIVE, RunManager, atomic_json, configured_provider_ids, runtime_env, settings
from scripts.eval.harbor.bench.workbench import open_local
from scripts.eval.harbor.store import config as store_config


def read_env(path):
    """Load this install's .env below the existing process environment."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    for line in lines:
        line = line.strip().removeprefix("export ")
        name, sep, value = line.partition("=")
        if not sep or not name.strip().isidentifier() or not name.strip().isupper():
            continue
        try:
            parts = shlex.split(value, comments=True)
        except ValueError:
            continue
        if len(parts) == 1:
            os.environ.setdefault(name.strip(), parts[0])


def saved_client(root, jobs_dir=None, store=None):
    """The client in one read of `service.json`; with `jobs_dir` (and `store`), only that service's."""
    saved = settings(root / "service.json")
    if not saved.get("url") or (jobs_dir is not None and saved.get("jobs_dir") != str(jobs_dir)):
        return None
    if store is not None and saved.get("store") != store.describe():
        return None
    return Client(saved["url"], saved.get("token", ""), saved.get("listen_url"))


def running_service(root, jobs_dir, store=None):
    """The service this install started for `jobs_dir` (and `store`), if it still answers."""
    # Check the directory and build the client from the same record: another
    # startup may publish a different directory's service between two reads.
    client = saved_client(root, jobs_dir, store)
    try:
        if client and client.request("api/workbench").get("service") == "metacodes-bench":
            return client
    except (OSError, ValueError):
        pass
    return None


def stop_service(client):
    """Stop a service and wait (briefly) until it no longer answers."""
    try:
        client.request("api/stop", {})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            client.request("api/workbench")
            time.sleep(0.1)
    except (OSError, ValueError):
        pass


def ensure_service(args, root, config, jobs_dir, store):
    client = running_service(root, jobs_dir, store)
    if client:
        return client
    stale = running_service(root, jobs_dir)
    if stale:
        # The store changed (or the service predates it): replace the
        # service so it does not keep writing the old store.
        stop_service(stale)
    ready = root / "service.json"
    # The CLI reserves a separate ready file per startup. A crashed or slow
    # old process cannot publish into the current startup's handshake.
    handshake = root / ("ready-" + uuid.uuid4().hex + ".json")
    command = [sys.executable, "-m", "scripts.eval.harbor.viewer.server", "--jobs-dir", str(jobs_dir),
               "--config", str(config), "--bind", args.bind, "--port", str(args.port),
               "--ready-file", str(handshake)]
    if args.public_url:
        command += ["--public-url", args.public_url]
    with (root / "service.log").open("ab") as log:
        process = subprocess.Popen(command, env=runtime_env(), cwd=str(Path(__file__).resolve().parents[3]),
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        value = settings(handshake)
        if value.get("url"):
            # Do not return a URL until its HTTP service answers.
            client = Client(value["url"], value.get("token", ""), value.get("listen_url"))
            try:
                client.request("api/workbench")
                atomic_json(ready, value)
                ready.chmod(0o600)
                handshake.unlink(missing_ok=True)
                threading.Thread(target=process.wait, daemon=True).start()
                return client
            except (OSError, ValueError):
                pass
        if process.poll() is not None:
            raise ValueError("工作台启动失败，请查看 " + str(root / "service.log"))
        time.sleep(0.1)
    process.terminate()
    raise ValueError("工作台未在 15 秒内就绪，请查看 " + str(root / "service.log"))


def print_suites(value):
    """Suites grouped by category, with what keeps each from running."""
    by_category = {}
    for suite in value.get("suites", []):
        by_category.setdefault(suite["category"], []).append(suite)
    for category in value.get("categories", []):
        rows = by_category.get(category["id"], [])
        if not rows:
            continue
        print(category["name"] + "：")
        for suite in rows:
            count = "?" if suite.get("task_count") is None else str(suite["task_count"])
            state = "可运行" if suite["ready"] else "待配置"
            print(f"  {suite['id']:<20} {suite['name']}（{count} 题，{state}）")
            # Service-wide and executor reasons are printed once above; here
            # only the suite's own and its per-executor combinations.
            shown = set(value.get("global_reasons", value.get("reasons", [])) + value.get("harbor_reasons", []))
            for executor in value.get("executors", []):
                shown.update(executor["reasons"])
            for reason in suite.get("suite_reasons", suite["reasons"]):
                if reason not in shown:
                    shown.add(reason)
                    print("      " + reason)
            for name, combo in (suite.get("executors") or {}).items():
                for reason in combo["reasons"]:
                    if reason not in shown:
                        print(f"      [{name}] " + reason)


def prepare_suite(args, root, config, cfg):
    """Run a harbor-local suite's adapter here, on the execution machine."""
    suite = suites.get(args.suite)
    if suite.runner != suites.HARBOR_LOCAL:
        raise ValueError(suite.name + " 不需要准备数据集")
    module = suites.adapter_module(suite)
    if module is None:
        raise ValueError(suite.name + " 适配器尚未接入")
    dest = root / "datasets" / suite.id
    import inspect
    try:
        takes_ctx = "ctx" in inspect.signature(module.prepare).parameters
    except (TypeError, ValueError):
        takes_ctx = False
    # Adapters that need the workbench settings (mirrors, options) or its
    # state root (source checkouts) take the suite Context as `ctx`.
    produced = Path(module.prepare(dest, ctx=suites.Context(cfg, root)) if takes_ctx
                    else module.prepare(dest)).resolve()
    if produced != dest.resolve():
        cfg.setdefault("datasets", {})[suite.id] = str(produced)
        atomic_json(config, cfg)
    tasks = suites.local_tasks(produced)
    return {"suite": suite.id, "dataset": str(produced), "task_count": len(tasks)}


PROVIDER_COMMANDS = ["add", "list", "remove", "probe"]


def read_key(args):
    """The API key from `--key-env` or stdin; never from argv (visible in
    the process list)."""
    if args.key_env:
        key = os.environ.get(args.key_env)
        if not key:
            raise ValueError("环境变量 " + args.key_env + " 为空")
        return key
    if sys.stdin.isatty():
        import getpass
        return getpass.getpass("API Key（输入不显示" + ("，留空沿用已保存的" if args.replace else "") + "）：")
    return sys.stdin.readline().strip()


def probe_line(result):
    head = ("探测通过" if result["ok"] else "探测失败") + f"：{result['provider']}/{result['model']}（{result['latency_ms']} ms）"
    detail = "发送 " + result["expected"] + "，回复 " + repr(result["reply"]) if "reply" in result else ""
    return "\n".join(x for x in (head, "  " + detail if detail else "", "  " + result["error"] if result.get("error") else "") if x)


def provider_command(args, root):
    from scripts.eval.harbor.bench.providers import Providers
    providers = Providers(root)
    if args.db_command == "list":
        value = providers.listing()
        if not args.json:
            for entry in value["providers"]:
                print(f"{entry['id']}  {entry['name']}  {entry['base_url']}  {entry['protocol']}  Key {entry['key_hint']}")
                for model in entry["models"]:
                    probe = model["probe"]
                    state = "未探测" if not probe else ("探测通过" if probe["ok"] else "探测失败") + " " + probe["at"]
                    print(f"  {model['id']}  {state}")
            if not value["providers"]:
                print("还没有导入 Provider：metacodes bench provider add --id <标识> --base-url <地址> --key-env <变量名>")
    elif not args.id:
        raise ValueError("bench provider " + args.db_command + " 需要 --id")
    elif args.db_command == "remove":
        value = providers.remove(args.id)
        if not args.json:
            print("已删除 Provider " + args.id)
    elif args.db_command == "probe":
        model = args.model.split("/", 1)[1] if args.model and args.model.startswith(args.id + "/") else args.model
        value = providers.probe(args.id, model)
        if not args.json:
            print(probe_line(value))
        if args.json:
            print(json.dumps(value, ensure_ascii=False))
        return 0 if value["ok"] else 1
    else:
        request = {"id": args.id, "base_url": args.base_url, "models": args.provider_model}
        for field, value in (("name", args.name), ("protocol", args.protocol), ("auth", args.auth_header)):
            if value:
                request[field] = value
        if args.replace:
            request["replace"] = True
        key = read_key(args)  # empty with --replace keeps the saved key
        if key:
            request["api_key"] = key
        value = providers.add(request, reserved=configured_provider_ids(settings(root / "workbench.json")))
        if not args.json:
            print(f"已导入 Provider {value['id']}：{len(value['models'])} 个模型")
            for model in value["models"]:
                print("  " + model["id"])
        if args.probe and value["models"]:
            value["probe"] = providers.probe(value["id"], value["models"][0]["name"])
            if not args.json:
                print(probe_line(value["probe"]))
    if args.json:
        print(json.dumps(value, ensure_ascii=False))
    return 0


def render_stop(_value):
    print("Bench 工作台已停止；评测 worker 继续运行。")


def render_info(value, url):
    print("Bench 工作台：" + (url or "运行 metacodes bench 启动"))
    print("执行环境：" + ("已就绪" if value.get("ready") else "待配置"))
    for reason in value.get("global_reasons", value.get("reasons", [])) + value.get("harbor_reasons", []):
        print("  " + reason)
    for executor in value.get("executors", []):
        print("执行机器：" + executor["label"] + ("（默认）" if executor.get("default") else "") + "：" +
              ("已就绪" if executor["ready"] else "待配置"))
        for reason in executor["reasons"]:
            print("    " + reason)
    for model in value.get("models", []):
        print("模型：" + model["id"])
    print_suites(value)


def render_list(value):
    for job in value["jobs"]:
        summary = job["summary"]
        print(f"{job['name']}  {job.get('model') or ''}  通过 {summary['counts']['pass']}/{summary['valid']}  无效 {summary['counts']['invalid']}")
    if not value["jobs"]:
        print("暂无评测，运行 metacodes bench 打开工作台。")


def render_run(record):
    print("评测 " + record["name"] + "：" + record["status"])
    print("Bench 工作台：" + record["url"])


def render_open(value):
    print("Bench 工作台：" + value["url"])


def show(value, as_json, render, *extra):
    if as_json:
        print(json.dumps(value, ensure_ascii=False))
    else:
        render(value, *extra)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="metacodes bench", description="查看评测、打开工作台，在页面选择任务和模型运行 Bench。")
    parser.add_argument("action", nargs="?", default="open",
                        choices=["open", "info", "list", "run", "stop", "prepare", "setup", "db", "sync", "provider"])
    parser.add_argument("db_command", nargs="?", choices=["status", "import", "migrate"] + PROVIDER_COMMANDS,
                        help="bench db 的子命令（status、import、migrate）或 bench provider 的子命令（add、list、remove、probe）")
    parser.add_argument("--state-root", type=Path, required=True, help=argparse.SUPPRESS)
    parser.add_argument("--url", default=os.environ.get("METACODES_BENCH_URL"), help="连接已有工作台（例如 devbox）")
    parser.add_argument("--jobs-dir", type=Path)
    parser.add_argument("--bundle", type=Path, help="用于评测的 Linux 发行包目录")
    parser.add_argument("--provider-config", type=Path, help="第三方 provider 的 config.json")
    parser.add_argument("--auth", choices=["metask", "provider"], help="默认使用当前 Metask 登录；provider 使用独立网关")
    parser.add_argument("--account-state-dir", type=Path, help="已登录 metacodes 的状态目录（默认当前安装）")
    parser.add_argument("--model", help="provider/model")
    parser.add_argument("--key-env", help="API Key 的环境变量名；不传 Key 本身")
    parser.add_argument("--harbor", help="Harbor 可执行文件")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="服务端口（默认自动选择）")
    parser.add_argument("--public-url", help="输出的工作台地址（用于 devbox 网络访问）")
    parser.add_argument("--no-open", action="store_true", help="仅输出链接，不打开浏览器")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--suite", help="评测集 id（bench info 列出；默认 " + suites.DEFAULT_SUITE + "）")
    parser.add_argument("--task", action="append", default=[], help="运行的任务名，可重复；省略时运行该评测集的推荐样例")
    parser.add_argument("--dataset", action="append", default=[], metavar="SUITE=DIR",
                        help="已生成的本地 Harbor 数据集目录（harbor-local 评测集）")
    parser.add_argument("--workbuddy-checkout", type=Path, help="WorkBuddy-Bench checkout（provision_checkout.sh 准备）")
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--wait", action="store_true", help="等待评测结束后返回结果和工作台链接")
    parser.add_argument("--store-sqlite", help="评测数据库使用该 SQLite 文件")
    parser.add_argument("--store-postgres", metavar="DSN", help="评测数据库使用 PostgreSQL（DSN 不含密码）")
    parser.add_argument("--store-password-env", metavar="NAME", help="PostgreSQL 密码所在的环境变量名")
    parser.add_argument("--to", metavar="TARGET", help="bench db migrate 的目标：SQLite 路径或 postgresql:// DSN")
    parser.add_argument("--password-env", metavar="NAME", help="迁移目标 PostgreSQL 密码所在的环境变量名")
    parser.add_argument("--switch", action="store_true", help="迁移校验后切换工作台到目标数据库")
    parser.add_argument("--verify", action="store_true", help="bench db import 按内容重新校验每个文件")
    parser.add_argument("--executor", help="执行机器名称（workbench.json 的 executors）")
    parser.add_argument("--run", metavar="NAME", help="sync：把这次 SSH 执行机器运行的结果同步回本机")
    parser.add_argument("--dry-run", action="store_true", help="setup：只检查并列出将执行的命令")
    parser.add_argument("--bundle-version", help="setup：下载这个发行版本的 Linux 包（X.Y.Z）")
    parser.add_argument("--source", type=Path, help="setup：开发版从这个源码目录交叉编译 Linux 包")
    parser.add_argument("--id", help="provider：Provider 标识（小写字母、数字、-、_），模型以 <标识>/<模型> 出现")
    parser.add_argument("--name", help="provider add：显示名称")
    parser.add_argument("--base-url", help="provider add：http(s)://主机 或 http(s)://主机/v1")
    parser.add_argument("--protocol", choices=["openai_chat", "openai_responses", "anthropic_messages"],
                        help="provider add：接口协议（默认 openai_chat）")
    parser.add_argument("--auth-header", choices=["bearer", "x-api-key"],
                        help="provider add：Key 放在哪个请求头（默认 Anthropic 用 x-api-key，其余 bearer）")
    parser.add_argument("--provider-model", action="append", default=[], metavar="MODEL",
                        help="provider add：模型名，可重复；省略时读取该地址的 /models")
    parser.add_argument("--replace", action="store_true", help="provider add：覆盖同名 Provider（不填 Key 时沿用已保存的）")
    parser.add_argument("--probe", action="store_true", help="provider add：导入后立即探测第一个模型")
    parser.add_argument("--metacodes-binary", help=argparse.SUPPRESS)
    parser.add_argument("--metacodes-version", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.action == "db" and args.db_command not in ("status", "import", "migrate"):
        parser.error("bench db 需要子命令 status、import 或 migrate")
    if args.action == "provider" and args.db_command not in PROVIDER_COMMANDS:
        parser.error("bench provider 需要子命令 add、list、remove 或 probe")
    if args.action not in ("db", "provider") and args.db_command is not None:
        parser.error("多余的参数 " + args.db_command)
    if args.store_sqlite and args.store_postgres:
        parser.error("--store-sqlite 与 --store-postgres 只能选一个")
    if args.store_password_env and not args.store_postgres:
        parser.error("--store-password-env 需要 --store-postgres")
    try:
        state = args.state_root.expanduser().resolve()
        read_env(state / ".env")
        root = state / "bench"
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if os.name != "nt":
            root.chmod(0o700)
        config = root / "workbench.json"
        cfg = settings(config)
        if args.store_sqlite:
            store_config.check_sqlite_path(args.store_sqlite)  # before a path collapses `://`
            cfg["store"] = store_config.SqliteConfig(Path(args.store_sqlite).expanduser().resolve()).to_json()
        elif args.store_postgres:
            cfg["store"] = store_config.PostgresConfig(args.store_postgres, args.store_password_env).to_json()
        store = store_config.for_workbench(cfg, config)
        if args.action == "db":
            from scripts.eval.harbor.store import commands
            if args.store_sqlite or args.store_postgres:
                atomic_json(config, cfg)
            jobs_dirs = [args.jobs_dir.expanduser().resolve()] if args.jobs_dir else [
                Path(cfg.get("jobs_dir") or root / "jobs").resolve()]
            return commands.run(args.db_command, active=store, jobs_dirs=jobs_dirs, target=args.to,
                                password_env=args.password_env, switch=args.switch, verify=args.verify,
                                as_json=args.json, config_path=config, settings=cfg, save=atomic_json)
        if args.action == "provider":
            # Local to this machine's workbench state, like setup; a running
            # service sees the change on its next catalog read.
            return provider_command(args, root)
        for name in ("bundle", "provider_config", "jobs_dir", "account_state_dir", "workbuddy_checkout"):
            value = getattr(args, name)
            if value is not None:
                cfg[name] = str(value.expanduser().resolve())
        for name in ("model", "key_env", "harbor"):
            value = getattr(args, name)
            if value is not None:
                cfg[name] = value
        cfg.setdefault("account_state_dir", str(state))
        for item in args.dataset:
            suite_id, sep, directory = item.partition("=")
            if not sep or not directory or suites.get(suite_id).runner != suites.HARBOR_LOCAL:
                parser.error("--dataset 需要 SUITE=DIR，SUITE 为 harbor-local 评测集")
            cfg.setdefault("datasets", {})[suite_id] = str(Path(directory).expanduser().resolve())
        if args.metacodes_binary or args.metacodes_version:
            # Non-secret: lets setup pick the matching Linux release and the
            # page start `metacodes login` for this install.
            cfg["metacodes"] = {"binary": args.metacodes_binary or "", "version": args.metacodes_version or ""}
        if args.auth:
            cfg["auth_mode"] = args.auth
        elif args.provider_config:
            cfg["auth_mode"] = "provider"
        jobs_dir = Path(cfg.get("jobs_dir") or root / "jobs").resolve()
        cfg["jobs_dir"] = str(jobs_dir)
        atomic_json(config, cfg)
        client = Client(args.url, os.environ.get("METACODES_BENCH_TOKEN", "")) if args.url else None
        if args.action == "prepare":
            if args.url or not args.suite:
                parser.error("bench prepare 需要 --suite，并在执行机器本地运行")
            value = prepare_suite(args, root, config, cfg)
            print(json.dumps(value, ensure_ascii=False) if args.json else
                  f"{value['suite']}：{value['task_count']} 道任务 → {value['dataset']}")
            return 0
        if args.action == "sync":
            if not args.run:
                parser.error("bench sync 需要 --run NAME")
            from scripts.eval.harbor.bench import executors
            value = executors.sync_run(jobs_dir, args.run, log=lambda text: print(text, file=sys.stderr, flush=True))
            print(json.dumps(value, ensure_ascii=False) if args.json else
                  f"{value['name']}：已同步 {value['files']} 个文件到 {value['local_dir']}（{value['status']}）")
            return 0
        if args.action == "stop":
            client = client or saved_client(root)
            value = client.request("api/stop", {}) if client else {"stopped": True, "message": "工作台未启动"}
            show(value, args.json, render_stop)
            return 0
        if args.action == "setup":
            from scripts.eval.harbor.bench import setup

            def report(progress, seen=set()):
                if args.json:
                    return
                for step in progress["steps"]:
                    key = (step["id"], step["status"])
                    if step["status"] != "running" and key not in seen:
                        seen.add(key)
                        print(f"  {step['title']}: {step['status']} {step['detail']}", file=sys.stderr, flush=True)
            options = {"bundle_version": args.bundle_version,
                       "source": str(args.source.expanduser().resolve()) if args.source else None}
            progress = setup.run_setup(config, args.executor, dry_run=args.dry_run, on_change=report, options=options)
            print(json.dumps(progress, ensure_ascii=False) if args.json else setup.format_progress(progress))
            return 0 if progress["status"] in ("ready", "planned") else 1
        if args.action in ("info", "list"):
            client = client or running_service(root, jobs_dir, store)
            if args.action == "info":
                value = client.request("api/workbench") if client else RunManager(jobs_dir, config).catalog()
                show(value, args.json, render_info, client.url if client else None)
            elif client:
                show(client.request("api/jobs"), args.json, render_list)
            else:
                # Without a service, the runtime answers from this machine's store.
                local = open_local(store, jobs_dir)
                try:
                    show({"jobs": local.overview()}, args.json, render_list)
                finally:
                    local.close()
            return 0
        client = client or ensure_service(args, root, config, jobs_dir, store)
        if args.action == "run":
            workbench = client.request("api/workbench")
            suite_id = args.suite or workbench.get("default_suite") or suites.DEFAULT_SUITE
            tasks = args.task
            if not tasks:
                tasks = client.request("api/suite?id=" + urllib.parse.quote(suite_id)).get("default_tasks")
                if not tasks:
                    parser.error("bench run 需要 --task（该评测集没有推荐样例），可重复选择几道题")
            model = args.model or workbench.get("default_model")
            payload = {"model": model, "tasks": tasks, "attempts": args.attempts, "concurrency": args.concurrency}
            if args.suite:
                payload["suite"] = args.suite
            if args.executor:
                payload["executor"] = args.executor
            record = client.request("api/runs", payload)
            if args.wait:
                while record["status"] in ACTIVE:
                    time.sleep(1)
                    record = client.request("api/run?name=" + record["name"])
            show({**record, "url": client.url + "#/run/" + record["name"]}, args.json, render_run)
            return 1 if record["status"] in ("failed", "interrupted", "cancelled") else 0
        show({"url": client.open_url(), "service": "metacodes-bench"}, args.json, render_open)
        if not args.no_open and not args.json:
            webbrowser.open(client.open_url())
        return 0
    except (ValueError, OSError) as exc:
        print("bench: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
