"""Execution machines for the Bench workbench: this host or a Linux host over SSH.

`workbench.json` may list `executors`; without one the workbench runs on this
host as before. An `ssh` executor runs the Harbor command on the remote host:

- the bench runtime (the Python files below) and the Linux release bundle are
  shipped over the SSH channel as tar streams into content-addressed
  directories under the executor's `state_dir`, once per digest;
- the run's account key or provider key travels as the first line on the SSH
  channel's stdin and lives only in the remote driver's process environment
  and its Harbor child (never argv, never a file);
- the remote driver (`viewer/remote.py`) owns the timing relay next to the
  remote Docker daemon, reports heartbeats on stdout, cancels on request or
  when the channel closes;
- the remote job directory is copied back incrementally into the local jobs
  directory, so the viewer and other local readers see ordinary job files.

Python 3.9, stdlib only. Every subprocess is spawned with an argv list.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Dict, List, Optional, Tuple, Union

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:_-]{0,252}$")
USER = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]{0,31}$")
REMOTE_PATH = re.compile(r"^[A-Za-z0-9._/+-]{1,512}$")
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

# What the remote driver and Harbor's agent import on the executor
# (all of them are also carried by the binary, see scripts/bench_assets.zig).
REMOTE_RUNTIME = (
    "scripts/__init__.py",
    "scripts/eval/__init__.py",
    "scripts/eval/model.py",
    "scripts/eval/workbuddy/__init__.py",
    "scripts/eval/workbuddy/trace.py",
    "scripts/eval/harbor/__init__.py",
    "scripts/eval/harbor/command.py",
    "scripts/eval/harbor/profiling.py",
    "scripts/eval/harbor/metacodes_agent.py",
    "scripts/eval/harbor/viewer/__init__.py",
    "scripts/eval/harbor/viewer/remote.py",
)


def runtime_root() -> Path:
    return Path(__file__).resolve().parents[4]


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

    kind = "ssh"

    @property
    def destination(self) -> str:
        return (self.user + "@" if self.user else "") + self.host

    def public(self) -> Dict:
        return {"name": self.name, "kind": "ssh",
                "label": f"{self.name}（SSH {self.destination}:{self.port}）"}

    def spec(self) -> Dict:
        return {"name": self.name, "kind": "ssh", "host": self.host, "user": self.user, "port": self.port,
                "identity_file": self.identity_file, "state_dir": self.state_dir, "harbor": self.harbor,
                "python": self.python, "metrics_bind": self.metrics_bind,
                "metrics_enabled": self.metrics_enabled}

    def remote(self, *parts: str) -> str:
        return str(PurePosixPath(self.state_dir, *parts))


Executor = Union[LocalExecutor, SshExecutor]


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
               "metrics_bind", "metrics_enabled"}
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
        identity = str(Path(identity).expanduser())
    values = {}
    for field in ("state_dir", "harbor", "python"):
        value = entry.get(field)
        if value is None:
            continue
        if not isinstance(value, str) or not REMOTE_PATH.fullmatch(value) or ".." in value.split("/") or value.startswith("-"):
            raise ValueError(f"{name}: {field} 只能是普通路径")
        values[field] = value
    bind = entry.get("metrics_bind", "172.17.0.1")
    if not isinstance(bind, str) or not HOST.fullmatch(bind):
        raise ValueError(f"{name}: metrics_bind 无效")
    enabled = entry.get("metrics_enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError(f"{name}: metrics_enabled 必须是布尔值")
    return SshExecutor(name=name, host=host, user=user, port=port, identity_file=identity,
                       metrics_bind=bind, metrics_enabled=enabled, **values)


def configured(cfg) -> Tuple[List[Executor], str]:
    """The executors in `cfg` and the default name. Without a list, this host."""
    entries = cfg.get("executors")
    if entries is None:
        return [LocalExecutor(DEFAULT_LOCAL, cfg.get("harbor"))], DEFAULT_LOCAL
    if not isinstance(entries, list) or not entries:
        raise ValueError("executors 必须是非空列表")
    result = [parse(entry) for entry in entries]
    names = [e.name for e in result]
    if len(set(names)) != len(names):
        raise ValueError("执行机器名称重复")
    if sum(1 for e in result if isinstance(e, LocalExecutor)) > 1:
        raise ValueError("只能配置一个本机执行器")
    result = [LocalExecutor(e.name, e.harbor or cfg.get("harbor")) if isinstance(e, LocalExecutor) else e
              for e in result]
    default = cfg.get("default_executor") or names[0]
    if default not in names:
        raise ValueError("default_executor 不在 executors 中")
    return result, default


def find(cfg, name: Optional[str]) -> Executor:
    executors, default = configured(cfg)
    wanted = name or default
    for executor in executors:
        if executor.name == wanted:
            return executor
    raise ValueError("未配置执行机器 " + str(wanted))


# ------------------------------------------------------------------ commands

def ssh_argv(executor: SshExecutor, remote: Optional[List[str]] = None, *, tty=False) -> List[str]:
    """`ssh` argv for one remote command. The remote side receives one
    shell-quoted string, so every argument stays a single word there."""
    argv = [shutil.which("ssh") or "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4",
            "-o", "StrictHostKeyChecking=accept-new", "-p", str(executor.port)]
    if executor.identity_file:
        argv += ["-i", executor.identity_file, "-o", "IdentitiesOnly=yes"]
    argv.append("-tt" if tty else "-T")
    argv.append(executor.destination)
    if remote:
        argv.append(shlex.join(remote))
    return argv


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
'''


def probe_script(executor: Executor) -> str:
    candidates = [executor.harbor] if executor.harbor else []
    candidates += ["harbor", "$HOME/.local/bin/harbor"]
    quoted = " ".join(shlex.quote(c) if not c.startswith("$HOME") else '"' + c + '"' for c in candidates)
    python = executor.python if isinstance(executor, SshExecutor) else "python3"
    return PROBE.replace("HARBOR_CANDIDATES", quoted).replace("PYTHON", shlex.quote(python))


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
    return facts


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
    else:
        result = []
        if facts.get("error"):
            return ["无法检查本机执行环境"]
    if not facts.get("harbor"):
        result.append("未找到 Harbor，请在执行机器安装：uv tool install harbor==0.26.0" + setup)
    if not facts.get("docker"):
        result.append("未找到 Docker；Harbor 任务需要 Docker 环境" + setup)
    elif facts.get("docker_daemon") == "permission":
        result.append("当前用户无权访问 Docker daemon（需要加入 docker 组）" + setup)
    elif facts.get("docker_daemon") != "ok":
        result.append("Docker daemon 未运行或不可达" + setup)
    elif facts.get("compose") != "1":
        result.append("缺少 docker compose 插件" + setup)
    if not facts.get("openssl"):
        result.append("未找到 OpenSSL（计时 relay 需要）" + setup)
    return result


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
                if not path.exists() and name == "scripts/__init__.py":
                    info = tarfile.TarInfo(name)
                    info.mode = 0o644
                    archive.addfile(info, io.BytesIO(b""))
                    continue
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


def ship_runtime(executor: SshExecutor, log=print, **kwargs) -> str:
    root = runtime_root()
    names = [n for n in REMOTE_RUNTIME if (root / n).exists() or n == "scripts/__init__.py"]
    digest = hashlib.sha256()
    for name in names:
        path = root / name
        digest.update(name.encode() + b"\0" + (path.read_bytes() if path.exists() else b"") + b"\0")
    destination = executor.remote("runtime", digest.hexdigest()[:16])
    ship(executor, root, names, destination, log=log, **kwargs)
    return destination


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


# ------------------------------------------------------------------ job sync

def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts and "\\" not in name


class JobSync:
    """Incrementally mirror one remote job directory into the local jobs dir."""

    def __init__(self, executor: SshExecutor, runtime: str, remote_dir: str, local_dir: Path,
                 runner=subprocess.run, log=print):
        self.executor, self.runtime, self.remote_dir = executor, runtime, remote_dir
        self.local_dir = Path(local_dir)
        self.runner, self.log = runner, log
        self.seen: Dict[str, List[int]] = {}
        self.files = 0

    def remote_python(self, *args: str) -> List[str]:
        return ssh_argv(self.executor, ["env", "PYTHONPATH=" + self.runtime, self.executor.python,
                                        "-m", "scripts.eval.harbor.viewer.remote", *args])

    def sync(self) -> int:
        listing = self.runner(self.remote_python("manifest", self.remote_dir), stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=120)
        if listing.returncode != 0:
            raise ValueError("读取远程作业目录失败")
        current = json.loads(listing.stdout or b"{}")
        changed = sorted(name for name, stamp in current.items()
                         if safe_member(name) and self.seen.get(name) != stamp)
        if not changed:
            return 0
        packed = self.runner(self.remote_python("pack", self.remote_dir),
                             input=json.dumps(changed).encode(), capture_output=True, timeout=600)
        if packed.returncode != 0:
            raise ValueError("复制远程作业文件失败")
        count = 0
        with tarfile.open(fileobj=io.BytesIO(packed.stdout), mode="r|") as archive:
            for member in archive:
                if not member.isfile() or not safe_member(member.name) or member.name not in current:
                    continue
                target = self.local_dir / member.name
                if self.local_dir.resolve() not in target.resolve().parents:
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                temporary = target.with_name(target.name + "." + uuid.uuid4().hex[:8] + ".sync")
                with temporary.open("wb") as output:
                    shutil.copyfileobj(source, output)
                temporary.replace(target)
                self.seen[member.name] = current[member.name]
                count += 1
        self.files += count
        return count


# ------------------------------------------------------------------ remote run

class RemoteRun:
    """Supervise one Harbor run on an SSH executor from the local worker."""

    HEARTBEAT_TIMEOUT = 90
    SYNC_INTERVAL = 10

    def __init__(self, spec: Dict, runner=subprocess.run, popen=subprocess.Popen, log=None):
        self.executor = parse({k: v for k, v in spec["executor"].items() if v is not None})
        self.spec = spec
        self.runner, self.popen = runner, popen
        self.log = log or (lambda text: print(text, flush=True))
        self.runtime = None
        self.bundle = None
        self.dataset = None
        self.process = None
        self.events: List[Dict] = []
        self.last_event = time.monotonic()
        self.sync_state = None

    @property
    def remote_job_dir(self) -> str:
        return self.executor.remote("jobs", self.spec["name"])

    def stage(self) -> None:
        """Ship runtime, bundle and the run's own (secret-free) spec."""
        self.runtime = ship_runtime(self.executor, log=self.log, runner=self.runner, popen=self.popen)
        self.bundle = ship_bundle(self.executor, Path(self.spec["bundle"]), log=self.log,
                                  runner=self.runner, popen=self.popen)
        if self.spec.get("local_dataset"):
            # harbor-local suite: `-p` names this host's prepared directory.
            self.dataset = ship_dataset(self.executor, Path(self.spec["local_dataset"]), log=self.log,
                                        runner=self.runner, popen=self.popen)

    def remote_spec(self, upstream=None, auth=("Authorization", "Bearer ")) -> Dict:
        from scripts.eval.harbor.viewer.worker import command
        run_dir = self.executor.remote("runs", self.spec["name"])
        remote = {**self.spec, "harbor": self.spec.get("remote_harbor") or self.executor.harbor or ".local/bin/harbor",
                  "bundle": self.bundle, "jobs_dir": self.executor.remote("jobs")}
        if self.dataset:
            args = list(remote.get("dataset_args") or [])
            if "-p" not in args:
                raise ValueError("本地数据集运行缺少 -p 参数")
            args[args.index("-p") + 1] = self.dataset
            remote["dataset_args"] = args
        remote.pop("local_dataset", None)
        remote.pop("forward_env", None)
        remote.pop("metrics_proxy", None)
        remote.pop("metrics_ca", None)
        if self.spec.get("provider_config"):
            remote["provider_config"] = run_dir + "/provider.json"
        relay = None
        if upstream:
            relay = {"upstream": upstream, "bind": self.executor.metrics_bind, "auth_header": auth[0],
                     "auth_prefix": auth[1], "metrics_dir": self.remote_job_dir + "/.bench-metrics"}
        return {"schema_version": 1, "name": self.spec["name"], "argv": command(remote),
                "key_env": self.spec["key_env"], "relay": relay, "runtime": self.runtime}

    def upload_run(self, remote_spec: Dict) -> str:
        """The run directory holds the remote spec and provider config only."""
        import tempfile
        run_dir = self.executor.remote("runs", self.spec["name"])
        with tempfile.TemporaryDirectory(prefix="bench-remote-run-") as temporary:
            root = Path(temporary)
            (root / "spec.json").write_text(json.dumps(remote_spec), encoding="utf-8")
            names = ["spec.json"]
            if self.spec.get("provider_config"):
                shutil.copyfile(self.spec["provider_config"], root / "provider.json")
                names.append("provider.json")
            ship(self.executor, root, names, run_dir, log=self.log, runner=self.runner, popen=self.popen, force=True)
        return run_dir + "/spec.json"

    def start(self, secret_env: Dict[str, str], remote_spec_path: str) -> None:
        argv = ssh_argv(self.executor, ["env", "PYTHONPATH=" + self.runtime, "PYTHONUNBUFFERED=1",
                                        self.executor.python, "-m", "scripts.eval.harbor.viewer.remote",
                                        "run", remote_spec_path])
        self.log("$ " + display(argv) + "  （密钥经 SSH stdin 传入）")
        self.process = self.popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True)
        self.last_event = time.monotonic()  # staging may have taken minutes
        # The secret is the first line on the encrypted channel; the remote
        # driver keeps it in its own and Harbor's environment only.
        self.process.stdin.write((json.dumps({"env": secret_env}) + "\n").encode())
        self.process.stdin.flush()
        threading.Thread(target=self.read_events, daemon=True).start()
        self.sync_state = JobSync(self.executor, self.runtime, self.remote_job_dir,
                                  Path(self.spec["jobs_dir"]) / self.spec["name"], runner=self.runner, log=self.log)

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
            self.process.stdin.write(b"cancel\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError, ValueError):
            pass

    def hang_up(self) -> None:
        try:
            self.process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    def exit_code(self) -> Optional[int]:
        for event in reversed(self.events):
            if event.get("event") == "exit":
                return event.get("code")
        return None

    def sync(self) -> None:
        try:
            self.sync_state.sync()
        except (ValueError, OSError, subprocess.TimeoutExpired, tarfile.TarError) as exc:
            self.log("同步远程作业目录失败：" + str(exc))
