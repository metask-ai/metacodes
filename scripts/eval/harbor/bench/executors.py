"""Execution machines for the Bench workbench: this host or a Linux host over SSH.

`workbench.json` may list `executors`; without one the workbench runs on this
host as before. An `ssh` executor runs the Harbor command on the remote host:

- the executor is a Bench node: its own `metacodes` (installed by setup at
  `<state_dir>/bin/metacodes`) answers `metacodes bench node ...` over SSH
  (node.py), describes itself (`info`) and runs the trials;
- the Linux release bundle the run evaluates is shipped over the SSH channel
  as a tar stream into a content-addressed directory under the executor's
  `state_dir`, once per digest;
- the run's real credential (account key, session access token or provider
  key) travels as the first line on the SSH channel's stdin, beside the
  run-scoped placeholder Harbor hands to the task containers; the real one
  lives only in the remote driver's relay (never argv, never a file, never
  Harbor's environment). A refreshed session access token follows on the
  same channel; the refresh token never leaves the workbench machine;
- the node's driver (remote.py) owns the credential relay next to
  the remote Docker daemon, reports heartbeats on stdout, cancels on request
  or when the channel closes;
- the remote job directory is copied back incrementally into the local jobs
  directory, so the viewer and other local readers see ordinary job files.

Python 3.9, stdlib only. Every subprocess is spawned with an argv list.
"""
from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Collection, Dict, List, Optional, Sequence, Tuple, Union

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$")
USER = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")
REMOTE_PATH = re.compile(r"^[A-Za-z0-9._/+-]{1,512}$")
# An executable's path (harbor, python) may also hold spaces and `@`, as a
# home directory can: it only ever travels as one argv word (shlex.join on
# the SSH command line, an argv list on the executor). state_dir stays
# strict; it is also interpolated into remote shell scripts.
REMOTE_EXECUTABLE = re.compile(r"^[A-Za-z0-9._/+@ -]{1,512}$")
DEFAULT_STATE_DIR = ".metacodes-bench"
DEFAULT_LOCAL = "local"
# Where `bench setup` installs tools (uv's ~/.local/bin, Homebrew). They are
# appended to PATH, so an existing PATH entry always wins.
# METACODES_BENCH_EXTRA_PATH replaces the list (tests use it to keep a host's
# real Homebrew out of reach).
EXTRA_PATH = "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"


def extra_path() -> str:
    return os.environ.get("METACODES_BENCH_EXTRA_PATH", EXTRA_PATH)


def path_prefix() -> str:
    return 'export PATH="$PATH:' + extra_path().replace('"', "") + '"; '

# `pypi_index`, `docker_mirrors` entries and `egress.proxy`: plain http(s)
# URLs (they reach shell scripts and JSON files on the executor).
MIRROR_URL = re.compile(r"^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/+-]*)?$")
# `ghcr_mirror`: a registry host (and optional port/path prefix).
REGISTRY_HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,252}(:[0-9]{1,5})?(/[a-z0-9._-]+)*$")
EGRESS_MODES = ("direct", "workbench")
EGRESS_HELP = 'egress 只能是 "direct"、"workbench" 或 {"proxy": "http://主机:端口"}'

CONTAINER_MIRRORS = ("apt", "pypi", "conda", "go", "rustup", "npm")
APT_CACHE_PORT = 3142
APT_CACHE_CONF = "/etc/apt/apt.conf.d/99metacodes-apt-cache"
COMPOSE_OVERLAY = "mirrors.compose.json"
APT_PROXY_SETTING = "Acquire::http::Proxy"
APT_CACHE_PROBE = r'''
import sys, time, urllib.request
for _ in range(int(sys.argv[2])):
    try:
        with urllib.request.urlopen(sys.argv[1], timeout=3) as response:
            sys.exit(0 if response.status == 200 else 1)
    except OSError:
        time.sleep(0.5)
sys.exit(1)
'''


def apt_cache_probe(executor: "SshExecutor", attempts: int) -> str:
    """Shell command on the executor that exits 0 once its apt cache answers."""
    return " ".join(shlex.quote(part) for part in (executor.python, "-c", APT_CACHE_PROBE,
                                                    executor.apt_cache_url + "/acng-report.html", str(attempts)))


def container_mirror_env(mirrors: Dict[str, str]) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if "pypi" in mirrors:
        env.update(PIP_INDEX_URL=mirrors["pypi"], UV_DEFAULT_INDEX=mirrors["pypi"])
    if "conda" in mirrors:
        root = mirrors["conda"].rstrip("/")
        env.update(CONDA_CHANNEL_ALIAS=root + "/cloud",
                   CONDA_DEFAULT_CHANNELS=root + "/pkgs/main," + root + "/pkgs/r")
    if "go" in mirrors:
        env["GOPROXY"] = mirrors["go"] + ",direct"
    if "rustup" in mirrors:
        root = mirrors["rustup"].rstrip("/")
        env.update(RUSTUP_DIST_SERVER=root, RUSTUP_UPDATE_ROOT=root + "/rustup")
    if "npm" in mirrors:
        env["NPM_CONFIG_REGISTRY"] = mirrors["npm"]
    return env


def task_owned_settings(dataset: Path, mirrors: Dict[str, str]) -> List[str]:
    """The mirror settings (environment variables, apt's proxy) that a task
    of `dataset` names in its compose files, task.toml or Dockerfiles."""
    wanted = list(container_mirror_env(mirrors)) + ([APT_PROXY_SETTING] if "apt" in mirrors else [])
    found = set()
    for path in Path(dataset).rglob("*"):
        name = path.name.lower()
        if not (name == "task.toml" or name.startswith("dockerfile") or
                (name.endswith((".yaml", ".yml")) and "compose" in name)):
            continue
        if not path.is_file() or path.is_symlink():
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        found.update(setting for setting in wanted if setting in text)
    return sorted(found)


def signal_group(process: subprocess.Popen, sig: int) -> None:
    try:
        os.killpg(process.pid, sig)
    except (ProcessLookupError, PermissionError):
        if process.poll() is None:
            raise


@dataclass(frozen=True)
class LocalExecutor:
    name: str = DEFAULT_LOCAL
    harbor: Optional[str] = None

    kind = "local"

    def public(self) -> Dict:
        return {"name": self.name, "kind": "local", "label": self.name + "（本机）"}

    def spec(self) -> Dict:
        return {"name": self.name, "kind": "local"}


@dataclass(frozen=True)
class SshExecutor:
    name: str
    host: str
    user: Optional[str] = None
    port: int = 22
    identity_file: Optional[str] = None
    state_dir: str = DEFAULT_STATE_DIR
    harbor: Optional[str] = None
    python: str = "python3"
    metrics_bind: str = "172.17.0.1"
    metrics_enabled: bool = True
    # Container egress: "direct" (the executor's own network), "workbench"
    # (through the workbench machine, see egress.py) or "proxy" (a site
    # proxy, egress_proxy).
    egress: str = "direct"
    egress_proxy: Optional[str] = None
    egress_ports: Tuple[int, ...] = (443, 80)
    # Networks the workbench proxy may connect to besides public addresses
    # (default: the fake-IP range 198.18.0.0/15, see egress.DEFAULT_ALLOW_NETWORKS).
    egress_allow: Optional[Tuple[str, ...]] = None
    # Mirrors: setup uses pypi_index and docker_mirrors, runs ghcr_mirror.
    pypi_index: Optional[str] = None
    docker_mirrors: Tuple[str, ...] = ()
    ghcr_mirror: Optional[str] = None
    container_mirrors: Tuple[Tuple[str, str], ...] = ()
    # Whether teamwork runs may give their task containers the permissions
    # bubblewrap needs (TEAMWORK_CONTAINER): near privileged, so only for a
    # disposable executor that holds no credentials.
    teamwork_privileged: bool = False

    kind = "ssh"

    @property
    def destination(self) -> str:
        return (self.user + "@" if self.user else "") + self.host

    def public(self) -> Dict:
        return {"name": self.name, "kind": "ssh", "teamwork_privileged": self.teamwork_privileged,
                "label": f"{self.name}（SSH {self.destination}:{self.port}）"}

    def spec(self) -> Dict:
        return {"name": self.name, "kind": "ssh", "host": self.host, "user": self.user, "port": self.port,
                "identity_file": self.identity_file, "state_dir": self.state_dir, "harbor": self.harbor,
                "python": self.python, "metrics_bind": self.metrics_bind,
                "metrics_enabled": self.metrics_enabled, "egress": self.egress_value(),
                "egress_ports": list(self.egress_ports),
                "egress_allow": list(self.egress_allow) if self.egress_allow is not None else None,
                "pypi_index": self.pypi_index,
                "docker_mirrors": list(self.docker_mirrors) or None, "ghcr_mirror": self.ghcr_mirror,
                "container_mirrors": dict(self.container_mirrors) or None,
                "teamwork_privileged": self.teamwork_privileged}

    @property
    def apt_cache_url(self) -> str:
        return f"http://{self.metrics_bind}:{APT_CACHE_PORT}"

    def compose_overlay(self, left_out: Collection[str] = ()) -> Optional[Dict]:
        """The Harbor compose overlay that points a run's task containers at
        container_mirrors, or None without any. Settings in `left_out`
        (environment variables, APT_PROXY_SETTING) are not set."""
        mirrors = dict(self.container_mirrors)
        if APT_PROXY_SETTING in left_out:
            mirrors.pop("apt", None)
        env = {k: v for k, v in container_mirror_env(mirrors).items() if k not in left_out}
        if not env and "apt" not in mirrors:
            return None
        main: Dict = {}
        overlay = {"services": {"main": main}}
        if env:
            main["environment"] = env
        if "apt" in mirrors:
            main["configs"] = [{"source": "metacodes_apt_cache", "target": APT_CACHE_CONF}]
            overlay["configs"] = {"metacodes_apt_cache": {
                "content": f'Acquire::http::Proxy "{self.apt_cache_url}";\n'}}
        return overlay

    def egress_value(self):
        """The `egress` field as written in workbench.json."""
        return {"proxy": self.egress_proxy} if self.egress == "proxy" else self.egress

    def remote(self, *parts: str) -> str:
        return str(PurePosixPath(self.state_dir, *parts))

    @property
    def node(self) -> str:
        """The executor's own `metacodes`, relative to its home directory."""
        return self.remote("bin", "metacodes")


Executor = Union[LocalExecutor, SshExecutor]


def with_teamwork(overlay: Optional[Dict], features, executor) -> Optional[Dict]:
    """The run's compose overlay, with the container permissions bubblewrap
    needs on Harbor's `main` service when the run uses teamwork."""
    from scripts.eval.harbor.command import TEAMWORK, TEAMWORK_CONTAINER
    if TEAMWORK not in features:
        return overlay
    if not executor.teamwork_privileged:
        raise ValueError(f"执行机器 {executor.name} 没有开启 teamwork_privileged，不能运行 Teamwork 评测")
    overlay = json.loads(json.dumps(overlay or {}))
    main = overlay.setdefault("services", {}).setdefault("main", {})
    for key, values in TEAMWORK_CONTAINER.items():
        main[key] = list(main.get(key) or []) + [v for v in values if v not in (main.get(key) or [])]
    return overlay


def parse(entry) -> Executor:
    """One validated executor entry; raises ValueError naming the problem."""
    if not isinstance(entry, dict):
        raise ValueError("executors 的每一项必须是对象")
    name, kind = entry.get("name"), entry.get("kind")
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ValueError("执行机器名称无效：" + repr(name))
    if kind == "local":
        extra = set(entry) - {"name", "kind", "harbor"}
        if extra:
            raise ValueError(f"{name}: 本机执行器不接受 {', '.join(sorted(extra))}")
        return LocalExecutor(name, entry.get("harbor"))
    if kind != "ssh":
        raise ValueError(f"{name}: kind 必须是 local 或 ssh")
    allowed = {"name", "kind", "host", "user", "port", "identity_file", "state_dir", "harbor", "python",
               "metrics_bind", "metrics_enabled", "egress", "egress_ports", "egress_allow", "pypi_index", "docker_mirrors",
               "ghcr_mirror", "container_mirrors", "teamwork_privileged"}
    extra = set(entry) - allowed
    if extra:
        raise ValueError(f"{name}: 不支持的字段 {', '.join(sorted(extra))}")
    host, user, port = entry.get("host"), entry.get("user"), entry.get("port", 22)
    if not isinstance(host, str) or not HOST.fullmatch(host):
        raise ValueError(f"{name}: host 无效")
    if user is not None and (not isinstance(user, str) or not USER.fullmatch(user)):
        raise ValueError(f"{name}: user 无效")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError(f"{name}: port 必须是 1–65535")
    identity = entry.get("identity_file")
    if identity is not None:
        if not isinstance(identity, str) or not identity or identity.startswith("-"):
            raise ValueError(f"{name}: identity_file 无效")
        identity = os.path.expanduser(identity)
    values = {}
    for field in ("state_dir", "harbor", "python"):
        value = entry.get(field)
        if value is None:
            continue
        if not remote_path_ok(value, executable=field != "state_dir"):
            raise ValueError(f"{name}: {field} 只能是普通路径")
        values[field] = value
    bind = entry.get("metrics_bind", "172.17.0.1")
    if not isinstance(bind, str) or not HOST.fullmatch(bind):
        raise ValueError(f"{name}: metrics_bind 无效")
    enabled = entry.get("metrics_enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError(f"{name}: metrics_enabled 必须是布尔值")
    teamwork = entry.get("teamwork_privileged", False)
    if not isinstance(teamwork, bool):
        raise ValueError(f"{name}: teamwork_privileged 必须是布尔值")
    values["teamwork_privileged"] = teamwork
    values.update(network_fields(name, entry))
    return SshExecutor(name=name, host=host, user=user, port=port, identity_file=identity,
                       metrics_bind=bind, metrics_enabled=enabled, **values)


def network_fields(name: str, entry: Dict) -> Dict:
    """egress / egress_ports / mirrors of an ssh entry, validated. `None`
    stands for the default (spec() writes defaults that way)."""
    values: Dict = {}
    egress = entry.get("egress")
    if isinstance(egress, dict):
        proxy = egress.get("proxy")
        if set(egress) != {"proxy"} or not isinstance(proxy, str) or not MIRROR_URL.fullmatch(proxy) \
                or not proxy.startswith("http://"):
            raise ValueError(f"{name}: {EGRESS_HELP}")
        values.update(egress="proxy", egress_proxy=proxy.rstrip("/"))
    elif egress is None or egress in EGRESS_MODES:
        values["egress"] = egress or "direct"
    else:
        raise ValueError(f"{name}: {EGRESS_HELP}")
    ports = entry.get("egress_ports")
    if ports is not None:
        if not isinstance(ports, list) or not ports or len(ports) > 16 or \
                not all(type(p) is int and 1 <= p <= 65535 for p in ports):
            raise ValueError(f"{name}: egress_ports 必须是 1–65535 的端口列表")
        values["egress_ports"] = tuple(dict.fromkeys(ports))
    allow = entry.get("egress_allow")
    if allow is not None:
        try:
            if not isinstance(allow, list) or len(allow) > 16:
                raise ValueError
            nets = [ipaddress.ip_network(n, strict=False) for n in allow if isinstance(n, str)]
            if len(nets) != len(allow) or any(n.is_loopback or n.is_link_local or n.is_unspecified for n in nets):
                raise ValueError
        except ValueError:
            raise ValueError(f"{name}: egress_allow 必须是网段列表（如 198.18.0.0/15），不能含回环或链路本地地址") from None
        values["egress_allow"] = tuple(str(n) for n in nets)
    index = entry.get("pypi_index")
    if index is not None:
        if not isinstance(index, str) or not MIRROR_URL.fullmatch(index):
            raise ValueError(f"{name}: pypi_index 必须是 http(s) 地址")
        values["pypi_index"] = index
    mirrors = entry.get("docker_mirrors")
    if mirrors is not None:
        if not isinstance(mirrors, list) or len(mirrors) > 8 or \
                not all(isinstance(m, str) and MIRROR_URL.fullmatch(m) for m in mirrors):
            raise ValueError(f"{name}: docker_mirrors 必须是 http(s) 地址列表")
        values["docker_mirrors"] = tuple(dict.fromkeys(mirrors))
    ghcr = entry.get("ghcr_mirror")
    if ghcr is not None:
        if not isinstance(ghcr, str) or not REGISTRY_HOST.fullmatch(ghcr):
            raise ValueError(f"{name}: ghcr_mirror 必须是镜像仓库主机名（如 ghcr.nju.edu.cn）")
        values["ghcr_mirror"] = ghcr
    container = entry.get("container_mirrors")
    if container is not None:
        if not isinstance(container, dict) or not set(container) <= set(CONTAINER_MIRRORS) or \
                not all(isinstance(url, str) and MIRROR_URL.fullmatch(url) for url in container.values()):
            raise ValueError(f"{name}: container_mirrors 的键只能是 {'、'.join(CONTAINER_MIRRORS)}，值必须是 http(s) 地址")
        if "apt" in container and not container["apt"].startswith("http://"):
            raise ValueError(f"{name}: container_mirrors.apt 必须是 http:// 地址（apt 缓存按 HTTP 回源）")
        if "apt" in container and values["egress"] != "direct":
            raise ValueError(f"{name}: container_mirrors.apt 只能和 egress = direct 一起用（apt 缓存由执行机器直接回源）")
        values["container_mirrors"] = tuple(sorted(container.items()))
    return values


def remote_path_ok(value, executable=False) -> bool:
    """A plain path on the executor (see REMOTE_PATH / REMOTE_EXECUTABLE)."""
    pattern = REMOTE_EXECUTABLE if executable else REMOTE_PATH
    return (isinstance(value, str) and bool(pattern.fullmatch(value)) and ".." not in value.split("/")
            and not value.startswith("-") and value == value.strip())


def configured(cfg, invalid: Optional[List[Tuple[str, str]]] = None) -> Tuple[List[Executor], str]:
    """The executors in `cfg` and the default name. Without a list, this host.

    A malformed entry is left out (and appended to `invalid` as (name,
    reason)), so one bad entry never makes the others unusable; a list
    without one valid entry, duplicate names or a default naming no valid
    entry is an error."""
    entries = cfg.get("executors")
    if entries is None:
        return [LocalExecutor(DEFAULT_LOCAL, cfg.get("harbor"))], DEFAULT_LOCAL
    if not isinstance(entries, list) or not entries:
        raise ValueError("executors 必须是非空列表")
    result, problems = [], []
    for index, entry in enumerate(entries):
        try:
            result.append(parse(entry))
        except ValueError as exc:
            label = entry.get("name") if isinstance(entry, dict) and isinstance(entry.get("name"), str) else ""
            problems.append((label if NAME.fullmatch(label or "") else f"executors[{index}]", str(exc)))
    if invalid is not None:
        invalid.extend(problems)
    if not result:
        raise ValueError("executors 中没有有效的执行机器：" + "；".join(p for _, p in problems))
    names = [e.name for e in result]
    if len(set(names)) != len(names):
        raise ValueError("执行机器名称重复")
    if sum(1 for e in result if isinstance(e, LocalExecutor)) > 1:
        raise ValueError("只能配置一个本机执行器")
    result = [LocalExecutor(e.name, e.harbor or cfg.get("harbor")) if isinstance(e, LocalExecutor) else e
              for e in result]
    default = cfg.get("default_executor") or names[0]
    if default not in names:
        broken = next((p for n, p in problems if n == default), None)
        raise ValueError("default_executor 配置无效：" + broken if broken else "default_executor 不在 executors 中")
    return result, default


def find(cfg, name: Optional[str]) -> Executor:
    executors, default = configured(cfg)
    wanted = name or default
    for executor in executors:
        if executor.name == wanted:
            return executor
    raise ValueError("未配置执行机器 " + str(wanted))


# ------------------------------------------------------------------ commands

def ssh_argv(executor: SshExecutor, remote: Optional[List[str]] = None, *, tty=False,
             reverse: Optional[Tuple[int, int]] = None) -> List[str]:
    """`ssh` argv for one remote command. The remote side receives one
    shell-quoted string, so every argument stays a single word there.

    `reverse` = (executor port, local port) adds a reverse forward from the
    executor's loopback to this machine's loopback; the session fails at
    once if the forward cannot be set up (ExitOnForwardFailure)."""
    argv = [shutil.which("ssh") or "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
            "-o", "StrictHostKeyChecking=accept-new", "-p", str(executor.port)]
    if executor.identity_file:
        argv += ["-i", executor.identity_file, "-o", "IdentitiesOnly=yes"]
    if reverse:
        argv += ["-o", "ExitOnForwardFailure=yes",
                 "-R", f"127.0.0.1:{int(reverse[0])}:127.0.0.1:{int(reverse[1])}"]
    argv.append("-tt" if tty else "-T")
    argv.append(executor.destination)
    if remote:
        argv.append(shlex.join(remote))
    return argv


TUNNEL_PORTS = range(20000, 32768)
TUNNEL_ATTEMPTS = 5


def tunnel_port(tried: Collection[int] = ()) -> int:
    return secrets.choice([port for port in TUNNEL_PORTS if port not in tried])


def forward_refused(returncode: Optional[int], stderr: Optional[str]) -> bool:
    return returncode == 255 and "remote port forwarding failed" in (stderr or "")


def tunnel_retry_note(executor: SshExecutor, refused: int, port: int, attempt: int) -> str:
    return (f"执行机器 {executor.name} 的回环端口 {refused} 上建不起 ssh -R 反向转发，"
            f"换端口 {port} 重试（第 {attempt}/{TUNNEL_ATTEMPTS} 次）")


def tunnel_unbound(executor: SshExecutor, ports: Sequence[int]) -> str:
    return (f"执行机器 {executor.name} 上绑不了隧道端口：ssh -R 试了 {len(ports)} 个回环端口"
            f"（{'、'.join(str(port) for port in ports)}）都没建起反向转发。可能这些端口已被占用，"
            "也可能执行机器不允许这个账号做远程端口转发（sshd_config 的 AllowTcpForwarding、PermitListen、"
            "DisableForwarding，或 authorized_keys 里的 no-port-forwarding、restrict）")


def node_prelude(executor: SshExecutor, binary: Optional[str] = None) -> str:
    """Shell that sets $n to the executor's node and hands it the configured
    Python. The node is `binary`, else setup's entry, else a `metacodes`
    already on the executor's PATH; the probe and every node command share
    this, so whatever the probe found is what runs."""
    q = shlex.quote
    find = (f"n={q(binary)}" if binary else
            f'n={q(executor.node)}; [ -x "$n" ] || n=$(command -v metacodes 2>/dev/null)')
    return (find + f"; py=$(command -v {q(executor.python)} 2>/dev/null); "
            'if [ -n "$py" ]; then METACODES_BENCH_PYTHON=$py; export METACODES_BENCH_PYTHON; fi; ')


def node_argv(executor: SshExecutor, *args: str, reverse: Optional[Tuple[int, int]] = None,
              binary: Optional[str] = None) -> List[str]:
    """`ssh` argv running `metacodes bench node <args>` on the executor."""
    script = (path_prefix() + node_prelude(executor, binary) +
              '[ -n "$n" ] || { echo "metacodes node not found" >&2; exit 127; }; '
              'exec "$n" bench node ' + shlex.join(args))
    return ssh_argv(executor, ["sh", "-c", script], reverse=reverse)


def shell_argv(executor: Executor, script: str) -> List[str]:
    """argv that runs a POSIX shell script on the executor."""
    if isinstance(executor, SshExecutor):
        return ssh_argv(executor, ["sh", "-c", path_prefix() + script])
    return ["/bin/sh", "-c", path_prefix() + script]


def display(argv: List[str]) -> str:
    return shlex.join(argv)


# ------------------------------------------------------------------ readiness

PROBE = r'''
echo "probe=1"
echo "os=$(uname -s)"
echo "arch=$(uname -m)"
harbor=""
for c in HARBOR_CANDIDATES; do
  [ -n "$c" ] || continue
  p=$(command -v "$c" 2>/dev/null) && [ -n "$p" ] && { harbor=$p; break; }
done
echo "harbor=$harbor"
echo "uv=$(command -v uv 2>/dev/null)"
d=$(command -v docker 2>/dev/null)
echo "docker=$d"
if [ -n "$d" ]; then
  if out=$(docker info --format '{{.ServerVersion}}' 2>&1); then echo "docker_daemon=ok"
  else case "$out" in *ermission*) echo "docker_daemon=permission";; *) echo "docker_daemon=down";; esac; fi
  docker compose version >/dev/null 2>&1 && echo "compose=1" || echo "compose=0"
fi
echo "openssl=$(command -v openssl 2>/dev/null)"
py=$(command -v PYTHON 2>/dev/null)
if [ -n "$py" ] && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then echo "python=$py"; else echo "python="; fi
echo "tar=$(command -v tar 2>/dev/null)"
echo "brew=$(command -v brew 2>/dev/null)"
echo "colima=$(command -v colima 2>/dev/null)"
if sudo -n true 2>/dev/null; then echo "sudo=1"; else echo "sudo=0"; fi
NODE_PRELUDE
if [ -n "$n" ] && [ -x "$n" ]; then echo "node=$("$n" bench node info --json --peer PEER 2>/dev/null)"; fi
if command -v ip >/dev/null 2>&1; then
  echo "docker0=$(ip -4 -o addr show docker0 2>/dev/null | sed -n 's/.* inet \([0-9.]*\).*/\1/p' | head -n 1)"
fi
'''


def probe_script(executor: Executor) -> str:
    candidates = [executor.harbor] if executor.harbor else []
    candidates += ["harbor", "$HOME/.local/bin/harbor"]
    quoted = " ".join(shlex.quote(c) if not c.startswith("$HOME") else '"' + c + '"' for c in candidates)
    python = executor.python if isinstance(executor, SshExecutor) else "python3"
    script = PROBE.replace("HARBOR_CANDIDATES", quoted).replace("PYTHON", shlex.quote(python))
    script = script.replace("PEER", shlex.quote(workbench_name()))
    return script.replace("NODE_PRELUDE", node_prelude(executor) if isinstance(executor, SshExecutor) else "n=")


def workbench_name() -> str:
    """How this machine introduces itself to the nodes it drives."""
    name = socket.gethostname()
    return name if HOST.fullmatch(name) else "workbench"


def search_path() -> str:
    extra = [os.path.expandvars(part.replace("$HOME", str(Path.home()))) for part in extra_path().split(":") if part]
    return os.pathsep.join([os.environ.get("PATH", "")] + extra)


def local_facts(executor: LocalExecutor, runner=subprocess.run) -> Dict:
    """The probe's facts for this host, without a shell (works on Windows)."""
    search = search_path()
    harbor = next((found for found in (shutil.which(c, path=search) for c in
                   [executor.harbor, "harbor"] if c) if found), None)
    facts = {"probe": "1", "os": os.uname().sysname if hasattr(os, "uname") else os.name,
             "harbor": harbor or "", "docker": shutil.which("docker", path=search) or "",
             "openssl": shutil.which("openssl", path=search) or "", "python": sys.executable}
    if facts["docker"]:
        try:
            info = runner([facts["docker"], "info", "--format", "{{.ServerVersion}}"], stdin=subprocess.DEVNULL,
                          capture_output=True, text=True, timeout=10)
            if info.returncode == 0:
                facts["docker_daemon"] = "ok"
            else:
                facts["docker_daemon"] = "permission" if "ermission" in (info.stderr or "") else "down"
            compose = runner([facts["docker"], "compose", "version"], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=10)
            facts["compose"] = "1" if compose.returncode == 0 else "0"
        except (OSError, subprocess.TimeoutExpired):
            facts["docker_daemon"] = "down"
    if facts["os"] == "Darwin" and facts.get("docker_daemon") != "ok":
        # A Mac that is itself a VM cannot start Colima's VM: say so instead
        # of pointing at a setup that cannot succeed.
        try:
            hv = runner(["/usr/sbin/sysctl", "-n", "kern.hv_support"], stdin=subprocess.DEVNULL,
                        capture_output=True, text=True, timeout=5)
            if hv.returncode == 0 and hv.stdout.strip() == "0":
                facts["hypervisor"] = "0"
        except (OSError, subprocess.TimeoutExpired):
            pass
    return facts


def probe(executor: Executor, runner=subprocess.run, timeout=25) -> Dict:
    """Facts about an executor, or {"error": ...} when it cannot be reached."""
    if isinstance(executor, LocalExecutor):
        return local_facts(executor, runner)
    argv = shell_argv(executor, probe_script(executor))
    if isinstance(executor, SshExecutor) and not shutil.which("ssh"):
        return {"error": "nossh"}
    try:
        done = runner(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"error": "timeout"}
    except OSError as exc:
        return {"error": "spawn", "detail": str(exc)}
    facts = {}
    for line in (done.stdout or "").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            facts[key.strip()] = value.strip()
    if facts.get("probe") != "1":
        detail = (done.stderr or "").strip().splitlines()
        return {"error": "ssh" if done.returncode == 255 else "noshell", "code": done.returncode,
                "detail": detail[-1] if detail else ""}
    if "node" in facts:
        try:
            node = json.loads(facts["node"])
        except ValueError:
            node = None
        facts["node"] = node if isinstance(node, dict) else {"error": "invalid"}
    return facts


def node_problem(executor: SshExecutor, facts: Dict) -> Optional[str]:
    """Why the executor's node cannot run this workbench's runs, or None."""
    from scripts.eval.harbor.bench.node import PROTOCOL
    where = f"{executor.name}（{executor.destination}:{executor.port}）"
    node = facts.get("node")
    if node is None:
        return f"{where} 上还没有 metacodes 节点；运行 metacodes bench setup --executor {executor.name} 或点“一键配置”安装"
    if node.get("protocol") != PROTOCOL:
        return (f"{where} 上的 metacodes 节点（{node.get('version') or '版本未知'}，协议 {node.get('protocol')}）"
                f"与工作台（协议 {PROTOCOL}）不兼容；运行 metacodes bench setup --executor {executor.name} 更新")
    return None


def reasons(executor: Executor, facts: Dict) -> List[str]:
    """Readiness reasons (Chinese, user-facing) for one executor."""
    setup = "；可运行 metacodes bench setup" + (" --executor " + executor.name if isinstance(executor, SshExecutor) else "") + " 或点“一键配置”"
    if isinstance(executor, SshExecutor):
        where = f"{executor.name}（{executor.destination}:{executor.port}）"
        error = facts.get("error")
        if error == "nossh":
            return ["未找到 ssh 客户端，无法连接 " + where]
        if error == "ssh":
            return [f"无法通过 SSH 登录 {where}：{(facts.get('detail') or '认证或连接失败').rstrip('.')}。"
                    "评测需要可执行命令的 SSH 密钥（仅端口转发的密钥不行），请在 executors 中配置 user/identity_file"]
        if error == "noshell":
            return [f"SSH 已连接 {where}，但不能执行远程命令（密钥可能限制为仅端口转发，或 forced command）。"
                    "请为工作台配置一个允许 shell 的密钥"]
        if error:
            return [f"连接 {where} 超时或失败"]
        result = []
        if facts.get("os") != "Linux":
            result.append(where + " 不是 Linux，SSH 执行机器只支持 Linux")
        if not facts.get("python"):
            result.append(where + " 缺少 Python 3.9+（远程驱动需要）" + setup)
        if not facts.get("tar"):
            result.append(where + " 缺少 tar")
        problem = node_problem(executor, facts)
        if problem:
            result.append(problem)
        if executor.egress == "workbench" and "docker0" in facts and not facts["docker0"] \
                and executor.metrics_bind.startswith("127."):
            # The forwarder falls back to metrics_bind, which containers
            # cannot reach when it is the host's loopback.
            result.append(f"{where} 没有 docker0 网桥，且 metrics_bind 是回环地址 {executor.metrics_bind}："
                          "容器无法连到“经工作台出网”的转发端口；请把 metrics_bind 设为容器可达的宿主机地址，"
                          "或把 egress 改为 direct")
    else:
        result = []
        if facts.get("error"):
            return ["无法检查本机执行环境"]
    if not facts.get("harbor"):
        result.append("未找到 Harbor，请在执行机器安装：uv tool install harbor==0.26.0" + setup)
    result += docker_reasons(facts, setup)
    if not facts.get("openssl"):
        result.append("未找到 OpenSSL（凭据 relay 需要）" + setup)
    return result


def reach_reasons(executor: SshExecutor, facts: Dict) -> List[str]:
    """What keeps the workbench from reaching a compatible node; suites the
    node prepares itself (WorkBuddy) add only the node's own report."""
    if facts.get("error"):
        return reasons(executor, facts)
    problem = node_problem(executor, facts)
    return [problem] if problem else []


def docker_reasons(facts: Dict, setup: str) -> List[str]:
    if facts.get("hypervisor") == "0":
        return ["这台 Mac 本身是虚拟机，没有嵌套虚拟化，不能运行 Docker；请配置一台 Linux SSH 执行机器"]
    if not facts.get("docker"):
        return ["未找到 Docker；Harbor 任务需要 Docker 环境" + setup]
    if facts.get("docker_daemon") == "permission":
        return ["当前用户无权访问 Docker daemon（需要加入 docker 组）" + setup]
    if facts.get("docker_daemon") != "ok":
        return ["Docker daemon 未运行或不可达" + setup]
    if facts.get("compose") != "1":
        return ["缺少 docker compose 插件" + setup]
    return []


# ------------------------------------------------------------------ remote files

def tree_files(root: Path, names=None) -> List[str]:
    root = Path(root)
    if names is not None:
        return sorted(names)
    found = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            found.append(path.relative_to(root).as_posix())
    return found


def tree_digest(root: Path, names: List[str]) -> str:
    digest = hashlib.sha256()
    for name in names:
        path = Path(root) / name
        digest.update(name.encode() + b"\0")
        digest.update(oct(path.stat().st_mode & 0o111).encode() + b"\0")
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1 << 20), b""):
                digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()[:16]


def ship(executor: SshExecutor, root: Path, names: List[str], destination: str, log=print,
         runner=subprocess.run, popen=subprocess.Popen, force=False) -> bool:
    """Copy `names` under `root` into `destination` on the executor, once.

    The directory appears atomically (extracted beside it, then renamed) and
    is marked complete; an existing complete directory is reused.
    """
    marker = destination + "/.complete"
    if not force:
        check = ssh_argv(executor, ["test", "-f", marker])
        log("$ " + display(check))
        if runner(check, stdin=subprocess.DEVNULL, capture_output=True).returncode == 0:
            return False
    temporary = destination + ".tmp-" + uuid.uuid4().hex[:8]
    q = shlex.quote
    script = (f"set -e; mkdir -p {q(temporary)}; tar -xf - -C {q(temporary)}; touch {q(temporary)}/.complete; "
              f"rm -rf {q(destination)}; mv {q(temporary)} {q(destination)}")
    argv = ssh_argv(executor, ["sh", "-c", script])
    log(f"$ {display(argv)}  < tar({len(names)} 个文件)")
    process = popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdin, mode="w|", format=tarfile.PAX_FORMAT) as archive:
            for name in names:
                path = Path(root) / name
                info = archive.gettarinfo(str(path), arcname=name)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                with path.open("rb") as source:
                    archive.addfile(info, source)
        process.stdin.close()
    except BrokenPipeError:
        pass
    stderr = process.stderr.read().decode(errors="replace") if process.stderr else ""
    if process.wait() != 0:
        raise ValueError(f"复制到 {executor.name}:{destination} 失败：{stderr.strip()[-300:]}")
    return True


def ship_bundle(executor: SshExecutor, bundle: Path, log=print, **kwargs) -> str:
    names = tree_files(bundle)
    destination = executor.remote("bundles", tree_digest(bundle, names))
    ship(executor, bundle, names, destination, log=log, **kwargs)
    return destination


def ship_dataset(executor: SshExecutor, dataset: Path, log=print, **kwargs) -> str:
    """A harbor-local suite's dataset directory (generated by `bench prepare`
    on this host), shipped once per content digest like the bundle."""
    dataset = Path(dataset)
    if not dataset.is_dir():
        raise ValueError("本地数据集目录不存在：" + str(dataset))
    # Adapters keep their download cache in <dataset>/.cache/ (Harbor and the
    # catalog skip it); only the generated task directories travel.
    names = [n for n in tree_files(dataset) if not n.split("/", 1)[0].startswith(".")]
    destination = executor.remote("datasets", tree_digest(dataset, names))
    ship(executor, dataset, names, destination, log=log, **kwargs)
    return destination


# ------------------------------------------------------------------ registry datasets

REGISTRY_MARKER = ".bench-registry.json"
REGISTRY_TIMEOUT = 3600


def workbench_harbor(cfg: Dict) -> Optional[str]:
    """Harbor on the workbench machine itself (registry downloads for SSH
    executors): the configured local Harbor, else one on the search path."""
    candidates = [cfg.get("harbor")]
    for entry in cfg.get("executors") or []:
        if isinstance(entry, dict) and entry.get("kind") == "local":
            candidates.append(entry.get("harbor"))
    search = search_path()
    for candidate in candidates + ["harbor"]:
        if not isinstance(candidate, str) or not candidate:
            continue
        found = shutil.which(candidate, path=search)
        if found:
            return found
    return None


def registry_cache_key(ref: str) -> str:
    return hashlib.sha256(ref.encode()).hexdigest()[:16]


def _task_dirs(directory: Path) -> List[str]:
    from scripts.eval.harbor.suites import local_tasks
    return local_tasks(directory)


def _cached_registry(final: Path, ref: str, expected) -> Optional[Path]:
    try:
        marker = json.loads((final / REGISTRY_MARKER).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(marker, dict) or marker.get("ref") != ref or not isinstance(marker.get("dataset"), str):
        return None
    dataset = final / marker["dataset"] if marker["dataset"] else final
    if final.resolve() not in dataset.resolve().parents and dataset.resolve() != final.resolve():
        return None
    tasks = set(_task_dirs(dataset))
    if len(tasks) != marker.get("tasks") or (expected and not set(expected) <= tasks):
        return None
    return dataset


REGISTRY_ATTEMPTS = 3
REGISTRY_BACKOFF = (5, 20)  # seconds before the 2nd and 3rd attempt


def registry_dataset(ref: str, cache_root: Path, harbor: Optional[str], expected=None, log=print,
                     runner=subprocess.run, timeout=REGISTRY_TIMEOUT, sleep=None) -> Path:
    """A Harbor registry dataset downloaded on this (the workbench) machine.

    `harbor download REF -o DIR` exports `DIR/<dataset name>/<task>/`; the
    result is cached per reference under `cache_root/<sha256(ref)[:16]>`
    and reused while its marker's task count still matches. `expected`
    (the suite's task ids) must all be present, or the download is refused."""
    cache_root = Path(cache_root)
    final = cache_root / registry_cache_key(ref)
    cached = _cached_registry(final, ref, expected)
    if cached is not None:
        log(f"复用工作台已下载的注册表数据集 {ref}：{cached}")
        return cached
    if not harbor:
        raise ValueError("工作台本机缺少 Harbor，无法下载注册表评测集 " + ref +
                         "；请运行 metacodes bench setup，或 uv tool install harbor==0.26.0")
    cache_root.mkdir(parents=True, exist_ok=True)
    work = cache_root / (final.name + ".tmp-" + uuid.uuid4().hex[:8])
    argv = [harbor, "download", ref, "-o", str(work)]
    sleep = sleep or time.sleep
    try:
        # Harbor clones the registry's git repository; GitHub clones fail
        # transiently often enough that one failure must not fail the run.
        for attempt in range(1, REGISTRY_ATTEMPTS + 1):
            log("$ " + display(argv) + (f"（第 {attempt} 次）" if attempt > 1 else ""))
            shutil.rmtree(work, ignore_errors=True)
            try:
                done = runner(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                raise ValueError(f"工作台下载注册表数据集 {ref} 超时") from None
            except OSError as exc:
                raise ValueError(f"无法运行工作台的 Harbor：{exc}") from None
            output = ((done.stdout or "") + (done.stderr or "")).strip()
            if output:
                # Keep the head too: the cause (e.g. git's own message) is
                # often above a long traceback.
                log(output if len(output) <= 3000 else output[:1000] + "\n…\n" + output[-2000:])
            if done.returncode == 0:
                break
            if attempt == REGISTRY_ATTEMPTS:
                raise ValueError(f"工作台下载注册表数据集 {ref} 失败（harbor download 退出码 {done.returncode}，"
                                 f"已重试 {REGISTRY_ATTEMPTS} 次）")
            sleep(REGISTRY_BACKOFF[attempt - 1])
        # Export layout: <work>/<dataset name>/<task>/; accept tasks at the top too.
        children = [c for c in sorted(work.iterdir()) if c.is_dir() and not c.name.startswith(".")] \
            if work.is_dir() else []
        dataset = children[0] if len(children) == 1 and _task_dirs(children[0]) else work
        tasks = _task_dirs(dataset)
        missing = sorted(set(expected or ()) - set(tasks))
        if not tasks or missing:
            raise ValueError(f"工作台下载的 {ref} 有 {len(tasks)} 道任务，缺少 {len(missing)} 道"
                             + ("（" + "、".join(missing[:5]) + "）" if missing else ""))
        relative = dataset.relative_to(work).as_posix() if dataset != work else ""
        (work / REGISTRY_MARKER).write_text(json.dumps({"ref": ref, "dataset": relative, "tasks": len(tasks)}),
                                            encoding="utf-8")
        shutil.rmtree(final, ignore_errors=True)
        work.replace(final)
        log(f"工作台已下载注册表数据集 {ref}：{len(tasks)} 道任务")
        return final / relative if relative else final
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ------------------------------------------------------------------ job sync

def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts and "\\" not in name


# Bytes before an offset that must match for a grown file to be sent as an
# append (remote.py checks them; see JobSync.plan).
DELTA_CHECK_BYTES = 64 * 1024


class _Watched:
    """A pipe reader that records when bytes last arrived (pack watchdog)."""

    def __init__(self, stream):
        self.stream = stream
        self.last = time.monotonic()
        self.bytes = 0

    def read(self, size=-1):
        chunk = self.stream.read(size)
        self.last = time.monotonic()
        self.bytes += len(chunk)
        return chunk


class JobSync:
    """Incrementally mirror one remote job directory into the local jobs dir.

    One pass (`sync`) reads the remote manifest and transfers a bounded batch
    of changed files (PASS_BYTES / PASS_FILES, smallest first, at least one
    file) as a tar stream extracted while it arrives, so a pass always
    finishes and every pass makes progress, however much a job wrote. A file
    that grew since it was last copied, and whose bytes before the old end
    are unchanged, arrives as an append (a growing log is never sent twice).
    `pending` counts the changed files a pass left for the next one;
    `complete()` proves the local copy matches the remote job.
    """

    MANIFEST_TIMEOUT = 120
    PACK_IDLE_TIMEOUT = 120
    PASS_BYTES = 128 * 1024 * 1024
    PASS_FILES = 2000

    def __init__(self, executor: SshExecutor, remote_dir: str, local_dir: Path,
                 runner=subprocess.run, log=print, popen=subprocess.Popen):
        self.executor, self.remote_dir = executor, remote_dir
        self.local_dir = Path(local_dir)
        self.runner, self.log, self.popen = runner, log, popen
        self.seen: Dict[str, List[int]] = {}
        self.files = 0
        self.bytes = 0  # tar stream bytes received
        self.pending = 0

    def manifest(self) -> Dict[str, List[int]]:
        listing = self.runner(node_argv(self.executor, "manifest", self.remote_dir), stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=self.MANIFEST_TIMEOUT)
        if listing.returncode != 0:
            raise ValueError("读取远程作业目录失败")
        current = json.loads(listing.stdout or b"{}")
        if not isinstance(current, dict):
            raise ValueError("远程作业目录清单无效")
        return {name: stamp for name, stamp in current.items() if safe_member(name)
                and isinstance(stamp, list) and len(stamp) == 2 and all(type(v) is int for v in stamp)}

    def local_path(self, name: str) -> Optional[Path]:
        target = self.local_dir / name
        return target if self.local_dir.resolve() in target.resolve().parents else None

    def plan(self, current: Dict[str, List[int]]) -> Tuple[List, int]:
        """(request items, files left over) for one pass. An item is a name,
        or [name, offset, sha256 of the DELTA_CHECK_BYTES before offset] for
        a file this sync copied before and that only grew."""
        changed = [name for name, stamp in current.items() if self.seen.get(name) != stamp]
        items = []
        for name in changed:
            stamp, item, cost = current[name], name, current[name][0]
            target = self.local_path(name)
            if name in self.seen and target is not None and target.is_file():
                offset = target.stat().st_size
                if DELTA_CHECK_BYTES <= offset < stamp[0]:
                    with target.open("rb") as source:
                        source.seek(offset - DELTA_CHECK_BYTES)
                        base = hashlib.sha256(source.read(DELTA_CHECK_BYTES)).hexdigest()
                    item, cost = [name, offset, base], stamp[0] - offset
            items.append((cost, name, item))
        items.sort(key=lambda entry: (entry[0], entry[1]))
        chosen, total = [], 0
        for cost, _, item in items:
            if chosen and (total + cost > self.PASS_BYTES or len(chosen) >= self.PASS_FILES):
                break
            chosen.append(item)
            total += cost
        return chosen, len(items) - len(chosen)

    def sync(self) -> int:
        """One bounded pass; the number of files written."""
        current = self.manifest()
        items, left = self.plan(current)
        self.pending = len(items) + left
        if not items:
            return 0
        count = self.pack(items, current)
        self.pending = max(0, self.pending - count)
        self.files += count
        return count

    def pack(self, items: List, current: Dict[str, List[int]]) -> int:
        """Request `items` and extract the tar stream as it arrives; a stream
        idle for PACK_IDLE_TIMEOUT is abandoned (the files already written
        stay written)."""
        import tempfile
        requested = {item if isinstance(item, str) else item[0] for item in items}
        with tempfile.TemporaryFile() as errors:
            process = self.popen(node_argv(self.executor, "pack", self.remote_dir), stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=errors)
            stream = _Watched(process.stdout)
            done = threading.Event()

            def watchdog():
                while not done.wait(1):
                    if time.monotonic() - stream.last > self.PACK_IDLE_TIMEOUT:
                        process.kill()
                        return

            threading.Thread(target=watchdog, name="bench-sync-watchdog", daemon=True).start()
            count = 0
            try:
                try:
                    process.stdin.write(json.dumps(items).encode())
                    process.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
                with tarfile.open(fileobj=stream, mode="r|") as archive:
                    for member in archive:
                        if member.name in requested and self.receive(archive, member, current):
                            count += 1
            except tarfile.TarError:
                pass  # a truncated stream: what arrived complete is kept
            finally:
                done.set()
                self.bytes += stream.bytes
                process.stdout.close()
                code = process.wait()
            if code != 0 and not count:
                errors.seek(0)
                detail = errors.read().decode(errors="replace").strip()[-300:]
                raise ValueError("复制远程作业文件失败" + ("：" + detail if detail else ""))
        return count

    def receive(self, archive, member, current) -> bool:
        if not member.isfile() or not safe_member(member.name):
            return False
        target = self.local_path(member.name)
        if target is None:
            return False
        source = archive.extractfile(member)
        offset = int(member.pax_headers.get("metacodes.offset", "0") or 0)
        if offset:
            # An append: valid only onto the local copy it was planned from.
            if not target.is_file() or target.stat().st_size != offset:
                self.seen.pop(member.name, None)
                return False
            with target.open("r+b") as output:
                output.seek(offset)
                shutil.copyfileobj(source, output)
                output.truncate()
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + "." + uuid.uuid4().hex[:8] + ".sync")
            try:
                with temporary.open("wb") as output:
                    shutil.copyfileobj(source, output)
                temporary.replace(target)
            finally:
                temporary.unlink(missing_ok=True)
        stamp = member.pax_headers.get("metacodes.stamp", "").split()
        # The size and mtime of what was read, so a file that changed after
        # the manifest is sent again and an unchanged one is not.
        self.seen[member.name] = ([int(v) for v in stamp] if len(stamp) == 2 and all(v.isdigit() for v in stamp)
                                  else current.get(member.name))
        return True

    def complete(self) -> bool:
        """Whether the local copy holds every remote file at its current
        size, as of a fresh manifest (no pass left anything behind)."""
        current = self.manifest()
        self.pending = sum(1 for name, stamp in current.items() if self.seen.get(name) != stamp)
        if self.pending:
            return False
        for name, (size, _) in current.items():
            target = self.local_path(name)
            if target is None or not target.is_file() or target.stat().st_size != size:
                self.seen.pop(name, None)
                self.pending += 1
        return not self.pending


# ------------------------------------------------------------------ remote run

class RemoteRun:
    """Supervise one Harbor run on an SSH executor from the local worker.

    The job directory is copied back on a background thread (`start_sync`),
    so the supervisor's heartbeat and cancel handling never wait for a
    transfer; `final_sync` copies what is left after Harbor exits and says
    whether the local copy was verified complete."""

    HEARTBEAT_TIMEOUT = 90
    SYNC_INTERVAL = 10
    FINAL_SYNC_TIMEOUT = 1800

    def __init__(self, spec: Dict, runner=subprocess.run, popen=subprocess.Popen, log=None):
        self.executor = parse({k: v for k, v in spec["executor"].items() if v is not None})
        self.spec = spec
        self.runner, self.popen = runner, popen
        self.log = log or (lambda text: print(text, flush=True))
        self.bundle = None
        self.dataset = None
        self.overlay = None
        self.process = None
        self.stdin_lock = threading.Lock()
        self.credential_pushes = 0
        self.pending_credential = None
        self.judge_credential = None
        self.events: List[Dict] = []
        self.last_event = time.monotonic()
        self.sync_state = None
        self.sync_stop = threading.Event()
        self.sync_thread = None
        # How long the final copy may take before the run reports its
        # results as still on the executor (the environment can shorten it).
        self.final_timeout = float(os.environ.get("METACODES_BENCH_FINAL_SYNC_TIMEOUT") or self.FINAL_SYNC_TIMEOUT)
        # egress "workbench": this run's proxy on the workbench loopback and
        # the executor loopback port its `ssh -R` forward listens on.
        self.proxy = None
        self.tunnel_ports = [tunnel_port()] if self.executor.egress == "workbench" else []
        self.uploaded = None
        self.remote_spec_path = None
        self.stderr_relay = None
        self.stderr_tail = ""

    @property
    def tunnel_port(self) -> Optional[int]:
        return self.tunnel_ports[-1] if self.tunnel_ports else None

    @property
    def remote_job_dir(self) -> str:
        return self.executor.remote("jobs", self.spec["name"])

    def stage(self) -> None:
        """Ship the bundle and the run's dataset. A WorkBuddy run needs
        neither: the node runs its own WorkBuddy checkout."""
        if self.spec.get("runner") == "workbuddy":
            return
        self.bundle = ship_bundle(self.executor, Path(self.spec["bundle"]), log=self.log,
                                  runner=self.runner, popen=self.popen)
        registry = self.spec.get("registry_download")
        local = None
        if registry:
            # harbor-registry suite: downloaded here (the executor may not
            # reach GitHub or the Hub), then shipped like a local dataset.
            local = registry_dataset(registry["ref"], Path(registry["cache"]), registry.get("harbor"),
                                     expected=registry.get("tasks"), log=self.log)
        elif self.spec.get("local_dataset"):
            # harbor-local suite: `-p` names this host's prepared directory.
            local = Path(self.spec["local_dataset"])
        if local is not None:
            self.dataset = ship_dataset(self.executor, local, log=self.log, runner=self.runner, popen=self.popen)
        self.overlay = with_teamwork(self.mirror_overlay(local), self.spec.get("features") or [], self.executor)

    def mirror_overlay(self, local: Optional[Path]) -> Optional[Dict]:
        """This run's compose overlay: without the settings the dataset's
        tasks make themselves, and without apt when the executor's apt cache
        does not answer."""
        mirrors = dict(self.executor.container_mirrors)
        left_out = task_owned_settings(local, mirrors) if mirrors and local is not None else []
        if left_out:
            self.log("任务自己设置了 " + "、".join(left_out) + "，本次运行不注入这些镜像设置")
        if "apt" in mirrors and APT_PROXY_SETTING not in left_out:
            try:
                answered = self.runner(shell_argv(self.executor, apt_cache_probe(self.executor, 3)),
                                       stdin=subprocess.DEVNULL, capture_output=True, timeout=60).returncode == 0
            except (OSError, subprocess.TimeoutExpired):
                answered = False
            if not answered:
                self.log(f"apt 缓存 {self.executor.apt_cache_url} 没有响应：本次运行的任务容器直接使用自己的 apt 源；"
                         f"运行 metacodes bench setup --executor {self.executor.name} 重新启动缓存")
                left_out.append(APT_PROXY_SETTING)
        return self.executor.compose_overlay(left_out)

    def remote_spec(self, upstream=None, auth=("Authorization", "Bearer "), record=True) -> Dict:
        from scripts.eval.harbor.bench.worker import command
        if self.spec.get("runner") == "workbuddy":
            # The node refuses a checkout whose staged executables are not
            # those of the bundle this run's record names.
            from scripts.eval.harbor.suites import workbuddy
            bundle = self.spec.get("bundle")
            return {"schema_version": 1, "runner": "workbuddy", "jobs_dir": self.executor.remote("jobs"),
                    "executables": workbuddy.bundle_executables(bundle) if bundle else None,
                    **{k: self.spec.get(k) for k in ("name", "suite", "model", "tasks", "attempts", "concurrency",
                                                     "reasoning_effort", "account_gateway", "workbuddy_judge")}}
        run_dir = self.executor.remote("runs", self.spec["name"])
        remote = {**self.spec, "harbor": self.spec.get("remote_harbor") or self.executor.harbor or ".local/bin/harbor",
                  "bundle": self.bundle, "jobs_dir": self.executor.remote("jobs")}
        if self.spec.get("registry_download"):
            # `-p` task names are the exported directory names: bare ids,
            # without the Hub's `org/` prefix that `-d` matches.
            remote["dataset_args"] = ["-p", self.dataset]
            remote["task_filters"] = list(self.spec["registry_download"]["filters"])
        elif self.dataset:
            args = list(remote.get("dataset_args") or [])
            if "-p" not in args:
                raise ValueError("本地数据集运行缺少 -p 参数")
            args[args.index("-p") + 1] = self.dataset
            remote["dataset_args"] = args
        remote.pop("local_dataset", None)
        remote.pop("registry_download", None)
        remote.pop("forward_env", None)
        remote.pop("metrics_proxy", None)
        remote.pop("metrics_ca", None)
        if self.spec.get("provider_config"):
            remote["provider_config"] = run_dir + "/provider.json"
        if self.overlay:
            remote["compose_overlay"] = run_dir + "/" + COMPOSE_OVERLAY
        relay = None
        if upstream:
            relay = {"upstream": upstream, "bind": self.executor.metrics_bind, "auth_header": auth[0],
                     "auth_prefix": auth[1], "metrics_dir": self.remote_job_dir + "/.bench-metrics",
                     "record": bool(record),
                     # An imported provider was probed from the workbench; the
                     # executor checks its own resolution before connecting.
                     "refuse_local_upstream": bool(self.spec.get("imported_provider"))}
        if relay and self.spec.get("judge"):
            # The driver appends the judge's `--ve` once its relay listens.
            relay["judge"] = self.spec["judge"]
        return {"schema_version": 1, "name": self.spec["name"], "argv": command(remote),
                "key_env": self.spec["key_env"], "relay": relay,
                "egress": self.egress_spec(), "ghcr_mirror": self.executor.ghcr_mirror}

    def egress_spec(self) -> Optional[Dict]:
        """What the remote driver needs for the containers' egress. Model
        traffic to the relay (metrics_bind) always bypasses the proxy."""
        executor = self.executor
        if executor.egress == "workbench":
            return {"mode": "workbench", "tunnel_port": self.tunnel_port, "bind": executor.metrics_bind,
                    "no_proxy": [executor.metrics_bind]}
        if executor.egress == "proxy":
            return {"mode": "proxy", "url": executor.egress_proxy, "no_proxy": [executor.metrics_bind]}
        return None

    def start_egress(self) -> Optional[Tuple[int, int]]:
        """Start this run's workbench proxy; (executor port, local port) of
        the reverse forward the run session carries, or None."""
        if self.tunnel_port is None:
            return None
        from scripts.eval.harbor.bench.egress import DEFAULT_ALLOW_NETWORKS, EgressProxy, allow_policy
        if self.proxy is None:
            self.proxy = EgressProxy(self.executor.egress_ports, log=self.log,
                                     allow=allow_policy(self.executor.egress_allow
                                                        if self.executor.egress_allow is not None
                                                        else DEFAULT_ALLOW_NETWORKS)).start()
            self.log(f"容器出网经工作台：代理 127.0.0.1:{self.proxy.port}，"
                     f"{self.executor.name} 回环端口 {self.tunnel_port}（ssh -R），"
                     f"允许端口 {', '.join(str(p) for p in sorted(self.executor.egress_ports))}")
        return self.tunnel_port, self.proxy.port

    def close(self) -> None:
        """Stop the run's workbench proxy (idempotent)."""
        if self.stderr_relay is not None:
            self.stderr_relay.join(5)
        if self.proxy is not None:
            self.proxy.close()
            self.log("出网代理已停止：" + json.dumps(self.proxy.counts))
            self.proxy = None

    def upload_run(self, remote_spec: Dict) -> str:
        """The run directory holds the remote spec, provider config and compose overlay only."""
        import tempfile
        self.uploaded = remote_spec
        run_dir = self.executor.remote("runs", self.spec["name"])
        with tempfile.TemporaryDirectory(prefix="bench-remote-run-") as temporary:
            root = Path(temporary)
            (root / "spec.json").write_text(json.dumps(remote_spec), encoding="utf-8")
            names = ["spec.json"]
            if self.spec.get("provider_config"):
                shutil.copyfile(self.spec["provider_config"], root / "provider.json")
                names.append("provider.json")
            if self.overlay:
                (root / COMPOSE_OVERLAY).write_text(json.dumps(self.overlay), encoding="utf-8")
                names.append(COMPOSE_OVERLAY)
            ship(self.executor, root, names, run_dir, log=self.log, runner=self.runner, popen=self.popen, force=True)
        return run_dir + "/spec.json"

    def start(self, secret_env: Dict[str, str], remote_spec_path: str, credential: Optional[str] = None) -> None:
        self.spawn(secret_env, remote_spec_path, credential)
        self.sync_state = self.job_sync()

    def retry_tunnel(self, secret_env: Dict[str, str], credential: Callable[[], Optional[str]]) -> bool:
        if len(self.tunnel_ports) >= TUNNEL_ATTEMPTS or not self.forward_was_refused():
            return False
        self.tunnel_ports.append(tunnel_port(self.tunnel_ports))
        self.log(tunnel_retry_note(self.executor, self.tunnel_ports[-2], self.tunnel_port, len(self.tunnel_ports)))
        if (self.uploaded or {}).get("egress"):
            self.upload_run({**self.uploaded, "egress": self.egress_spec()})
        self.spawn(secret_env, self.remote_spec_path, credential())
        return True

    def forward_was_refused(self) -> bool:
        if self.tunnel_port is None or self.events or self.process is None or self.process.poll() != 255:
            return False
        if self.stderr_relay is not None:
            self.stderr_relay.join(10)
        return forward_refused(self.process.returncode, self.stderr_tail)

    def relay_stderr(self, process) -> None:
        if process.stderr is None:
            return
        tail, sink = b"", True
        try:
            for chunk in iter(lambda: process.stderr.read1(65536), b""):
                tail = (tail + chunk)[-4096:]
                while sink and chunk:
                    try:
                        chunk = chunk[os.write(2, chunk):]
                    except OSError:
                        sink = False
        except (OSError, ValueError):
            pass
        finally:
            process.stderr.close()
        if process is self.process:
            self.stderr_tail = tail.decode(errors="replace")

    def spawn(self, secret_env: Dict[str, str], remote_spec_path: str, credential: Optional[str]) -> None:
        self.remote_spec_path = remote_spec_path
        argv = node_argv(self.executor, "run", remote_spec_path, reverse=self.start_egress())
        self.log("$ " + display(argv) + "  （密钥经 SSH stdin 传入）")
        # The secrets are the first line on the encrypted channel: `env` goes
        # to Harbor (the placeholder, a judge key), `credential` to the relay.
        # Under the lock, so no pushed token can precede that line; a token
        # pushed before the channel existed replaces the one given here.
        with self.stdin_lock:
            self.process = self.popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      start_new_session=True)
            self.stderr_tail = ""
            self.last_event = time.monotonic()  # staging may have taken minutes
            first = {"env": secret_env}
            credential = self.pending_credential or credential
            if credential:
                first["credential"] = credential
            if self.judge_credential:
                # A fixed account key for the judge model (legacy group
                # keys); a session login's pushed token serves both.
                first["judge_credential"] = self.judge_credential
            self.process.stdin.write((json.dumps(first) + "\n").encode())
            self.process.stdin.flush()
        threading.Thread(target=self.read_events, daemon=True).start()
        self.stderr_relay = threading.Thread(target=self.relay_stderr, args=(self.process,), daemon=True)
        self.stderr_relay.start()

    def read_events(self) -> None:
        for line in self.process.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict):
                self.events.append(event)
                self.last_event = time.monotonic()

    def cancel(self) -> None:
        try:
            with self.stdin_lock:
                self.process.stdin.write(b"cancel\n")
                self.process.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def push_credential(self, credential: str) -> bool:
        """Send a refreshed access token to the remote relay. On failure the
        relay keeps the previous token until it expires."""
        try:
            with self.stdin_lock:
                if self.process is None:
                    self.pending_credential = credential  # sent with the first line
                    return True
                self.process.stdin.write((json.dumps({"credential": credential}) + "\n").encode())
                self.process.stdin.flush()
            self.credential_pushes += 1
            return True
        except (AttributeError, BrokenPipeError, OSError, ValueError):
            self.log("向远程凭据代理推送新令牌失败；它继续使用旧令牌直到过期")
            return False

    def hang_up(self) -> None:
        try:
            with self.stdin_lock:
                self.process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    def exit_code(self) -> Optional[int]:
        for event in reversed(self.events):
            if event.get("event") == "exit":
                return event.get("code")
        return None

    def error_message(self) -> Optional[str]:
        for event in reversed(self.events):
            if event.get("event") == "error" and isinstance(event.get("message"), str):
                return event["message"]
        return None

    @property
    def local_job_dir(self) -> Path:
        return Path(self.spec["jobs_dir"]) / self.spec["name"]

    def job_sync(self) -> JobSync:
        return JobSync(self.executor, self.remote_job_dir, self.local_job_dir,
                       runner=self.runner, log=self.log, popen=self.popen)

    def sync(self) -> bool:
        """One pass; False when it failed (logged, retried by the caller)."""
        try:
            self.sync_state.sync()
            return True
        except (ValueError, OSError, subprocess.TimeoutExpired, tarfile.TarError) as exc:
            self.log("同步远程作业目录失败：" + str(exc))
            return False

    def start_sync(self) -> None:
        """Copy the job back every SYNC_INTERVAL seconds on a thread; a pass
        that left files behind is followed by the next one at once."""
        def loop():
            while not self.sync_stop.is_set():
                ok = self.sync()
                if self.sync_stop.wait(0 if ok and self.sync_state.pending else self.SYNC_INTERVAL):
                    return

        self.sync_thread = threading.Thread(target=loop, name="bench-remote-sync", daemon=True)
        self.sync_thread.start()

    def final_sync(self, stop: Optional[threading.Event] = None, timeout: Optional[float] = None) -> bool:
        """After Harbor exited: finish the running pass, then copy until a
        fresh manifest shows the local copy complete. False when that could
        not be verified within `timeout` or `stop` was set."""
        self.sync_stop.set()
        if self.sync_thread is not None:
            self.sync_thread.join()
        deadline = time.monotonic() + (self.final_timeout if timeout is None else timeout)
        stop = stop or threading.Event()
        while time.monotonic() < deadline and not stop.is_set():
            pause = self.SYNC_INTERVAL
            try:
                if self.sync_state.complete():
                    return True
                # Files left: copy at once; a pass that copied nothing (a
                # file the remote side cannot read yet) waits a little.
                pause = 0 if self.sync_state.sync() else 1
            except (ValueError, OSError, subprocess.TimeoutExpired, tarfile.TarError) as exc:
                self.log("同步远程作业目录失败：" + str(exc))
            stop.wait(min(pause, max(0.0, deadline - time.monotonic())))
        return False

    def results_note(self) -> Dict:
        """Where the results still are, and how to copy them."""
        return {"executor": self.executor.name, "path": self.remote_job_dir,
                "retry": "metacodes bench sync --run " + self.spec["name"]}


RUN_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]*$")


def sync_run(jobs_dir: Path, name: str, log=print, timeout: Optional[float] = None) -> Dict:
    """`metacodes bench sync --run NAME`: copy an SSH run's job directory
    back after its worker could not, and clear the receipt's note. A run
    whose Harbor exited 0 becomes `finished` once its copy is complete."""
    from scripts.eval.harbor.store.ingest import root_lock
    if not isinstance(name, str) or not RUN_NAME.fullmatch(name):
        raise ValueError("运行名称无效")
    with root_lock(Path(jobs_dir)):
        return _sync_run(Path(jobs_dir), name, log, timeout)


def _sync_run(jobs_dir: Path, name: str, log, timeout: Optional[float]) -> Dict:
    from scripts.eval.harbor.bench.runner import ACTIVE, RunManager, atomic_json
    records = Path(jobs_dir) / ".bench-runs"
    record_path, spec_path = records / (name + ".json"), records / (name + ".spec")
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ValueError("运行不存在：" + name) from None
    if (spec.get("executor") or {}).get("kind") != "ssh":
        raise ValueError(name + " 不是在 SSH 执行机器上运行的，结果已在本机")
    fresh = time.time() - record_path.stat().st_mtime <= RunManager.STALE_AFTER
    if record.get("status") in ACTIVE and fresh:
        raise ValueError(name + " 仍在运行；它结束时会自己同步结果")
    remote = RemoteRun(spec, log=log)
    # Results left by a workbench from before nodes: say how to install one.
    facts = probe(remote.executor)
    problem = "；".join(reach_reasons(remote.executor, facts))
    if problem:
        raise ValueError(problem)
    job = remote.job_sync()
    deadline = time.monotonic() + (RemoteRun.FINAL_SYNC_TIMEOUT if timeout is None else timeout)
    complete = False
    while time.monotonic() < deadline:
        if job.complete():
            complete = True
            break
        if not job.sync():
            time.sleep(1)
    if not complete:
        raise ValueError(f"仍有 {job.pending} 个文件未同步完整，请稍后重试")
    note = record.pop("remote_results", None)
    if isinstance(note, dict):
        rest = [part for part in str(record.get("error") or "").split("；") if part and part not in
                str(note.get("message") or "").split("；")]
        record["error"] = "；".join(rest) or None
        if record.get("status") == "failed" and record.get("exit_code") == 0 and not rest:
            record["status"] = "finished"
        atomic_json(record_path, record)
    return {"name": name, "files": job.files, "status": record.get("status"),
            "local_dir": str(remote.local_job_dir)}
