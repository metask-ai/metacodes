#!/usr/bin/env python3
"""The self-hosted VM pools that run metacodes' macOS and Windows gates
(doc/VM_POOLS.md, doc/CI_DESIGN.md §6).

One controller, two backends: `tart` on the Mac Studio (macOS guests) and
`hyperv` on AIPC (Windows guests). It runs on the pool host as the dedicated
`ci-host` user, one process per slot, and never runs a job itself. Each turn
of a slot creates a fresh VM from the golden image, asks GitHub for a
just-in-time runner configuration (one job, then the runner is gone), hands
the configuration to the VM, and destroys the VM when the job ends, fails or
exceeds its limit. The GitHub App's private key stays on the host; a VM sees
only its single-use configuration.

- tart: `tart clone` of the golden image, `tart run` on Softnet, the runner
  started over SSH with the configuration on standard input.
- hyperv: a differencing disk over the golden VHDX, port ACLs on the virtual
  switch that deny private networks (enforced outside the guest), and the
  configuration handed over by PowerShell Direct, which needs no network; a
  task in the guest runs the one job and powers the VM off.

Commands:
  check              configuration, tools, key files, image, GitHub App access
  verify             boot VMs and check what a job inside one can reach and see
  slot N             run slot N until stopped (launchd / Task Scheduler)
  once N             one turn of slot N
  cleanup            remove leftover pool VMs and offline pool runners
  service N          print what installs slot N as a service

Configuration: ~/.metacodes-runner/config.json (--config); fields in
doc/VM_POOLS.md. Python 3.9, stdlib only; host tools: openssl, and tart and
ssh, or PowerShell with Hyper-V. Tests: scripts/tests/test_vm_pool.py.
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
BACKENDS = ("tart", "hyperv")
# Virtualization.framework runs at most two macOS guests per host; Hyper-V is
# bounded by the machine.
MAX_SLOTS = {"tart": 2, "hyperv": 8}
# The organization's persistent runners, retired 2026-11-18 for the pools.
RETIRED_RUNNERS = ("AppledeMac-Studio", "AIPC")
GENERIC_LABELS = {"self-hosted", "macos", "linux", "windows", "x64", "arm64", "arm"}
PRIVATE_NETWORKS = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")
SWITCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()-]{0,63}$")
CIDR_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$")
JIT_RE = re.compile(r"^[A-Za-z0-9+/=]+$")
IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")


class PoolError(Exception):
    pass


# ------------------------------------------------------------- configuration


@dataclass(frozen=True)
class Config:
    backend: str
    owner: str
    repository: str
    app_id: int
    installation_id: int
    private_key: Path
    runner_group_id: int
    labels: Tuple[str, ...]
    image: str
    slots: int
    job_limit_seconds: int
    boot_timeout_seconds: int
    state_dir: Path
    api_url: str
    vm_user: str
    vm_runner_dir: str
    # tart
    vm_ssh_key: Optional[Path] = None
    tart_run_args: Tuple[str, ...] = ()
    # hyperv
    vhd_dir: Optional[Path] = None
    vm_password_file: Optional[Path] = None
    switch: str = ""
    cpus: int = 0
    memory_mb: int = 0
    blocked_networks: Tuple[str, ...] = ()

    @property
    def pool_label(self) -> str:
        return next(label for label in self.labels if label.lower() not in GENERIC_LABELS)


COMMON_REQUIRED = ("backend", "owner", "app_id", "installation_id", "private_key", "runner_group_id", "image")
COMMON_DEFAULTS: Dict[str, object] = {
    "repository": "",
    "slots": 2,
    "job_limit_seconds": 5400,
    "boot_timeout_seconds": 240,
    "state_dir": "~/.metacodes-runner",
    "api_url": "https://api.github.com",
}
BACKEND_REQUIRED = {"tart": ("vm_ssh_key",), "hyperv": ("vhd_dir", "vm_password_file", "cpus", "memory_mb")}
BACKEND_DEFAULTS: Dict[str, Dict[str, object]] = {
    "tart": {
        "labels": ["self-hosted", "macOS", "ARM64", "metacodes-macos-vm"],
        "vm_user": "admin",
        "vm_runner_dir": "actions-runner",
        "tart_run_args": ["--no-graphics", "--net-softnet"],
    },
    "hyperv": {
        "labels": ["self-hosted", "Windows", "X64", "metacodes-windows-vm"],
        "vm_user": "runner",
        "vm_runner_dir": "C:\\actions-runner",
        "switch": "Default Switch",
        "blocked_networks": list(PRIVATE_NETWORKS),
        "boot_timeout_seconds": 600,
    },
}


def _int(value: object, name: str, low: int, high: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise PoolError(f"{name} must be an integer within {low}..{high}")
    return value


def _name(value: object, name: str, empty: bool = False) -> str:
    if not isinstance(value, str) or not (NAME_RE.match(value) or (empty and value == "")):
        raise PoolError(f"{name} must be a plain name")
    return value


def _path(value: object, name: str) -> Path:
    if not isinstance(value, str) or not value:
        raise PoolError(f"{name} must be a path")
    return Path(os.path.expanduser(value))


def _strings(value: object, name: str) -> Tuple[str, ...]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise PoolError(f"{name} must be a list of strings")
    return tuple(value)


def parse_config(value: object) -> Config:
    if not isinstance(value, dict):
        raise PoolError("the configuration is not a JSON object")
    backend = value.get("backend")
    if backend not in BACKENDS:
        raise PoolError(f"backend must be one of {list(BACKENDS)}")
    allowed = set(COMMON_REQUIRED) | set(COMMON_DEFAULTS) | set(BACKEND_REQUIRED[backend]) | set(BACKEND_DEFAULTS[backend])
    missing = [key for key in COMMON_REQUIRED + BACKEND_REQUIRED[backend] if key not in value]
    unknown = sorted(set(value) - allowed)
    if missing or unknown:
        raise PoolError(f"configuration fields: missing {missing}, unknown {unknown}")
    merged = {**COMMON_DEFAULTS, **BACKEND_DEFAULTS[backend], **value}
    labels = _strings(merged["labels"], "labels")
    if not all(NAME_RE.match(label) for label in labels):
        raise PoolError("labels must be plain names")
    if "self-hosted" not in labels or all(label.lower() in GENERIC_LABELS for label in labels):
        raise PoolError("labels must hold self-hosted and one dedicated pool label")
    if not isinstance(merged["api_url"], str) or not merged["api_url"].startswith("https://"):
        raise PoolError("api_url must be an https URL")
    common = dict(
        backend=backend,
        owner=_name(merged["owner"], "owner"),
        repository=_name(merged["repository"], "repository", empty=True),
        app_id=_int(merged["app_id"], "app_id", 1, 2**63),
        installation_id=_int(merged["installation_id"], "installation_id", 1, 2**63),
        private_key=_path(merged["private_key"], "private_key"),
        runner_group_id=_int(merged["runner_group_id"], "runner_group_id", 1, 2**63),
        labels=labels,
        image=_name(merged["image"], "image"),
        slots=_int(merged["slots"], "slots", 1, MAX_SLOTS[backend]),
        job_limit_seconds=_int(merged["job_limit_seconds"], "job_limit_seconds", 600, 6 * 3600),
        boot_timeout_seconds=_int(merged["boot_timeout_seconds"], "boot_timeout_seconds", 30, 1800),
        state_dir=_path(merged["state_dir"], "state_dir"),
        api_url=merged["api_url"].rstrip("/"),
        vm_user=_name(merged["vm_user"], "vm_user"),
    )
    if backend == "tart":
        args = _strings(merged["tart_run_args"], "tart_run_args")
        # The pool's network isolation (doc/VM_POOLS.md, M3): no VM without Softnet.
        if not any(arg.startswith("--net-softnet") for arg in args):
            raise PoolError("tart_run_args must run every VM on Softnet (--net-softnet)")
        if any(arg.startswith(("--dir", "--disk")) for arg in args):
            raise PoolError("tart_run_args must not share host directories or disks with a VM")
        return Config(**common, vm_runner_dir=_name(merged["vm_runner_dir"], "vm_runner_dir"),
                      vm_ssh_key=_path(merged["vm_ssh_key"], "vm_ssh_key"), tart_run_args=args)
    blocked = _strings(merged["blocked_networks"], "blocked_networks")
    if not all(CIDR_RE.match(network) for network in blocked):
        raise PoolError("blocked_networks must be IPv4 CIDR blocks")
    # The pool's network isolation: every private range stays denied.
    if not set(PRIVATE_NETWORKS) <= set(blocked):
        raise PoolError(f"blocked_networks must deny at least {list(PRIVATE_NETWORKS)}")
    switch = merged["switch"]
    if not isinstance(switch, str) or not SWITCH_RE.match(switch):
        raise PoolError("switch must be a Hyper-V virtual switch name")
    runner_dir = merged["vm_runner_dir"]
    if not isinstance(runner_dir, str) or not re.match(r"^[A-Za-z]:\\[A-Za-z0-9._\\-]+$", runner_dir):
        raise PoolError("vm_runner_dir must be a Windows path")
    return Config(**common, vm_runner_dir=runner_dir,
                  vhd_dir=_path(merged["vhd_dir"], "vhd_dir"),
                  vm_password_file=_path(merged["vm_password_file"], "vm_password_file"),
                  switch=switch,
                  cpus=_int(merged["cpus"], "cpus", 1, 64),
                  memory_mb=_int(merged["memory_mb"], "memory_mb", 2048, 262144),
                  blocked_networks=blocked)


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


# ------------------------------------------------------- the tart backend

TART_RUNNER_COMMAND = ('cd {dir} && export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH" '
                       '&& exec ./run.sh --jitconfig "$(cat)"')
SSH_OPTIONS = ("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
               "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4",
               "-o", "LogLevel=ERROR")
# Runs inside a macOS VM (python3 -, the targets as its argument).
POSIX_PROBE = r'''
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
mounts = subprocess.run(["mount"], capture_output=True, text=True).stdout.splitlines()
print(json.dumps({
    "tcp": [dict(t, open=tcp(t["host"], t["port"])) for t in targets],
    "gateway": gateway,
    "gateway_open": [port for port in (22,) if gateway and tcp(gateway, port)],
    "shared": [line for line in mounts if "virtiofs" in line or "My Shared Files" in line],
    "secret_files": sorted(p for pattern in patterns for p in glob.glob(os.path.expanduser(pattern))),
    "secret_env": sorted(k for k in os.environ if any(w in k.upper() for w in ("TOKEN", "SECRET", "PASSWORD", "PRIVATE"))),
    "tools": {tool: subprocess.run(["/bin/sh", "-c", "PATH=/opt/homebrew/bin:$PATH command -v " + tool],
                                   capture_output=True).returncode == 0
              for tool in ("python3", "brew", "git", "rg", "zstd", "gtar", "bash")},
    "runner": os.path.exists(os.path.expanduser("~/actions-runner/run.sh")),
}))
'''


class TartBackend:
    tools = ("tart", "ssh", "openssl")
    host_ports = (22,)        # what a VM must not reach on the host
    guest_ports = (22,)       # what a VM must not reach on another pool VM

    def __init__(self, config: Config, run: Callable = subprocess.run, popen: Callable = subprocess.Popen,
                 now: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep) -> None:
        self.config, self.run, self.popen, self.now, self.sleep = config, run, popen, now, sleep
        self.processes: Dict[str, subprocess.Popen] = {}
        self.addresses: Dict[str, str] = {}

    def names(self) -> List[str]:
        out = self.run(["tart", "list", "--format", "json"], capture_output=True, text=True)
        if out.returncode == 0:
            try:
                return [str(item.get("Name") or item.get("name")) for item in json.loads(out.stdout)]
            except (ValueError, AttributeError):
                pass
        out = self.run(["tart", "list"], capture_output=True, text=True, check=True)
        return [line.split()[1] for line in out.stdout.splitlines()[1:] if len(line.split()) > 1]

    def image_exists(self) -> bool:
        return self.config.image in self.names()

    def create(self, name: str) -> None:
        self.run(["tart", "clone", self.config.image, name], check=True, capture_output=True)

    def start(self, name: str) -> None:
        self.config.state_dir.mkdir(parents=True, exist_ok=True)
        with open(self.config.state_dir / "tart.log", "ab") as log:
            self.processes[name] = self.popen(["tart", "run", name, *self.config.tart_run_args], stdout=log,
                                              stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

    def ssh(self, address: str, command: str) -> List[str]:
        return ["ssh", "-i", str(self.config.vm_ssh_key), *SSH_OPTIONS, f"{self.config.vm_user}@{address}", command]

    def wait_ready(self, name: str) -> None:
        out = self.run(["tart", "ip", name, "--wait", str(self.config.boot_timeout_seconds)],
                       capture_output=True, text=True, check=True)
        address = out.stdout.strip()
        if not IPV4_RE.match(address):
            raise PoolError(f"tart ip {name} gave {address!r}")
        deadline = self.now() + self.config.boot_timeout_seconds
        while True:
            try:
                if self.run(self.ssh(address, "true"), capture_output=True, timeout=30).returncode == 0:
                    self.addresses[name] = address
                    return
            except subprocess.TimeoutExpired:
                pass
            if self.now() >= deadline:
                raise PoolError(f"no SSH on {address} within {self.config.boot_timeout_seconds} s")
            self.sleep(5)

    def address(self, name: str) -> str:
        return self.addresses[name]

    def run_job(self, name: str, jit: str) -> object:
        command = TART_RUNNER_COMMAND.format(dir=shlex.quote(self.config.vm_runner_dir))
        try:
            # The configuration on standard input: never in a command line.
            return self.run(self.ssh(self.address(name), command), input=jit.encode(),
                            timeout=self.config.job_limit_seconds).returncode
        except subprocess.TimeoutExpired:
            return f"stopped at the {self.config.job_limit_seconds} s job limit"

    def probe(self, name: str, targets: List[dict]) -> dict:
        out = self.run(self.ssh(self.address(name), "python3 - " + shlex.quote(json.dumps(targets))),
                       input=POSIX_PROBE.encode(), capture_output=True, timeout=300)
        if out.returncode != 0:
            raise PoolError(f"the probe failed in the VM: {out.stderr.decode('utf-8', 'replace')[:300]}")
        return json.loads(out.stdout.decode("utf-8"))

    def destroy(self, name: str) -> None:
        self.run(["tart", "stop", name], capture_output=True)
        process = self.processes.pop(name, None)
        if process is not None:
            try:
                process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                process.kill()
        self.run(["tart", "delete", name], capture_output=True)
        self.addresses.pop(name, None)

    def host_addresses(self) -> List[str]:
        out = self.run(["ifconfig"], capture_output=True, text=True).stdout
        return [a for a in re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)", out) if not a.startswith("127.")]

    def host_gateway(self) -> str:
        out = self.run(["route", "-n", "get", "default"], capture_output=True, text=True).stdout
        return next((line.split(":", 1)[1].strip() for line in out.splitlines() if "gateway:" in line), "")

    def service(self, slot: int, python: str, script: str, config_path: str) -> str:
        return plistlib.dumps({
            "Label": f"ai.metask.metacodes-vm-pool.slot{slot}",
            "ProgramArguments": [python, script, "--config", config_path, "slot", str(slot)],
            "RunAtLoad": True,
            "KeepAlive": True,
            "ThrottleInterval": 30,
            # Tart's macOS guests need the logged-in user's session.
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
            "StandardOutPath": str(self.config.state_dir / f"slot-{slot}.out.log"),
            "StandardErrorPath": str(self.config.state_dir / f"slot-{slot}.err.log"),
        }).decode()


# ----------------------------------------------------- the Hyper-V backend

PS_PRELUDE = "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'\n"
# PowerShell Direct reaches the guest over the VM bus, not the network, with
# the guest's runner account. The password file is the host's only copy.
PS_CREDENTIAL = (
    "$secret = ConvertTo-SecureString ((Get-Content -Raw -LiteralPath $env:POOL_PASSWORD_FILE).Trim()) "
    "-AsPlainText -Force\n"
    "$cred = New-Object System.Management.Automation.PSCredential($env:POOL_VM_USER, $secret)\n"
)
PS_CREATE = PS_PRELUDE + r'''
$parent = Join-Path $env:POOL_VHD_DIR ($env:POOL_IMAGE + '.vhdx')
$disk = Join-Path $env:POOL_VHD_DIR ($env:POOL_VM + '.vhdx')
New-VHD -Path $disk -ParentPath $parent -Differencing | Out-Null
New-VM -Name $env:POOL_VM -Generation 2 -MemoryStartupBytes ([int64]$env:POOL_MEMORY_MB * 1MB) -VHDPath $disk -SwitchName $env:POOL_SWITCH | Out-Null
Set-VM -Name $env:POOL_VM -ProcessorCount ([int]$env:POOL_CPUS) -StaticMemory -AutomaticCheckpointsEnabled $false -CheckpointType Disabled
Disable-VMIntegrationService -VMName $env:POOL_VM -Name 'Guest Service Interface'
# The virtual switch enforces these outside the guest: DHCP and DNS out, then
# no private network (the host, its LAN, the other VMs).
Add-VMNetworkAdapterExtendedAcl -VMName $env:POOL_VM -Action Allow -Direction Outbound -Protocol UDP -RemotePort 67 -Weight 300
Add-VMNetworkAdapterExtendedAcl -VMName $env:POOL_VM -Action Allow -Direction Outbound -Protocol UDP -RemotePort 53 -Weight 299
Add-VMNetworkAdapterExtendedAcl -VMName $env:POOL_VM -Action Allow -Direction Outbound -Protocol TCP -RemotePort 53 -Weight 298
$weight = 200
foreach ($network in $env:POOL_BLOCKED.Split(',')) {
  Add-VMNetworkAdapterExtendedAcl -VMName $env:POOL_VM -Action Deny -Direction Outbound -RemoteIPAddress $network -Weight $weight
  $weight -= 1
}
'''
PS_START = PS_PRELUDE + "Start-VM -Name $env:POOL_VM\n"
PS_READY = PS_PRELUDE + PS_CREDENTIAL + r'''
$ready = Invoke-Command -VMName $env:POOL_VM -Credential $cred -ArgumentList $env:POOL_RUNNER_DIR -ScriptBlock {
  param($dir)
  Test-Path -LiteralPath (Join-Path $dir 'run.cmd')
}
if (-not $ready) { exit 1 }
'''
# The guest's start-up task (scripts/ci/windows_vm_provision.ps1) waits for
# C:\pool\jit, runs that one job and powers the VM off.
PS_HANDOVER = PS_PRELUDE + PS_CREDENTIAL + r'''
$jit = [Console]::In.ReadToEnd().Trim()
Invoke-Command -VMName $env:POOL_VM -Credential $cred -ArgumentList $jit -ScriptBlock {
  param($j)
  Set-Content -LiteralPath 'C:\pool\jit.tmp' -Value $j -NoNewline -Encoding ascii
  Move-Item -LiteralPath 'C:\pool\jit.tmp' -Destination 'C:\pool\jit' -Force
}
'''
PS_STATE = PS_PRELUDE + "(Get-VM -Name $env:POOL_VM).State.ToString()\n"
PS_ADDRESS = PS_PRELUDE + (
    "(Get-VMNetworkAdapter -VMName $env:POOL_VM).IPAddresses | "
    "Where-Object { $_ -match '^\\d+\\.\\d+\\.\\d+\\.\\d+$' } | Select-Object -First 1\n")
PS_DESTROY = r'''
$vm = Get-VM -Name $env:POOL_VM -ErrorAction SilentlyContinue
if ($vm) { Stop-VM -VM $vm -TurnOff -Force -ErrorAction SilentlyContinue; Remove-VM -VM $vm -Force }
$disk = Join-Path $env:POOL_VHD_DIR ($env:POOL_VM + '.vhdx')
if (Test-Path -LiteralPath $disk) { Remove-Item -LiteralPath $disk -Force }
'''
PS_NAMES = PS_PRELUDE + "Get-VM | ForEach-Object { $_.Name }\n"
PS_HOST_ADDRESSES = PS_PRELUDE + (
    "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | "
    "ForEach-Object { $_.IPAddress }\n")
PS_HOST_GATEWAY = PS_PRELUDE + (
    "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop\n")
# Runs inside a Windows VM over PowerShell Direct, the targets on standard input.
PS_PROBE = PS_PRELUDE + PS_CREDENTIAL + r'''
$targets = [Console]::In.ReadToEnd()
Invoke-Command -VMName $env:POOL_VM -Credential $cred -ArgumentList $targets -ScriptBlock {
  param($json)
  function Test-Tcp($address, $port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { return [bool]($client.ConnectAsync($address, [int]$port).Wait(4000) -and $client.Connected) }
    catch { return $false } finally { $client.Dispose() }
  }
  $gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop
  $patterns = @("$env:USERPROFILE\.ssh\id_*", "$env:USERPROFILE\*.pem", "$env:USERPROFILE\.git-credentials",
                "$env:APPDATA\GitHub CLI\hosts.yml", 'C:\actions-runner\.credentials*', 'C:\actions-runner\.runner')
  $tools = @{}
  foreach ($tool in 'git', 'python', 'rg', 'zstd', 'bash') { $tools[$tool] = [bool](Get-Command $tool -ErrorAction SilentlyContinue) }
  [pscustomobject]@{
    tcp = @(foreach ($t in ($json | ConvertFrom-Json)) { [pscustomobject]@{ host = $t.host; port = [int]$t.port; open = (Test-Tcp $t.host $t.port) } })
    gateway = $gateway
    gateway_open = @(foreach ($port in 135, 445, 3389, 5985) { if ($gateway -and (Test-Tcp $gateway $port)) { $port } })
    shared = @(@(Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object { $_.RemotePath }) +
               @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.DisplayRoot } | ForEach-Object { $_.DisplayRoot }))
    secret_files = @(foreach ($p in $patterns) { Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName } })
    secret_env = @(Get-ChildItem Env: | Where-Object { $_.Name -match 'TOKEN|SECRET|PASSWORD|PRIVATE' } | ForEach-Object { $_.Name })
    tools = $tools
    runner = (Test-Path -LiteralPath 'C:\actions-runner\run.cmd')
  } | ConvertTo-Json -Depth 4 -Compress
}
'''


class HyperVBackend:
    tools = ("powershell", "openssl")
    host_ports = (135, 445, 3389, 5985)
    guest_ports = (445, 3389, 5985)

    def __init__(self, config: Config, run: Callable = subprocess.run,
                 now: Callable[[], float] = time.time, sleep: Callable[[float], None] = time.sleep) -> None:
        self.config, self.run, self.now, self.sleep = config, run, now, sleep

    def ps(self, script: str, name: str = "", input: Optional[bytes] = None, timeout: Optional[float] = None,
           check: bool = True) -> subprocess.CompletedProcess:
        """A PowerShell script with every value in its environment, never in
        its text, so no name or path is ever parsed as code."""
        env = dict(os.environ)
        env.update({
            "POOL_VM": name, "POOL_IMAGE": self.config.image, "POOL_VHD_DIR": str(self.config.vhd_dir),
            "POOL_SWITCH": self.config.switch, "POOL_CPUS": str(self.config.cpus),
            "POOL_MEMORY_MB": str(self.config.memory_mb), "POOL_BLOCKED": ",".join(self.config.blocked_networks),
            "POOL_PASSWORD_FILE": str(self.config.vm_password_file), "POOL_VM_USER": self.config.vm_user,
            "POOL_RUNNER_DIR": self.config.vm_runner_dir,
        })
        out = self.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                        "-Command", script], input=input, capture_output=True, env=env, timeout=timeout)
        if check and out.returncode != 0:
            raise PoolError(f"PowerShell failed ({out.returncode}): {out.stderr.decode('utf-8', 'replace')[:300]}")
        return out

    def names(self) -> List[str]:
        return [line.strip() for line in self.ps(PS_NAMES).stdout.decode("utf-8", "replace").splitlines() if line.strip()]

    def image_exists(self) -> bool:
        return (self.config.vhd_dir / f"{self.config.image}.vhdx").is_file()

    def create(self, name: str) -> None:
        self.ps(PS_CREATE, name)

    def start(self, name: str) -> None:
        self.ps(PS_START, name)

    def wait_ready(self, name: str) -> None:
        deadline = self.now() + self.config.boot_timeout_seconds
        while True:
            try:
                if self.ps(PS_READY, name, timeout=120, check=False).returncode == 0:
                    return
            except subprocess.TimeoutExpired:
                pass
            if self.now() >= deadline:
                raise PoolError(f"{name} was not ready within {self.config.boot_timeout_seconds} s")
            self.sleep(10)

    def address(self, name: str) -> str:
        deadline = self.now() + self.config.boot_timeout_seconds
        while True:
            address = self.ps(PS_ADDRESS, name, check=False).stdout.decode("utf-8", "replace").strip()
            if IPV4_RE.match(address):
                return address
            if self.now() >= deadline:
                raise PoolError(f"{name} reported no IPv4 address")
            self.sleep(5)

    def run_job(self, name: str, jit: str) -> object:
        # The configuration on standard input: never in a command line.
        self.ps(PS_HANDOVER, name, input=jit.encode(), timeout=300)
        deadline = self.now() + self.config.job_limit_seconds
        while self.now() < deadline:
            state = self.ps(PS_STATE, name, check=False).stdout.decode("utf-8", "replace").strip()
            if state == "Off":
                return "powered off after its job"
            self.sleep(15)
        return f"stopped at the {self.config.job_limit_seconds} s job limit"

    def probe(self, name: str, targets: List[dict]) -> dict:
        out = self.ps(PS_PROBE, name, input=json.dumps(targets).encode(), timeout=300)
        return json.loads(out.stdout.decode("utf-8"))

    def destroy(self, name: str) -> None:
        self.ps(PS_DESTROY, name, check=False)

    def host_addresses(self) -> List[str]:
        return [line.strip() for line in self.ps(PS_HOST_ADDRESSES).stdout.decode().splitlines() if line.strip()]

    def host_gateway(self) -> str:
        return self.ps(PS_HOST_GATEWAY, check=False).stdout.decode().strip()

    def service(self, slot: int, python: str, script: str, config_path: str) -> str:
        """A Task Scheduler task at start-up: Hyper-V needs no logged-in user."""
        task = f"metacodes-vm-pool-slot{slot}"
        arguments = subprocess.list2cmdline([script, "--config", config_path, "slot", str(slot)])
        return "\n".join([
            "# Run in an elevated PowerShell as the account the pool runs under (ci-host).",
            f"$action = New-ScheduledTaskAction -Execute '{python}' -Argument '{arguments}'",
            "$trigger = New-ScheduledTaskTrigger -AtStartup",
            "$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) "
            "-ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew",
            "$password = Read-Host -AsSecureString \"Password of $env:USERNAME\"",
            "$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))",
            f"Register-ScheduledTask -TaskName '{task}' -Action $action -Trigger $trigger -Settings $settings "
            "-User $env:USERNAME -Password $plain -RunLevel Highest -Force",
            f"Start-ScheduledTask -TaskName '{task}'",
            "",
        ])


def backend_for(config: Config, now: Callable[[], float] = time.time,
                sleep: Callable[[float], None] = time.sleep):
    if config.backend == "tart":
        return TartBackend(config, now=now, sleep=sleep)
    return HyperVBackend(config, now=now, sleep=sleep)


# --------------------------------------------------------------- the slots


def vm_name(slot: int, when: float) -> str:
    return f"{VM_PREFIX}{slot}-{time.strftime('%Y%m%d%H%M%S', time.gmtime(when))}"


def slot_prefix(slot: int) -> str:
    return f"{VM_PREFIX}{slot}-"


@dataclass
class Host:
    """What a slot turn touches, injectable for tests."""
    github: GitHub
    vm: object
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
    for name in host.vm.names():
        if name.startswith(prefixes):
            host.vm.destroy(name)
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
    created = False
    try:
        host.vm.create(name)
        created = True
        jit = host.github.jit_config(name)
        host.vm.start(name)
        host.vm.wait_ready(name)
        record["runner_exit"] = host.vm.run_job(name, jit)
    except Exception as exc:
        record["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        if created:
            host.vm.destroy(name)
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
    gateway_open = probe.get("gateway_open") or []
    results.append(("isolation", "FAIL" if gateway_open else "PASS",
                    f"the host's services through the VM's gateway {probe.get('gateway') or '?'}"
                    + (f": {gateway_open} open" if gateway_open else "")))
    shared = probe.get("shared") or []
    results.append(("no host directories", "FAIL" if shared else "PASS", "; ".join(shared) or "none mounted"))
    results.append(("no credentials", "FAIL" if probe.get("secret_files") else "PASS",
                    ", ".join(probe.get("secret_files") or []) or "no key, token or runner credential files"))
    results.append(("no secret variables", "FAIL" if probe.get("secret_env") else "PASS",
                    ", ".join(probe.get("secret_env") or []) or "none"))
    missing = sorted(tool for tool, present in (probe.get("tools") or {}).items() if not present)
    results.append(("image tools", "FAIL" if missing else "PASS", f"missing {missing}" if missing else "all present"))
    results.append(("image runner", "PASS" if probe.get("runner") else "FAIL", "the Actions runner"))
    return results


def reachable_from_host(address: str, port: int) -> bool:
    try:
        socket.create_connection((address, port), timeout=4).close()
        return True
    except OSError:
        return False


def verify(config: Config, host: Host, reaches: Callable[[str, int], bool] = reachable_from_host) -> int:
    """Boot up to two VMs as the slots do and check, from inside the first,
    what a job could reach and see. Run it with the slot services stopped."""
    names = [vm_name(slot, host.now()) + "-verify" for slot in range(1, min(config.slots, 2) + 1)]
    created: List[str] = []
    try:
        for name in names:
            host.vm.create(name)
            created.append(name)
            host.vm.start(name)
        for name in names:
            host.vm.wait_ready(name)
        addresses = [host.vm.address(name) for name in names]
        gateway = host.vm.host_gateway()
        blocked = [{"host": a, "port": p, "what": "the host"} for a in host.vm.host_addresses()
                   if a not in addresses for p in host.vm.host_ports]
        if gateway:
            blocked += [{"host": gateway, "port": p, "what": "the host's router"} for p in (53, 80, 443)]
        blocked += [{"host": a, "port": p, "what": "another pool VM"} for a in addresses[1:] for p in host.vm.guest_ports]
        blocked += [{"host": h, "port": p, "what": "a private range"} for h, p in PRIVATE_SAMPLES]
        for target in blocked:
            target["host_reaches"] = reaches(target["host"], target["port"])
        targets = [{"host": "github.com", "port": 443}] + [{"host": t["host"], "port": t["port"]} for t in blocked]
        results = judge(host.vm.probe(names[0], targets), blocked)
    finally:
        for name in created:
            host.vm.destroy(name)
    for check, verdict, detail in results:
        print(f"{verdict:4}  {check}: {detail}")
    return 1 if any(verdict == "FAIL" for _, verdict, _ in results) else 0


# ------------------------------------------------------------------- check


def check(config: Config, host: Host, which: Callable[[str], Optional[str]]) -> int:
    results: List[Tuple[str, bool, str]] = []
    for tool in host.vm.tools:
        results.append((f"tool {tool}", which(tool) is not None, which(tool) or "not on PATH"))
    secrets = [("App private key", config.private_key)]
    secrets.append(("VM SSH key", config.vm_ssh_key) if config.backend == "tart"
                   else ("VM password file", config.vm_password_file))
    for label, path in secrets:
        try:
            mode = path.stat().st_mode & 0o777
            # POSIX modes only; on Windows the account's own profile protects the file.
            private = os.name == "nt" or mode & 0o077 == 0
            results.append((label, private, f"{path}" + ("" if os.name == "nt" else f" mode {mode:o}")))
        except OSError as exc:
            results.append((label, False, str(exc)))
    try:
        results.append(("golden image", host.vm.image_exists(), config.image))
    except Exception as exc:
        results.append(("golden image", False, str(exc)))
    try:
        host.github.token()
        results.append(("GitHub App token", True, f"installation {config.installation_id}"))
        runners = host.github.runners()
        results.append(("runners readable", True, f"{len(runners)} registered"))
        if not config.repository:
            stale = [r["name"] for r in runners if r.get("name") in RETIRED_RUNNERS]
            results.append(("persistent runners retired", not stale,
                            ", ".join(stale) or f"{' and '.join(RETIRED_RUNNERS)} gone"))
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


# ---------------------------------------------------------------- the CLI


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    commands.add_parser("verify")
    commands.add_parser("cleanup")
    for name in ("slot", "once", "service"):
        commands.add_parser(name).add_argument("slot", type=int)
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        if getattr(args, "slot", 1) not in range(1, config.slots + 1):
            raise PoolError(f"slot must be within 1..{config.slots}")
    except PoolError as exc:
        print(f"vm_pool: {exc}", file=sys.stderr)
        return 2
    host = Host(GitHub(config), backend_for(config))
    if args.command == "service":
        sys.stdout.write(host.vm.service(args.slot, sys.executable, str(Path(__file__).resolve()),
                                         str(Path(os.path.expanduser(args.config)))))
        return 0
    # A service stops a slot with SIGTERM: unwind so the current VM is destroyed.
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
