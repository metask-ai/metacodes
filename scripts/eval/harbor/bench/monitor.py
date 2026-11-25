from __future__ import annotations

import datetime as dt
import json
import shlex
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from scripts.eval.harbor.bench import executors
from scripts.eval.harbor.bench.executors import Executor, SshExecutor, shell_argv

PROBE_SOURCE = Path(__file__).with_name("monitor_probe.py")
APT_CACHE_CONTAINER = "metacodes-apt-cache"
DOWNLOAD_CACHE_PORT = 3143
SNAPSHOT_SECONDS = 10.0
TARGET_SECONDS = 60.0
USAGE_SECONDS = 600.0
PROBE_TIMEOUT = 30
TARGET_TIMEOUT = 5
SOURCES = (
    ("dockerhub", "Docker Hub", "https://registry-1.docker.io/v2/"),
    ("ghcr", "ghcr.io", "https://ghcr.io/v2/"),
    ("github", "GitHub", "https://github.com/"),
    ("pypi", "PyPI", "https://pypi.org/simple/pip/"),
    ("huggingface", "Hugging Face", "https://huggingface.co/robots.txt"),
    ("astral", "astral.sh（uv 安装脚本）", "https://astral.sh/uv/install.sh"),
)
CONTAINER_LABELS = {"apt": "apt", "pypi": "PyPI", "conda": "conda", "go": "Go 模块", "rustup": "rustup",
                    "npm": "npm", "github": "GitHub Releases", "hf": "Hugging Face"}
SSH_ERRORS = {"nossh": "工作台机器上没有 ssh 命令", "timeout": f"{PROBE_TIMEOUT} 秒内没有返回"}


def iso(epoch: Optional[float]) -> Optional[str]:
    if epoch is None:
        return None
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()


def mirror_rows(executor: Executor) -> List[Dict]:
    if not isinstance(executor, SshExecutor):
        return []
    rows = []
    if executor.pypi_index:
        rows.append({"key": "mirror.pypi_index", "scope": "执行机器", "label": "PyPI（安装 Harbor）",
                     "setting": "pypi_index", "url": executor.pypi_index})
    for index, mirror in enumerate(executor.docker_mirrors):
        rows.append({"key": f"mirror.docker.{index}", "scope": "执行机器", "label": "Docker Hub 镜像加速",
                     "setting": "docker_mirrors", "url": mirror.rstrip("/") + "/v2/"})
    if executor.ghcr_mirror:
        rows.append({"key": "mirror.ghcr", "scope": "执行机器", "label": "ghcr.io 镜像",
                     "setting": "ghcr_mirror", "url": "https://" + executor.ghcr_mirror.split("/", 1)[0] + "/v2/"})
    for kind, url in executor.container_mirrors:
        rows.append({"key": "mirror.container." + kind, "scope": "任务容器",
                     "label": CONTAINER_LABELS.get(kind, kind), "setting": "container_mirrors." + kind, "url": url})
    return rows


def source_rows() -> List[Dict]:
    return [{"key": "source." + key, "scope": "源站", "label": label, "setting": None, "url": url}
            for key, label, url in SOURCES]


def probe_options(executor: Executor, state_root: Path, jobs_dir: Path, targets: Dict[str, str],
                  docker_usage: bool = True) -> Dict:
    remote = isinstance(executor, SshExecutor)
    return {
        "bind": executor.metrics_bind if remote else None,
        "apt_port": executors.APT_CACHE_PORT, "apt_container": APT_CACHE_CONTAINER,
        "download_port": DOWNLOAD_CACHE_PORT,
        "state_dir": executor.state_dir if remote else str(state_root),
        "jobs_dir": executor.remote("jobs") if remote else str(jobs_dir),
        "runs_dir": executor.remote("runs") if remote else None,
        "targets": targets, "target_timeout": TARGET_TIMEOUT, "docker_usage": docker_usage,
    }


def probe_argv(executor: Executor, options: Dict) -> List[str]:
    python = executor.python if isinstance(executor, SshExecutor) else sys.executable
    return shell_argv(executor, shlex.join([python, "-", json.dumps(options, separators=(",", ":"))]))


def run_probe(executor: Executor, options: Dict, runner=subprocess.run) -> Tuple[Optional[Dict], Optional[str]]:
    if isinstance(executor, SshExecutor) and not shutil.which("ssh"):
        return None, SSH_ERRORS["nossh"]
    try:
        done = runner(probe_argv(executor, options), input=PROBE_SOURCE.read_text(encoding="utf-8"),
                      capture_output=True, text=True, timeout=PROBE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, SSH_ERRORS["timeout"]
    except OSError as exc:
        return None, f"无法运行探测命令：{exc}"
    lines = (done.stdout or "").strip().splitlines()
    try:
        value = json.loads(lines[-1]) if lines else None
    except ValueError:
        value = None
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        detail = (done.stderr or "").strip().splitlines()
        reason = "连接执行机器失败" if done.returncode == 255 else f"探测脚本没有返回结果（退出码 {done.returncode}）"
        return None, reason + ("：" + detail[-1][:300] if detail else "")
    return value, None


def rate(hits, requests):
    return hits / requests if requests else None


def cache_views(executor: Executor, caches: Dict) -> Dict:
    container = dict(executor.container_mirrors) if isinstance(executor, SshExecutor) else {}
    apt = dict(caches.get("apt") or {})
    apt["configured"] = "apt" in container
    apt["upstream"] = container.get("apt")
    apt["hit_rate"] = rate(apt.get("hits"), apt.get("requests"))
    download = dict(caches.get("download") or {})
    download["configured"] = bool(getattr(executor, "download_cache", False))
    for route in (download.get("routes") or {}).values():
        route["hit_rate"] = rate(route.get("hits"), route.get("requests"))
    totals = download.get("totals")
    if totals:
        totals["hit_rate"] = rate(totals.get("hits"), totals.get("requests"))
    images = dict(caches.get("images") or {})
    if "error" not in images:
        images["hit_rate"] = rate(images.get("hits"), (images.get("hits") or 0) + (images.get("misses") or 0))
    return {"apt": apt, "download": download, "images": images}


def assemble(executor: Executor, probed: Dict, targets: Dict[str, Dict], targets_at: Optional[float],
             usage: Optional[Dict] = None, usage_at: Optional[float] = None) -> Dict:
    rows = source_rows() + mirror_rows(executor)
    for row in rows:
        row["probe"] = targets.get(row["key"])
    docker = probed.get("docker")
    if isinstance(docker, dict) and "error" not in docker:
        docker = {**docker, **(usage or {"usage": {}, "usage_error": None}), "usage_checked_at": iso(usage_at)}
    return {
        "schema_version": 1, "executor": executor.public(), "error": None,
        "collected_at": iso(probed.get("collected_at")), "host": probed.get("host"), "os": probed.get("os"),
        "load": probed.get("load"), "disks": probed.get("disks") or [],
        "network": {"interfaces": probed.get("interfaces") or [], "targets": rows,
                    "targets_checked_at": iso(targets_at)},
        "docker": docker,
        "mirrors": {"egress": executor.egress_value() if isinstance(executor, SshExecutor) else "direct",
                    "items": [row for row in rows if row["setting"]]},
        "caches": cache_views(executor, probed.get("caches") or {}),
    }


class Monitor:
    def __init__(self, runner=subprocess.run):
        self.runner = runner
        self.lock = threading.Lock()
        self.locks: Dict[str, threading.Lock] = {}
        self.snapshots: Dict[str, Tuple[float, str, Dict]] = {}
        self.targets: Dict[str, Tuple[float, str, float, Dict[str, Dict]]] = {}
        self.usage: Dict[str, Tuple[float, str, float, Dict]] = {}

    def snapshot(self, cfg: Dict, executor_name: Optional[str], state_root: Path, jobs_dir: Path) -> Dict:
        configured, default = executors.configured(cfg)
        wanted = executor_name or default
        executor = next((e for e in configured if e.name == wanted), None)
        if executor is None:
            raise ValueError("未配置执行机器 " + str(wanted))
        value = self.measured(executor, Path(state_root), Path(jobs_dir))
        return {**value, "executors": [e.public() for e in configured], "default_executor": default}

    def measured(self, executor: Executor, state_root: Path, jobs_dir: Path) -> Dict:
        identity = json.dumps(executor.spec(), sort_keys=True)
        with self.lock:
            lock = self.locks.setdefault(executor.name, threading.Lock())
        with lock:
            cached = self.snapshots.get(executor.name)
            if cached and cached[1] == identity and time.monotonic() - cached[0] < SNAPSHOT_SECONDS:
                return cached[2]
            known = self.targets.get(executor.name)
            fresh = bool(known) and known[1] == identity and time.monotonic() - known[0] < TARGET_SECONDS
            wanted = {} if fresh else {row["key"]: row["url"] for row in source_rows() + mirror_rows(executor)}
            sized = self.usage.get(executor.name)
            counted = bool(sized) and sized[1] == identity and time.monotonic() - sized[0] < USAGE_SECONDS
            probed, error = run_probe(executor, probe_options(executor, state_root, jobs_dir, wanted, not counted),
                                      self.runner)
            if probed is None:
                value = {"schema_version": 1, "executor": executor.public(), "error": error}
            else:
                at = probed.get("collected_at") or time.time()
                if not fresh:
                    known = (time.monotonic(), identity, at, probed.get("targets") or {})
                    self.targets[executor.name] = known
                docker = probed.get("docker") or {}
                if not counted and "usage" in docker:
                    sized = (time.monotonic(), identity, at,
                             {"usage": docker["usage"], "usage_error": docker.get("usage_error")})
                    if not docker.get("usage_error"):
                        self.usage[executor.name] = sized
                value = assemble(executor, probed, known[3], known[2], sized[3] if sized else None,
                                 sized[2] if sized else None)
            self.snapshots[executor.name] = (time.monotonic(), identity, value)
            return value


def snapshot(cfg: Dict, executor_name: Optional[str], jobs_dir: Path, runner=subprocess.run,
             state_root: Optional[Path] = None) -> Dict:
    return Monitor(runner).snapshot(cfg, executor_name, Path(state_root or Path(jobs_dir).parent), Path(jobs_dir))


def render(value: Dict) -> str:
    executor = value.get("executor") or {}
    lines = ["执行机器：" + str(executor.get("label") or executor.get("name"))]
    if value.get("error"):
        return "\n".join(lines + ["无法采集：" + value["error"]])
    load = value.get("load") or {}
    memory = load.get("memory") or {}
    average = load.get("average")
    lines.append("负载：" + (" ".join(f"{v:.2f}" for v in average) if average else "—")
                 + f" · CPU {load.get('cpus') or '—'} 核"
                 + (f" · 占用 {load['cpu_busy_percent']}%" if load.get("cpu_busy_percent") is not None else "")
                 + (f" · 内存可用 {memory['available'] / 2 ** 30:.1f} / {memory['total'] / 2 ** 30:.1f} GiB"
                    if memory.get("available") is not None and memory.get("total") else ""))
    docker = value.get("docker") or {}
    if docker.get("error"):
        lines.append("Docker：" + docker["error"])
    else:
        usage = docker.get("usage") or {}
        images = usage.get("images") or {}
        lines.append(f"Docker {docker.get('version')}：镜像 {images.get('count', '—')} 个"
                     + (f"（{images['bytes'] / 1e9:.1f} GB）" if images.get("bytes") is not None else "")
                     + f" · 运行中的容器 {docker.get('containers_running', '—')}")
    for row in (value.get("network") or {}).get("targets") or []:
        probe = row.get("probe") or {}
        state = f"{probe.get('seconds')} 秒" if probe.get("ok") else "不可达" if probe else "未探测"
        lines.append(f"{row['scope']} {row['label']}：{state}  {row['url']}")
    caches = value.get("caches") or {}
    for key, label in (("apt", "apt 缓存"), ("download", "下载缓存")):
        cache = caches.get(key) or {}
        totals = cache.get("totals") or cache
        if cache.get("answering"):
            hit_rate = totals.get("hit_rate")
            lines.append(f"{label}：命中 {totals.get('hits', 0)} / {totals.get('requests', 0)}"
                         + (f"（{hit_rate * 100:.0f}%）" if hit_rate is not None else ""))
        else:
            lines.append(f"{label}：" + ("已配置，但没有响应" if cache.get("configured") else "未启用"))
    images = caches.get("images") or {}
    if not images.get("error"):
        lines.append(f"镜像（本地镜像库）：命中 {images.get('hits', 0)} · 拉取或构建 {images.get('misses', 0)}"
                     f" · 失败 {images.get('failed', 0)} · 排队 {images.get('queued', 0)}"
                     f" · 准备中 {images.get('preparing', 0)} · 就绪等待 {images.get('ready', 0)}")
    return "\n".join(lines)
