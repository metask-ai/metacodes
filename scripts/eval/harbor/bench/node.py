"""`metacodes bench node`: this installation as a Bench node another one drives over SSH.

Every machine with `metacodes` installed is a node. A workbench reaches
another node the way an editor reaches a remote host: it runs that node's
own `metacodes` over SSH and talks to it on the channel's stdin/stdout.

    metacodes bench node info [--json] [--peer NAME]
    metacodes bench node peers [--json]
    metacodes bench node run <spec.json>
    metacodes bench node attach <spec.json>
    metacodes bench node build                   # {"ref", "repo"} on stdin
    metacodes bench node manifest <job-dir>
    metacodes bench node pack <job-dir>          # JSON items on stdin
    metacodes bench node egress-probe <json>

`info` describes this node from its own point of view: version, protocol,
machine, Docker and Harbor, and the WorkBuddy suites prepared here (their
readiness and task ids). `--peer` names the workbench asking, which this
node remembers, so either side can list the other (`peers`).

`run` executes one run on this node. A Harbor run is the argv the workbench
built (remote.py); a WorkBuddy run uses this node's own WorkBuddy checkout,
so it runs here exactly as it would on the workbench's own machine. The
channel protocol is remote.py's: the first stdin line carries the secrets,
later lines a refreshed token or `cancel`; stdout carries JSON events.
`attach` reconnects a new session to a run whose session was lost.
`build` builds one git revision's Linux unit in this node's own Docker,
exactly as `metacodes bench build` does on its own machine (builds.py), and
prints the unit as the last stdout line; closing stdin cancels it.
`manifest`, `pack` and `egress-probe` are remote.py's job copy-back and
setup's container egress check.

Python 3.9, stdlib only.
"""
from __future__ import annotations

import json
import os
import platform
import socket
import subprocess
import sys
import threading
from pathlib import Path

from scripts.eval.harbor import suites
from scripts.eval.harbor.bench import builds, executors, remote
from scripts.eval.harbor.bench.runner import atomic_json, now, settings

# Raised whenever the workbench and a node stop understanding each other's
# `info` or `run`; the workbench refuses a node with another protocol.
PROTOCOL = 8
PEERS = "peers.json"
# How long removing a run's image tag may take before the run ends anyway.
CLEANUP_TIMEOUT = 60


class Node:
    def __init__(self, state_root: Path, version: str):
        self.root = Path(state_root) / "bench"
        self.version = version or "unknown"
        self.cfg = settings(self.root / "workbench.json")

    def context(self) -> suites.Context:
        # The credential comes from the workbench driving this node, so this
        # node's own authentication setting never blocks a run here.
        return suites.Context({**self.cfg, "auth_mode": "metask"}, self.root)

    def docker_reasons(self):
        facts = executors.local_facts(executors.LocalExecutor(executors.DEFAULT_LOCAL, self.cfg.get("harbor")))
        return executors.docker_reasons(facts, "；在这台机器上运行 metacodes bench setup")

    def buildx_reasons(self):
        # WorkBuddy runs here build their mount image with `docker buildx`.
        try:
            done = subprocess.run(["docker", "buildx", "version"], stdin=subprocess.DEVNULL, capture_output=True,
                                  timeout=10)
            if done.returncode == 0:
                return []
        except (OSError, subprocess.SubprocessError):
            pass
        return ["缺少 docker buildx 插件（WorkBuddy 构建挂载镜像需要）；在这台机器上运行 metacodes bench setup，"
                "或由工作台对它运行 metacodes bench setup --executor <名称>"]

    def workbuddy(self):
        ctx, docker = self.context(), self.docker_reasons() + self.buildx_reasons()
        result = {}
        for suite in suites.WORKBUDDY_SUITES:
            try:
                tasks = suites.task_ids(suite, ctx)
            except suites.Unavailable:
                tasks = []
            result[suite.id] = {"reasons": docker + suites.readiness(suite, ctx), "tasks": tasks}
        return result

    def info(self):
        return {"protocol": PROTOCOL, "version": self.version, "host": socket.gethostname(),
                "os": platform.system(), "arch": platform.machine(), "workbuddy": self.workbuddy()}

    def remember(self, peer: str):
        if not executors.HOST.fullmatch(peer or ""):
            return
        known = settings(self.root / PEERS)
        known[peer] = {"last_seen": now()}
        atomic_json(self.root / PEERS, known)

    def peers(self):
        outgoing = []
        try:
            configured, _ = executors.configured(self.cfg)
            outgoing = [e.public() for e in configured if isinstance(e, executors.SshExecutor)]
        except ValueError:
            pass
        incoming = [{"name": name, **value} for name, value in sorted(settings(self.root / PEERS).items())
                    if isinstance(value, dict)]
        return {"outgoing": outgoing, "incoming": incoming}

    def run(self, spec_path: str) -> int:
        spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
        if spec.get("runner") == suites.WORKBUDDY:
            return self.run_workbuddy(spec, Path(spec_path).resolve().parent)
        return remote.run(spec_path)

    def build(self) -> int:
        try:
            request = json.loads(sys.stdin.buffer.readline())
            ref, repo = request["ref"], request.get("repo")
        except (ValueError, KeyError, TypeError):
            print("missing build request line", file=sys.stderr)
            return 2
        stop = threading.Event()

        def hang_up():
            while sys.stdin.buffer.read(1 << 16):
                pass
            stop.set()

        threading.Thread(target=hang_up, daemon=True).start()
        try:
            unit, info = builds.bundle(ref, self.root, repo if isinstance(repo, str) else None, cancelled=stop.is_set)
        except builds.BuildError as exc:
            print(f"{socket.gethostname()}：{exc}", file=sys.stderr, flush=True)
            return 1
        print(json.dumps({"bundle": unit.name, "path": str(unit), **info}, ensure_ascii=False), flush=True)
        return 0

    def run_workbuddy(self, spec, run_dir: Path) -> int:
        """WorkBuddy on this node's checkout. Its host proxy talks to a
        loopback relay holding only a placeholder; the relay forwards with the
        access token from the stdin line and swaps in each refreshed one."""
        from scripts.eval.harbor.profiling import PushedCredential, TimingRelay, placeholder
        from scripts.eval.harbor.suites import workbuddy
        os.chdir(os.path.expanduser("~"))
        remote.claim(run_dir)
        try:
            message = json.loads(sys.stdin.buffer.readline())
            credential = PushedCredential(message["credential"])
        except (ValueError, KeyError, TypeError):
            remote.emit("error", message="missing credential line")
            return 2
        suite = suites.get(spec.get("suite"))
        problems = self.workbuddy().get(suite.id, {}).get("reasons") or []
        if not spec.get("bundle"):
            problems.append("本次运行没有 metacodes 包；请把工作台和执行节点更新到同一版本")
        if problems:
            remote.emit("error", message=f"{socket.gethostname()}：" + "；".join(problems))
            return 2
        jobs_dir = remote.absolute(spec["jobs_dir"])
        token = placeholder(spec["name"])
        # The trials mount an image of this run's own tag, staged from the
        # run's bundle: run.sh reuses whatever an existing tag holds, and
        # another workbench on this Docker daemon may move the shared one.
        tag = workbuddy.run_image_tag(spec["name"])
        repo = workbuddy.checkout(self.context())
        spec = {**spec, "jobs_dir": jobs_dir,
                "workbuddy": {**workbuddy.spec_fields(suite, self.context()), "harness_image": tag}}
        env = dict(os.environ)
        env["METASK_API_KEY"] = token
        relay = None

        def prepare(stop):
            nonlocal relay
            try:
                if not workbuddy.build_harness_image(repo, remote.absolute(spec["bundle"]), tag, stop):
                    return None
                relay = TimingRelay(spec["account_gateway"], credential,
                                    Path(jobs_dir) / spec["name"] / ".bench-metrics",
                                    bind="127.0.0.1", token=token, record=False).__enter__()
                argv, cwd, child_env = workbuddy.launch({**spec, "account_gateway": relay.url + "/workbuddy"}, env)
            except (OSError, subprocess.SubprocessError) as exc:
                raise ValueError(f"WorkBuddy 启动失败：{exc}") from None
            return argv, child_env, cwd

        def finish():
            # Before the terminal event, still under heartbeats, and bounded.
            workbuddy.finish(spec)
            try:
                subprocess.run(["docker", "image", "rm", tag], stdin=subprocess.DEVNULL, capture_output=True,
                               timeout=CLEANUP_TIMEOUT)
            except (OSError, subprocess.SubprocessError):
                print(f"未能删除本次运行的镜像标签 {tag}", file=sys.stderr, flush=True)

        try:
            return remote.supervise(spec, None, None, credential, threading.Event(), threading.Event(),
                                    prepare=prepare, finish=finish, run_dir=run_dir)
        finally:
            if relay is not None:
                relay.__exit__(None, None, None)


def main(argv, state_root, version) -> int:
    os.environ["PATH"] = executors.search_path()
    args = list(argv)
    node = Node(state_root, version)
    action = args.pop(0) if args else ""
    if action == "info":
        if "--peer" in args[:-1]:
            node.remember(args[args.index("--peer") + 1])
        value = node.info()
        print(json.dumps(value, ensure_ascii=False) if "--json" in args else render_info(value))
        return 0
    if action == "peers":
        value = node.peers()
        print(json.dumps(value, ensure_ascii=False) if "--json" in args else render_peers(value))
        return 0
    if action == "run" and len(args) == 1:
        code = node.run(args[0])
        # The control channel's reader may still block on stdin, which the
        # workbench closes only after this process ends: exit without the
        # interpreter's shutdown waiting on that thread's buffer lock.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)
    if action == "attach" and len(args) == 1:
        code = remote.attach(args[0])
        sys.stdout.flush()
        os._exit(code)
    if action == "build" and not args:
        code = node.build()
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)
    if action in ("manifest", "pack", "egress-probe") and len(args) == 1:
        return remote.main([action, args[0]])
    print("usage: metacodes bench node info [--json] | peers [--json] | run <spec> | attach <spec> | build | "
          "manifest <dir> | pack <dir> | egress-probe <json>", file=sys.stderr)
    return 2


def render_info(value) -> str:
    lines = [f"metacodes {value['version']} 节点 {value['host']}（{value['os']} {value['arch']}，协议 {value['protocol']}）"]
    for suite_id, entry in value["workbuddy"].items():
        state = "可运行" if not entry["reasons"] else "；".join(entry["reasons"])
        lines.append(f"  {suite_id}：{state}")
    return "\n".join(lines)


def render_peers(value) -> str:
    lines = ["本节点连接的执行机器："]
    lines += ["  " + e["label"] for e in value["outgoing"]] or ["  （无）"]
    lines.append("连接过本节点的工作台：")
    lines += [f"  {p['name']}（最近 {p.get('last_seen', '?')}）" for p in value["incoming"]] or ["  （无）"]
    return "\n".join(lines)
