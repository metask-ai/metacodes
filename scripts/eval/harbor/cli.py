"""Implementation of `metacodes bench`; extracted with the binary's assets.

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
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor import suites
from scripts.eval.harbor.viewer.runner import RunManager, atomic_json, runtime_env, settings


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


class Client:
    def __init__(self, url, token="", api_url=None):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password:
            raise ValueError("工作台地址必须是 http(s) URL")
        self.url = urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, parsed.path.rstrip("/") + "/", "", ""))
        self.token = token or urllib.parse.parse_qs(parsed.query).get("token", [""])[0]
        self.api_url = api_url or self.url

    def request(self, path, payload=None):
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        body = None
        if payload is not None:
            body = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(urllib.parse.urljoin(self.api_url, path), data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            try:
                message = json.load(exc).get("error", str(exc.code))
            except (ValueError, AttributeError):
                message = str(exc.code)
            finally:
                exc.close()
            raise ValueError(message) from None

    def open_url(self):
        return self.url + ("?token=" + self.token if self.token else "")


def same_service(saved, jobs_dir, store):
    return bool(saved.get("url")) and saved.get("jobs_dir") == str(jobs_dir) and saved.get("store") == store.describe()


def ensure_service(args, root, config, jobs_dir, store):
    ready = root / "service.json"
    saved = settings(ready)
    if saved.get("url") and saved.get("jobs_dir") == str(jobs_dir):
        client = Client(saved["url"], saved.get("token", ""), saved.get("listen_url"))
        try:
            if client.request("api/workbench").get("service") == "metacodes-bench":
                if same_service(saved, jobs_dir, store):
                    return client
                # The store changed (or the service predates it): replace
                # the service so it does not keep writing the old store.
                client.request("api/stop", {})
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    client.request("api/workbench")
                    time.sleep(0.1)
        except (OSError, ValueError):
            pass
    # The CLI reserves a separate ready file per startup. A crashed or slow
    # old process cannot publish into the current startup's handshake.
    import uuid
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


def local_overview(store, jobs_dir):
    """Jobs from the store after bringing it up to date with the jobs directory."""
    from scripts.eval.harbor.store.backend import Store
    from scripts.eval.harbor.store.library import StoreLibrary

    library = StoreLibrary(Store(store), [jobs_dir] if jobs_dir.is_dir() else [], owns_store=True)
    try:
        library.sync()
        return library.overview()
    finally:
        library.close()


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


def main(argv=None):
    parser = argparse.ArgumentParser(prog="metacodes bench", description="查看评测、打开工作台，在页面选择任务和模型运行 Bench。")
    parser.add_argument("action", nargs="?", default="open",
                        choices=["open", "info", "list", "run", "stop", "prepare", "setup", "db", "sync"])
    parser.add_argument("db_command", nargs="?", choices=["status", "import", "migrate"], help="bench db 的子命令")
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
    parser.add_argument("--metacodes-binary", help=argparse.SUPPRESS)
    parser.add_argument("--metacodes-version", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if (args.db_command is None) != (args.action != "db"):
        parser.error("bench db 需要子命令 status、import 或 migrate" if args.action == "db" else "多余的参数 " + args.db_command)
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
        if client is None and args.action in ("info", "list"):
            saved = settings(root / "service.json")
            if same_service(saved, jobs_dir, store):
                existing = Client(saved["url"], saved.get("token", ""), saved.get("listen_url"))
                try:
                    if existing.request("api/workbench").get("service") == "metacodes-bench":
                        client = existing
                except (OSError, ValueError):
                    pass
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
            from scripts.eval.harbor.viewer import executors
            value = executors.sync_run(jobs_dir, args.run, log=lambda text: print(text, file=sys.stderr, flush=True))
            print(json.dumps(value, ensure_ascii=False) if args.json else
                  f"{value['name']}：已同步 {value['files']} 个文件到 {value['local_dir']}（{value['status']}）")
            return 0
        if args.action == "stop":
            saved = settings(root / "service.json")
            if client is None and saved.get("url"):
                client = Client(saved["url"], saved.get("token", ""), saved.get("listen_url"))
            if client is None:
                value = {"stopped": True, "message": "工作台未启动"}
            else:
                value = client.request("api/stop", {})
            print(json.dumps(value, ensure_ascii=False) if args.json else "Bench 工作台已停止；评测 worker 继续运行。")
            return 0
        if args.action == "setup":
            from scripts.eval.harbor.viewer import setup

            def show(progress, seen=set()):
                if args.json:
                    return
                for step in progress["steps"]:
                    key = (step["id"], step["status"])
                    if step["status"] != "running" and key not in seen:
                        seen.add(key)
                        print(f"  {step['title']}: {step['status']} {step['detail']}", file=sys.stderr, flush=True)
            options = {"bundle_version": args.bundle_version,
                       "source": str(args.source.expanduser().resolve()) if args.source else None}
            progress = setup.run_setup(config, args.executor, dry_run=args.dry_run, on_change=show, options=options)
            print(json.dumps(progress, ensure_ascii=False) if args.json else setup.format_progress(progress))
            return 0 if progress["status"] in ("ready", "planned") else 1
        if args.action in ("info", "list"):
            if args.action == "info":
                value = client.request("api/workbench") if client else RunManager(jobs_dir, config).catalog()
                if not args.json:
                    print("Bench 工作台：" + (client.url if client else "运行 metacodes bench 启动"))
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
            else:
                value = client.request("api/jobs") if client else {"jobs": local_overview(store, jobs_dir)}
                if not args.json:
                    for job in value["jobs"]:
                        summary = job["summary"]
                        print(f"{job['name']}  {job.get('model') or ''}  通过 {summary['counts']['pass']}/{summary['valid']}  无效 {summary['counts']['invalid']}")
                    if not value["jobs"]:
                        print("暂无评测，运行 metacodes bench 打开工作台。")
            if args.json:
                print(json.dumps(value, ensure_ascii=False))
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
            url = client.url + "#/run/" + record["name"]
            if args.wait:
                while record["status"] in ("queued", "starting", "running", "cancelling"):
                    time.sleep(1)
                    record = client.request("api/run?name=" + record["name"])
            if args.json:
                print(json.dumps({**record, "url": url}, ensure_ascii=False))
            else:
                print("评测 " + record["name"] + "：" + record["status"])
                print("Bench 工作台：" + url)
            return 1 if record["status"] in ("failed", "interrupted", "cancelled") else 0
        if args.json:
            print(json.dumps({"url": client.open_url(), "service": "metacodes-bench"}))
        else:
            print("Bench 工作台：" + client.open_url())
        if not args.no_open and not args.json:
            webbrowser.open(client.open_url())
        return 0
    except (ValueError, OSError) as exc:
        print("bench: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
