#!/usr/bin/env python3
"""The self-hosted macOS VM pool that runs metacodes' macOS gates
(doc/MACOS_VM_POOL.md, doc/CI_DESIGN.md §6).

It runs on the pool host (the Mac Studio) as the dedicated `ci-host` user,
one launchd process per slot, and never runs a job itself. Each turn of a
slot clones a fresh macOS VM from the golden image, asks GitHub for a
just-in-time runner configuration (one job, then the runner is gone), boots
the VM on Softnet, hands the configuration to the runner inside over SSH
standard input, and destroys the VM when the job ends, fails or exceeds its
limit. The GitHub App's private key stays on the host; a VM sees only its
single-use configuration.

Commands:
  check              configuration, tools, key files, image, GitHub App access
  verify             boot VMs and check what a job inside one can reach and see
  slot N             run slot N until stopped (launchd)
  once N             one turn of slot N
  cleanup            remove leftover pool VMs and offline pool runners
  launchd-plist N    print the LaunchAgent for slot N

Configuration: ~/.metacodes-runner/config.json (--config); fields in
doc/MACOS_VM_POOL.md. Python 3.9, stdlib only; host tools: tart, ssh,
openssl. Tests: scripts/tests/test_macos_vm_pool.py.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

DEFAULT_CONFIG = "~/.metacodes-runner/config.json"
VM_PREFIX = "metacodes-s"
# Virtualization.framework runs at most two macOS guests per host.
MAX_SLOTS = 2
GENERIC_LABELS = {"self-hosted", "macos", "linux", "windows", "x64", "arm64", "arm"}
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
JIT_RE = re.compile(r"^[A-Za-z0-9+/=]+$")
IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
# The runner reads the job's PATH from its environment: Homebrew first, as on
# a hosted macOS image. The configuration arrives on standard input.
RUNNER_COMMAND = ('cd {dir} && export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH" '
                  '&& exec ./run.sh --jitconfig "$(cat)"')
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
               "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4",
               "-o", "LogLevel=ERROR")


class PoolError(Exception):
    pass


# ------------------------------------------------------------- configuration


@dataclass(frozen=True)
class Config:
    owner: str
    repository: str
    app_id: int
    installation_id: int
    private_key: Path
    runner_group_id: int
    labels: Tuple[str, ...]
    image: str
    slots: int
    vm_user: str
    vm_ssh_key: Path
    vm_runner_dir: str
    tart_run_args: Tuple[str, ...]
    job_limit_seconds: int
    boot_timeout_seconds: int
    state_dir: Path
    api_url: str

    @property
    def pool_label(self) -> str:
        return next(label for label in self.labels if label.lower() not in GENERIC_LABELS)


REQUIRED = ("owner", "app_id", "installation_id", "private_key", "runner_group_id", "image", "vm_ssh_key")
DEFAULTS: Dict[str, object] = {
    "repository": "",
    "labels": ["self-hosted", "macOS", "ARM64", "metacodes-macos-vm"],
    "slots": MAX_SLOTS,
    "vm_user": "admin",
    "vm_runner_dir": "actions-runner",
    "tart_run_args": ["--no-graphics", "--net-softnet"],
    "job_limit_seconds": 5400,
    "boot_timeout_seconds": 240,
    "state_dir": "~/.metacodes-runner",
    "api_url": "https://api.github.com",
}


def _int(value: object, name: str, low: int, high: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise PoolError(f"{name} must be an integer within {low}..{high}")
    return value


def _name(value: object, name: str, empty: bool = False) -> str:
    if not isinstance(value, str) or not (NAME_RE.match(value) or (empty and value == "")):
        raise PoolError(f"{name} must be a plain name")
    return value


def parse_config(value: object) -> Config:
    if not isinstance(value, dict):
        raise PoolError("the configuration is not a JSON object")
    missing = [key for key in REQUIRED if key not in value]
    unknown = sorted(set(value) - set(REQUIRED) - set(DEFAULTS))
    if missing or unknown:
        raise PoolError(f"configuration fields: missing {missing}, unknown {unknown}")
    merged = {**DEFAULTS, **value}
    labels = merged["labels"]
    if not isinstance(labels, list) or not all(isinstance(label, str) and NAME_RE.match(label) for label in labels):
        raise PoolError("labels must be a list of plain names")
    if "self-hosted" not in labels or all(label.lower() in GENERIC_LABELS for label in labels):
        raise PoolError("labels must hold self-hosted and one dedicated pool label")
    args = merged["tart_run_args"]
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise PoolError("tart_run_args must be a list of strings")
    # The pool's network isolation (doc/MACOS_VM_POOL.md, M3): no VM without Softnet.
    if not any(arg == "--net-softnet" or arg.startswith("--net-softnet") for arg in args):
        raise PoolError("tart_run_args must run every VM on Softnet (--net-softnet)")
    if any(arg.startswith(("--dir", "--disk")) for arg in args):
        raise PoolError("tart_run_args must not share host directories or disks with a VM")
    for key in ("private_key", "vm_ssh_key", "state_dir"):
        if not isinstance(merged[key], str) or not merged[key]:
            raise PoolError(f"{key} must be a path")
    if not isinstance(merged["api_url"], str) or not merged["api_url"].startswith("https://"):
        raise PoolError("api_url must be an https URL")
    return Config(
        owner=_name(merged["owner"], "owner"),
        repository=_name(merged["repository"], "repository", empty=True),
        app_id=_int(merged["app_id"], "app_id", 1, 2**63),
        installation_id=_int(merged["installation_id"], "installation_id", 1, 2**63),
        private_key=Path(os.path.expanduser(merged["private_key"])),
        runner_group_id=_int(merged["runner_group_id"], "runner_group_id", 1, 2**63),
        labels=tuple(labels),
        image=_name(merged["image"], "image"),
        slots=_int(merged["slots"], "slots", 1, MAX_SLOTS),
        vm_user=_name(merged["vm_user"], "vm_user"),
        vm_ssh_key=Path(os.path.expanduser(merged["vm_ssh_key"])),
        vm_runner_dir=_name(merged["vm_runner_dir"], "vm_runner_dir"),
        tart_run_args=tuple(args),
        job_limit_seconds=_int(merged["job_limit_seconds"], "job_limit_seconds", 600, 6 * 3600),
        boot_timeout_seconds=_int(merged["boot_timeout_seconds"], "boot_timeout_seconds", 30, 900),
        state_dir=Path(os.path.expanduser(merged["state_dir"])),
        api_url=merged["api_url"].rstrip("/"),
    )


def load_config(path: str) -> Config:
    try:
        value = json.loads(Path(os.path.expanduser(path)).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PoolError(f"cannot read {path}: {exc}") from exc
    return parse_config(value)


# ------------------------------------------------------------------- GitHub


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def parse_time(value: str) -> float:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


class GitHub:
    """The App's installation token, the just-in-time runner configuration and
    runner housekeeping. Only this host ever holds the App's private key."""

    def __init__(self, config: Config, opener: Callable = urllib.request.urlopen,
                 run: Callable = subprocess.run, now: Callable[[], float] = time.time) -> None:
        self.config, self.opener, self.run, self.now = config, opener, run, now
        self._token, self._expires = "", 0.0

    def app_jwt(self) -> str:
        issued = int(self.now())
        header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
        payload = b64url(json.dumps({"iat": issued - 60, "exp": issued + 540, "iss": self.config.app_id},
                                    separators=(",", ":")).encode())
        signed = self.run(["openssl", "dgst", "-sha256", "-sign", str(self.config.private_key), "-binary"],
                          input=f"{header}.{payload}".encode(), capture_output=True, check=True)
        return f"{header}.{payload}.{b64url(signed.stdout)}"

    def request(self, method: str, path: str, body: Optional[dict] = None, token: str = "") -> Optional[dict]:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.config.api_url}{path}", data=data, method=method, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token or self.token()}",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with self.opener(request, timeout=30) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:300]
            raise PoolError(f"{method} {path}: HTTP {exc.code} {detail}") from exc
        return json.loads(raw.decode("utf-8")) if raw.strip() else None

    def token(self) -> str:
        if self._token and self.now() < self._expires - 300:
            return self._token
        data = self.request("POST", f"/app/installations/{self.config.installation_id}/access_tokens",
                            token=self.app_jwt()) or {}
        self._token = data["token"]
        self._expires = parse_time(data["expires_at"]) if data.get("expires_at") else self.now() + 3000
        return self._token

    @property
    def runners_path(self) -> str:
        if self.config.repository:
            return f"/repos/{self.config.owner}/{self.config.repository}/actions/runners"
        return f"/orgs/{self.config.owner}/actions/runners"

    def jit_config(self, name: str) -> str:
        data = self.request("POST", f"{self.runners_path}/generate-jitconfig", {
            "name": name,
            "runner_group_id": self.config.runner_group_id,
            "labels": list(self.config.labels),
            "work_folder": "_work",
        }) or {}
        jit = data.get("encoded_jit_config", "")
        if not JIT_RE.match(jit):
            raise PoolError("GitHub returned no usable just-in-time configuration")
        return jit

    def runners(self) -> List[dict]:
        found: List[dict] = []
        page = 1
        while True:
            batch = (self.request("GET", f"{self.runners_path}?per_page=100&page={page}") or {}).get("runners", [])
            found.extend(batch)
            if len(batch) < 100:
                return found
            page += 1

    def delete_runner(self, runner_id: int) -> None:
        self.request("DELETE", f"{self.runners_path}/{runner_id}")

    def runner_group(self, group_id: int) -> dict:
        return self.request("GET", f"/orgs/{self.config.owner}/actions/runner-groups/{group_id}") or {}


# --------------------------------------------------------------------- Tart


class Tart:
    def __init__(self, run: Callable = subprocess.run, popen: Callable = subprocess.Popen) -> None:
        self.run, self.popen = run, popen

    def names(self) -> List[str]:
        out = self.run(["tart", "list", "--format", "json"], capture_output=True, text=True)
        if out.returncode == 0:
            try:
                return [str(item.get("Name") or item.get("name")) for item in json.loads(out.stdout)]
            except (ValueError, AttributeError):
                pass
        out = self.run(["tart", "list"], capture_output=True, text=True, check=True)
        return [line.split()[1] for line in out.stdout.splitlines()[1:] if len(line.split()) > 1]

    def clone(self, source: str, name: str) -> None:
        self.run(["tart", "clone", source, name], check=True, capture_output=True)

    def start(self, name: str, args: Sequence[str], log: Path) -> subprocess.Popen:
        with open(log, "ab") as handle:
            return self.popen(["tart", "run", name, *args], stdout=handle, stderr=subprocess.STDOUT,
                              stdin=subprocess.DEVNULL)

    def ip(self, name: str, wait: int) -> str:
        out = self.run(["tart", "ip", name, "--wait", str(wait)], capture_output=True, text=True, check=True)
        address = out.stdout.strip()
        if not IPV4_RE.match(address):
            raise PoolError(f"tart ip {name} gave {address!r}")
        return address

    def stop(self, name: str) -> None:
        self.run(["tart", "stop", name], capture_output=True)

    def delete(self, name: str) -> None:
        self.run(["tart", "delete", name], capture_output=True)


def ssh_argv(config: Config, address: str, command: str) -> List[str]:
    return ["ssh", "-i", str(config.vm_ssh_key), *SSH_OPTIONS, f"{config.vm_user}@{address}", command]


def wait_for_ssh(config: Config, address: str, run: Callable, now: Callable[[], float],
                 sleep: Callable[[float], None]) -> None:
    deadline = now() + config.boot_timeout_seconds
    while True:
        try:
            if run(ssh_argv(config, address, "true"), capture_output=True, timeout=30).returncode == 0:
                return
        except subprocess.TimeoutExpired:
            pass
        if now() >= deadline:
            raise PoolError(f"no SSH on {address} within {config.boot_timeout_seconds} s")
        sleep(5)


# --------------------------------------------------------------- the slots


def vm_name(slot: int, when: float) -> str:
    return f"{VM_PREFIX}{slot}-{time.strftime('%Y%m%d%H%M%S', time.gmtime(when))}"


def slot_prefix(slot: int) -> str:
    return f"{VM_PREFIX}{slot}-"


@dataclass
class Host:
    """What a slot turn touches, injectable for tests."""
    github: GitHub
    tart: Tart
    run: Callable = subprocess.run
    now: Callable[[], float] = time.time
    sleep: Callable[[float], None] = time.sleep


def log_record(config: Config, record: dict) -> None:
    line = json.dumps(record, sort_keys=True)
    print(line, flush=True)
    config.state_dir.mkdir(parents=True, exist_ok=True)
    with open(config.state_dir / "pool.log", "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def cleanup(config: Config, host: Host, slots: Sequence[int]) -> Dict[str, List[str]]:
    """Leftovers of earlier turns: VMs a crash left behind, and runners whose
    VM went away before they took a job (offline, never reused)."""
    prefixes = tuple(slot_prefix(slot) for slot in slots)
    removed: Dict[str, List[str]] = {"vms": [], "runners": []}
    for name in host.tart.names():
        if name.startswith(prefixes):
            host.tart.stop(name)
            host.tart.delete(name)
            removed["vms"].append(name)
    for runner in host.github.runners():
        if str(runner.get("name", "")).startswith(prefixes) and runner.get("status") == "offline":
            host.github.delete_runner(runner["id"])
            removed["runners"].append(runner["name"])
    return removed


def turn(config: Config, slot: int, host: Host) -> dict:
    """One VM, at most one job, then the VM is gone, whatever happened."""
    started = host.now()
    name = vm_name(slot, started)
    record: dict = {"slot": slot, "vm": name, "started": datetime.fromtimestamp(started, timezone.utc).isoformat()}
    process: Optional[subprocess.Popen] = None
    cloned = False
    try:
        host.tart.clone(config.image, name)
        cloned = True
        jit = host.github.jit_config(name)
        config.state_dir.mkdir(parents=True, exist_ok=True)
        process = host.tart.start(name, config.tart_run_args, config.state_dir / f"slot-{slot}.tart.log")
        address = host.tart.ip(name, config.boot_timeout_seconds)
        wait_for_ssh(config, address, host.run, host.now, host.sleep)
        command = RUNNER_COMMAND.format(dir=shlex.quote(config.vm_runner_dir))
        try:
            result = host.run(ssh_argv(config, address, command), input=jit.encode(), timeout=config.job_limit_seconds)
            record["runner_exit"] = result.returncode
        except subprocess.TimeoutExpired:
            record["runner_exit"] = f"stopped at the {config.job_limit_seconds} s job limit"
    except Exception as exc:
        record["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        if cloned:
            host.tart.stop(name)
            if process is not None:
                try:
                    process.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    process.kill()
            host.tart.delete(name)
        record["seconds"] = round(host.now() - started)
        log_record(config, record)
    return record


def run_slot(config: Config, slot: int, host: Host, stop: Callable[[], bool] = lambda: False) -> None:
    backoff = 30
    while not stop():
        try:
            cleanup(config, host, [slot])
        except Exception as exc:
            log_record(config, {"slot": slot, "cleanup_error": f"{type(exc).__name__}: {exc}"})
        record = turn(config, slot, host)
        if "error" in record:
            host.sleep(backoff)
            backoff = min(backoff * 2, 600)
        else:
            backoff = 30


# ------------------------------------------------------------ verification

# Runs inside a VM (python3 -, the targets as its argument) and reports what a
# job there could reach and see.
PROBE = r'''
import glob, json, os, socket, subprocess, sys
targets = json.loads(sys.argv[1])
def tcp(host, port):
    try:
        socket.create_connection((host, port), timeout=4).close()
        return True
    except OSError:
        return False
route = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True).stdout
gateway = next((line.split(":", 1)[1].strip() for line in route.splitlines() if "gateway:" in line), "")
patterns = ["~/.ssh/id_*", "~/*.pem", "~/.config/gh/hosts.yml", "~/.git-credentials",
            "~/.netrc", "~/actions-runner/.credentials*", "~/actions-runner/.runner"]
print(json.dumps({
    "tcp": [dict(t, open=tcp(t["host"], t["port"])) for t in targets],
    "gateway_ssh": bool(gateway) and tcp(gateway, 22),
    "gateway": gateway,
    "mounts": subprocess.run(["mount"], capture_output=True, text=True).stdout.splitlines(),
    "secret_files": sorted(p for pattern in patterns for p in glob.glob(os.path.expanduser(pattern))),
    "secret_env": sorted(k for k in os.environ if any(w in k.upper() for w in ("TOKEN", "SECRET", "PASSWORD", "PRIVATE"))),
    "tools": {tool: subprocess.run(["/bin/sh", "-c", "PATH=/opt/homebrew/bin:$PATH command -v " + tool],
                                   capture_output=True).returncode == 0
              for tool in ("python3", "brew", "git", "rg", "zstd", "gtar", "bash")},
    "runner": os.path.exists(os.path.expanduser("~/actions-runner/run.sh")),
}))
'''
PRIVATE_SAMPLES = (("10.0.0.1", 80), ("172.16.0.1", 80), ("192.168.0.1", 80), ("192.168.1.1", 80),
                   ("100.64.0.1", 80), ("169.254.169.254", 80))


def judge(probe: dict, blocked: Sequence[dict]) -> List[Tuple[str, str, str]]:
    """(check, PASS | FAIL | NOTE, detail) for one VM's probe. `blocked` are the
    targets a job must not reach, each with whether the host reaches it (a
    closed port proves isolation only if something listens there)."""
    results: List[Tuple[str, str, str]] = []
    opened = {(t["host"], t["port"]): t["open"] for t in probe.get("tcp", [])}
    results.append(("internet", "PASS" if opened.get(("github.com", 443)) else "FAIL", "github.com:443"))
    for target in blocked:
        key = (target["host"], target["port"])
        where = f"{target['host']}:{target['port']} ({target['what']})"
        if opened.get(key):
            results.append(("isolation", "FAIL", f"{where} is reachable from the VM"))
        elif target.get("host_reaches"):
            results.append(("isolation", "PASS", f"{where} reachable from the host, not from the VM"))
        else:
            results.append(("isolation", "NOTE", f"{where} unreachable, but the host does not reach it either"))
    results.append(("isolation", "FAIL" if probe.get("gateway_ssh") else "PASS",
                    f"the host's SSH through the VM's gateway {probe.get('gateway') or '?'}"))
    shared = [line for line in probe.get("mounts", []) if "virtiofs" in line or "My Shared Files" in line]
    results.append(("no host directories", "FAIL" if shared else "PASS", "; ".join(shared) or "none mounted"))
    results.append(("no credentials", "FAIL" if probe.get("secret_files") else "PASS",
                    ", ".join(probe.get("secret_files", [])) or "no key, token or runner credential files"))
    results.append(("no secret variables", "FAIL" if probe.get("secret_env") else "PASS",
                    ", ".join(probe.get("secret_env", [])) or "none"))
    missing = sorted(tool for tool, present in probe.get("tools", {}).items() if not present)
    results.append(("image tools", "FAIL" if missing else "PASS", f"missing {missing}" if missing else "all present"))
    results.append(("image runner", "PASS" if probe.get("runner") else "FAIL", "~/actions-runner/run.sh"))
    return results


def host_addresses(run: Callable) -> List[str]:
    out = run(["ifconfig"], capture_output=True, text=True).stdout
    found = re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)", out)
    return [address for address in found if not address.startswith("127.")]


def host_gateway(run: Callable) -> str:
    out = run(["route", "-n", "get", "default"], capture_output=True, text=True).stdout
    return next((line.split(":", 1)[1].strip() for line in out.splitlines() if "gateway:" in line), "")


def reachable_from_host(address: str, port: int) -> bool:
    try:
        socket.create_connection((address, port), timeout=4).close()
        return True
    except OSError:
        return False


def verify(config: Config, host: Host, reaches: Callable[[str, int], bool] = reachable_from_host) -> int:
    """Boot two VMs as the slots do and check, from inside the first, what a
    job could reach and see. Run it with the slot services stopped."""
    names = [vm_name(slot, host.now()) + "-verify" for slot in range(1, config.slots + 1)]
    processes: List[subprocess.Popen] = []
    try:
        addresses = []
        for name in names:
            host.tart.clone(config.image, name)
            processes.append(host.tart.start(name, config.tart_run_args, config.state_dir / "verify.tart.log"))
            addresses.append(host.tart.ip(name, config.boot_timeout_seconds))
        for address in addresses:
            wait_for_ssh(config, address, host.run, host.now, host.sleep)
        gateway = host_gateway(host.run)
        blocked = [{"host": a, "port": 22, "what": "host"} for a in host_addresses(host.run)
                   if a not in addresses]
        if gateway:
            blocked += [{"host": gateway, "port": port, "what": "the host's router"} for port in (53, 80, 443)]
        blocked += [{"host": a, "port": 22, "what": "another pool VM"} for a in addresses[1:]]
        blocked += [{"host": h, "port": p, "what": "private range"} for h, p in PRIVATE_SAMPLES]
        for target in blocked:
            target["host_reaches"] = reaches(target["host"], target["port"])
        targets = [{"host": "github.com", "port": 443}] + [{"host": t["host"], "port": t["port"]} for t in blocked]
        out = host.run(ssh_argv(config, addresses[0], "python3 - " + shlex.quote(json.dumps(targets))),
                       input=PROBE.encode(), capture_output=True, timeout=300)
        if out.returncode != 0:
            raise PoolError(f"the probe failed in the VM: {out.stderr.decode('utf-8', 'replace')[:300]}")
        results = judge(json.loads(out.stdout.decode("utf-8")), blocked)
    finally:
        for name in names:
            host.tart.stop(name)
        for process in processes:
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                process.kill()
        for name in names:
            host.tart.delete(name)
    for check, verdict, detail in results:
        print(f"{verdict:4}  {check}: {detail}")
    return 1 if any(verdict == "FAIL" for _, verdict, _ in results) else 0


# ------------------------------------------------------------------- check


def check(config: Config, host: Host, which: Callable[[str], Optional[str]]) -> int:
    results: List[Tuple[str, bool, str]] = []
    for tool in ("tart", "ssh", "openssl"):
        results.append((f"tool {tool}", which(tool) is not None, which(tool) or "not on PATH"))
    for label, path in (("App private key", config.private_key), ("VM SSH key", config.vm_ssh_key)):
        try:
            mode = path.stat().st_mode & 0o777
            results.append((label, mode & 0o077 == 0, f"{path} mode {mode:o}"))
        except OSError as exc:
            results.append((label, False, str(exc)))
    try:
        results.append(("golden image", config.image in host.tart.names(), config.image))
    except Exception as exc:
        results.append(("golden image", False, str(exc)))
    try:
        host.github.token()
        results.append(("GitHub App token", True, f"installation {config.installation_id}"))
        runners = host.github.runners()
        results.append(("runners readable", True, f"{len(runners)} registered"))
        if not config.repository:
            # The organization's persistent macOS runner, retired 2026-11-18.
            stale = [r["name"] for r in runners if r.get("name") == "AppledeMac-Studio"]
            results.append(("persistent runner retired", not stale, ", ".join(stale) or "AppledeMac-Studio gone"))
            group = host.github.runner_group(config.runner_group_id)
            results.append(("pool runner group", group.get("visibility") == "selected"
                            and bool(group.get("allows_public_repositories")),
                            f"{group.get('name')}: visibility {group.get('visibility')}, "
                            f"public repositories {group.get('allows_public_repositories')}"))
            default = host.github.runner_group(1)
            results.append(("Default group keeps public repositories out",
                            default.get("allows_public_repositories") is False,
                            f"allows_public_repositories={default.get('allows_public_repositories')}"))
    except Exception as exc:
        results.append(("GitHub App access", False, f"{type(exc).__name__}: {exc}"))
    for name, ok, detail in results:
        print(f"{'PASS' if ok else 'FAIL':4}  {name}: {detail}")
    return 0 if all(ok for _, ok, _ in results) else 1


def launchd_plist(config: Config, slot: int, python: str, script: str, config_path: str) -> bytes:
    return plistlib.dumps({
        "Label": f"ai.metask.metacodes-vm-pool.slot{slot}",
        "ProgramArguments": [python, script, "--config", config_path, "slot", str(slot)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        # Tart's macOS guests need the logged-in user's session.
        "LimitLoadToSessionType": "Aqua",
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
        "StandardOutPath": str(config.state_dir / f"slot-{slot}.out.log"),
        "StandardErrorPath": str(config.state_dir / f"slot-{slot}.err.log"),
    })


# ---------------------------------------------------------------- the CLI


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("verify")
    commands.add_parser("cleanup")
    for name in ("slot", "once", "launchd-plist"):
        commands.add_parser(name).add_argument("slot", type=int)
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        if getattr(args, "slot", 1) not in range(1, config.slots + 1):
            raise PoolError(f"slot must be within 1..{config.slots}")
    except PoolError as exc:
        print(f"macos_vm_pool: {exc}", file=sys.stderr)
        return 2
    if args.command == "launchd-plist":
        sys.stdout.write(launchd_plist(config, args.slot, sys.executable, str(Path(__file__).resolve()),
                                       str(Path(os.path.expanduser(args.config)))).decode())
        return 0
    host = Host(GitHub(config), Tart())
    # launchd stops a slot with SIGTERM: unwind so the current VM is destroyed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if args.command == "check":
        return check(config, host, shutil.which)
    if args.command == "verify":
        return verify(config, host)
    if args.command == "cleanup":
        print(json.dumps(cleanup(config, host, range(1, config.slots + 1))))
        return 0
    if args.command == "once":
        return 0 if "error" not in turn(config, args.slot, host) else 1
    run_slot(config, args.slot, host)
    return 0


if __name__ == "__main__":
    sys.exit(main())
