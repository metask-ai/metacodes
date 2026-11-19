"""One-click setup of a Bench execution machine (`metacodes bench setup`).

Each step checks first, installs only what is missing, then verifies, and
logs every command it runs. `dry_run` executes the read-only checks and lists
the exact commands an install would run. Results the readiness checks need
(Harbor path, Linux release bundle) are written to `workbench.json`; no secret
is ever stored or printed. Steps that need root run only with passwordless
sudo; otherwise the step reports the exact command for the user. Signing in to
Metask always stays with the user (`metacodes login`, or the page's 登录
button, which shows the device code).

    python3 -m scripts.eval.harbor.viewer.setup --config <workbench.json> \
        [--executor NAME] [--dry-run] [--progress FILE]

Python 3.9, stdlib only.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.request
import uuid
from pathlib import Path, PurePosixPath
from typing import Callable, Dict, List, Optional

from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.viewer import data, executors
from scripts.eval.harbor.viewer.executors import LocalExecutor, SshExecutor, display, shell_argv

UV_VERSION = "0.13.9"
HARBOR_VERSION = "0.26.0"
HARBOR_PYTHON = "3.12"
PSYCOPG = "psycopg[binary]==3.2.13" if sys.version_info < (3, 10) else "psycopg[binary]==3.3.9"
RELEASE_BASE = "https://github.com/metask-ai/metacodes/releases"
RELEASE_API = "https://api.github.com/repos/metask-ai/metacodes/releases/latest"
LINUX_TARGET = "x86_64-linux-gnu"          # release asset target (release.yml)
CROSS_TARGET = "x86_64-linux-gnu.2.31"     # its cli_target: glibc baseline
RELEASE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
ROSETTA = "${METACODES_BENCH_ROSETTA_DIR:-/Library/Apple/usr/libexec/oah/RosettaLinux}"
COLIMA_DEFAULTS = {"emulation": "rosetta", "cpu": 4, "memory": 8, "disk": 100}
# Docker on Colima: containers reach the Mac's loopback through the VM's
# user-mode gateway (host.lima.internal).
COLIMA_HOST = "192.168.5.2"
PROBE_IMAGE = "alpine:3.20"
FINAL = {"ok", "done", "planned", "manual", "failed", "skipped"}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


class Manual(Exception):
    """The step needs the user: `command` is what they should run."""

    def __init__(self, message, command=None):
        super().__init__(message)
        self.command = command


class Failed(Exception):
    pass


class Skip(Exception):
    pass


class Setup:
    """State and command runner shared by the steps of one setup run."""

    def __init__(self, config_path, executor_name=None, *, dry_run=False, on_change=None,
                 runner=subprocess.run, popen=subprocess.Popen, options=None):
        self.config_path = Path(config_path)
        self.cfg = self.settings()
        self.executor = executors.find(self.cfg, executor_name)
        self.dry_run = dry_run
        self.on_change = on_change or (lambda progress: None)
        self.runner, self.popen = runner, popen
        self.options = options or {}
        self.facts: Dict[str, str] = {}
        self.step: Optional[Dict] = None
        self.progress = {"schema_version": 1, "id": uuid.uuid4().hex[:12], "executor": self.executor.name,
                         "kind": self.executor.kind, "dry_run": dry_run, "status": "running",
                         "started_at": now(), "finished_at": None, "steps": []}
        self.lock = threading.Lock()

    # ----------------------------------------------------------- recording
    def settings(self):
        value = data.read_json(self.config_path) or {}
        return value if isinstance(value, dict) else {}

    def log(self, text):
        with self.lock:
            if self.step is not None:
                self.step["log"].append(text)
                del self.step["log"][:-200]
        self.on_change(self.progress)

    def run(self, argv, *, mutate, input=None, timeout=1800, check=False):
        """Run (or, in a dry run, list) one command. Mutating commands are
        never executed in a dry run."""
        line = display(argv)
        with self.lock:
            self.step["commands"].append({"command": line, "mutates": mutate,
                                          "executed": not (mutate and self.dry_run)})
        if mutate and self.dry_run:
            self.log("将执行：" + line)
            return None
        self.log("$ " + line)
        try:
            done = self.runner(argv, input=input, capture_output=True, text=True, timeout=timeout,
                               **({} if input is not None else {"stdin": subprocess.DEVNULL}))
        except subprocess.TimeoutExpired:
            raise Failed("命令超时：" + line) from None
        except OSError as exc:
            raise Failed(f"无法运行 {argv[0]}：{exc}") from None
        output = ((done.stdout or "") + (done.stderr or "")).strip()
        if output:
            self.log(output[-2000:])
        if check and done.returncode != 0:
            raise Failed(f"命令失败（{done.returncode}）：{line}")
        return done

    def sh(self, script, *, mutate=False, **kwargs):
        return self.run(shell_argv(self.executor, script), mutate=mutate, **kwargs)

    def out(self, script):
        """stdout of a read-only check, '' when it fails."""
        done = self.sh(script)
        return (done.stdout or "").strip() if done and done.returncode == 0 else ""

    def found(self, name):
        return self.out("command -v " + shlex.quote(name) + " 2>/dev/null")

    def note_action(self, text):
        """A non-command action (file write, download): listed in dry runs."""
        with self.lock:
            self.step["commands"].append({"command": text, "mutates": True, "executed": not self.dry_run})
        self.log(("将执行：" if self.dry_run else "") + text)
        return not self.dry_run

    def update_config(self, describe, change: Callable[[Dict], None]):
        """Read-modify-write workbench.json, keeping keys others own."""
        if not self.note_action("更新 " + str(self.config_path) + "：" + describe):
            return
        cfg = self.settings()
        change(cfg)
        data_path = self.config_path
        from scripts.eval.harbor.viewer.runner import atomic_json
        atomic_json(data_path, cfg)
        self.cfg = cfg

    def set_executor_value(self, key, value):
        """Persist an executor-scoped value (local Harbor goes top level,
        where the readiness check and launch already read it)."""
        def change(cfg):
            entries = cfg.get("executors")
            if isinstance(self.executor, LocalExecutor) and key == "harbor":
                cfg["harbor"] = value
            if isinstance(entries, list):
                for entry in entries:
                    if isinstance(entry, dict) and entry.get("name") == self.executor.name:
                        if not (isinstance(self.executor, LocalExecutor) and key == "harbor"):
                            entry[key] = value
        self.update_config(f"{self.executor.name}.{key} = {value}", change)

    # ----------------------------------------------------------- running
    def execute(self, plan):
        for step_id, title, function in plan:
            record = {"id": step_id, "title": title, "status": "running", "detail": "", "command": None,
                      "commands": [], "log": []}
            with self.lock:
                self.progress["steps"].append(record)
                self.step = record
            self.on_change(self.progress)
            try:
                status, detail = function(self)
            except Manual as exc:
                status, detail = "manual", str(exc)
                record["command"] = exc.command
            except Skip as exc:
                status, detail = "skipped", str(exc)
            except Failed as exc:
                status, detail = "failed", str(exc)
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                status, detail = "failed", f"{type(exc).__name__}: {exc}"
            record.update(status=status, detail=detail)
            self.on_change(self.progress)
        statuses = {s["status"] for s in self.progress["steps"]}
        self.progress["status"] = ("failed" if "failed" in statuses else
                                   "needs_user" if "manual" in statuses else
                                   "planned" if self.dry_run and "planned" in statuses else "ready")
        self.progress["finished_at"] = now()
        self.step = None
        self.on_change(self.progress)
        return self.progress

    @property
    def remote(self):
        return isinstance(self.executor, SshExecutor)

    def require_shell(self):
        if self.remote and self.facts.get("error"):
            raise Skip("需要先解决 SSH 访问")

    def os_name(self):
        if "os" not in self.facts:
            self.facts["os"] = self.out("uname -s") or "unknown"
        return self.facts["os"]


# ===================================================================== steps

def step_ssh(s: Setup):
    facts = executors.probe(s.executor, runner=s.runner)
    s.log("$ " + display(shell_argv(s.executor, "<probe>")))
    s.facts = dict(facts)
    problems = executors.reasons(s.executor, facts) if facts.get("error") else []
    if problems:
        hint = ["ssh", "-p", str(s.executor.port)] + (["-i", s.executor.identity_file] if s.executor.identity_file else [])
        raise Manual(problems[0], display(hint + [s.executor.destination, "true"]))
    if facts.get("os") != "Linux":
        raise Manual(s.executor.name + " 不是 Linux（uname -s = " + str(facts.get("os")) + "）")
    return "ok", f"已连接（{facts.get('os')} {facts.get('arch')}）"


def step_python(s: Setup):
    s.require_shell()
    python = s.executor.python
    check = shlex.quote(python) + " -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'"
    if s.sh(check).returncode == 0:
        return "ok", s.out(shlex.quote(python) + " --version")
    if s.found("apt-get") and sudo_available(s):
        s.sh("sudo -n apt-get install -y python3", mutate=True, check=True)
        return verified(s, s.sh(check) if not s.dry_run else None, "python3")
    raise Manual(s.executor.name + " 需要 Python 3.9+", "sudo apt-get install -y python3")


def sudo_available(s: Setup):
    done = s.sh("sudo -n true 2>/dev/null")
    return done is not None and done.returncode == 0


def verified(s: Setup, done, what):
    if s.dry_run:
        return "planned", "将安装 " + what
    if done is None or done.returncode != 0:
        raise Failed(what + " 安装后验证失败")
    return "done", "已安装 " + what


def step_uv(s: Setup):
    s.require_shell()
    if s.found("uv"):
        return "ok", s.out("uv --version")
    system = s.os_name()
    if system == "Darwin" and s.found("brew"):
        # Homebrew's formula follows its own release; the version is logged.
        s.run(["brew", "install", "uv"], mutate=True, check=True)
    elif s.found("curl"):
        s.sh(f"curl -LsSf https://astral.sh/uv/{UV_VERSION}/install.sh | "
             'env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh', mutate=True, check=True)
    elif s.found("wget"):
        s.sh(f"wget -qO- https://astral.sh/uv/{UV_VERSION}/install.sh | "
             'env UV_INSTALL_DIR="$HOME/.local/bin" UV_NO_MODIFY_PATH=1 sh', mutate=True, check=True)
    else:
        raise Manual("需要 curl 或 wget 才能安装 uv",
                     f"curl -LsSf https://astral.sh/uv/{UV_VERSION}/install.sh | sh")
    if s.dry_run:
        return "planned", "将用 Homebrew 安装 uv（版本随 Homebrew）" if system == "Darwin" and s.found("brew") else f"将安装 uv {UV_VERSION}（官方安装脚本，~/.local/bin）"
    version = s.out("uv --version")
    if not version:
        raise Failed("uv 安装后仍不可用")
    return "done", version


def harbor_state(s: Setup):
    listing = s.out("uv tool list 2>/dev/null")
    version = next((line.split()[1].lstrip("v") for line in listing.splitlines()
                    if line.startswith("harbor ") and len(line.split()) > 1), "")
    path = s.out('command -v harbor 2>/dev/null || { test -x "$HOME/.local/bin/harbor" && echo "$HOME/.local/bin/harbor"; }')
    if path and not version:
        text = s.out(shlex.quote(path) + " --version 2>&1")
        match = re.search(r"\d+\.\d+\.\d+", text)
        version = match.group(0) if match else ""
    return path, version


def record_harbor(s: Setup, path):
    """Save the Harbor path an executor reported. An SSH executor's entry
    must still parse afterwards: a path it would refuse is reported instead
    of written, so it cannot make the executors list unreadable."""
    if s.remote and not executors.remote_path_ok(path, executable=True):
        raise Failed(f"找到的 Harbor 路径 {path!r} 含有执行机器配置不接受的字符；"
                     "请把 Harbor 装到普通路径，或在 executors 中手工填写 harbor")
    s.set_executor_value("harbor", path)


def step_harbor(s: Setup):
    s.require_shell()
    path, version = harbor_state(s)
    recorded = s.executor.harbor if s.remote else s.cfg.get("harbor")
    if path and version == HARBOR_VERSION:
        if recorded != path:
            record_harbor(s, path)
        return "ok", f"Harbor {version}（{path}）"
    if not s.found("uv") and not s.dry_run:
        raise Failed("需要先安装 uv")
    s.sh(f"uv tool install --force --python {HARBOR_PYTHON} harbor=={HARBOR_VERSION}", mutate=True, check=True)
    if s.dry_run:
        return "planned", (f"将把 Harbor {version} 换成 {HARBOR_VERSION}" if version else f"将安装 Harbor {HARBOR_VERSION}")
    path, version = harbor_state(s)
    if not path or version != HARBOR_VERSION:
        raise Failed(f"Harbor 安装后验证失败（找到 {path or '无'} {version}）")
    record_harbor(s, path)
    return "done", f"Harbor {version}（{path}）"


# ----------------------------------------------------------------- docker

def docker_config_add_plugin_dir(s: Setup, plugin_dir):
    """Homebrew's compose/buildx plugins live outside Docker's default
    plugin path; Docker reads `cliPluginsExtraDirs` from its config."""
    path = Path.home() / ".docker" / "config.json"
    try:
        current = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except ValueError:
        raise Failed(str(path) + " 不是有效 JSON，请手动修复") from None
    dirs = current.get("cliPluginsExtraDirs") or []
    if plugin_dir in dirs:
        return
    if not s.note_action(f"在 {path} 的 cliPluginsExtraDirs 加入 {plugin_dir}"):
        return
    current["cliPluginsExtraDirs"] = dirs + [plugin_dir]
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".bench-setup.tmp")
    temporary.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def colima_settings(s: Setup):
    value = {**COLIMA_DEFAULTS, **(s.cfg.get("colima") or {})}
    if value["emulation"] not in ("rosetta", "qemu"):
        raise Failed("colima.emulation 只能是 rosetta 或 qemu")
    for key in ("cpu", "memory", "disk"):
        if type(value[key]) is not int or value[key] <= 0:
            raise Failed(f"colima.{key} 必须是正整数")
    return value


def colima_start_argv(s: Setup, settings):
    argv = ["colima", "start", "--runtime", "docker", "--cpu", str(settings["cpu"]),
            "--memory", str(settings["memory"]), "--disk", str(settings["disk"])]
    if settings["emulation"] == "rosetta":
        # Native arm64 VM; linux/amd64 containers run through Rosetta's
        # binfmt handler (fast, but not every x86 extension is translated).
        argv += ["--vm-type", "vz", "--vz-rosetta", "--arch", "aarch64", "--mount-type", "virtiofs"]
    else:
        # A whole x86_64 VM under QEMU: exact amd64, several times slower.
        argv += ["--vm-type", "qemu", "--arch", "x86_64"]
    # Harbor bind-mounts trial directories under the jobs dir.
    home = Path.home().resolve()
    mounts = [str(home)]
    jobs = Path(s.cfg["jobs_dir"]).resolve() if s.cfg.get("jobs_dir") else None
    if jobs and jobs != home and home not in jobs.parents:
        mounts.append(str(jobs))
    for mount in mounts:
        argv += ["--mount", mount + ":w"]
    return argv


def relay_reachable(s: Setup):
    """A container can reach a listener on the Mac's loopback through Colima's
    gateway: the path the timing relay uses."""
    if s.dry_run:
        s.run(["docker", "run", "--rm", PROBE_IMAGE, "nc", "-z", "-w", "5", COLIMA_HOST, "<临时端口>"], mutate=True)
        return True
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]

    def accept():
        try:
            listener.accept()[0].close()
        except OSError:
            pass
    threading.Thread(target=accept, daemon=True).start()
    try:
        done = s.run(["docker", "run", "--rm", PROBE_IMAGE, "nc", "-z", "-w", "5", COLIMA_HOST, str(port)],
                     mutate=True, timeout=300)
        return done is None or done.returncode == 0
    finally:
        listener.close()


def step_docker_macos(s: Setup):
    settings = colima_settings(s)
    brew = s.found("brew")
    wanted = ["docker", "docker-compose", "docker-buildx", "colima"]
    if settings["emulation"] == "qemu":
        wanted += ["qemu", "lima-additional-guestagents"]
    if settings["emulation"] == "rosetta" and s.found("sysctl") and s.out("sysctl -n kern.hv_support 2>/dev/null") == "0":
        # A macOS guest without nested virtualization (e.g. a cloud Mac VM)
        # cannot start the vz VM Colima needs; fail before installing anything.
        raise Failed("这台 Mac 本身是虚拟机，没有嵌套虚拟化（kern.hv_support=0），Colima 无法启动，"
                     "本机不能运行 Docker。请在 workbench.json 的 executors 配置一台 Linux SSH 执行机器")
    installed = set(s.out("brew list --formula -1 2>/dev/null").split()) if brew else set()
    missing = [f for f in wanted if f not in installed]
    if missing and not brew:
        if s.found("docker") and s.sh("docker info >/dev/null 2>&1").returncode == 0:
            return "ok", "Docker 可用（非 Homebrew 安装）"
        raise Manual("macOS 上用 Homebrew 安装 Colima 和 docker CLI；请先安装 Homebrew（需要管理员密码）",
                     '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"')
    changed = False
    if missing:
        s.run(["brew", "install"] + missing, mutate=True, check=True)
        changed = True
    prefix = s.out("brew --prefix") or "/opt/homebrew"
    docker_config_add_plugin_dir(s, prefix + "/lib/docker/cli-plugins")
    if settings["emulation"] == "rosetta" and s.sh(f'test -d "{ROSETTA}"').returncode != 0:
        raise Manual("Colima 的 Rosetta 模式需要 Rosetta（Linux 虚拟机版）。安装后重试；或在 workbench.json 设 colima.emulation=qemu",
                     "softwareupdate --install-rosetta --agree-to-license")
    running = s.sh("colima status >/dev/null 2>&1")
    if running is None or running.returncode != 0:
        s.run(colima_start_argv(s, settings), mutate=True, check=True, timeout=1800)
        changed = True
    if s.dry_run:
        if not s.found("docker") or s.sh("docker info >/dev/null 2>&1").returncode != 0:
            s.run(["docker", "context", "use", "colima"], mutate=True)
        s.run(["docker", "run", "--rm", "--platform", "linux/amd64", PROBE_IMAGE, "uname", "-m"], mutate=True)
        relay_reachable(s)
        s.update_config(f"metrics_bind = 127.0.0.1, metrics_host = {COLIMA_HOST}", lambda cfg: None)
        return ("planned" if changed or missing else "ok"), "Colima（" + settings["emulation"] + "）"
    if s.sh("docker info >/dev/null 2>&1").returncode != 0:
        s.run(["docker", "context", "use", "colima"], mutate=True, check=True)
    if s.sh("docker info >/dev/null 2>&1").returncode != 0:
        raise Failed("Colima 已启动，但 docker 仍连不上 daemon")
    for plugin in ("compose", "buildx"):
        if s.sh(f"docker {plugin} version >/dev/null 2>&1").returncode != 0:
            raise Failed(f"docker {plugin} 插件不可用（检查 ~/.docker/config.json 的 cliPluginsExtraDirs）")
    arch = s.run(["docker", "run", "--rm", "--platform", "linux/amd64", PROBE_IMAGE, "uname", "-m"],
                 mutate=True, timeout=600)
    if arch.returncode != 0 or (arch.stdout or "").strip() != "x86_64":
        raise Failed("Colima 无法运行 linux/amd64 镜像（uname -m = " + (arch.stdout or "").strip() + "）")
    if not relay_reachable(s):
        raise Failed(f"容器无法访问本机 {COLIMA_HOST}（凭据 relay 的回连地址）")

    def relay(cfg):
        cfg["metrics_bind"] = "127.0.0.1"
        cfg["metrics_host"] = COLIMA_HOST
    if s.cfg.get("metrics_bind") != "127.0.0.1" or s.cfg.get("metrics_host") != COLIMA_HOST:
        s.update_config(f"metrics_bind = 127.0.0.1, metrics_host = {COLIMA_HOST}", relay)
    return ("done" if changed else "ok"), "Colima（" + settings["emulation"] + "），linux/amd64 可运行"


def step_docker_linux(s: Setup):
    sudo = sudo_available(s)
    changed = False

    def root(command, manual):
        nonlocal changed
        if not sudo:
            raise Manual(manual, command)
        s.sh("sudo -n sh -c " + shlex.quote(command), mutate=True, check=True)
        changed = True

    if not s.found("docker"):
        root("curl -fsSL https://get.docker.com | sh", "需要 root 安装 Docker（无免密 sudo）")
    if not s.dry_run or s.found("docker"):
        info = s.sh("docker info 2>&1 >/dev/null")
        message = (info.stdout or "") + (info.stderr or "") if info else ""
        if info is not None and info.returncode != 0:
            if "ermission" in message:
                root('usermod -aG docker "$SUDO_USER"', "当前用户需要加入 docker 组")
                s.log("已加入 docker 组：新的登录会话生效（SSH 执行机器下次连接即生效）")
            else:
                root("systemctl enable --now docker", "Docker daemon 未运行，需要 root 启动")
        if s.sh("docker compose version >/dev/null 2>&1").returncode != 0:
            installer = "apt-get install -y docker-compose-plugin" if s.found("apt-get") else "dnf install -y docker-compose-plugin"
            root(installer, "缺少 docker compose 插件")
    arch = s.out("uname -m")
    if arch not in ("x86_64", "amd64"):
        s.log("注意：执行机器是 " + arch + "，linux/amd64 镜像需要 binfmt 模拟")
    bind = s.executor.metrics_bind if s.remote else s.cfg.get("metrics_bind", "172.17.0.1")
    if s.found("ip") and bind not in s.out("ip -4 -o addr show 2>/dev/null"):
        s.log(f"注意：本机没有 {bind}（Docker 网桥），凭据 relay 无法绑定；请设置 metrics_bind")
    if s.dry_run:
        return ("planned" if changed else "ok"), "Docker（" + (arch or "?") + "）"
    if s.sh("docker info >/dev/null 2>&1").returncode != 0:
        if changed:
            return "done", "已配置；docker 组权限在新的登录会话生效"
        raise Failed("docker daemon 仍不可达")
    return ("done" if changed else "ok"), "Docker 可用（" + (arch or "?") + "）"


def step_docker(s: Setup):
    s.require_shell()
    if s.os_name() == "Darwin":
        if s.remote:
            raise Manual("SSH 执行机器只支持 Linux")
        return step_docker_macos(s)
    return step_docker_linux(s)


def step_openssl(s: Setup):
    s.require_shell()
    test = ('d=$(mktemp -d) && openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes -subj /CN=bench-setup '
            '-addext "subjectAltName=IP:127.0.0.1,DNS:127.0.0.1" -addext "basicConstraints=critical,CA:TRUE" '
            '-keyout "$d/key.pem" -out "$d/ca.pem" >/dev/null 2>&1; status=$?; rm -rf "$d"; exit $status')
    if s.found("openssl") and s.sh(test).returncode == 0:
        return "ok", s.out("openssl version")
    if s.os_name() == "Darwin" and s.found("brew"):
        s.run(["brew", "install", "openssl@3"], mutate=True, check=True)
    elif s.found("apt-get") and sudo_available(s):
        s.sh("sudo -n apt-get install -y openssl", mutate=True, check=True)
    else:
        raise Manual("需要 OpenSSL（凭据 relay 用它生成临时证书）",
                     "brew install openssl@3" if s.os_name() == "Darwin" else "sudo apt-get install -y openssl")
    return verified(s, None if s.dry_run else s.sh(test), "OpenSSL")


# ----------------------------------------------------------------- bundle

def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url, destination=None, timeout=60):
    request = urllib.request.Request(url, headers={"User-Agent": "metacodes-bench-setup"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if destination is None:
            return response.read()
        with Path(destination).open("wb") as output:
            shutil.copyfileobj(response, output)
    return None


def safe_extract(archive_path, destination):
    """Extract a release archive: regular files and directories only, all
    inside `destination` (Python 3.9 has no extraction filter)."""
    destination = Path(destination).resolve()
    with tarfile.open(archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            parts = PurePosixPath(member.name).parts
            if PurePosixPath(member.name).is_absolute() or ".." in parts or not (member.isfile() or member.isdir()):
                raise Failed("发行包含不安全的条目：" + member.name)
            target = (destination / member.name).resolve()
            if destination != target and destination not in target.parents:
                raise Failed("发行包含不安全的条目：" + member.name)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)


def unit_root(directory):
    directory = Path(directory)
    if (directory / "manifest.json").is_file():
        return directory
    for child in directory.iterdir():
        if (child / "manifest.json").is_file():
            return child
    raise Failed(str(directory) + " 中没有 manifest.json")


def release_base(s: Setup):
    return (s.options.get("release_base") or os.environ.get("METACODES_RELEASE_BASE") or RELEASE_BASE).rstrip("/")


def download_release(s: Setup, version, bundles):
    """The verified Linux x86_64 release unit for `version`, unpacked."""
    name = f"metacodes-{version}-{LINUX_TARGET}"
    final = bundles / name
    if final.is_dir():
        try:
            check_bundle(final)
            s.log("已下载过 " + str(final))
            return final, None
        except ValueError:
            pass
    base = release_base(s)
    sums_url = f"{base}/download/{version}/metacodes-{version}-SHA256SUMS"
    archive_url = f"{base}/download/{version}/{name}.tar.gz"
    s.note_action("GET " + sums_url)
    s.note_action(f"GET {archive_url}，用 SHA256SUMS 校验后解压到 {final}")
    if s.dry_run:
        return final, None
    bundles.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".download-", dir=str(bundles)))
    try:
        sums = fetch(sums_url).decode("utf-8")
        expected = next((line.split()[0] for line in sums.splitlines()
                         if len(line.split()) == 2 and line.split()[1] == name + ".tar.gz"), None)
        if not expected or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise Failed(f"{version} 的 SHA256SUMS 没有 {name}.tar.gz")
        archive = work / (name + ".tar.gz")
        fetch(archive_url, archive, timeout=600)
        actual = sha256_file(archive)
        if actual != expected:
            raise Failed(f"SHA-256 不匹配：{actual} != {expected}")
        s.log(f"SHA-256 校验通过：{actual}")
        safe_extract(archive, work / "unpacked")
        root = unit_root(work / "unpacked")
        manifest = check_bundle(root)
        target = manifest.get("target") or {}
        if target.get("id") != LINUX_TARGET:
            raise Failed("发行包目标不是 " + LINUX_TARGET)
        shutil.rmtree(final, ignore_errors=True)
        root.replace(final)
        return final, actual
    finally:
        shutil.rmtree(work, ignore_errors=True)


def find_checkout(s: Setup):
    candidates = []
    if s.options.get("source"):
        candidates.append(Path(s.options["source"]))
    binary = (s.cfg.get("metacodes") or {}).get("binary")
    if binary:
        candidates += list(Path(binary).resolve().parents)
    for candidate in candidates:
        zon = candidate / "build.zig.zon"
        if zon.is_file() and (candidate / "build.zig").is_file() and (candidate / "scripts/bench_assets.zig").is_file():
            return candidate.resolve()
    return None


def find_zig(s: Setup, checkout):
    text = (checkout / "build.zig.zon").read_text(encoding="utf-8")
    match = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', text)
    wanted = match.group(1) if match else ""
    candidates = [shutil.which("zig")] + sorted(str(p) for p in (Path.home() / ".cache/metacodes-toolchains").glob(f"zig-*-{wanted}/zig"))
    for candidate in candidates:
        if not candidate:
            continue
        try:
            version = subprocess.run([candidate, "version"], capture_output=True, text=True, timeout=30).stdout.strip()
        except OSError:
            continue
        if version == wanted:
            return candidate
    raise Manual(f"从源码构建 Linux 发行包需要 Zig {wanted}", f"zig {wanted} （见 build.zig.zon）")


def kernel_pins(prefix):
    pins = []
    for option, stem in (("formal-kernel-sha256", "metacodes-formal-kernel"),
                         ("project-kernel-sha256", "metacodes-project-kernel")):
        path = Path(prefix) / "libexec/metacodes" / stem
        if not path.is_file():
            raise Failed("基础发行包缺少 " + stem)
        pins.append(f"-D{option}={sha256_file(path)}")
    return pins


def latest_release(s: Setup):
    override = s.options.get("base_release")
    if override:
        return override
    s.log("GET " + RELEASE_API)
    try:
        tag = json.loads(fetch(RELEASE_API, timeout=30))["tag_name"]
    except (OSError, ValueError, KeyError) as exc:
        raise Failed("无法读取最新发行版本：" + str(exc)) from None
    if not RELEASE.fullmatch(str(tag)):
        raise Failed("最新发行标签无效：" + str(tag))
    return tag


def build_overlay(s: Setup, checkout, bundles):
    """A development binary has no published asset. Cross-compile this
    checkout's executable for Linux on top of the newest verified release
    unit, whose Lean kernels (built natively in CI) the executable pins."""
    base_version = latest_release(s)
    base, _ = download_release(s, base_version, bundles)
    # The checkout is on the workbench's machine, whatever the executor.
    try:
        done = s.run(["git", "-C", str(checkout), "rev-parse", "--short=12", "HEAD"], mutate=False)
        commit = (done.stdout or "").strip() if done.returncode == 0 else ""
    except Failed:
        commit = ""
    commit = commit if re.fullmatch(r"[0-9a-f]{7,40}", commit) else "worktree"
    final = bundles / f"metacodes-dev-{commit}-{LINUX_TARGET}"
    zig = find_zig(s, checkout)
    staging = bundles / (final.name + ".staging")
    s.note_action(f"复制基础发行包 {base} 到 {staging}")
    pins = ["-Dformal-kernel-sha256=<基础发行包 formal kernel 的 SHA-256>", "-Dproject-kernel-sha256=<…>"]
    if not s.dry_run:
        shutil.rmtree(staging, ignore_errors=True)
        shutil.copytree(base, staging)
        pins = kernel_pins(staging)
    argv = [zig, "build", "install", "-Drelease-layout=true", "-Doptimize=ReleaseSafe", "-Dtarget=" + CROSS_TARGET,
            "-Dlean-kernels=off"] + pins + ["--prefix", str(staging)]
    if s.dry_run:
        s.run(["sh", "-c", "cd " + shlex.quote(str(checkout)) + " && " + display(argv)], mutate=True)
        return final, {"kind": "checkout-overlay", "base_release": base_version, "commit": commit}
    s.step["commands"].append({"command": "cd " + str(checkout) + " && " + display(argv), "mutates": True, "executed": True})
    s.log("$ cd " + str(checkout) + " && " + display(argv))
    done = s.runner(argv, cwd=str(checkout), capture_output=True, text=True, timeout=3600, stdin=subprocess.DEVNULL)
    s.log(((done.stdout or "") + (done.stderr or ""))[-2000:])
    if done.returncode != 0:
        shutil.rmtree(staging, ignore_errors=True)
        raise Failed("交叉编译 Linux 发行包失败")
    check_bundle(staging)
    shutil.rmtree(final, ignore_errors=True)
    staging.replace(final)
    return final, {"kind": "checkout-overlay", "base_release": base_version, "commit": commit}


def step_bundle(s: Setup):
    current = s.cfg.get("bundle")
    if current:
        try:
            manifest = check_bundle(Path(current))
            target = (manifest.get("target") or {}).get("id", "linux")
            return "ok", f"{current}（{target}）"
        except ValueError as exc:
            s.log("当前 bundle 不可用：" + str(exc))
    bundles = s.config_path.parent / "bundles"
    version = (s.options.get("bundle_version") or (s.cfg.get("metacodes") or {}).get("version") or "").split("+")[0]
    if RELEASE.fullmatch(version):
        path, digest = download_release(s, version, bundles)
        source = {"kind": "release", "version": version, "target": LINUX_TARGET, "sha256": digest,
                  "url": f"{release_base(s)}/download/{version}/metacodes-{version}-{LINUX_TARGET}.tar.gz"}
    else:
        checkout = find_checkout(s)
        if checkout is None:
            raise Manual(f"当前 metacodes 版本 {version or '未知'} 没有对应的发行包，也找不到源码目录",
                         "metacodes bench setup --bundle-version <X.Y.Z>   # 或 --source <checkout>，或 metacodes bench --bundle <dir>")
        path, source = build_overlay(s, checkout, bundles)

    def change(cfg):
        cfg["bundle"] = str(path)
        cfg["bundle_source"] = {k: v for k, v in source.items() if v is not None}
    s.update_config("bundle = " + str(path), change)
    return ("planned" if s.dry_run else "done"), str(path)


def step_remote_files(s: Setup):
    s.require_shell()
    bundle = s.cfg.get("bundle")
    if not bundle or not Path(bundle).is_dir():
        if s.dry_run:
            s.note_action(f"复制 bench 运行时与 Linux 发行包到 {s.executor.name}:{s.executor.remote('runtime')}/ 和 bundles/")
            return "planned", "发行包就绪后复制"
        raise Failed("需要先配置 Linux 发行包")
    if s.dry_run:
        s.note_action(f"tar | ssh {s.executor.destination} 解压到 {s.executor.remote('runtime', '<digest>')}")
        s.note_action(f"tar | ssh {s.executor.destination} 解压到 {s.executor.remote('bundles', '<digest>')}")
        return "planned", "运行时和发行包将按内容摘要复制"
    runtime = executors.ship_runtime(s.executor, log=s.log, runner=s.runner, popen=s.popen)
    remote_bundle = executors.ship_bundle(s.executor, Path(bundle), log=s.log, runner=s.runner, popen=s.popen)
    return "done", f"运行时 {runtime}，发行包 {remote_bundle}"


def step_psycopg(s: Setup):
    store = s.cfg.get("store") or {}
    if not (isinstance(store, dict) and store.get("backend") == "postgres"):
        raise Skip("未配置 PostgreSQL 存储")
    check = [sys.executable, "-c", "import psycopg"]
    done = s.run(check, mutate=False)
    if done.returncode == 0:
        return "ok", "psycopg 已安装"
    s.run([sys.executable, "-m", "pip", "install", "--user", PSYCOPG], mutate=True, check=True, timeout=1800)
    return verified(s, None if s.dry_run else s.run(check, mutate=False), PSYCOPG)


def step_login(s: Setup):
    mode = s.cfg.get("auth_mode") or ("provider" if s.cfg.get("provider_config") else "metask")
    if mode != "metask":
        raise Skip("使用第三方 Provider，不需要 Metask 登录")
    from scripts.eval.harbor.viewer.account import Account
    state = s.cfg.get("account_state_dir")
    try:
        Account(state).login()
        return "ok", "工作台机器已登录 Metask" + ("（远程执行使用本机解析的 Key）" if s.remote else "")
    except ValueError as exc:
        binary = (s.cfg.get("metacodes") or {}).get("binary") or "metacodes"
        command = [binary] + (["--state-dir", state] if state else []) + ["login"]
        raise Manual(str(exc) + "。需要本人登录：在终端运行下面的命令，或在页面点“登录”获取设备码",
                     display(command)) from None


def plan(s: Setup):
    steps = []
    if s.remote:
        steps += [("ssh", "SSH 访问", step_ssh), ("python", "Python 3.9+", step_python)]
    steps += [("uv", "uv", step_uv), ("harbor", "Harbor " + HARBOR_VERSION, step_harbor),
              ("docker", "Docker" + ("" if s.remote else "（macOS: Colima）"), step_docker),
              ("openssl", "OpenSSL", step_openssl), ("bundle", "Linux 发行包", step_bundle)]
    if s.remote:
        steps.append(("remote_files", "复制运行时和发行包", step_remote_files))
    steps += [("psycopg", "psycopg（PostgreSQL 存储）", step_psycopg), ("login", "Metask 登录", step_login)]
    return steps


def run_setup(config_path, executor=None, *, dry_run=False, on_change=None, options=None, **kwargs):
    if os.name == "nt":
        raise ValueError("bench setup 目前支持 macOS 和 Linux")
    setup = Setup(config_path, executor, dry_run=dry_run, on_change=on_change, options=options, **kwargs)
    return setup.execute(plan(setup))


def format_progress(progress):
    lines = [f"执行机器 {progress['executor']}（{progress['kind']}）" + ("：仅预演，未做任何修改" if progress["dry_run"] else "")]
    labels = {"ok": "已就绪", "done": "已完成", "planned": "将执行", "manual": "需要你操作", "failed": "失败",
              "skipped": "跳过", "running": "进行中"}
    for step in progress["steps"]:
        lines.append(f"[{labels.get(step['status'], step['status'])}] {step['title']}：{step['detail']}")
        for command in step["commands"]:
            if command["mutates"]:
                lines.append(("    将执行：" if not command["executed"] else "    已执行：") + command["command"])
        if step.get("command"):
            lines.append("    请运行：" + step["command"])
    lines.append("结果：" + {"ready": "执行环境已就绪", "planned": "预演完成", "needs_user": "还有需要你操作的步骤",
                           "failed": "有步骤失败，见上方日志"}.get(progress["status"], progress["status"]))
    return "\n".join(lines)


# ----------------------------------------------------------------- service side

class SetupManager:
    """Background setup runs launched from the page, one at a time. Each
    runs in its own process and records progress in a private file."""

    def __init__(self, config_path):
        self.config_path = Path(config_path)
        self.directory = self.config_path.parent / "setup"
        self.lock = threading.Lock()
        self.process = None

    def mutating(self):
        """Whether a setup that changes the machine (not a dry run) is
        running: a launch waits for it, as it waits for a launch."""
        value = self.latest()
        return isinstance(value, dict) and value.get("status") == "running" and not value.get("dry_run")

    def latest(self):
        files = sorted(self.directory.glob("*.json"), key=lambda p: p.stat().st_mtime) if self.directory.is_dir() else []
        value = data.read_json(files[-1]) if files else None
        alive = self.process is not None and self.process.poll() is None
        if isinstance(value, dict) and value.get("status") == "running" and not alive:
            import time
            # A setup process started by an earlier service, or one that died.
            if self.process is not None or time.time() - files[-1].stat().st_mtime > 1800:
                value = {**value, "status": "interrupted"}
        return value

    def start(self, request, runtime_env, cwd, busy=False):
        if not isinstance(request, dict) or set(request) - {"executor", "dry_run"}:
            raise ValueError("只接受 executor、dry_run")
        dry_run = request.get("dry_run", False)
        if not isinstance(dry_run, bool):
            raise ValueError("dry_run 必须是布尔值")
        cfg = data.read_json(self.config_path) or {}
        executor = executors.find(cfg, request.get("executor"))
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                raise ValueError("一键配置正在进行")
            if busy and not dry_run:
                raise ValueError("有评测正在运行，配置可能重启 Docker；请等评测结束")
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            ident = dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
            progress = self.directory / (ident + ".json")
            from scripts.eval.harbor.viewer.runner import atomic_json
            atomic_json(progress, {"schema_version": 1, "id": ident, "executor": executor.name, "kind": executor.kind,
                                   "dry_run": dry_run, "status": "running", "started_at": now(), "steps": []})
            argv = [sys.executable, "-m", "scripts.eval.harbor.viewer.setup", "--config", str(self.config_path),
                    "--executor", executor.name, "--progress", str(progress)] + (["--dry-run"] if dry_run else [])
            with (self.directory / (ident + ".log")).open("wb") as log:
                self.process = subprocess.Popen(argv, cwd=cwd, env=runtime_env, stdin=subprocess.DEVNULL,
                                                stdout=log, stderr=log, start_new_session=True)
            threading.Thread(target=self.process.wait, daemon=True).start()
            return {"id": ident, "executor": executor.name, "dry_run": dry_run, "status": "running"}


class LoginManager:
    """`metacodes login --provider metask --no-browser` for the page: the
    device flow prints a verification URL and code, then waits for the user
    to approve it in their own browser. No password reaches the workbench."""

    def __init__(self, config_path):
        self.config_path = Path(config_path)
        self.log_path = self.config_path.parent / "login.log"
        self.lock = threading.Lock()
        self.process = None

    def start(self, runtime_env):
        cfg = data.read_json(self.config_path) or {}
        binary = (cfg.get("metacodes") or {}).get("binary")
        if not binary or not Path(binary).is_file():
            raise ValueError("工作台不知道 metacodes 可执行文件位置，请在终端运行 metacodes login")
        state = cfg.get("account_state_dir")
        argv = [binary] + (["--state-dir", state] if state else []) + ["login", "--provider", "metask", "--no-browser"]
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                return self.status()
            fd = os.open(str(self.log_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "wb") as log:
                self.process = subprocess.Popen(argv, env=runtime_env, stdin=subprocess.DEVNULL, stdout=log,
                                                stderr=log, start_new_session=True)
            threading.Thread(target=self.process.wait, daemon=True).start()
        return self.status()

    def status(self):
        if self.process is None:
            # No sign-in started by this service: a device code left in the
            # log by an earlier one is stale whether or not it completed.
            return {"running": False, "exit_code": None, "verification_uri": None, "user_code": None,
                    "signed_in": False}
        text = data.tail(self.log_path) if self.log_path.exists() else ""
        uri = re.findall(r"^METASK_VERIFICATION_URI=(https?://\S+)$", text, re.M)
        code = re.findall(r"^METASK_USER_CODE=([A-Za-z0-9-]{1,32})$", text, re.M)
        running = self.process is not None and self.process.poll() is None
        exit_code = None if self.process is None or running else self.process.returncode
        return {"running": running, "exit_code": exit_code, "verification_uri": uri[-1] if uri else None,
                "user_code": code[-1] if code else None,
                "signed_in": exit_code == 0}


def main(argv=None):
    parser = argparse.ArgumentParser(description="One-click setup of a Bench execution machine")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--executor")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--progress", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    from scripts.eval.harbor.viewer.runner import atomic_json

    def save(progress):
        if args.progress:
            atomic_json(args.progress, progress)
    try:
        progress = run_setup(args.config, args.executor, dry_run=args.dry_run, on_change=save)
    except ValueError as exc:
        print("bench setup: " + str(exc), file=sys.stderr)
        if args.progress:
            value = data.read_json(args.progress) or {}
            atomic_json(args.progress, {**value, "status": "failed", "error": str(exc), "finished_at": now()})
        return 1
    print(json.dumps(progress, ensure_ascii=False) if args.json else format_progress(progress))
    return 0 if progress["status"] in ("ready", "planned") else 1


if __name__ == "__main__":
    sys.exit(main())
