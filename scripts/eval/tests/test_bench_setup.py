"""`metacodes bench setup` and SSH executors, against fake tools.

Every package manager, container tool and the SSH client are fakes on PATH
that log their argv and change only files under the test's temp directory.
The fake `ssh` runs the remote command with `sh -c` in a separate "remote"
home with a clean environment, so the real remote driver, file shipping and
job sync run end to end. Nothing is installed and no provider is called.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import random
import re
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import types
import unittest
import urllib.error
import urllib.request
from functools import partial
from http.server import BaseHTTPRequestHandler, SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.command import BUNDLE_EXECUTABLES, check_bundle
from scripts.eval.harbor.bench import data, executors, remote, setup
from scripts.eval.harbor.bench import node as node_protocol
from scripts.eval.harbor.viewer import server
from scripts.eval.harbor.bench.runner import RunManager, atomic_json
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_bench_workbench import (FAKE_HARBOR, RotatingGateway, gaia2_dataset, node_script,
                                                     offline_hugging_face, session_fixture, stop_profiles_and_workers,
                                                     wait_run)

FAKES = r'''
import json, os, shutil, subprocess, sys, time
from pathlib import Path
name, args = sys.argv[1], sys.argv[2:]
env = os.environ
with open(env["FAKE_LOG"], "a") as log:
    log.write(json.dumps([name, args, env.get("FAKE_SIDE", "local")]) + "\n")
state = Path(env["FAKE_STATE"]); state.mkdir(parents=True, exist_ok=True)
install = Path(env["FAKE_INSTALL_DIR"]); install.mkdir(parents=True, exist_ok=True)
templates = Path(env["FAKE_TEMPLATES"])

def place(tool, where=install):
    Path(where).mkdir(parents=True, exist_ok=True)
    shutil.copy(templates / tool, Path(where) / tool)
    os.chmod(Path(where) / tool, 0o755)

if name == "uname":
    print(env.get("FAKE_UNAME", "Linux") if (not args or args[0] == "-s") else env.get("FAKE_ARCH", "x86_64"))
elif name == "brew":
    if args[:1] == ["install"]:
        for formula in args[1:]:
            (state / ("brew-" + formula)).touch()
            tool = {"docker": "docker", "colima": "colima", "uv": "uv"}.get(formula)
            if tool:
                place(tool)
    elif args[:1] == ["list"]:
        print("\n".join(p.name[5:] for p in state.glob("brew-*")))
    elif args[:1] == ["--prefix"]:
        print(env["FAKE_BREW_PREFIX"])
elif name == "uv":
    if args[:1] == ["--version"]:
        print("uv 0.13.9")
    elif args[:2] == ["tool", "list"]:
        if (state / "harbor").exists():
            print("harbor v0.26.0\n- harbor")
    elif args[:2] == ["tool", "install"]:
        place("harbor", Path(env["HOME"]) / ".local/bin")
        (state / "harbor").touch()
elif name == "curl":
    url = args[-1]
    if "astral.sh/uv/" in url:
        print('mkdir -p "$UV_INSTALL_DIR" && cp "%s/uv" "$UV_INSTALL_DIR/uv" && chmod 755 "$UV_INSTALL_DIR/uv"' % templates)
    elif "get.docker.com" in url:
        print('cp "%s/docker" "%s/docker" && chmod 755 "%s/docker"' % (templates, install, install))
    else:
        sys.exit(22)
elif name == "sudo":
    if env.get("FAKE_SUDO") != "1":
        sys.exit(1)
    rest = args[1:] if args[:1] == ["-n"] else args
    os.execvp(rest[0], rest)
elif name == "docker":
    if args[:1] == ["buildx"]:
        if env.get("FAKE_NO_BUILDX"):
            print("docker: 'buildx' is not a docker command.", file=sys.stderr)
            sys.exit(1)
        if args[1:2] == ["build"]:
            time.sleep(float(env.get("FAKE_BUILD_DELAY") or 0))
            if env.get("FAKE_BUILD_BREAKS"):
                os.chmod(env["FAKE_BUILD_BREAKS"], 0o644)
            images = state / "images"
            images.mkdir(exist_ok=True)
            (images / args[args.index("--tag") + 1].replace("/", "_")).touch()
            staged = Path(args[-1]) / "artifacts/share/metacodes/artifact-manifest.json"
            if staged.exists():
                (images / (args[args.index("--tag") + 1].replace("/", "_") + ".manifest")).write_bytes(staged.read_bytes())
        sys.exit(0)
    if args[:2] == ["image", "rm"]:
        time.sleep(float(env.get("FAKE_RM_DELAY") or 0))
        (state / "images" / args[2].replace("/", "_")).unlink(missing_ok=True)
        sys.exit(0)
    if args[:1] == ["info"]:
        running = (state / "colima-running").exists() or env.get("FAKE_DOCKER_DAEMON") == "1"
        if not running:
            print("Cannot connect to the Docker daemon", file=sys.stderr)
        sys.exit(0 if running else 1)
    if args[:1] == ["run"] and "uname" in args:
        print("x86_64")
    if args[:1] == ["run"] and "wget" in args:
        # A container fetching a URL (setup's egress probe): really fetched.
        import urllib.request
        request = urllib.request.Request(args[-1])
        container_env = dict(args[i + 1].split("=", 1) for i, arg in enumerate(args) if arg == "-e")
        if "http_proxy" in container_env:
            request.set_proxy(container_env["http_proxy"].split("://", 1)[-1], "http")
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response:
                sys.stdout.write(response.read().decode())
        except Exception as exc:
            print("wget: " + str(exc), file=sys.stderr)
            sys.exit(1)
    if args[:1] == ["inspect"] and env.get("FAKE_DOCKER_INSPECT"):
        print(env["FAKE_DOCKER_INSPECT"])
    if args[:1] == ["build"] and args[-1:] == ["-"]:
        (state / ("dockerfile-" + args[args.index("-t") + 1])).write_text(sys.stdin.read())
    images = state / "images"
    if args[:2] == ["image", "inspect"]:
        sys.exit(0 if (images / args[2].replace("/", "_")).exists() else 1)
    if args[:1] == ["pull"]:
        images.mkdir(exist_ok=True)
        (images / args[1].replace("/", "_")).touch()
    if args[:1] == ["tag"]:
        images.mkdir(exist_ok=True)
        (images / args[2].replace("/", "_")).touch()
elif name == "systemctl":
    pass
elif name == "colima":
    if args[:1] == ["status"]:
        sys.exit(0 if (state / "colima-running").exists() else 1)
    if args[:1] == ["start"]:
        (state / "colima-running").touch()
elif name == "ssh":
    i, reverse = 0, None
    while args[i].startswith("-"):
        if args[i] == "-R":
            reverse = args[i + 1]
        i += 2 if args[i] in ("-o", "-p", "-i", "-R") else 1
    destination, command = args[i], " ".join(args[i + 1:])
    mode = env.get("FAKE_SSH_MODE", "ok")
    if mode == "deny":
        print(destination + ": Permission denied (publickey).", file=sys.stderr)
        sys.exit(255)
    if mode == "noshell":
        sys.exit(0)
    home = env["FAKE_REMOTE_HOME"]
    remote = {"PATH": env["FAKE_REMOTE_PATH"], "HOME": home, "FAKE_SIDE": "remote",
              "FAKE_INSTALL_DIR": env["FAKE_REMOTE_BIN"], "FAKE_STATE": env["FAKE_REMOTE_STATE"],
              "FAKE_UNAME": "Linux", "FAKE_SUDO": env.get("FAKE_REMOTE_SUDO", ""),
              "FAKE_DOCKER_DAEMON": env.get("FAKE_REMOTE_DOCKER_DAEMON", "")}
    for key in ("FAKE_LOG", "FAKE_TEMPLATES", "FAKE_BENCH_DELAY", "FAKE_PROFILE_REQUEST",
                "FAKE_EXPECT_ACCOUNT_KEY", "FAKE_BREW_PREFIX", "FAKE_RELAY_REQUESTS", "FAKE_RELAY_INTERVAL",
                "FAKE_EGRESS_FETCH", "FAKE_JUDGE_REQUEST", "FAKE_NO_BUILDX", "FAKE_BUILD_DELAY",
                "FAKE_RM_DELAY", "FAKE_BUILD_BREAKS", "FAKE_DOCKER_INSPECT", "FAKE_BENCH_RELEASE_FILE",
                "FAKE_LATE_TRAFFIC"):
        if key in env:
            remote[key] = env[key]
    if " pack " in command:
        # A slow or broken copy-back of the job directory.
        if env.get("FAKE_SSH_PACK_FAIL"):
            print("pack refused", file=sys.stderr)
            sys.exit(1)
        time.sleep(float(env.get("FAKE_SSH_PACK_DELAY") or 0))
    os.chdir(home)
    drops = env.get("FAKE_SSH_DROPS")
    if drops and " node run " in command and int(Path(drops).read_text()) > 0:
        # The network fails under a run's session: the driver's stdin ends
        # and its stdout breaks while it keeps running. FAKE_SSH_DROP_SILENT:
        # none of its events got through before that.
        Path(drops).write_text(str(int(Path(drops).read_text()) - 1))
        import threading
        child = subprocess.Popen(["/bin/sh", "-c", command], env=remote, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, start_new_session=True)
        sent = threading.Event()
        def down():
            for line in sys.stdin.buffer:
                child.stdin.write(line)
                child.stdin.flush()
                sent.set()
        def up():
            for line in child.stdout:
                if not env.get("FAKE_SSH_DROP_SILENT"):
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
        threading.Thread(target=down, daemon=True).start()
        threading.Thread(target=up, daemon=True).start()
        sent.wait(30)
        time.sleep(float(env.get("FAKE_SSH_DROP_AFTER") or 2))
        child.stdin.close()
        print("client_loop: send disconnect: Broken pipe", file=sys.stderr)
        os._exit(255)
    if reverse:
        # `-R 127.0.0.1:R:127.0.0.1:L`: the "executor" is this machine, so
        # the remote end listens on loopback port R and relays to L, for the
        # life of the session (ExitOnForwardFailure: a busy port fails it).
        import socket, threading
        _, rport, _, lport = reverse.split(":")
        refusals = env.get("FAKE_REFUSED_ATTACH_FORWARDS" if " node attach " in command else "FAKE_REFUSED_FORWARDS")
        listener = socket.socket()
        try:
            if refusals and int(Path(refusals).read_text()) > 0:
                Path(refusals).write_text(str(int(Path(refusals).read_text()) - 1))
                raise OSError("the executor refuses this forward")
            listener.bind(("127.0.0.1", int(rport)))
        except OSError:
            print("Error: remote port forwarding failed for listen port " + rport, file=sys.stderr)
            sys.exit(255)
        listener.listen(16)
        def one_way(a, b):
            try:
                while True:
                    chunk = a.recv(65536)
                    if not chunk:
                        break
                    b.sendall(chunk)
            except OSError:
                pass
            try:
                b.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        def serve():
            while True:
                conn, _ = listener.accept()
                upstream = socket.create_connection(("127.0.0.1", int(lport)))
                threading.Thread(target=one_way, args=(conn, upstream), daemon=True).start()
                threading.Thread(target=one_way, args=(upstream, conn), daemon=True).start()
        threading.Thread(target=serve, daemon=True).start()
        sys.exit(subprocess.call(["/bin/sh", "-c", command], env=remote))
    os.execve("/bin/sh", ["sh", "-c", command], remote)
elif name == "sysctl":
    print(env.get("FAKE_HV_SUPPORT", "1"))
elif name == "zig":
    if args[:1] == ["version"]:
        print("0.16.0")
    elif args[:2] == ["build", "install"]:
        prefix = Path(args[args.index("--prefix") + 1])
        (prefix / "bin/metacodes").write_text("cross-compiled overlay")
elif name == "metacodes":
    print("METASK_VERIFICATION_URI=https://example.invalid/device", file=sys.stderr, flush=True)
    print("METASK_USER_CODE=ABCD-1234", file=sys.stderr, flush=True)
    print("Open https://example.invalid/device and enter the code ABCD-1234", file=sys.stderr, flush=True)
'''

# Appended to test_bench_suites.FAKE_UV: WorkBuddy's host proxy making model
# requests for a while, through whatever endpoint and key it was given.
FAKE_UV_REQUESTS = r'''
import time, urllib.error, urllib.request
statuses = []
for _ in range(int(os.environ.get('FAKE_RELAY_REQUESTS') or 0)):
    request = urllib.request.Request(os.environ[spec['backend_url_env']], data=b'{}', method='POST',
                                     headers={'Authorization': 'Bearer ' + os.environ[spec['backend_key_env']]})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
            statuses.append(response.status)
    except urllib.error.HTTPError as exc:
        statuses.append(exc.code)
    time.sleep(float(os.environ.get('FAKE_RELAY_INTERVAL') or 0))
(jobs_dir.parent / 'relay-statuses.json').write_text(json.dumps(statuses))
observed = json.loads((jobs_dir.parent / 'observed.json').read_text())
observed['key'] = os.environ.get(spec['backend_key_env'])
version = cwd / 'configs/harnesses/metacodes/versions' / (job['harness'].split('/')[1] + '.yaml')
observed['harness_version'] = version.read_text() if version.is_file() else None
(jobs_dir.parent / 'observed.json').write_text(json.dumps(observed))
'''

SIMPLE = ("uname", "brew", "uv", "curl", "sudo", "docker", "colima", "ssh", "zig", "metacodes", "sysctl",
          "systemctl")
SYSTEM_TOOLS = ("sh", "env", "mkdir", "tar", "cp", "chmod", "rm", "mv", "mktemp", "touch", "cat", "python3",
                "openssl", "grep", "sed", "ls", "id", "head", "tail", "dirname", "basename", "true", "false", "git",
                "ln", "readlink", "bash")
LOWEST_EPHEMERAL_PORT = 32768


def release_fixture(root, version="9.9.9", corrupt=False):
    """A release directory laid out like GitHub's download URLs."""
    name = f"metacodes-{version}-x86_64-linux-gnu"
    unit = root / "unit" / name
    for file in BUNDLE_EXECUTABLES:
        path = unit / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(node_script() if file == "bin/metacodes" else b"release " + file.encode())
        path.chmod(0o755)
    atomic_json(unit / "manifest.json", {"target": {"id": "x86_64-linux-gnu", "os": "linux"},
                                         "release": {"version": version}})
    download = root / "site" / "download" / version
    download.mkdir(parents=True)
    archive = download / (name + ".tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(str(unit), arcname=name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    sums = ("0" * 64 if corrupt else digest) + "  " + name + ".tar.gz\n" + "1" * 64 + "  other.tar.gz\n"
    (download / f"metacodes-{version}-SHA256SUMS").write_text(sums)
    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *_args):
            pass
    handler = partial(Quiet, directory=str(root / "site"))
    http = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    return http, digest


class NodeProtocolTest(unittest.TestCase):
    def test_a_node_from_before_run_features_is_refused(self):
        relay = executors.SshExecutor(name="relay", host="relay.invalid")
        self.assertGreaterEqual(node_protocol.PROTOCOL, 2)
        facts = {"node": {"protocol": 1, "version": "0.12.0"}}
        problem = executors.node_problem(relay, facts)
        self.assertIn("不兼容", problem)
        self.assertIn(problem, executors.reasons(relay, facts))
        self.assertIsNone(executors.node_problem(relay, {"node": {"protocol": node_protocol.PROTOCOL}}))

    def test_a_node_that_builds_workbuddy_from_its_staged_checkout_is_refused(self):
        """Such a node ignores the run's bundle and would mount whatever its
        checkout staged under the selected version's name."""
        relay = executors.SshExecutor(name="relay", host="relay.invalid")
        self.assertIn("不兼容", executors.node_problem(relay, {"node": {"protocol": 4}}))
        self.assertIn("不兼容", executors.reach_reasons(relay, {"node": {"protocol": 4}})[0])


    def test_only_network_failures_count_as_unreachable(self):
        for detail in ("ssh: connect to host 203.0.113.7 port 107: No route to host",
                       "ssh: connect to host 203.0.113.7 port 107: Operation timed out",
                       "ssh: Could not resolve hostname relay: Name or service not known",
                       "kex_exchange_identification: read: Connection reset by peer"):
            self.assertTrue(executors.unreachable({"error": "ssh", "detail": detail}), detail)
        self.assertTrue(executors.unreachable({"error": "timeout"}))
        self.assertFalse(executors.unreachable({"error": "ssh", "detail": "bench@relay: Permission denied (publickey)."}))
        self.assertFalse(executors.unreachable({"error": "noshell"}))


@unittest.skipUnless(POSIX, "fake executables are POSIX shell scripts")
class SetupFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.root = Path(self.tmp.name)
        self.templates = root / "templates"
        self.common = root / "common"
        self.local_bin = root / "local-bin"
        self.remote_bin = root / "remote-bin"
        self.home = root / "home"
        self.remote_home = root / "remote-home"
        for path in (self.templates, self.common, self.local_bin, self.remote_bin, self.home, self.remote_home):
            path.mkdir()
        fakes = root / "fakes.py"
        fakes.write_text(FAKES)
        for tool in SIMPLE:
            script = f'#!/bin/sh\nexec {sys.executable} {fakes} {tool} "$@"\n'
            (self.templates / tool).write_text(script)
            (self.templates / tool).chmod(0o755)
        (self.templates / "harbor").write_text(FAKE_HARBOR.format(python=sys.executable))
        (self.templates / "harbor").chmod(0o755)
        os.symlink(self.templates / "brew", self.local_bin / "brew")  # Homebrew is present locally
        for tool in ("uname", "curl", "sudo", "ssh", "zig", "sysctl", "systemctl"):
            os.symlink(self.templates / tool, self.common / tool)
        # Only these host tools are visible: a host's own docker, brew, ip or
        # apt-get must not change which branch a step takes.
        system_dir = root / "system"
        system_dir.mkdir()
        for tool in SYSTEM_TOOLS:
            found = shutil.which(tool)
            if found:
                os.symlink(found, system_dir / tool)
        # The remote driver runs on this interpreter (a venv's python cannot
        # be symlinked elsewhere).
        (system_dir / "python3").unlink(missing_ok=True)
        (system_dir / "python3").write_text(f'#!/bin/sh\nexec {sys.executable} "$@"\n')
        (system_dir / "python3").chmod(0o755)
        system = str(system_dir)
        self.log = root / "fake.log"
        self.env = {
            "PATH": f"{self.local_bin}:{self.common}:{system}", "HOME": str(self.home),
            "METACODES_BENCH_EXTRA_PATH": "$HOME/.local/bin", "FAKE_LOG": str(self.log),
            "FAKE_STATE": str(root / "state-local"), "FAKE_INSTALL_DIR": str(self.local_bin),
            "FAKE_TEMPLATES": str(self.templates), "FAKE_UNAME": "Darwin", "FAKE_ARCH": "arm64",
            "FAKE_BREW_PREFIX": str(root / "brew"), "FAKE_REMOTE_HOME": str(self.remote_home),
            "FAKE_REMOTE_BIN": str(self.remote_bin), "FAKE_REMOTE_STATE": str(root / "state-remote"),
            "FAKE_REMOTE_PATH": f"{self.remote_bin}:{self.common}:{system}",
            "METACODES_BENCH_ROSETTA_DIR": str(root),
            "TOKENJOY_API_KEY": "private-test-value", "METACODES_RELEASE_BASE": "",
        }
        patcher = patch.dict(os.environ, self.env)
        patcher.start()
        self.addCleanup(patcher.stop)
        offline_hugging_face(self)
        self.release, self.release_digest = release_fixture(root / "release")
        self.addCleanup(self.release.server_close)
        self.addCleanup(self.release.shutdown)
        os.environ["METACODES_RELEASE_BASE"] = f"http://127.0.0.1:{self.release.server_port}"
        # The network step never leaves this machine: every target answers
        # (the release server), unless a test says otherwise. daemon.json
        # is a file of the fixture.
        self.reachable = f"http://127.0.0.1:{self.release.server_port}/"
        self.daemon_json = root / "etc-docker" / "daemon.json"
        for patcher in (patch.object(setup, "NETWORK_TARGETS", {k: self.reachable for k in setup.NETWORK_TARGETS}),
                        patch.object(setup, "NETWORK_TIMEOUT", 2), patch.object(setup, "DAEMON_JSON", str(self.daemon_json))):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.state = root / "bench-state"
        self.config = self.state / "bench" / "workbench.json"
        native = root / "provider.json"
        atomic_json(native, {"custom_providers": {"tokenjoy": {
            "channels": [{"id": "default", "protocol": "openai_chat", "base_url": "https://tokenjoy.invalid/v1"}],
            "models": [{"request_model_id": "test-model"}]}}})
        atomic_json(self.config, {"auth_mode": "provider", "provider_config": str(native), "model": "tokenjoy/test-model",
                                  "key_env": "TOKENJOY_API_KEY", "jobs_dir": str(self.state / "bench/jobs"),
                                  "metacodes": {"binary": str(self.templates / "metacodes"), "version": "9.9.9"},
                                  "model_prices": "off"})

    def calls(self, tool=None, side=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [r for r in rows if (tool is None or r[0] == tool) and (side is None or r[2] == side)]

    def cfg(self):
        return json.loads(self.config.read_text())

    def add_ssh_executor(self, node=True, **extra):
        """`node`: the executor already has its metacodes node (as setup leaves it)."""
        cfg = self.cfg()
        cfg["executors"] = [{"name": "devbox-mac", "kind": "local"},
                            {"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1", "user": "bench", **extra}]
        atomic_json(self.config, cfg)
        if node:
            path = self.remote_home / (extra.get("state_dir") or ".metacodes-bench") / "bin" / "metacodes"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(node_script())
            path.chmod(0o755)

    def step(self, progress, step_id):
        return next(s for s in progress["steps"] if s["id"] == step_id)

    def mutations(self, progress):
        return [c["command"] for s in progress["steps"] for c in s["commands"] if c["mutates"]]


class LocalSetupTest(SetupFixture):
    def test_dry_run_lists_exact_commands_and_changes_nothing(self):
        before = self.config.read_bytes()
        progress = setup.run_setup(self.config, dry_run=True)
        planned = self.mutations(progress)
        self.assertIn("brew install uv", planned)
        self.assertTrue(any(c.endswith("uv tool install --force --python 3.12 harbor==0.26.0'") for c in planned), planned)
        self.assertIn("brew install docker docker-compose docker-buildx colima", planned)
        start = next(c for c in planned if c.startswith("colima start"))
        for flag in ("--vm-type vz", "--vz-rosetta", "--arch aarch64", "--runtime docker", "--mount " + str(self.home.resolve()) + ":w"):
            self.assertIn(flag, start)
        self.assertIn("docker run --rm --platform linux/amd64 alpine:3.20 uname -m", planned)
        self.assertTrue(any("metacodes-9.9.9-SHA256SUMS" in c for c in planned))
        self.assertEqual(self.config.read_bytes(), before)
        self.assertEqual(self.calls("brew", "local") and [c for c in self.calls("brew") if c[1][:1] == ["install"]], [])
        self.assertEqual(self.calls("colima") and [c for c in self.calls("colima") if c[1][:1] == ["start"]], [])
        self.assertEqual(progress["status"], "planned")
        self.assertFalse((self.state / "bench/bundles/metacodes-9.9.9-x86_64-linux-gnu").exists())

    def test_setup_installs_verifies_and_makes_readiness_pass(self):
        catalog = RunManager(self.state / "bench/jobs", self.config).catalog()
        self.assertFalse(catalog["ready"])
        self.assertTrue(any("未找到 Harbor" in r for r in catalog["reasons"]))
        progress = setup.run_setup(self.config)
        self.assertEqual(progress["status"], "ready", json.dumps(progress, ensure_ascii=False, indent=1))
        brew = [c[1] for c in self.calls("brew") if c[1][:1] == ["install"]]
        self.assertEqual(brew, [["install", "uv"], ["install", "docker", "docker-compose", "docker-buildx", "colima"]])
        self.assertEqual([c[1][:2] for c in self.calls("uv") if c[1][:2] == ["tool", "install"]], [["tool", "install"]])
        self.assertIn(["tool", "install", "--force", "--python", "3.12", "harbor==0.26.0"], [c[1] for c in self.calls("uv")])
        start = next(c[1] for c in self.calls("colima") if c[1][:1] == ["start"])
        self.assertEqual(start[start.index("--vm-type") + 1], "vz")
        self.assertIn(["run", "--rm", "--platform", "linux/amd64", "alpine:3.20", "uname", "-m"], [c[1] for c in self.calls("docker")])
        cfg = self.cfg()
        self.assertEqual(cfg["harbor"], str(self.home / ".local/bin/harbor"))
        bundle = Path(cfg["bundle"])
        self.assertEqual(bundle, self.state / "bench/bundles/metacodes-9.9.9-x86_64-linux-gnu")
        self.assertEqual(check_bundle(bundle)["target"]["id"], "x86_64-linux-gnu")
        self.assertTrue(os.access(bundle / "bin/metacodes", os.X_OK))
        self.assertEqual(cfg["bundle_source"]["sha256"], self.release_digest)
        self.assertEqual((cfg["metrics_bind"], cfg["metrics_host"]), ("127.0.0.1", "192.168.5.2"))
        docker_config = json.loads((self.home / ".docker/config.json").read_text())
        self.assertEqual(docker_config["cliPluginsExtraDirs"], [str(self.root / "brew") + "/lib/docker/cli-plugins"])
        self.assertNotIn("private-test-value", self.config.read_text() + json.dumps(progress))
        catalog = RunManager(self.state / "bench/jobs", self.config).catalog()
        self.assertTrue(catalog["ready"], catalog["reasons"])
        self.assertEqual(catalog["executors"][0]["name"], "local")
        # Idempotent: a second run only checks.
        installs = len(self.calls("brew"))
        again = setup.run_setup(self.config)
        self.assertEqual({s["status"] for s in again["steps"]} - {"skipped"}, {"ok"})
        self.assertEqual([c for c in self.calls("brew")[installs:] if c[1][:1] == ["install"]], [])

    def test_checksum_mismatch_refuses_the_bundle(self):
        self.release.shutdown()
        self.release, _ = release_fixture(self.root / "corrupt", corrupt=True)
        self.addCleanup(self.release.server_close)
        self.addCleanup(self.release.shutdown)
        os.environ["METACODES_RELEASE_BASE"] = f"http://127.0.0.1:{self.release.server_port}"
        progress = setup.run_setup(self.config)
        bundle = self.step(progress, "bundle")
        self.assertEqual(bundle["status"], "failed")
        self.assertIn("SHA-256", bundle["detail"])
        self.assertNotIn("bundle", self.cfg())
        self.assertEqual(list((self.state / "bench/bundles").iterdir()), [])

    def test_development_binary_cross_compiles_on_the_verified_release(self):
        checkout = self.root / "checkout"
        (checkout / "scripts").mkdir(parents=True)
        (checkout / "build.zig").write_text("")
        (checkout / "build.zig.zon").write_text('.{ .minimum_zig_version = "0.16.0" }')
        (checkout / "scripts/bench_assets.zig").write_text("")
        cfg = self.cfg()
        cfg["metacodes"]["version"] = "9.9.10-dev"
        atomic_json(self.config, cfg)
        progress = setup.run_setup(self.config, options={"source": str(checkout), "base_release": "9.9.9"})
        self.assertEqual(self.step(progress, "bundle")["status"], "done", self.step(progress, "bundle"))
        build = next(c[1] for c in self.calls("zig") if c[1][:2] == ["build", "install"])
        self.assertIn("-Dtarget=x86_64-linux-gnu.2.31", build)
        kernel = hashlib.sha256(b"release libexec/metacodes/metacodes-formal-kernel").hexdigest()
        self.assertIn("-Dformal-kernel-sha256=" + kernel, build)
        bundle = Path(self.cfg()["bundle"])
        self.assertTrue(bundle.name.startswith("metacodes-dev-") and bundle.name.endswith("-x86_64-linux-gnu"))
        self.assertEqual((bundle / "bin/metacodes").read_text(), "cross-compiled overlay")
        self.assertEqual(self.cfg()["bundle_source"]["base_release"], "9.9.9")

    def test_mac_vm_without_nested_virtualization_fails_before_installing(self):
        os.environ["FAKE_HV_SUPPORT"] = "0"
        progress = setup.run_setup(self.config)
        docker = self.step(progress, "docker")
        self.assertEqual(docker["status"], "failed")
        self.assertIn("kern.hv_support=0", docker["detail"])
        self.assertIn("SSH 执行机器", docker["detail"])
        self.assertNotIn(["install", "docker", "docker-compose", "docker-buildx", "colima"],
                         [c[1] for c in self.calls("brew")])
        self.assertEqual(self.calls("colima"), [])

    def test_linux_without_sudo_reports_the_root_command(self):
        os.environ["FAKE_UNAME"] = "Linux"
        progress = setup.run_setup(self.config)
        docker = self.step(progress, "docker")
        self.assertEqual(docker["status"], "manual")
        self.assertEqual(docker["command"], "curl -fsSL https://get.docker.com | sh")
        self.assertEqual(self.calls("docker"), [])
        uv = self.step(progress, "uv")
        self.assertEqual(uv["status"], "done")
        self.assertTrue(any("astral.sh/uv/0.13.9/install.sh" in c for c in self.mutations(progress)))
        self.assertTrue((self.home / ".local/bin/uv").exists())

    def test_linux_with_passwordless_sudo_installs_docker(self):
        os.environ.update(FAKE_UNAME="Linux", FAKE_SUDO="1", FAKE_DOCKER_DAEMON="1")
        progress = setup.run_setup(self.config)
        self.assertEqual(self.step(progress, "docker")["status"], "done", self.step(progress, "docker"))
        self.assertIn(["-n", "sh", "-c", "curl -fsSL https://get.docker.com | sh"], [c[1] for c in self.calls("sudo")])
        self.assertTrue((self.local_bin / "docker").exists())

    def test_postgres_store_adds_psycopg_and_login_points_to_the_user(self):
        cfg = self.cfg()
        cfg.update(store={"backend": "postgres"}, auth_mode="metask", account_state_dir=str(self.root / "nobody"))
        atomic_json(self.config, cfg)
        progress = setup.run_setup(self.config, dry_run=True)
        psycopg = self.step(progress, "psycopg")
        if psycopg["status"] == "planned":
            self.assertIn(f"{sys.executable} -m pip install --user '{setup.PSYCOPG}'", self.mutations(progress))
        else:
            self.assertEqual(psycopg["status"], "ok")
        login = self.step(progress, "login")
        self.assertEqual(login["status"], "manual")
        self.assertEqual(login["command"], f"{self.templates / 'metacodes'} --state-dir {self.root / 'nobody'} login")
        cfg.pop("store")
        atomic_json(self.config, cfg)
        self.assertEqual(self.step(setup.run_setup(self.config, dry_run=True), "psycopg")["status"], "skipped")

    def test_cli_setup_json(self):
        out = io.StringIO()
        with patch("sys.stdout", out), patch("sys.stderr", io.StringIO()):
            code = cli.main(["--state-root", str(self.state), "setup", "--dry-run", "--json",
                             "--metacodes-version", "9.9.9", "--metacodes-binary", "/opt/metacodes/bin/metacodes"])
        progress = json.loads(out.getvalue())
        self.assertEqual((code, progress["dry_run"], progress["status"]), (0, True, "planned"))
        self.assertEqual(self.cfg()["metacodes"], {"binary": "/opt/metacodes/bin/metacodes", "version": "9.9.9"})


class ExecutorConfigTest(unittest.TestCase):
    def test_mac_vm_without_hypervisor_names_the_ssh_executor_remedy(self):
        def runner(argv, **_kwargs):
            out = "0\n" if argv[0].endswith("sysctl") else ""
            return subprocess.CompletedProcess(argv, 0 if argv[0].endswith("sysctl") else 1, out, "Cannot connect")
        with patch.object(executors.os, "uname", create=True,
                          return_value=types.SimpleNamespace(sysname="Darwin", machine="arm64")), \
                patch.object(executors.shutil, "which", side_effect=lambda name, path=None: "/opt/homebrew/bin/" + name):
            facts = executors.local_facts(executors.LocalExecutor(), runner=runner)
        self.assertEqual(facts["hypervisor"], "0")
        found = executors.reasons(executors.LocalExecutor(), facts)
        self.assertTrue(any("没有嵌套虚拟化" in r and "SSH 执行机器" in r for r in found), found)
        self.assertFalse(any("一键配置" in r and "Docker" in r for r in found), found)
        facts.pop("hypervisor")
        self.assertTrue(any("Docker daemon" in r for r in executors.reasons(executors.LocalExecutor(), facts)))

    def test_entries_are_validated_before_any_ssh_argv(self):
        bad = [{"name": "x", "kind": "ssh", "host": "-oProxyCommand=sh"},
               {"name": "x", "kind": "ssh", "host": "h", "port": 0},
               {"name": "x", "kind": "ssh", "host": "h", "user": "a b"},
               {"name": "x", "kind": "ssh", "host": "h", "state_dir": "../etc"},
               {"name": "x", "kind": "ssh", "host": "h", "password": "never"},
               {"name": "x", "kind": "docker"}]
        for entry in bad:
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                executors.parse(entry)
        relay = executors.parse({"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1", "user": "bench",
                                 "port": 2222, "identity_file": "/keys/bench"})
        argv = executors.ssh_argv(relay, ["test", "-f", "a b"])
        self.assertEqual(argv[-2:], ["bench@10.126.126.1", "test -f 'a b'"])
        self.assertIn("BatchMode=yes", argv)
        self.assertEqual(argv[argv.index("-p") + 1], "2222")
        self.assertEqual(argv[argv.index("-i") + 1], "/keys/bench")
        self.assertEqual(executors.configured({})[0][0].name, "local")


    def test_container_mirrors_are_validated_and_become_the_compose_overlay(self):
        base = {"name": "relay", "kind": "ssh", "host": "h"}
        for bad in ({"apt": "https://mirrors.aliyun.com"}, {"docker": "https://docker.m.daocloud.io"},
                    {"pypi": "file:///simple"}, ["pypi"], {"pypi": "https://gh-proxy.com/https://pypi.org/simple"},
                    {"github": "https://gh-proxy.com/https://github.com; rm -rf /"},
                    {"github": "https://gh-proxy.com/ftp://github.com"}, {"hf": "hf-mirror.com"}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                executors.parse({**base, "container_mirrors": bad})
        with self.assertRaises(ValueError):
            executors.parse({**base, "egress": "workbench", "container_mirrors": {"apt": "http://mirrors.aliyun.com"}})
        self.assertIsNone(executors.parse(base).compose_overlay())
        mirrors = {"pypi": "https://mirrors.aliyun.com/pypi/simple/", "conda": "https://mirrors.tuna.tsinghua.edu.cn/anaconda/",
                   "go": "https://goproxy.cn", "rustup": "https://rsproxy.cn", "npm": "https://registry.npmmirror.com",
                   "github": "https://gh-proxy.com/https://github.com/", "hf": "https://hf-mirror.com"}
        relay = executors.parse({**base, "egress": "workbench", "container_mirrors": mirrors})
        self.assertEqual(executors.parse(relay.spec()), relay)
        self.assertEqual(relay.compose_overlay(), {"services": {"main": {"environment": {
            "PIP_INDEX_URL": "https://mirrors.aliyun.com/pypi/simple/",
            "UV_DEFAULT_INDEX": "https://mirrors.aliyun.com/pypi/simple/",
            "CONDA_CHANNEL_ALIAS": "https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud",
            "CONDA_DEFAULT_CHANNELS": "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main,"
                                      "https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r",
            "GOPROXY": "https://goproxy.cn,direct",
            "RUSTUP_DIST_SERVER": "https://rsproxy.cn", "RUSTUP_UPDATE_ROOT": "https://rsproxy.cn/rustup",
            "NPM_CONFIG_REGISTRY": "https://registry.npmmirror.com",
            "UV_INSTALLER_GITHUB_BASE_URL": "https://gh-proxy.com/https://github.com",
            "UV_PYTHON_INSTALL_MIRROR": "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone"
                                        "/releases/download",
            "HF_ENDPOINT": "https://hf-mirror.com"}}}})

    def test_mirror_settings_a_task_sets_itself_are_left_out(self):
        relay = executors.parse({"name": "relay", "kind": "ssh", "host": "h", "container_mirrors": {
            "apt": "http://mirrors.aliyun.com", "pypi": "https://mirrors.aliyun.com/pypi/simple/",
            "go": "https://goproxy.cn", "github": "https://github.example", "hf": "https://hf-mirror.com"}})
        mirrors = dict(relay.container_mirrors)
        with tempfile.TemporaryDirectory() as tmp:
            dataset = Path(tmp)
            (dataset / "offline-go/environment").mkdir(parents=True)
            (dataset / "offline-go/environment/docker-compose.yaml").write_text(
                "services:\n  main:\n    environment:\n      - GOPROXY=off\n")
            (dataset / "apt-proxy/environment").mkdir(parents=True)
            (dataset / "apt-proxy/environment/Dockerfile").write_text(
                "FROM debian\nRUN echo 'Acquire::http::Proxy \"http://proxy\";' > /etc/apt/apt.conf.d/01p\n")
            (dataset / "plain/tests").mkdir(parents=True)
            (dataset / "plain/tests/test.sh").write_text("export PIP_INDEX_URL=https://example.invalid\n")
            (dataset / "own-hub").mkdir()
            (dataset / "own-hub/task.toml").write_text('[environment.env]\nHF_ENDPOINT = "https://hub.internal"\n')
            (dataset / "own-python/environment").mkdir(parents=True)
            (dataset / "own-python/environment/Dockerfile").write_text(
                "FROM debian\nENV UV_PYTHON_INSTALL_MIRROR=https://python.internal\n")
            owned = executors.task_owned_settings(dataset, mirrors)
        self.assertEqual(owned, ["Acquire::http::Proxy", "GOPROXY", "HF_ENDPOINT", "UV_PYTHON_INSTALL_MIRROR"])
        self.assertEqual(relay.compose_overlay(owned), {"services": {"main": {"environment": {
            "PIP_INDEX_URL": "https://mirrors.aliyun.com/pypi/simple/",
            "UV_DEFAULT_INDEX": "https://mirrors.aliyun.com/pypi/simple/",
            "UV_INSTALLER_GITHUB_BASE_URL": "https://github.example"}}}})
        self.assertIsNone(relay.compose_overlay(owned + ["PIP_INDEX_URL", "UV_DEFAULT_INDEX",
                                                         "UV_INSTALLER_GITHUB_BASE_URL"]))

    def test_download_cache_points_the_kinds_it_routes_at_the_cache(self):
        base = {"name": "relay", "kind": "ssh", "host": "h"}
        mirrors = {"apt": "http://mirrors.aliyun.com", "pypi": "https://pypi.tuna.tsinghua.edu.cn/simple",
                   "conda": "https://mirrors.tuna.tsinghua.edu.cn/anaconda/", "go": "https://goproxy.cn",
                   "rustup": "https://rsproxy.cn", "npm": "https://registry.npmmirror.com",
                   "github": "https://gh-proxy.com/https://github.com", "hf": "https://hf-mirror.com"}
        with self.assertRaises(ValueError):
            executors.parse({**base, "download_cache": "yes"})
        with self.assertRaises(ValueError):
            executors.parse({**base, "egress": "workbench", "download_cache": True})
        plain = executors.parse({**base, "container_mirrors": mirrors})
        self.assertEqual((plain.download_cache, plain.download_cache_routes()), (False, {}))
        self.assertEqual(plain.compose_overlay(cached=executors.DOWNLOAD_CACHE_KINDS), plain.compose_overlay())
        relay = executors.parse({**base, "container_mirrors": mirrors, "download_cache": True})
        self.assertEqual(executors.parse(relay.spec()), relay)
        self.assertEqual(relay.download_cache_routes(), {
            "pypi": "https://pypi.tuna.tsinghua.edu.cn", "conda": "https://mirrors.tuna.tsinghua.edu.cn/anaconda",
            "go": "https://goproxy.cn", "rustup": "https://rsproxy.cn", "npm": "https://registry.npmmirror.com",
            "github": "https://gh-proxy.com/https://github.com"})
        cache = "http://172.17.0.1:3143"
        every = executors.DOWNLOAD_CACHE_KINDS
        self.assertEqual(relay.compose_overlay(cached=every)["services"]["main"]["environment"], {
            "PIP_TRUSTED_HOST": "172.17.0.1",
            "PIP_INDEX_URL": cache + "/pypi/simple/", "UV_DEFAULT_INDEX": cache + "/pypi/simple/",
            "CONDA_CHANNEL_ALIAS": cache + "/conda/cloud",
            "CONDA_DEFAULT_CHANNELS": cache + "/conda/pkgs/main," + cache + "/conda/pkgs/r",
            "GOPROXY": cache + "/go,direct",
            "RUSTUP_DIST_SERVER": cache + "/rustup", "RUSTUP_UPDATE_ROOT": cache + "/rustup/rustup",
            "NPM_CONFIG_REGISTRY": cache + "/npm/",
            "UV_INSTALLER_GITHUB_BASE_URL": cache + "/github",
            "UV_PYTHON_INSTALL_MIRROR": cache + "/github/astral-sh/python-build-standalone/releases/download",
            "HF_ENDPOINT": "https://hf-mirror.com"})
        self.assertIn("configs", relay.compose_overlay(cached=every))
        some = relay.compose_overlay(cached=["go", "github"])["services"]["main"]["environment"]
        self.assertEqual((some["GOPROXY"], some["UV_INSTALLER_GITHUB_BASE_URL"], some["NPM_CONFIG_REGISTRY"],
                          some["PIP_INDEX_URL"], "PIP_TRUSTED_HOST" in some),
                         (cache + "/go,direct", cache + "/github", "https://registry.npmmirror.com",
                          "https://pypi.tuna.tsinghua.edu.cn/simple", False))
        direct = relay.compose_overlay()["services"]["main"]["environment"]
        self.assertEqual((direct["PIP_INDEX_URL"], direct["NPM_CONFIG_REGISTRY"], "PIP_TRUSTED_HOST" in direct),
                         ("https://pypi.tuna.tsinghua.edu.cn/simple", "https://registry.npmmirror.com", False))
        own_index = relay.compose_overlay(["PIP_INDEX_URL"], cached=every)["services"]["main"]["environment"]
        self.assertEqual(("PIP_TRUSTED_HOST" in own_index, own_index["UV_DEFAULT_INDEX"]), (False, cache + "/pypi/simple/"))
        unrouted = executors.parse({**base, "download_cache": True, "container_mirrors": {
            "pypi": "https://pypi.example/root/pypi/+simple/", "hf": "https://hf-mirror.com",
            "apt": "http://mirrors.aliyun.com"}})
        self.assertEqual(unrouted.download_cache_routes(), {})
        self.assertEqual(unrouted.compose_overlay(cached=every)["services"]["main"]["environment"], {
            "PIP_INDEX_URL": "https://pypi.example/root/pypi/+simple/",
            "UV_DEFAULT_INDEX": "https://pypi.example/root/pypi/+simple/", "HF_ENDPOINT": "https://hf-mirror.com"})
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "own-trust").mkdir()
            (Path(tmp) / "own-trust/task.toml").write_text('[verifier.env]\nPIP_TRUSTED_HOST = "pypi.internal"\n')
            self.assertEqual(executors.task_owned_settings(Path(tmp), dict(relay.container_mirrors)), ["PIP_TRUSTED_HOST"])

    def test_apt_is_left_out_of_a_run_whose_apt_cache_does_not_answer(self):
        relay = executors.parse({"name": "relay", "kind": "ssh", "host": "h", "container_mirrors": {
            "apt": "http://mirrors.aliyun.com", "go": "https://goproxy.cn"}})
        for code, apt in ((0, True), (1, False)):
            probes, logged = [], []

            def runner(argv, **_kwargs):
                probes.append(argv)
                return subprocess.CompletedProcess(argv, code, "", "")
            run = executors.RemoteRun({"name": "r", "executor": relay.spec()}, runner=runner, log=logged.append)
            overlay = run.mirror_overlay(None)
            with self.subTest(code=code):
                self.assertEqual(len(probes), 1)
                self.assertIn("http://172.17.0.1:3142/acng-report.html", probes[0][-1])
                self.assertEqual("configs" in overlay, apt)
                self.assertEqual(overlay["services"]["main"]["environment"], {"GOPROXY": "https://goproxy.cn,direct"})
                self.assertEqual(any("没有响应" in line for line in logged), not apt)


class ExecutorEntryTest(SetupFixture):
    def test_harbor_path_with_space_and_at_parses_and_a_bad_entry_spares_the_others(self):
        relay = executors.parse({"name": "relay", "kind": "ssh", "host": "h",
                                 "harbor": "/home/a b@corp/.local/bin/harbor", "python": "/opt/py 3/bin/python3"})
        self.assertEqual(relay.harbor, "/home/a b@corp/.local/bin/harbor")
        self.assertIn("'/home/a b@corp/.local/bin/harbor'", executors.probe_script(relay))
        for bad in ("/home/$(id)/harbor", "-oProxyCommand=x", "../harbor", "/home/x'y/harbor", " /lead"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                executors.parse({"name": "relay", "kind": "ssh", "host": "h", "harbor": bad})
        cfg = self.cfg()
        cfg["executors"] = [{"name": "devbox-mac", "kind": "local"},
                            {"name": "broken", "kind": "ssh", "host": "h", "harbor": "/x/$(id)"},
                            {"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1", "user": "bench"}]
        atomic_json(self.config, cfg)
        invalid = []
        found, default = executors.configured(cfg, invalid)
        self.assertEqual(([e.name for e in found], default), (["devbox-mac", "relay-4090"], "devbox-mac"))
        self.assertEqual([name for name, _ in invalid], ["broken"])
        self.assertEqual(executors.find(cfg, "relay-4090").host, "10.126.126.1")
        states = {s["name"]: s for s in RunManager(self.state / "bench/jobs", self.config).catalog()["executors"]}
        self.assertEqual(sorted(states), ["broken", "devbox-mac", "relay-4090"])
        self.assertFalse(states["broken"]["ready"])
        self.assertIn("harbor", states["broken"]["reasons"][0])
        self.assertEqual(states["relay-4090"]["label"], "relay-4090（SSH bench@10.126.126.1:22）")

    def test_setup_never_writes_a_harbor_path_the_executor_list_would_refuse(self):
        self.add_ssh_executor()
        written = []
        stub = types.SimpleNamespace(remote=True, set_executor_value=lambda key, value: written.append((key, value)))
        setup.record_harbor(stub, "/home/a b@corp/.local/bin/harbor")
        self.assertEqual(written, [("harbor", "/home/a b@corp/.local/bin/harbor")])
        with self.assertRaisesRegex(setup.Failed, "harbor"):
            setup.record_harbor(stub, "/home/we$ird/.local/bin/harbor")
        self.assertEqual(len(written), 1)
        # Through the real step: the remote Harbor lives under a home with
        # a space and `@`; the saved entry still parses.
        home = self.root / "remote home@corp"
        self.remote_home.rename(home)
        os.environ["FAKE_REMOTE_HOME"] = str(home)
        self.remote_home = home
        (home / ".local/bin").mkdir(parents=True)
        harbor = home / ".local/bin/harbor"
        harbor.write_text('#!/bin/sh\necho "harbor 0.26.0"\n')
        harbor.chmod(0o755)
        os.symlink(self.templates / "uv", self.remote_bin / "uv")
        (self.root / "state-remote").mkdir(exist_ok=True)
        (self.root / "state-remote" / "harbor").touch()
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "harbor")
        self.assertEqual(step["status"], "ok", step)
        entry = next(e for e in self.cfg()["executors"] if e["name"] == "relay-4090")
        self.assertEqual(entry["harbor"], str(harbor))
        self.assertEqual(executors.find(self.cfg(), "relay-4090").harbor, str(harbor))


class SshExecutorTest(SetupFixture):
    def test_readiness_names_missing_ssh_shell_access(self):
        self.add_ssh_executor()
        manager = RunManager(self.state / "bench/jobs", self.config)
        for mode, text in (("deny", "无法通过 SSH 登录 relay-4090"), ("noshell", "不能执行远程命令")):
            with self.subTest(mode=mode), patch.dict(os.environ, {"FAKE_SSH_MODE": mode}):
                manager.probe_cache.clear()
                relay = next(e for e in manager.catalog()["executors"] if e["name"] == "relay-4090")
                self.assertFalse(relay["ready"])
                self.assertIn(text, relay["reasons"][0])
        with patch.dict(os.environ, {"FAKE_SSH_MODE": "deny"}):
            progress = setup.run_setup(self.config, "relay-4090")
        ssh = self.step(progress, "ssh")
        self.assertEqual((ssh["status"], ssh["command"]), ("manual", "ssh -p 22 bench@10.126.126.1 true"))
        for step_id in ("python", "uv", "harbor", "docker", "openssl", "node"):
            self.assertEqual(self.step(progress, step_id)["status"], "skipped")
        self.assertEqual(self.step(progress, "bundle")["status"], "done")

    def test_remote_setup_installs_the_node_over_ssh_and_ships_the_bundle_once(self):
        self.add_ssh_executor(node=False)
        os.environ.update(FAKE_REMOTE_SUDO="1", FAKE_REMOTE_DOCKER_DAEMON="1")
        # The workbench machine's own Harbor (registry suites are downloaded
        # here) is installed with this machine's uv.
        os.symlink(self.templates / "uv", self.local_bin / "uv")
        progress = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(progress["status"], "ready", json.dumps(progress, ensure_ascii=False, indent=1))
        ssh_commands = [c[1][-1] for c in self.calls("ssh")]
        self.assertTrue(all(c[1][c[1].index("-p") + 1] == "22" and "bench@10.126.126.1" in c[1] for c in self.calls("ssh")))
        self.assertTrue(any("astral.sh/uv/0.13.9/install.sh" in c and "UV_INSTALL_DIR" in c for c in ssh_commands))
        self.assertTrue(any("uv tool install --force --python 3.12 harbor==0.26.0" in c for c in ssh_commands))
        self.assertIn(["-n", "sh", "-c", "curl -fsSL https://get.docker.com | sh"],
                      [c[1] for c in self.calls("sudo", "remote")])
        self.assertEqual([c for c in self.calls() if c[0] in ("brew", "colima")], [])
        relay = next(e for e in self.cfg()["executors"] if e["name"] == "relay-4090")
        self.assertEqual(relay["harbor"], str(self.remote_home / ".local/bin/harbor"))
        bundles = list((self.remote_home / ".metacodes-bench/bundles").iterdir())
        self.assertFalse((self.remote_home / ".metacodes-bench/runtime").exists())
        self.assertTrue(os.access(bundles[0] / "bin/metacodes", os.X_OK))
        # The executor's own metacodes, also on its PATH, answers as a node
        # and remembers the workbench that asked.
        node = self.remote_home / ".metacodes-bench/bin/metacodes"
        self.assertEqual(node.resolve(), (bundles[0] / "bin/metacodes").resolve())
        self.assertEqual(Path(os.readlink(self.remote_home / ".local/bin/metacodes")).resolve(), node.resolve())
        self.assertIn("metacodes 9.9.9 节点", self.step(progress, "node")["detail"])
        peers = json.loads((self.remote_home / ".metacodes/bench/peers.json").read_text())
        self.assertEqual(list(peers), [executors.workbench_name()])
        catalog = RunManager(self.state / "bench/jobs", self.config).catalog()
        relay_state = next(e for e in catalog["executors"] if e["name"] == "relay-4090")
        self.assertTrue(relay_state["ready"], relay_state["reasons"])
        shipped = len([c for c in self.calls("ssh") if "tar -xf -" in c[1][-1]])
        setup.run_setup(self.config, "relay-4090")
        self.assertEqual(len([c for c in self.calls("ssh") if "tar -xf -" in c[1][-1]]), shipped)


    def test_a_failed_node_upgrade_keeps_the_installed_node(self):
        self.add_ssh_executor(node=False)
        os.environ.update(FAKE_REMOTE_SUDO="1", FAKE_REMOTE_DOCKER_DAEMON="1")
        os.symlink(self.templates / "uv", self.local_bin / "uv")
        self.assertEqual(setup.run_setup(self.config, "relay-4090")["status"], "ready")
        node = self.remote_home / ".metacodes-bench/bin/metacodes"
        installed = node.resolve()
        # A candidate bundle whose metacodes speaks another protocol.
        candidate = self.root / "candidate-bundle"
        shutil.copytree(self.cfg()["bundle"], candidate)
        (candidate / "bin/metacodes").write_text('#!/bin/sh\necho \'{"protocol": 17, "version": "x", "host": "h"}\'\n')
        cfg = self.cfg()
        cfg["bundle"] = str(candidate)
        atomic_json(self.config, cfg)
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "node")
        self.assertEqual(step["status"], "failed", step)
        self.assertIn("原有节点保持不变", step["detail"])
        self.assertEqual(node.resolve(), installed)
        relay = executors.find(self.cfg(), "relay-4090")
        info = subprocess.run(executors.node_argv(relay, "info", "--json"), capture_output=True, text=True)
        self.assertEqual(json.loads(info.stdout)["protocol"], node_protocol.PROTOCOL, info.stderr)

    def test_a_run_keeps_its_node_when_setup_switches_the_entry(self):
        self.add_ssh_executor(node=False)
        entry = self.remote_home / ".metacodes-bench/bin/metacodes"
        started = self.remote_home / ".metacodes-bench/bundles/old/bin/metacodes"
        upgraded = self.remote_home / ".metacodes-bench/bundles/new/bin/metacodes"
        for binary, script in ((started, node_script()), (upgraded, b"#!/bin/sh\nexit 3\n")):
            binary.parent.mkdir(parents=True)
            binary.write_bytes(script)
            binary.chmod(0o755)
        entry.parent.mkdir(parents=True)
        entry.symlink_to(started)
        relay = executors.find(self.cfg(), "relay-4090")
        run = executors.RemoteRun({"name": "pinned", "executor": relay.spec(), "jobs_dir": str(self.root / "jobs")},
                                  log=lambda _t: None)
        run.node = executors.resolve_node(relay)
        self.assertEqual(Path(run.node), started.resolve())
        entry.unlink()
        entry.symlink_to(upgraded)
        self.assertEqual(run.job_sync().manifest(), {})
        self.assertIn(run.node, executors.node_argv(relay, "run", "spec.json", binary=run.node)[-1])

    def test_a_missing_node_refuses_the_run(self):
        self.add_ssh_executor(node=False)
        relay = executors.find(self.cfg(), "relay-4090")
        with self.assertRaisesRegex(ValueError, "找不到 metacodes 节点"):
            executors.resolve_node(relay)

    def test_an_unreachable_executor_is_not_reported_as_a_missing_node(self):
        self.add_ssh_executor()
        relay = executors.find(self.cfg(), "relay-4090")

        def runner(argv, **_kwargs):
            return subprocess.CompletedProcess(argv, 255, "", "ssh: connect to host 10.126.126.1: Connection refused")
        with self.assertRaisesRegex(ValueError, "连接执行机器 relay-4090.*退出码 255.*Connection refused"):
            executors.resolve_node(relay, runner)

        def timeout(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
        with self.assertRaisesRegex(ValueError, "连接执行机器 relay-4090"):
            executors.resolve_node(relay, timeout)

    def test_a_node_on_the_path_runs_with_the_configured_python(self):
        """No setup-managed entry: the `metacodes` on the executor's PATH is
        the node, started with the entry's `python`, for probe and commands."""
        calls = self.root / "python-calls.log"
        python = self.remote_home / "opt/bench/bin/python3.12"
        python.parent.mkdir(parents=True)
        python.write_text(f'#!/bin/sh\necho "$*" >> {calls}\nexec {sys.executable} "$@"\n')
        python.chmod(0o755)
        self.add_ssh_executor(node=False, python=str(python))
        (self.remote_bin / "metacodes").write_bytes(node_script())
        (self.remote_bin / "metacodes").chmod(0o755)
        os.environ["FAKE_REMOTE_DOCKER_DAEMON"] = "1"
        relay = executors.find(self.cfg(), "relay-4090")
        facts = executors.probe(relay)
        self.assertEqual(facts["node"]["protocol"], node_protocol.PROTOCOL, facts)
        self.assertIsNone(executors.node_problem(relay, facts))
        self.assertIn("scripts.eval.harbor.cli", calls.read_text())
        listing = subprocess.run(executors.node_argv(relay, "manifest", "nowhere"), capture_output=True, text=True)
        self.assertEqual((listing.returncode, json.loads(listing.stdout)), (0, {}), listing.stderr)
        self.assertEqual(calls.read_text().count("scripts.eval.harbor.cli"), 2)


class SshRunTest(SetupFixture):
    def prepare_remote(self, profile=False, gateway=None):
        if gateway is None:
            state, upstream, calls = session_fixture(self.root)
            self.addCleanup(upstream.server_close)
            self.addCleanup(upstream.shutdown)
            os.environ["METASK_SITE_URL"] = f"http://127.0.0.1:{upstream.server_port}"
        else:
            state, calls = gateway.state, gateway.requests
            os.environ["METASK_SITE_URL"] = gateway.url
        (self.remote_home / ".local/bin").mkdir(parents=True)
        harbor = self.remote_home / ".local/bin/harbor"
        harbor.write_text(FAKE_HARBOR.format(python=sys.executable))
        harbor.chmod(0o755)
        os.symlink(self.templates / "docker", self.remote_bin / "docker")
        os.environ["FAKE_REMOTE_DOCKER_DAEMON"] = "1"
        from scripts.eval.tests.test_bench_suites import workbuddy_bundle
        bundle = workbuddy_bundle(self.root / "bundle")
        self.add_ssh_executor(metrics_bind="127.0.0.1", metrics_enabled=profile)
        cfg = self.cfg()
        cfg.update(auth_mode="metask", account_state_dir=str(state), bundle=str(bundle), metrics_enabled=profile,
                   harbor=str(self.templates / "harbor"))
        atomic_json(self.config, cfg)
        manager = RunManager(self.state / "bench/jobs", self.config)
        http = server.make_server(Workbench(data.Library([manager.jobs_dir]), manager), "127.0.0.1", 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        self.addCleanup(stop_profiles_and_workers, manager)
        return manager, cli.Client(f"http://127.0.0.1:{http.server_address[1]}/"), calls

    def request(self):
        return {"model": "metask/session-model", "tasks": ["fix-git"], "attempts": 1, "concurrency": 1,
                "executor": "relay-4090"}

    def test_run_on_ssh_executor_profiles_remotely_and_syncs_results(self):
        manager, client, calls = self.prepare_remote(profile=True)
        catalog = client.request("api/workbench")
        relay = next(e for e in catalog["executors"] if e["name"] == "relay-4090")
        self.assertTrue(relay["ready"], relay["reasons"])
        os.environ.update(FAKE_EXPECT_ACCOUNT_KEY="session-access", FAKE_PROFILE_REQUEST="1")
        run = client.request("api/runs", self.request())
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        self.assertEqual(final["executor"], "relay-4090")
        local = manager.jobs_dir / run["name"]
        argv = json.loads((local / "argv.json").read_text())
        remote_root = str((self.remote_home / ".metacodes-bench").resolve())
        self.assertEqual(argv[argv.index("-o") + 1], remote_root + "/jobs")
        bundle_arg = next(a for a in argv if a.startswith("bundle="))
        self.assertTrue(bundle_arg.startswith("bundle=" + remote_root + "/bundles/"), bundle_arg)
        self.assertTrue(any(a.startswith("metrics_proxy=https://127.0.0.1:") for a in argv))
        # The remote Harbor process holds only the placeholder; the remote
        # relay sent the real token, which is in no argv or file.
        check = json.loads((local / "credential-check.json").read_text())
        self.assertEqual((check["account_key_matches"], check["placeholder"]), (False, True))
        self.assertIn(("model-request", "Bearer session-access", {"model": "session-model"}), calls)
        for row in self.calls("ssh"):
            self.assertNotIn("session-access", json.dumps(row))
        for path in list(self.remote_home.rglob("*")) + list(manager.records.iterdir()):
            if path.is_file():
                self.assertNotIn(b"session-access", path.read_bytes(), path)
        view = client.request("api/job?name=" + run["name"])
        self.assertEqual(view["summary"]["counts"]["pass"], 1)
        self.assertEqual((view["rows"][0]["requests"], view["rows"][0]["total_tokens"]), (1, 70))
        self.assertTrue(list((local / ".bench-metrics").glob("*.jsonl")))

    def test_container_mirrors_reach_harbor_as_a_compose_overlay(self):
        manager, client, _ = self.prepare_remote()
        cfg = self.cfg()
        entry = next(e for e in cfg["executors"] if e["name"] == "relay-4090")
        entry["container_mirrors"] = {"apt": "http://mirrors.aliyun.com", "go": "https://goproxy.cn",
                                      "github": "https://gh-proxy.com/https://github.com",
                                      "hf": "https://hf-mirror.com"}
        entry["download_cache"] = True
        atomic_json(self.config, cfg)
        run = client.request("api/runs", self.request())
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        argv = json.loads((manager.jobs_dir / run["name"] / "argv.json").read_text())
        overlay = self.remote_home / ".metacodes-bench/runs" / run["name"] / executors.COMPOSE_OVERLAY
        self.assertEqual(argv[argv.index("--extra-docker-compose") + 1], str(overlay.resolve()))
        # Nothing answers as the apt cache here: apt keeps the task's own sources.
        self.assertEqual(json.loads(overlay.read_text()), {"services": {"main": {"environment": {
            "GOPROXY": "https://goproxy.cn,direct",
            "UV_INSTALLER_GITHUB_BASE_URL": "https://gh-proxy.com/https://github.com",
            "UV_PYTHON_INSTALL_MIRROR": "https://gh-proxy.com/https://github.com/astral-sh/python-build-standalone"
                                        "/releases/download",
            "HF_ENDPOINT": "https://hf-mirror.com"}}}})
        log = (manager.records / (run["name"] + ".log")).read_text()
        self.assertIn("apt 缓存 http://127.0.0.1:3142 没有响应", log)
        self.assertIn("下载缓存 http://127.0.0.1:3143 没有响应", log)

    def test_refreshed_tokens_reach_the_remote_relay_over_stdin_only(self):
        gateway = RotatingGateway(self.root, lifetime=4)
        self.addCleanup(gateway.close)
        manager, client, _ = self.prepare_remote(profile=True, gateway=gateway)
        os.environ.update(METACODES_BENCH_REFRESH_MARGIN="2", METACODES_BENCH_REFRESH_INTERVAL="0.2",
                          FAKE_RELAY_REQUESTS="30", FAKE_RELAY_INTERVAL="0.3")
        run = client.request("api/runs", self.request())
        final, _ = self.watch_until_done(manager, run["name"])
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        local = manager.jobs_dir / run["name"]
        # Every request through the remote relay was authorized upstream,
        # across 2.5 token lifetimes: the executor holds no refresh token, so
        # the newer tokens it used can only have arrived over the channel.
        self.assertEqual(json.loads((local / "relay-statuses.json").read_text()), [200] * 30)
        self.assertEqual(len(gateway.requests), 30)
        self.assertTrue(all(ok for _, ok, _ in gateway.requests), gateway.requests)
        self.assertGreaterEqual(len({token for token, _, _ in gateway.requests}), 3)
        during_run = gateway.refreshes_while_serving()
        self.assertGreaterEqual(len(during_run), 2, gateway.refreshes)
        self.assertTrue(all(left > 0 for left in during_run), gateway.refreshes)
        self.assertGreaterEqual(final["credential"]["refresh_count"], 2)
        self.assertEqual(json.loads((gateway.state / "oauth/metask.json").read_text())["refresh_token"],
                         gateway.refresh_token)
        # Neither the access nor the refresh tokens are in the remote files
        # (the synced job, harbor-env.json = the remote driver's environment
        # plus what it handed Harbor), the SSH argv, or the local records.
        container = json.loads((local / "container-env.json").read_text())
        self.assertTrue(container["METASK_API_KEY"].startswith("mcb-"), container)
        remote_files = [p for p in self.remote_home.rglob("*") if p.is_file()]
        self.assertTrue(any(p.name == "harbor-env.json" for p in remote_files))
        public = b"".join(p.read_bytes() for p in remote_files + list(manager.records.iterdir())
                          + [p for p in local.rglob("*") if p.is_file()])
        argv = json.dumps(self.calls("ssh"))
        for secret in gateway.issued:
            self.assertNotIn(secret.encode(), public, secret)
            self.assertNotIn(secret, argv)

    def watch_until_done(self, manager, name, timeout=60):
        """Every status the page shows until the run ends."""
        shown, deadline = [], time.monotonic() + timeout
        while time.monotonic() < deadline:
            run = next((r for r in manager.runs() if r["name"] == name), {})
            shown.append(run.get("status"))
            if run.get("status") in ("finished", "failed", "cancelled", "interrupted"):
                return run, shown
            time.sleep(0.1)
        raise AssertionError(f"run did not finish: {shown[-5:]}")

    def test_slow_copy_back_keeps_the_run_alive_and_cancellable(self):
        """A copy-back slower than the liveness window never shows the run
        as interrupted, never admits a second launch, and cancel works."""
        manager, client, _ = self.prepare_remote()
        os.environ.update(FAKE_SSH_PACK_DELAY="6", FAKE_BENCH_DELAY="2")
        with patch.object(RunManager, "STALE_AFTER", 3):
            run = client.request("api/runs", self.request())
            final, shown = self.watch_until_done(manager, run["name"])
            self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
            self.assertNotIn("interrupted", shown)
            self.assertTrue((manager.jobs_dir / run["name"] / "fix-git__fake" / "result.json").exists())

            os.environ["FAKE_BENCH_DELAY"] = "30"
            second = client.request("api/runs", self.request())
            deadline = time.monotonic() + 30
            while not (self.remote_home / ".metacodes-bench/jobs" / second["name"] / "argv.json").exists():
                self.assertLess(time.monotonic(), deadline, data.tail(manager.records / (second["name"] + ".log")))
                time.sleep(0.1)
            time.sleep(4)  # a copy-back pass is in flight now
            with self.assertRaisesRegex(ValueError, "已有评测正在运行"):
                client.request("api/runs", self.request())
            client.request("api/cancel", {"name": second["name"]})
            final, shown = self.watch_until_done(manager, second["name"])
            self.assertEqual(final["status"], "cancelled", final)
            self.assertNotIn("interrupted", shown)

    def test_unfinished_copy_back_is_reported_and_bench_sync_recovers(self):
        manager, client, _ = self.prepare_remote()
        os.environ.update(FAKE_SSH_PACK_FAIL="1", METACODES_BENCH_FINAL_SYNC_TIMEOUT="2")
        run = client.request("api/runs", self.request())
        final, _ = self.watch_until_done(manager, run["name"])
        # Harbor exited 0, but the results never reached this host.
        self.assertEqual((final["status"], final["exit_code"]), ("failed", 0), final)
        self.assertEqual(final["remote_results"]["path"], ".metacodes-bench/jobs/" + run["name"])
        self.assertIn("metacodes bench sync --run " + run["name"], final["error"])
        local = manager.jobs_dir / run["name"]
        self.assertFalse((local / "fix-git__fake" / "result.json").exists())

        del os.environ["FAKE_SSH_PACK_FAIL"]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(["--state-root", str(self.state), "sync", "--run", run["name"], "--json"])
        self.assertEqual(code, 0, output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["status"], "finished")
        self.assertTrue((local / "fix-git__fake" / "result.json").exists())
        record = next(r for r in manager.runs() if r["name"] == run["name"])
        self.assertEqual((record["status"], record.get("error"), record.get("remote_results")), ("finished", None, None))

    def test_copy_back_is_bounded_per_pass_and_appends_grown_files(self):
        manager, _, _ = self.prepare_remote()
        relay = executors.find(self.cfg(), "relay-4090")
        remote_dir = self.remote_home / "jobs" / "grow"
        (remote_dir / "t__1").mkdir(parents=True)
        for index in range(5):
            (remote_dir / "t__1" / f"small-{index}.json").write_text(json.dumps({"index": index}))
        log = remote_dir / "t__1" / "agent.log"
        log.write_bytes(os.urandom(300 * 1024))
        local = self.root / "local-jobs" / "grow"
        sync = executors.JobSync(relay, "jobs/grow", local, log=lambda _t: None)
        sync.PASS_BYTES = 100 * 1024
        self.assertEqual(sync.sync(), 5)  # the small files first; the log waits
        self.assertEqual(sync.pending, 1)
        self.assertFalse((local / "t__1/agent.log").exists())
        self.assertEqual(sync.sync(), 1)  # alone, larger than one pass: still sent
        self.assertTrue(sync.complete())
        received = sync.bytes
        with log.open("ab") as handle:
            handle.write(b"appended line\n" * 100)
        (remote_dir / "t__1" / "small-0.json").write_text(json.dumps({"index": "rewritten"}))
        self.assertEqual(sync.sync(), 2)
        self.assertLess(sync.bytes - received, 32 * 1024)  # the 1.4 KiB append, not 300 KiB again
        self.assertEqual((local / "t__1/agent.log").read_bytes(), log.read_bytes())
        self.assertEqual(json.loads((local / "t__1/small-0.json").read_text()), {"index": "rewritten"})
        # A file rewritten with different earlier bytes is copied whole.
        log.write_bytes(os.urandom(400 * 1024))
        sync.PASS_BYTES = 1 << 30
        sync.sync()
        self.assertEqual((local / "t__1/agent.log").read_bytes(), log.read_bytes())
        self.assertTrue(sync.complete())

    def test_a_dropped_session_is_reattached_and_the_run_finishes(self):
        manager, client, _ = self.prepare_remote()
        drops = self.root / "drops"
        drops.write_text("1")
        os.environ.update(FAKE_SSH_DROPS=str(drops), FAKE_SSH_DROP_AFTER="2", FAKE_BENCH_DELAY="6")
        run = client.request("api/runs", self.request())
        final, _ = self.watch_until_done(manager, run["name"])
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertEqual(final["status"], "finished", (final, log))
        self.assertEqual((final["exit_code"], final["reconnects"]), (0, 1), final)
        self.assertEqual(drops.read_text(), "0")
        self.assertIn("已重新连上执行机器 relay-4090", log)
        self.assertTrue((manager.jobs_dir / run["name"] / "fix-git__fake" / "result.json").exists())

    def test_a_session_lost_before_its_first_event_is_attached_too(self):
        """The start request reached the node but no event came back: the
        worker attaches (waiting while the driver starts) and gets the
        remote run's own end."""
        manager, client, _ = self.prepare_remote()
        drops = self.root / "drops"
        drops.write_text("1")
        os.environ.update(FAKE_SSH_DROPS=str(drops), FAKE_SSH_DROP_AFTER="0", FAKE_SSH_DROP_SILENT="1",
                          FAKE_BENCH_DELAY="4")
        run = client.request("api/runs", self.request())
        final, _ = self.watch_until_done(manager, run["name"])
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertEqual((final["status"], final["exit_code"]), ("finished", 0), (final, log))
        self.assertEqual(final["reconnects"], 1, final)
        end = self.remote_home / ".metacodes-bench/runs" / run["name"] / remote.END_EVENT
        self.assertEqual(json.loads(end.read_text())["code"], 0)
        self.assertTrue((manager.jobs_dir / run["name"] / "fix-git__fake" / "result.json").exists())

    def test_a_session_silent_before_its_first_event_is_ended_and_attached(self):
        manager, client, _ = self.prepare_remote()
        drops = self.root / "drops"
        drops.write_text("1")
        os.environ.update(FAKE_SSH_DROPS=str(drops), FAKE_SSH_DROP_AFTER="120", FAKE_SSH_DROP_SILENT="1",
                          FAKE_BENCH_DELAY="6", METACODES_BENCH_HEARTBEAT_TIMEOUT="2")
        run = client.request("api/runs", self.request())
        final, _ = self.watch_until_done(manager, run["name"])
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertEqual((final["status"], final["exit_code"], final["reconnects"]), ("finished", 0, 1), (final, log))
        self.assertIn("心跳超时，断开重连", log)
        self.assertEqual(len([c for c in self.calls("ssh") if " node run " in c[1][-1]]), 1)

    def test_the_attach_socket_is_short_and_private_for_a_deep_state_dir(self):
        self.prepare_remote()
        run_dir = self.remote_home / ("state/" * 12) / "runs" / "bench-20261124-055700-0a1b2c"
        run_dir.mkdir(parents=True)
        control = remote.Control(run_dir, lambda _line: None, 60)
        self.addCleanup(control.close)
        self.assertTrue(control.listen())
        self.assertLess(len(control.path), 100)
        self.assertEqual(control.path, remote.attach_socket(run_dir))
        self.assertEqual(os.stat(os.path.dirname(control.path)).st_mode & 0o777, 0o700)

    def test_cancel_reaches_the_remote_harbor_process(self):
        manager, client, _ = self.prepare_remote()
        os.environ["FAKE_BENCH_DELAY"] = "30"
        run = client.request("api/runs", self.request())
        deadline = time.monotonic() + 20
        while not (self.remote_home / ".metacodes-bench/jobs" / run["name"] / "argv.json").exists():
            self.assertLess(time.monotonic(), deadline, data.tail(manager.records / (run["name"] + ".log")))
            time.sleep(0.1)
        started = time.monotonic()
        client.request("api/cancel", {"name": run["name"]})
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "cancelled", final)
        self.assertLess(time.monotonic() - started, 15)
        self.assertNotEqual(final["exit_code"], 0)
        self.assertTrue((manager.jobs_dir / run["name"] / "argv.json").exists())

    def start_driver(self, grace, delay=30, name="eof", relay=None, env=None, credential=None, egress=None):
        """A remote driver whose Harbor runs `delay` s, and its first session."""
        self.prepare_remote()
        executor = executors.find(self.cfg(), "relay-4090")
        jobs = self.remote_home / "jobs"
        spec = {"argv": [str(self.remote_home / ".local/bin/harbor"), "run", "-m", "metask/x", "-k", "1",
                         "-o", str(jobs), "--job-name", name], "key_env": "METASK_API_KEY", "relay": relay,
                "detach_grace": grace, "egress": egress}
        (self.remote_home / "runs" / name).mkdir(parents=True)
        (self.remote_home / "runs" / name / "spec.json").write_text(json.dumps(spec))
        process = subprocess.Popen(executors.node_argv(executor, "run", f"runs/{name}/spec.json"),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   env={**os.environ, "FAKE_BENCH_DELAY": str(delay), **(env or {})})
        self.addCleanup(process.kill)
        first = {"env": {"METASK_API_KEY": "k"}, **({"credential": credential} if credential else {})}
        process.stdin.write(json.dumps(first).encode() + b"\n")
        process.stdin.flush()
        self.driver_events = []
        while not self.driver_events or self.driver_events[-1]["event"] != "started":
            self.driver_events.append(json.loads(process.stdout.readline()))
        return executor, process

    def streaming_upstream(self, events=10, pause=0.6, slow=1):
        """A model endpoint whose `slow`-th answer streams for `events` x
        `pause` seconds (`streaming` is set once it has begun), the others at
        once."""
        streaming, seen = threading.Event(), []

        class Endpoint(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                seen.append(self.headers.get("Authorization"))
                slowly = len(seen) == slow
                parts = ([{"type": "message_start", "message": {"usage": {"input_tokens": 5}}}] +
                         [{"type": "content_block_delta", "delta": {"text": "x"}}] * events +
                         [{"type": "message_delta", "usage": {"output_tokens": events}}, {"type": "message_stop"}])
                chunks = [b"data: " + json.dumps(part).encode() + b"\n\n" for part in parts]
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(sum(len(chunk) for chunk in chunks)))
                self.end_headers()
                for index, chunk in enumerate(chunks):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if slowly and index < events:
                        streaming.set()
                        time.sleep(pause)

            def log_message(self, *_args):
                pass

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Endpoint)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        return upstream, streaming, seen

    def test_a_driver_upgrade_mid_stream_completes_the_request_and_the_run(self):
        """`node upgrade` replaces the driver while a model request streams
        through its relay: that request completes, the later ones go through
        the new driver with the same placeholder and CA, and the run ends as
        it would have without the upgrade."""
        upstream, streaming, seen = self.streaming_upstream()
        metrics = "jobs/up/.bench-metrics"
        relay, process = self.start_driver(
            grace=60, delay=1, name="up", credential="real-token",
            env={"FAKE_RELAY_REQUESTS": "3", "FAKE_RELAY_INTERVAL": "0"},
            relay={"upstream": f"http://127.0.0.1:{upstream.server_port}", "bind": "127.0.0.1",
                   "auth_header": "Authorization", "auth_prefix": "Bearer ", "metrics_dir": metrics, "record": True})
        run_dir = self.remote_home / "runs/up"
        self.assertTrue(streaming.wait(30))
        before = (run_dir / remote.DRIVER_PID).read_text()
        done = subprocess.run(executors.node_argv(relay, "upgrade", "runs/up/spec.json"), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        outcome = json.loads(done.stdout)
        self.assertEqual((outcome["run"], outcome["result"]), ("up", "upgraded"), outcome)
        self.assertEqual(len(seen), 1)  # the first request is still streaming
        self.assertNotEqual(str(outcome["pid"]), before)
        self.assertEqual((run_dir / remote.DRIVER_PID).read_text(), str(outcome["pid"]))
        events = []
        for line in process.stdout:
            events.append(json.loads(line)["event"])
            if events[-1] == "handoff":
                break
        self.assertEqual(events[-1], "handoff", events)
        # The old driver ends once the request it had accepted is complete.
        self.assertEqual(process.wait(30), 0)
        session = subprocess.Popen(executors.node_argv(relay, "attach", "runs/up/spec.json"),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(session.kill)
        session.stdin.write(b'{"credential": "fresh-token"}\n')
        session.stdin.flush()
        ends = [json.loads(line) for line in session.stdout]
        self.assertIn({"event": "credential", "pushes": 1}, ends)
        self.assertEqual(ends[-1], {"event": "exit", "code": 0, "cancelled": False})
        self.assertEqual(json.loads((self.remote_home / "jobs/up/relay-statuses.json").read_text()), [200, 200, 200])
        rows = [json.loads(line) for line in
                (self.remote_home / metrics / "fix-git__fake.jsonl").read_text().splitlines()]
        self.assertEqual([(r["request"], r["http_status"], r["complete"]) for r in rows],
                         [(1, 200, True), (2, 200, True), (3, 200, True)])
        self.assertEqual(seen[0], "Bearer real-token")
        self.assertTrue(set(seen) <= {"Bearer real-token", "Bearer fresh-token"}, seen)
        self.assertTrue((self.remote_home / "jobs/up/fix-git__fake/result.json").exists())
        self.assertFalse((run_dir / remote.RELAY_TLS).exists())

    def tunnels(self, *labels):
        """Stand-ins for the executor ends of `ssh -R` tunnels: each answers
        a connection with its label. {label: port}."""
        tunnels = {}
        for label in labels:
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            listener.listen(8)
            self.addCleanup(listener.close)

            def answer(listener=listener, label=label):
                while True:
                    try:
                        conn, _ = listener.accept()
                    except OSError:
                        return
                    with conn:
                        conn.sendall(label.encode())
            threading.Thread(target=answer, daemon=True).start()
            tunnels[label] = listener.getsockname()[1]
        return tunnels

    def start_egress_driver(self, name, port):
        """A driver with workbench egress on tunnel `port`, and a function
        connecting through its forwarder (the address stays the same across
        handoffs) that returns what the tunnel answered."""
        relay, process = self.start_driver(grace=60, delay=60, name=name, egress={
            "mode": "workbench", "tunnel_port": port, "bind": "127.0.0.1", "no_proxy": []})
        proxy = next(e for e in self.driver_events if e["event"] == "egress")["proxy"]
        host, forwarder_port = proxy.removeprefix("http://").rsplit(":", 1)

        def through_forwarder():
            with socket.create_connection((host, int(forwarder_port)), timeout=10) as conn:
                return conn.recv(16).decode()
        return relay, process, through_forwarder

    def test_the_old_tunnel_carries_egress_until_the_new_driver_has_its_own(self):
        """Handed over, the forwarder keeps the old session's tunnel port
        until a session brings the new driver its own; the old driver (and
        with it that session and tunnel) ends only then."""
        tunnels = self.tunnels("old", "new")
        relay, process, through_forwarder = self.start_egress_driver("tun", tunnels["old"])

        self.assertEqual(through_forwarder(), "old")
        for _ in range(2):  # twice before any session attaches
            done = subprocess.run(executors.node_argv(relay, "upgrade", "runs/tun/spec.json"),
                                  stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            self.assertEqual(json.loads(done.stdout)["result"], "upgraded", done.stderr)
            time.sleep(1)
        for line in process.stdout:
            if json.loads(line)["event"] == "handoff":
                break
        time.sleep(2)
        self.assertIsNone(process.poll())  # nothing in flight, but no new tunnel yet
        self.assertEqual(through_forwarder(), "old")
        session = subprocess.Popen(executors.node_argv(relay, "attach", "runs/tun/spec.json"),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(session.kill)
        session.stdin.write(json.dumps({"tunnel_port": tunnels["new"]}).encode() + b"\n")
        session.stdin.flush()
        self.assertEqual(process.wait(30), 0)
        self.assertEqual(through_forwarder(), "new")
        session.stdin.write(b"cancel\n")
        session.stdin.flush()
        self.assertEqual([json.loads(line) for line in session.stdout][-1]["event"], "exit")

    def test_a_tunnel_brought_during_a_handoff_reaches_the_next_driver(self):
        """A session attaches to B with a new tunnel while B is handing the
        run to C (C has B's state, B awaits `ready`): A may end, and C must
        start with the new tunnel, not A's port from that state."""
        from scripts.eval.harbor.bench import egress
        tunnels = self.tunnels("a", "b")
        relay, process, _ = self.start_egress_driver("mid", tunnels["a"])
        done = subprocess.run(executors.node_argv(relay, "upgrade", "runs/mid/spec.json"), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(json.loads(done.stdout)["result"], "upgraded", done.stderr)
        run_dir = self.remote_home / "runs/mid"
        # This test is driver C.
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(conn.close)
        conn.connect(remote.handoff_socket(run_dir))
        conn.sendall(json.dumps({"handoff": remote.HANDOFF}).encode() + b"\n")
        data, fds, _flags, _address = socket.recv_fds(conn, 65536, 4)
        reader = conn.makefile("rb")
        state = json.loads(data if data.endswith(b"\n") else data + reader.readline())
        sockets = dict(zip(state["sockets"], (socket.socket(fileno=fd) for fd in fds)))
        for sock in sockets.values():
            self.addCleanup(sock.close)
        self.addCleanup(os.killpg, state["harbor"], signal.SIGKILL)
        self.assertEqual(state["forwarder"]["target"][1], tunnels["a"])
        session = subprocess.Popen(executors.node_argv(relay, "attach", "runs/mid/spec.json"),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(session.kill)
        session.stdin.write(json.dumps({"tunnel_port": tunnels["b"]}).encode() + b"\n")
        session.stdin.flush()
        self.assertEqual(process.wait(30), 0)  # B has its own tunnel: A may end
        conn.sendall(b'{"ready": true}\n')
        released = json.loads(reader.readline())
        self.assertEqual((released["released"], released["target"][1]), (True, tunnels["b"]))
        forwarder = egress.Forwarder("", tuple(released["target"]), sock=sockets.pop("forwarder")).start()
        self.addCleanup(forwarder.close)
        with socket.create_connection(forwarder.address, timeout=10) as through:
            self.assertEqual(through.recv(16), b"b")
        conn.sendall(b'{"tunnel": true}\n')

    def test_a_failed_driver_upgrade_leaves_the_run_to_its_driver(self):
        relay, process = self.start_driver(grace=60, delay=4)
        path = remote.handoff_socket(self.remote_home / "runs/eof")
        deadline = time.monotonic() + 10
        while not os.path.exists(path):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.05)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.connect(path)
            conn.sendall(b'{"handoff": 0}\n')
            self.assertIn("refused", json.loads(conn.makefile("rb").readline()))
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            # A new driver that dies once it has the run's state.
            conn.connect(path)
            conn.sendall(json.dumps({"handoff": remote.HANDOFF}).encode() + b"\n")
            state, fds, _flags, _address = socket.recv_fds(conn, 65536, 4)
            for fd in fds:
                os.close(fd)
            self.assertGreater(json.loads(state)["harbor"], 0)
        # A run whose driver predates hot upgrade finishes with it.
        old = self.remote_home / "runs/old"
        old.mkdir()
        (old / "spec.json").write_text("{}")
        (old / remote.DRIVER_PID).write_text(str(os.getpid()))
        done = subprocess.run(executors.node_argv(relay, "upgrade", "runs/old/spec.json"), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(json.loads(done.stdout), {"run": "old", "result": "unsupported"}, done.stderr)
        events = [json.loads(line) for line in process.stdout]
        self.assertNotIn("handoff", [e["event"] for e in events])
        self.assertEqual(events[-1], {"event": "exit", "code": 0, "cancelled": False})
        self.assertTrue((self.remote_home / "jobs/eof/fix-git__fake/result.json").exists())

    def test_closed_channel_stops_remote_harbor_after_the_grace_period(self):
        _, process = self.start_driver(grace=1)
        process.stdin.close()
        process.stdout.close()
        process.wait(30)
        end = json.loads((self.remote_home / "runs/eof" / remote.END_EVENT).read_text())
        self.assertEqual((end["event"], end["cancelled"]), ("exit", True))

    def test_a_new_session_attaches_to_a_run_whose_channel_closed(self):
        """A dropped SSH session leaves Harbor running; `node attach` takes
        over its events and control lines, and gets the terminal event even
        once the run has ended."""
        relay, process = self.start_driver(grace=60)
        process.stdin.close()
        process.stdout.close()
        attach = executors.node_argv(relay, "attach", "runs/eof/spec.json")
        session = subprocess.Popen(attach, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(session.kill)
        self.assertEqual(json.loads(session.stdout.readline())["event"], "heartbeat")
        self.assertIsNone(process.poll())
        session.stdin.write(b"cancel\n")
        session.stdin.flush()
        events = [json.loads(line) for line in session.stdout]
        self.assertEqual(events[-1]["event"], "exit")
        self.assertTrue(events[-1]["cancelled"])
        process.wait(30)
        late = subprocess.run(attach, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        self.assertEqual(json.loads(late.stdout), events[-1])


class DrainTest(unittest.TestCase):
    """What a driver that handed its run over waits for before it ends."""

    streaming_upstream = SshRunTest.streaming_upstream

    def test_the_relay_waits_for_handshakes_and_streams_but_not_for_idle_connections(self):
        import http.client
        import ssl
        from scripts.eval.harbor.profiling import TimingRelay
        upstream, streaming, seen = self.streaming_upstream(events=6, pause=0.5, slow=2)
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        relay = TimingRelay(f"http://127.0.0.1:{upstream.server_port}", "real", tmp / "metrics", bind="127.0.0.1",
                            tls=True, token="mcb-token", cert_dir=tmp / "tls").__enter__()
        port = relay.server.server_port
        context = ssl.create_default_context(cafile=str(relay.ca_path))
        headers = {"Authorization": "Bearer mcb-token", "Content-Type": "application/json"}

        def post(conn):
            conn.request("POST", "/t/v1/messages", body=b"{}", headers=headers)
            response = conn.getresponse()
            return response.status, response.read()

        idle = http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=30)
        self.addCleanup(idle.close)
        self.assertEqual(post(idle)[0], 200)  # kept alive, idle from now on
        streamed = {}
        stream = threading.Thread(target=lambda: streamed.update(
            result=post(http.client.HTTPSConnection("127.0.0.1", port, context=context, timeout=30))))
        stream.start()
        self.assertTrue(streaming.wait(10))
        handshaking = socket.create_connection(("127.0.0.1", port))  # no ClientHello yet
        self.addCleanup(handshaking.close)
        time.sleep(0.3)
        released = threading.Thread(target=relay.release)
        released.start()
        stream.join(30)
        self.assertEqual(streamed["result"][0], 200)
        self.assertIn(b'"message_stop"', streamed["result"][1])
        time.sleep(0.5)
        self.assertTrue(released.is_alive())  # the handshake is not over
        handshaking.close()
        released.join(20)
        self.assertFalse(released.is_alive())
        # The idle keep-alive connection was closed: a request sent on it now
        # never reaches the upstream, so the client may send it again.
        with self.assertRaises((OSError, http.client.HTTPException)):
            post(idle)
        self.assertEqual(len(seen), 2)
        relay.remove_files()

    def test_the_forwarder_waits_for_its_connections_or_the_end_of_the_run(self):
        from scripts.eval.harbor.bench import egress
        target = socket.socket()
        target.bind(("127.0.0.1", 0))
        target.listen(8)
        self.addCleanup(target.close)
        answer = threading.Event()

        def serve():
            while True:
                try:
                    conn, _ = target.accept()
                except OSError:
                    return
                threading.Thread(target=respond, args=(conn,), daemon=True).start()

        def respond(conn):
            with conn:
                request = conn.recv(1)
                if request == b"w":  # an upstream still computing its answer
                    answer.wait(30)
                    conn.sendall(b"answer")
                else:
                    conn.recv(1)  # idle until the client closes

        threading.Thread(target=serve, daemon=True).start()
        forwarder = egress.Forwarder("127.0.0.1", target.getsockname()).start()
        waiting = socket.create_connection(forwarder.address)
        self.addCleanup(waiting.close)
        waiting.sendall(b"w")
        time.sleep(0.3)
        released = threading.Thread(target=forwarder.release, args=(lambda: False,))
        released.start()
        time.sleep(2)  # silent all along, yet waiting for its answer
        self.assertTrue(released.is_alive())
        answer.set()
        self.assertEqual(waiting.recv(16), b"answer")
        waiting.close()
        released.join(10)
        self.assertFalse(released.is_alive())

        forwarder = egress.Forwarder("127.0.0.1", target.getsockname()).start()
        idle = socket.create_connection(forwarder.address)
        self.addCleanup(idle.close)
        idle.sendall(b"i")
        time.sleep(0.3)
        over = threading.Event()
        released = threading.Thread(target=forwarder.release, args=(over.is_set,))
        released.start()
        time.sleep(1.5)
        self.assertTrue(released.is_alive())
        over.set()  # the run ended
        released.join(10)
        self.assertFalse(released.is_alive())


class SuiteOnExecutorTest(SetupFixture):
    """bench-suites x bench-setup x bench-store: a launch picks a suite and an
    executor, and its results reach the evaluation database."""

    prepare_remote = SshRunTest.prepare_remote

    def harbor_local_suite(self):
        dataset = self.root / "humaneval-dataset"
        for task in ("humaneval-0", "humaneval-7"):
            (dataset / task).mkdir(parents=True)
            (dataset / task / "task.toml").write_text("[task]\n")
        (dataset / "humaneval-7" / "tests").mkdir()
        (dataset / "humaneval-7" / "tests" / "test.sh").write_text("exit 0\n")
        adapter = types.ModuleType("scripts.eval.harbor.adapters.humaneval")
        adapter.SUITE = {"name": "HumanEval"}
        adapter.HOST_ENV = ("FAKE_JUDGE_KEY", "lower-case-ignored")
        adapter.prepare = lambda dest: dest
        cfg = self.cfg()
        cfg["datasets"] = {"humaneval": str(dataset)}
        atomic_json(self.config, cfg)
        patcher = patch.dict(sys.modules, {adapter.__name__: adapter})
        patcher.start()
        self.addCleanup(patcher.stop)
        return dataset

    def test_readiness_is_per_suite_and_executor(self):
        manager, client, _ = self.prepare_remote()
        catalog = client.request("api/workbench")
        self.assertEqual(catalog["default_executor"], "devbox-mac")
        self.assertEqual(catalog["login"], {"available": True, "signed_in": True})
        self.assertEqual((catalog["global_reasons"], catalog["harbor_reasons"]), ([], []))
        suites_by_id = {s["id"]: s for s in catalog["suites"]}
        local = next(e for e in catalog["executors"] if e["name"] == "devbox-mac")
        self.assertFalse(local["ready"])  # no Docker on this side of the fixture
        tb = suites_by_id["terminal-bench-2.1"]
        self.assertTrue(tb["executors"]["relay-4090"]["ready"], tb["executors"]["relay-4090"])
        self.assertEqual(tb["executors"]["devbox-mac"]["reasons"], local["reasons"])
        # Top level and suite level describe the default executor.
        self.assertEqual((catalog["ready"], catalog["reasons"]), (False, local["reasons"]))
        self.assertEqual(tb["reasons"], local["reasons"])
        wb = suites_by_id["workbuddy-code"]
        # On the SSH executor its readiness is what the node reports about
        # its own WorkBuddy checkout.
        on_ssh = wb["executors"]["relay-4090"]["reasons"]
        self.assertTrue(any("未配置 WorkBuddy checkout" in r for r in on_ssh), on_ssh)
        # WorkBuddy brings its own Harbor: the local executor's Harbor/Docker
        # probe is not its readiness (it checks its own tools).
        self.assertFalse(set(local["reasons"]) & set(wb["executors"]["devbox-mac"]["reasons"]) - set(wb["suite_reasons"]))
        with self.assertRaisesRegex(ValueError, "未配置 WorkBuddy checkout"):
            client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                        "tasks": ["bug_fix-easy-alpha"], "executor": "relay-4090"})
        with self.assertRaisesRegex(ValueError, "Docker"):
            client.request("api/runs", {"suite": "aime-2025", "model": "metask/session-model",
                                        "tasks": ["aime_i-1"], "executor": "devbox-mac"})
        self.assertEqual(manager.runs(), [])
        with contextlib.redirect_stdout(io.StringIO()) as out:
            cli.main(["info", "--state-root", str(self.state), "--url", client.url])
        text = out.getvalue()
        self.assertIn("执行机器：relay-4090", text)
        self.assertIn("竞赛数学：", text)
        self.assertIn("执行机器：relay-4090（SSH bench@10.126.126.1:22） · metacodes 9.9.9：已就绪", text)

    def test_workbuddy_runs_on_the_ssh_node_with_the_nodes_own_checkout(self):
        """The node reports its WorkBuddy checkout, tasks and readiness; a run
        uses that checkout there with an image staged from the run's bundle,
        behind the node's relay, which receives each refreshed session token
        over the SSH stdin."""
        from scripts.eval.harbor.bench.setup import sha256_file
        from scripts.eval.harbor.suites import workbuddy as wb_suite
        from scripts.eval.tests.test_bench_suites import FAKE_UV, workbuddy_checkout
        from scripts.eval.workbuddy import WORKBUDDY_JUDGE_KEY_ENV
        gateway = RotatingGateway(self.root, lifetime=4)
        self.addCleanup(gateway.close)
        manager, client, _ = self.prepare_remote(gateway=gateway)
        os.environ.update(METACODES_BENCH_REFRESH_MARGIN="2", METACODES_BENCH_REFRESH_INTERVAL="0.2",
                          FAKE_RELAY_REQUESTS="30", FAKE_RELAY_INTERVAL="0.3")
        uv = self.remote_home / ".local/bin/uv"
        uv.write_text(FAKE_UV.format(python=sys.executable, judge=WORKBUDDY_JUDGE_KEY_ENV) + FAKE_UV_REQUESTS)
        uv.chmod(0o755)
        # WorkBuddy brings its own Harbor: the executor's missing Harbor CLI
        # keeps Harbor suites from running there, not WorkBuddy.
        (self.remote_home / ".local/bin/harbor").unlink()
        repo = self.node_checkout(workbuddy_checkout)
        # The mount image is built with buildx: a node without it says so.
        os.environ["FAKE_NO_BUILDX"] = "1"
        catalog = client.request("api/workbench")
        wb = next(s for s in catalog["suites"] if s["id"] == "workbuddy-code")
        self.assertTrue(any("buildx" in r for r in wb["executors"]["relay-4090"]["reasons"]), wb["executors"])
        del os.environ["FAKE_NO_BUILDX"]
        manager.probe_cache.clear()
        catalog = client.request("api/workbench")
        wb = next(s for s in catalog["suites"] if s["id"] == "workbuddy-code")
        tb = next(s for s in catalog["suites"] if s["id"] == "terminal-bench-2.1")
        self.assertTrue(wb["executors"]["relay-4090"]["ready"], wb["executors"]["relay-4090"])
        self.assertFalse(tb["executors"]["relay-4090"]["ready"])
        self.assertFalse(wb["executors"]["devbox-mac"]["ready"])  # no checkout on the workbench machine
        relay = next(e for e in catalog["executors"] if e["name"] == "relay-4090")
        self.assertEqual(relay["node"]["version"], "9.9.9")
        self.assertIn("metacodes 9.9.9", relay["label"])
        self.assertEqual(len(client.request("api/suite?id=workbuddy-code&executor=relay-4090")["tasks"]), 3)
        self.assertEqual(client.request("api/suite?id=workbuddy-code")["tasks"], [])
        with self.assertRaisesRegex(ValueError, "没有这些任务"):
            client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                        "tasks": ["not-a-workbuddy-task"], "executor": "relay-4090"})
        # The mount image of an earlier staging is cached under the shared
        # tag, which run.sh would reuse (and another workbench could move):
        # the run mounts an image of its own tag, staged from its bundle.
        images = Path(os.environ["FAKE_REMOTE_STATE"]) / "images"
        images.mkdir(parents=True, exist_ok=True)
        (images / wb_suite.HARNESS_IMAGE.replace("/", "_")).touch()
        run = client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                          "tasks": ["bug_fix-easy-alpha", "data_quality-hard-beta"],
                                          "attempts": 1, "concurrency": 2, "executor": "relay-4090"})
        final = wait_run(manager, run["name"], timeout=60)
        self.assertEqual(final["status"], "finished", data.tail(manager.records / (run["name"] + ".log")))
        local = manager.jobs_dir / run["name"]
        observed = json.loads((local / "observed.json").read_text())
        self.assertEqual(Path(observed["cwd"]).resolve(), repo.resolve())
        self.assertEqual(final["features"], run["features"])
        self.assertEqual({key: value for key, value in observed["job"]["harness_params_override"].items()
                          if key != "METACODES_REASONING_EFFORT"},
                         {wb_suite.FEATURE_PARAMS[name]: True for name in run["features"]})
        # WorkBuddy holds a placeholder and talks to the node's loopback relay.
        self.assertTrue(observed["key"].startswith("mcb-"), observed["key"])
        self.assertTrue(observed["base_url"].startswith("http://127.0.0.1:"), observed["base_url"])
        self.assertTrue(observed["base_url"].endswith("/workbuddy/v1/messages"), observed["base_url"])
        # Every request across 2.5 token lifetimes was authorized upstream with
        # tokens that could only have arrived over the channel.
        self.assertEqual(json.loads((local / "relay-statuses.json").read_text()), [200] * 30)
        self.assertGreaterEqual(len({token for token, _, _ in gateway.requests}), 3)
        self.assertTrue(all(ok for _, ok, _ in gateway.requests), gateway.requests)
        self.assertGreaterEqual(final["credential"]["refresh_count"], 2)
        slug = "metacodes-" + run["name"]
        self.assertFalse((repo / "configs/jobs" / (slug + ".yaml")).exists())
        view = client.request("api/job?name=" + run["name"])
        self.assertEqual((view["summary"]["counts"]["pass"], view["summary"]["counts"]["fail"]), (1, 1))
        builds = [c[1] for c in self.calls("docker", "remote") if c[1][:2] == ["buildx", "build"]]
        tag = wb_suite.run_image_tag(run["name"])
        self.assertEqual(len(builds), 1, builds)
        self.assertEqual(builds[0][builds[0].index("--tag") + 1], tag)
        self.assertNotEqual(Path(builds[0][-1]).resolve(), (repo / wb_suite.HARNESS_CONTEXT).resolve())
        staged = json.loads((images / (tag + ".manifest").replace("/", "_")).read_text())
        self.assertEqual({label: row["sha256"] for label, row in staged["executables"].items()},
                         {"metacodes": sha256_file(self.root / "bundle/bin/metacodes"),
                          "tinykg": sha256_file(self.root / "bundle/vendor/tinykg/tinykg"),
                          "metacodes-formal-kernel":
                              sha256_file(self.root / "bundle/libexec/metacodes/metacodes-formal-kernel"),
                          "ripgrep": sha256_file(self.root / "bundle/bin/rg")})
        # WorkBuddy resolved that tag through the run's own harness version,
        # the pinned one plus the image; both transient files are gone and the
        # run's tag is removed (the shared one is untouched).
        self.assertEqual(observed["job"]["harness"], "metacodes/" + slug)
        pinned = (repo / wb_suite.HARNESS_VERSIONS / "0.1.0.yaml").read_text()
        self.assertEqual(observed["harness_version"], pinned.rstrip("\n") + f'\n  mount:\n    images:\n      local: "{tag}"\n')
        self.assertFalse((repo / wb_suite.HARNESS_VERSIONS / (slug + ".yaml")).exists())
        self.assertIn(["image", "rm", tag], [c[1] for c in self.calls("docker", "remote")])
        self.assertTrue((images / wb_suite.HARNESS_IMAGE.replace("/", "_")).exists())
        self.assertIsNotNone(json.loads((manager.jobs_dir / run["name"] / "result.json").read_text())["finished_at"])
        remote_files = [p for p in self.remote_home.rglob("*") if p.is_file() and ".metacodes-bench/" in str(p)]
        public = b"".join(p.read_bytes() for p in remote_files + list(manager.records.iterdir())
                          + [p for p in local.rglob("*") if p.is_file()])
        for secret in gateway.issued:
            self.assertNotIn(secret.encode(), public, secret)

    def node_checkout(self, workbuddy_checkout):
        """A WorkBuddy checkout the node prepared."""
        repo = workbuddy_checkout(self.remote_home)
        atomic_json(self.remote_home / ".metacodes/bench/workbench.json", {"workbuddy_checkout": str(repo)})
        return repo

    def test_a_slow_mount_image_build_keeps_the_channel_alive_and_cancels(self):
        """The node builds the run's mount image under heartbeats; a cancel
        during the build kills it and ends the run before WorkBuddy starts."""
        from scripts.eval.tests.test_bench_suites import workbuddy_checkout
        self.prepare_remote()
        uv = self.remote_home / ".local/bin/uv"
        uv.write_text("#!/bin/sh\ntouch \"$HOME/uv-ran\"\n")
        uv.chmod(0o755)
        self.node_checkout(workbuddy_checkout)
        spec = {"schema_version": 1, "runner": "workbuddy", "jobs_dir": "jobs", "name": "slow", "suite": "workbuddy-code",
                "model": "metask/session-model", "tasks": ["bug_fix-easy-alpha"], "attempts": 1, "concurrency": 1,
                "account_gateway": "http://127.0.0.1:9", "bundle": str(self.root / "bundle")}
        (self.remote_home / "spec.json").write_text(json.dumps(spec))
        relay = executors.find(self.cfg(), "relay-4090")
        env = {**os.environ, "FAKE_BUILD_DELAY": "60"}
        process = subprocess.Popen(executors.node_argv(relay, "run", "spec.json"), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, env=env)
        self.addCleanup(process.kill)
        process.stdin.write(b'{"env": {}, "credential": "access"}\n')
        process.stdin.flush()
        beats = [json.loads(process.stdout.readline()) for _ in range(2)]
        self.assertEqual([(e["event"], e.get("phase")) for e in beats], [("heartbeat", "prepare")] * 2)
        started = time.monotonic()
        process.stdin.write(b"cancel\n")
        process.stdin.flush()
        events = [json.loads(line) for line in process.stdout]
        # The process itself ends with the reported code (the stdin reader
        # never holds up its exit) while the channel is still open.
        self.assertEqual(process.wait(30), 130)
        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual(events[-1], {"event": "exit", "code": 130, "cancelled": True})
        self.assertNotIn("started", [e["event"] for e in events])
        self.assertFalse((self.remote_home / "uv-ran").exists())

    def test_cleanup_runs_under_heartbeats_before_the_one_terminal_event(self):
        """A finished WorkBuddy run removes its tag and transient harness
        version (slowly here) while heartbeats continue, then reports once."""
        from scripts.eval.harbor.suites import workbuddy as wb_suite
        from scripts.eval.tests.test_bench_suites import workbuddy_checkout
        self.prepare_remote()
        uv = self.remote_home / ".local/bin/uv"
        uv.write_text("#!/bin/sh\nexit 0\n")
        uv.chmod(0o755)
        repo = self.node_checkout(workbuddy_checkout)
        spec = {"schema_version": 1, "runner": "workbuddy", "jobs_dir": "jobs", "name": "quick",
                "suite": "workbuddy-code", "model": "metask/session-model", "tasks": ["bug_fix-easy-alpha"],
                "attempts": 1, "concurrency": 1, "account_gateway": "http://127.0.0.1:9", "bundle": str(self.root / "bundle")}
        (self.remote_home / "spec.json").write_text(json.dumps(spec))
        relay = executors.find(self.cfg(), "relay-4090")
        env = {**os.environ, "FAKE_RM_DELAY": "5"}
        process = subprocess.Popen(executors.node_argv(relay, "run", "spec.json"), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, env=env)
        self.addCleanup(process.kill)
        process.stdin.write(b'{"env": {}, "credential": "access"}\n')
        process.stdin.flush()
        events = [json.loads(line) for line in process.stdout]
        self.assertEqual(process.wait(30), 0)
        kinds = [(e["event"], e.get("phase")) for e in events]
        exit_at = kinds.index(("exit", None))
        self.assertEqual(exit_at, len(events) - 1, kinds)
        self.assertEqual(events[-1], {"event": "exit", "code": 0, "cancelled": False})
        self.assertGreaterEqual(kinds[kinds.index(("started", None)):].count(("heartbeat", "finish")), 2, kinds)
        self.assertIn(["image", "rm", wb_suite.run_image_tag("quick")], [c[1] for c in self.calls("docker", "remote")])
        self.assertFalse((repo / wb_suite.HARNESS_VERSIONS / "metacodes-quick.yaml").exists())

    def test_a_workbuddy_launch_failure_cleans_up_and_reports_the_real_error(self):
        """uv breaks after the readiness check: the node removes the run's tag
        and transient harness versions, then reports why it could not start."""
        from scripts.eval.harbor.suites import workbuddy as wb_suite
        from scripts.eval.tests.test_bench_suites import workbuddy_checkout
        manager, client, _ = self.prepare_remote()
        uv = self.remote_home / ".local/bin/uv"
        uv.write_text("#!/bin/sh\nexit 0\n")
        uv.chmod(0o755)
        repo = self.node_checkout(workbuddy_checkout)
        os.environ["FAKE_BUILD_BREAKS"] = str(uv)
        spec = {"schema_version": 1, "runner": "workbuddy", "jobs_dir": "jobs", "name": "broken",
                "suite": "workbuddy-code", "model": "metask/session-model", "tasks": ["bug_fix-easy-alpha"],
                "attempts": 1, "concurrency": 1, "account_gateway": "http://127.0.0.1:9", "bundle": str(self.root / "bundle")}
        (self.remote_home / "spec.json").write_text(json.dumps(spec))
        relay = executors.find(self.cfg(), "relay-4090")
        process = subprocess.Popen(executors.node_argv(relay, "run", "spec.json"), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE)
        self.addCleanup(process.kill)
        process.stdin.write(b'{"env": {}, "credential": "access"}\n')
        process.stdin.flush()
        events = [json.loads(line) for line in process.stdout]
        self.assertEqual(process.wait(30), 2)
        self.assertNotIn("started", [e["event"] for e in events])
        self.assertEqual(events[-1]["event"], "error", events)
        self.assertIn("启动失败", events[-1]["message"])
        self.assertIn(str(uv), events[-1]["message"])
        self.assertIn(["image", "rm", wb_suite.run_image_tag("broken")], [c[1] for c in self.calls("docker", "remote")])
        self.assertEqual(list((repo / wb_suite.HARNESS_VERSIONS).glob("metacodes-broken*")), [])
        self.assertEqual(list((repo / "configs").rglob("metacodes-broken*")), [])
        # Through the worker, the run fails with that reason, not a lost channel.
        uv.chmod(0o755)
        run = client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                          "tasks": ["bug_fix-easy-alpha"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"], timeout=60)
        self.assertEqual(final["status"], "failed", final)
        self.assertIn("启动失败", final["error"])
        self.assertNotIn("SSH 连接中断", final["error"])
        self.assertEqual(list((repo / "configs").rglob("metacodes-" + run["name"] + "*")), [])

    def test_a_stale_node_overlay_refuses_a_workbuddy_run_with_gates(self):
        from scripts.eval.harbor.suites import workbuddy as wb_suite
        from scripts.eval.tests.test_bench_suites import workbuddy_checkout
        manager, client, _ = self.prepare_remote()
        uv = self.remote_home / ".local/bin/uv"
        uv.write_text("#!/bin/sh\nexit 0\n")
        uv.chmod(0o755)
        repo = self.node_checkout(workbuddy_checkout)
        (repo / wb_suite.AGENT).write_text("# an older overlay\n")
        run = client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                          "tasks": ["bug_fix-easy-alpha"], "executor": "relay-4090",
                                          "features": ["stall_gate"]})
        final = wait_run(manager, run["name"], timeout=60)
        self.assertEqual(final["status"], "failed", final)
        self.assertIn("install_overlay", final["error"])
        self.assertEqual(list((repo / "configs").rglob("metacodes-" + run["name"] + "*")), [])

    def test_registry_suite_runs_on_ssh_executor_into_the_store(self):
        """A registry suite on an SSH executor is downloaded on the workbench
        machine (cached per reference), shipped by content digest and run
        with `-p` and bare task names."""
        manager, client, _ = self.prepare_remote()
        downloads = self.root / "downloads.log"
        os.environ.update(FAKE_EXPECT_ACCOUNT_KEY="session-access", FAKE_HARBOR_DOWNLOAD_LOG=str(downloads))
        remote_root = (self.remote_home / ".metacodes-bench").resolve()
        cache = self.state / "bench" / "registry-cache" / executors.registry_cache_key("aime@1.0")
        names = []
        for suite_id, tasks in (("aime-2025", ["aime_i-1", "aime_ii-15"]), ("aime", ["aime_60"])):
            run = client.request("api/runs", {"suite": suite_id, "model": "metask/session-model",
                                              "tasks": tasks, "executor": "relay-4090"})
            self.assertEqual((run["suite"], run["executor"]), (suite_id, "relay-4090"))
            final = wait_run(manager, run["name"])
            self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
            argv = json.loads((manager.jobs_dir / run["name"] / "argv.json").read_text())
            self.assertNotIn("-d", argv)
            digest = executors.tree_digest(cache / "aime", executors.tree_files(cache / "aime"))
            self.assertEqual(argv[argv.index("-p") + 1], str(remote_root / "datasets" / digest))
            self.assertEqual([argv[i + 1] for i, a in enumerate(argv) if a == "-i"], tasks)
            names.append(run["name"])
        # Both suites share aime@1.0: one download, one shipped copy.
        self.assertEqual(downloads.read_text().split(), ["aime@1.0"])
        self.assertEqual(len(list((cache / "aime").iterdir())), 60)
        self.assertEqual(len([p for p in (remote_root / "datasets").iterdir()]), 1)
        log = data.tail(manager.records / (names[1] + ".log"))
        self.assertIn("复用工作台已下载的注册表数据集 aime@1.0", log)
        # Synced back, ingested by the worker: the store serves it without files.
        shutil.rmtree(manager.jobs_dir / names[0])
        view = client.request("api/job?name=" + names[0])
        self.assertEqual((view["suite"], view["category_name"]), ("aime-2025", "竞赛数学"))
        self.assertEqual(view["summary"]["counts"]["pass"], 1)

    def test_hub_suite_on_ssh_executor_drops_the_org_prefix(self):
        manager, client, _ = self.prepare_remote()
        run = client.request("api/runs", {"model": "metask/session-model", "tasks": ["fix-git", "kv-store-grpc"],
                                          "executor": "relay-4090"})
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        argv = json.loads((manager.jobs_dir / run["name"] / "argv.json").read_text())
        # `-d` matched `terminal-bench/fix-git`; the exported `-p` copy names it `fix-git`.
        self.assertEqual([argv[i + 1] for i, a in enumerate(argv) if a == "-i"], ["fix-git", "kv-store-grpc"])
        shipped = Path(argv[argv.index("-p") + 1])
        self.assertEqual(len([p for p in shipped.iterdir() if (p / "task.toml").is_file()]), 89)

    def test_incomplete_download_or_missing_workbench_harbor_refuses_the_run(self):
        manager, client, _ = self.prepare_remote()
        os.environ["FAKE_HARBOR_DOWNLOAD_DROP"] = "1"
        run = client.request("api/runs", {"suite": "aime", "model": "metask/session-model",
                                          "tasks": ["aime_60"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "failed")
        self.assertIn("有 59 道任务，缺少 1 道", final["error"])
        self.assertFalse((self.remote_home / ".metacodes-bench/jobs" / run["name"]).exists())
        self.assertEqual(list((self.state / "bench/registry-cache").iterdir()), [])  # nothing half-cached
        # Without Harbor on the workbench machine, registry suites are not ready there.
        cfg = self.cfg()
        cfg.pop("harbor")
        atomic_json(self.config, cfg)
        catalog = client.request("api/workbench")
        aime = next(s for s in catalog["suites"] if s["id"] == "aime")
        self.assertTrue(any("工作台本机缺少 Harbor" in r for r in aime["executors"]["relay-4090"]["reasons"]))

    def test_harbor_local_suite_ships_its_dataset_to_the_ssh_executor(self):
        manager, client, _ = self.prepare_remote()
        dataset = self.harbor_local_suite()
        remote_harbor = self.remote_home / ".local/bin/harbor"
        remote_harbor.write_text(remote_harbor.read_text().replace(
            "(root / 'argv.json').write_text(json.dumps(args))",
            "(root / 'argv.json').write_text(json.dumps(args))\n"
            "(root / 'judge.json').write_text(json.dumps(os.environ.get('FAKE_JUDGE_KEY')))"))
        os.environ.update(FAKE_EXPECT_ACCOUNT_KEY="session-access", FAKE_JUDGE_KEY="judge-secret")
        catalog = client.request("api/workbench")
        humaneval = next(s for s in catalog["suites"] if s["id"] == "humaneval")
        self.assertTrue(humaneval["executors"]["relay-4090"]["ready"], humaneval["executors"]["relay-4090"])
        names = []
        for _ in range(2):
            run = client.request("api/runs", {"suite": "humaneval", "model": "metask/session-model",
                                              "tasks": ["humaneval-7"], "executor": "relay-4090"})
            final = wait_run(manager, run["name"])
            self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
            names.append(run["name"])
        remote_root = (self.remote_home / ".metacodes-bench").resolve()
        digest = executors.tree_digest(dataset, executors.tree_files(dataset))
        for name in names:
            argv = json.loads((manager.jobs_dir / name / "argv.json").read_text())
            self.assertEqual(argv[argv.index("-p") + 1], str(remote_root / "datasets" / digest))
            self.assertEqual([argv[i + 1] for i, a in enumerate(argv) if a == "-i"], ["humaneval-7"])
            # The judge key reached the remote Harbor over the SSH stdin only.
            self.assertEqual(json.loads((manager.jobs_dir / name / "judge.json").read_text()), "judge-secret")
        shipped = remote_root / "datasets" / digest
        self.assertEqual((shipped / "humaneval-7/tests/test.sh").read_text(), "exit 0\n")
        self.assertEqual([p.name for p in (remote_root / "datasets").iterdir()], [digest])  # shipped once
        for row in self.calls("ssh"):
            self.assertNotIn("judge-secret", json.dumps(row))
        for path in list(self.remote_home.rglob("*")) + list(manager.records.iterdir()):
            if path.is_file() and path.name != "judge.json":
                self.assertNotIn(b"judge-secret", path.read_bytes(), path)
        spec = json.loads((manager.records / (names[0] + ".spec")).read_text())
        self.assertEqual(spec["forward_env"], ["FAKE_JUDGE_KEY"])
        self.assertEqual(spec["local_dataset"], str(dataset.resolve()))

    def test_gaia2_judge_on_ssh_executor_uses_the_remote_relay_and_placeholders_only(self):
        manager, client, calls = self.prepare_remote()
        dataset = gaia2_dataset(self.root)
        cfg = self.cfg()
        cfg["datasets"] = {"gaia2-cli": str(dataset)}
        atomic_json(self.config, cfg)
        # A judge key on the workbench stays there: the relay route replaces it.
        os.environ.update(FAKE_JUDGE_REQUEST="1", OPENAI_API_KEY="real-openai-key")
        run = client.request("api/runs", {"suite": "gaia2-cli", "model": "metask/session-model",
                                          "tasks": ["gaia2-search-0000-abc"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        self.assertEqual(final["judge"], {"model": "glm-5.3-flash", "via": "metask"})
        local = manager.jobs_dir / run["name"]
        argv = json.loads((local / "argv.json").read_text())
        relay = next(a.removeprefix("metrics_proxy=") for a in argv if a.startswith("metrics_proxy="))
        verifier = json.loads((local / "verifier-env.json").read_text())
        self.assertEqual(verifier["OPENAI_BASE_URL"], relay + "/bench-judge/v1")
        self.assertEqual((verifier["JUDGE_MODEL"], verifier["SSL_CERT_FILE"]),
                         ("glm-5.3-flash", "/usr/local/share/metacodes-bench/ca-bundle.pem"))
        self.assertTrue(verifier["OPENAI_API_KEY"].startswith("mcb-"))
        self.assertNotEqual(verifier["OPENAI_API_KEY"], json.loads((local / "container-env.json").read_text())["METASK_API_KEY"])
        self.assertEqual(json.loads((local / "judge-statuses.json").read_text()),
                         {"judge": [200, "GRADE: yes"], "agent-token": [403, None]})
        self.assertIn(("judge-request", "Bearer session-access",
                       {"model": "glm-5.3-flash", "messages": [{"role": "user", "content": "grade"}]}), calls)
        self.assertFalse(any(isinstance(c[1], str) and "mcb-" in c[1] for c in calls), calls)
        spec = json.loads((manager.records / (run["name"] + ".spec")).read_text())
        self.assertEqual(spec["forward_env"], [])  # no judge key travels
        for row in self.calls("ssh"):
            self.assertNotIn("session-access", json.dumps(row))
            self.assertNotIn("real-openai-key", json.dumps(row))
        for path in [p for p in self.remote_home.rglob("*") if p.is_file()] + list(manager.records.iterdir()) \
                + [p for p in local.rglob("*") if p.is_file()]:
            content = path.read_bytes()
            self.assertNotIn(b"session-access", content, path)
            self.assertNotIn(b"real-openai-key", content, path)

    def test_real_adapter_suites_ship_their_tasks_but_not_the_download_cache(self):
        from scripts.eval.harbor.bench.runner import settings
        from scripts.eval.tests.test_bench_suites import ADAPTER_IDS, offline_adapter_sources

        manager, client, _ = self.prepare_remote()
        os.environ["FAKE_EXPECT_ACCOUNT_KEY"] = "session-access"
        prepared = {}
        with offline_adapter_sources(self.root / "sources"):
            for suite_id in ADAPTER_IDS:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(cli.main(["prepare", "--state-root", str(self.state), "--suite", suite_id,
                                               "--json"]), 0)
                prepared[suite_id] = Path(json.loads(out.getvalue())["dataset"])
        cfg = settings(self.config)
        cfg["datasets"] = {k: str(v) for k, v in prepared.items()}
        atomic_json(self.config, cfg)
        remote_root = (self.remote_home / ".metacodes-bench").resolve()
        by_id = {s["id"]: s for s in client.request("api/workbench")["suites"]}
        for suite_id, dataset in prepared.items():
            with self.subTest(suite=suite_id):
                self.assertTrue(by_id[suite_id]["executors"]["relay-4090"]["ready"],
                                by_id[suite_id]["executors"]["relay-4090"])
                # prepare() keeps downloads in <dataset>/.cache/; they stay local.
                (dataset / ".cache").mkdir(exist_ok=True)
                (dataset / ".cache" / "download.bin").write_bytes(b"x" * 1024)
                task = client.request("api/suite?id=" + suite_id)["tasks"][0]
                run = client.request("api/runs", {"suite": suite_id, "model": "metask/session-model",
                                                  "tasks": [task], "executor": "relay-4090"})
                final = wait_run(manager, run["name"])
                self.assertEqual(final["status"], "finished", data.tail(manager.records / (run["name"] + ".log")))
                argv = json.loads((manager.jobs_dir / run["name"] / "argv.json").read_text())
                shipped = Path(argv[argv.index("-p") + 1])
                self.assertEqual(shipped.parent, remote_root / "datasets")
                self.assertEqual([argv[i + 1] for i, a in enumerate(argv) if a == "-i"], [task])
                self.assertTrue((shipped / task / "task.toml").is_file())
                self.assertFalse((shipped / ".cache").exists())
                self.assertEqual(sorted(p.name for p in shipped.iterdir() if not p.name.startswith(".")),
                                 sorted(p.name for p in dataset.iterdir() if not p.name.startswith(".")))

    def test_harbor_local_suite_without_a_local_dataset_is_not_ready_anywhere(self):
        manager, client, _ = self.prepare_remote()
        self.harbor_local_suite()
        cfg = self.cfg()
        cfg["datasets"] = {"humaneval": str(self.root / "missing")}
        atomic_json(self.config, cfg)
        catalog = client.request("api/workbench")
        humaneval = next(s for s in catalog["suites"] if s["id"] == "humaneval")
        reasons = humaneval["executors"]["relay-4090"]["reasons"]
        self.assertTrue(any("bench prepare --suite humaneval" in r for r in reasons), reasons)
        with self.assertRaisesRegex(ValueError, "bench prepare"):
            client.request("api/runs", {"suite": "humaneval", "model": "metask/session-model",
                                        "tasks": ["humaneval-7"], "executor": "relay-4090"})


@unittest.skipUnless(POSIX, "fake executables are POSIX shell scripts")
class SetupHttpTest(SetupFixture):
    def setUp(self):
        super().setUp()
        self.manager = RunManager(self.state / "bench/jobs", self.config)
        http = server.make_server(Workbench(data.Library([self.manager.jobs_dir]), self.manager), "127.0.0.1", 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        self.url = f"http://127.0.0.1:{http.server_address[1]}/"
        self.client = cli.Client(self.url)

    def test_setup_endpoint_requires_same_origin(self):
        request = urllib.request.Request(self.url + "api/setup", data=b'{"dry_run": true}', headers={
            "Content-Type": "application/json", "Origin": "https://evil.example"})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request)
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()
        with self.assertRaisesRegex(ValueError, "只接受"):
            self.client.request("api/setup", {"command": "rm -rf /"})
        self.assertFalse((self.state / "bench/setup").exists())

    def test_page_setup_runs_in_background_with_live_steps(self):
        started = self.client.request("api/setup", {"dry_run": True})
        self.assertEqual((started["executor"], started["dry_run"]), ("local", True))
        deadline = time.monotonic() + 60
        while True:
            latest = self.client.request("api/setup")["setup"]
            if latest and latest["status"] != "running":
                break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.2)
        self.assertEqual(latest["status"], "planned", latest)
        self.assertEqual([s["id"] for s in latest["steps"]], ["uv", "harbor", "docker", "openssl", "bundle", "psycopg", "login"])
        self.assertIn("brew install uv", [c["command"] for c in latest["steps"][0]["commands"]])
        self.assertEqual([c for c in self.calls("brew") if c[1][:1] == ["install"]], [])

    def test_launch_and_a_changing_setup_exclude_each_other(self):
        setups = self.state / "bench" / "setup"
        setups.mkdir(parents=True)
        progress = setups / "20261118-000000-abcdef.json"
        atomic_json(progress, {"schema_version": 1, "id": "x", "executor": "local", "dry_run": False,
                               "status": "running", "steps": []})
        with self.assertRaisesRegex(ValueError, "一键配置正在进行"):
            self.client.request("api/runs", {"model": "tokenjoy/test-model", "tasks": ["fix-git"]})
        with self.assertRaisesRegex(ValueError, "一键配置正在进行"):
            self.manager.launch({"model": "tokenjoy/test-model", "tasks": ["fix-git"]})
        # A dry run changes nothing and does not block a launch.
        atomic_json(progress, {**json.loads(progress.read_text()), "dry_run": True})
        self.assertFalse(self.manager.setup_running())
        atomic_json(progress, {**json.loads(progress.read_text()), "dry_run": False, "status": "ready"})
        self.assertFalse(self.manager.setup_running())
        # And the other way round: an active run refuses a changing setup.
        records = self.manager.records
        atomic_json(records / "bench-live.json", {"name": "bench-live", "status": "running"})
        with self.assertRaisesRegex(ValueError, "有评测正在运行"):
            self.client.request("api/setup", {})

    def test_login_shows_device_code_from_metacodes_login(self):
        cfg = self.cfg()
        cfg.update(auth_mode="metask", account_state_dir=str(self.root / "account"))
        atomic_json(self.config, cfg)
        catalog = self.client.request("api/workbench")
        self.assertEqual(catalog["login"], {"available": True, "signed_in": False})
        self.client.request("api/login", {})
        deadline = time.monotonic() + 15
        while True:
            status = self.client.request("api/login")
            if not status["running"] and status["verification_uri"]:
                break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.1)
        self.assertEqual((status["verification_uri"], status["user_code"]), ("https://example.invalid/device", "ABCD-1234"))
        self.assertEqual(self.calls("metacodes")[0][1],
                         ["--state-dir", str(self.root / "account"), "login", "--provider", "metask", "--no-browser"])
        # A restarted service has no sign-in of its own: the earlier log's
        # expired device code is not shown as an unfinished sign-in.
        fresh = setup.LoginManager(self.config)
        self.assertTrue(fresh.log_path.exists())
        self.assertEqual(fresh.status(), {"running": False, "exit_code": None, "verification_uri": None,
                                          "user_code": None, "signed_in": False})


def echo_server():
    """A loopback TCP echo server: (port, close)."""
    import socket
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)

    def serve():
        while True:
            try:
                conn, _ = listener.accept()
            except OSError:
                return

            def echo(c=conn):
                with c:
                    while True:
                        chunk = c.recv(4096)
                        if not chunk:
                            return
                        c.sendall(chunk)
            threading.Thread(target=echo, daemon=True).start()
    threading.Thread(target=serve, daemon=True).start()
    from scripts.eval.harbor.bench.egress import stop_listening
    return listener.getsockname()[1], partial(stop_listening, listener)


def proxy_request(port, head, payload=b""):
    """Send a raw request to the proxy; (first response line, socket)."""
    import socket
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.sendall(head.encode() + payload)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    head_bytes, _, rest = data.partition(b"\r\n\r\n")
    return head_bytes.split(b"\r\n")[0].decode(), sock, rest


class EgressUnitTest(unittest.TestCase):
    def test_forwarder_relays_bytes_end_to_end(self):
        import socket
        from scripts.eval.harbor.bench import egress
        port, close = echo_server()
        self.addCleanup(close)
        with egress.Forwarder("127.0.0.1", ("127.0.0.1", port)) as forwarder:
            with socket.create_connection(forwarder.address, timeout=10) as sock:
                payload = os.urandom(200 * 1024)
                sender = threading.Thread(target=sock.sendall, args=(payload,))
                sender.start()
                received = b""
                while len(received) < len(payload):
                    received += sock.recv(65536)
                sender.join()
        self.assertEqual(received, payload)

    def test_a_closed_listener_stops_accepting_and_its_thread_ends(self):
        import socket
        from scripts.eval.harbor.bench import egress
        port, close = echo_server()
        self.addCleanup(close)
        forwarder = egress.Forwarder("127.0.0.1", ("127.0.0.1", port)).start()
        address = forwarder.address
        forwarder.close()
        forwarder.thread.join(timeout=5)
        self.assertFalse(forwarder.thread.is_alive())
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(address, timeout=5).close()

    @unittest.skipUnless(hasattr(signal, "pthread_kill"), "needs POSIX thread signals")
    def test_a_closed_listener_never_takes_connections_of_a_socket_that_reuses_its_descriptor(self):
        import socket
        from scripts.eval.harbor.bench import egress
        port, close = echo_server()
        self.addCleanup(close)
        forwarder = egress.Forwarder("127.0.0.1", ("127.0.0.1", port)).start()
        time.sleep(0.2)
        descriptor = forwarder.sock.fileno()
        forwarder.close()
        forwarder.thread.join(timeout=5)
        held = []
        self.addCleanup(lambda: [sock.close() for sock in held])
        later = None
        for _ in range(1024):
            sock = socket.socket()
            held.append(sock)
            if sock.fileno() == descriptor:
                later = sock
                break
            if sock.fileno() > descriptor:
                break
        if later is None:
            self.skipTest("another thread took the closed listener's descriptor")
        later.bind(("127.0.0.1", 0))
        later.listen(1)
        if forwarder.thread.is_alive():
            previous = signal.signal(signal.SIGUSR1, lambda *_args: None)
            self.addCleanup(signal.signal, signal.SIGUSR1, previous)
            signal.siginterrupt(signal.SIGUSR1, False)
            with contextlib.suppress(ProcessLookupError):
                signal.pthread_kill(forwarder.thread.ident, signal.SIGUSR1)
            time.sleep(0.2)
        with socket.create_connection(later.getsockname(), timeout=5):
            time.sleep(0.5)
            later.setblocking(False)
            try:
                conn, _ = later.accept()
            except BlockingIOError:
                self.fail("the closed forwarder's accept thread took a connection meant for the socket "
                          "that reused its descriptor")
        conn.close()

    def test_proxy_tunnels_allowed_ports_and_refuses_the_rest(self):
        from scripts.eval.harbor.bench import egress
        port, close = echo_server()
        self.addCleanup(close)
        # A permissive address check, so the loopback echo server can stand
        # in for a public host; ports are still enforced.
        with egress.EgressProxy([port], allow=lambda _a: True) as proxy:
            line, sock, _ = proxy_request(proxy.port, f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\nHost: x\r\n\r\n")
            self.assertEqual(line, "HTTP/1.1 200 Connection established")
            sock.sendall(b"through the tunnel")
            self.assertEqual(sock.recv(100), b"through the tunnel")
            sock.close()
            line, sock, _ = proxy_request(proxy.port, "CONNECT 127.0.0.1:22 HTTP/1.1\r\n\r\n")
            sock.close()
            self.assertTrue(line.startswith("HTTP/1.1 403"), line)
            # A compose service name is refused at once, without a lookup.
            def resolve(*_args):
                raise AssertionError("single-label names are never resolved")
            proxy.resolve = resolve
            line, sock, rest = proxy_request(proxy.port, f"GET http://alfworld-env:{port}/step HTTP/1.1\r\n\r\n")
            sock.close()
            self.assertTrue(line.startswith("HTTP/1.1 502"), line)
            self.assertIn(b"NO_PROXY", rest)
            self.assertEqual(proxy.counts["connect"], 1)
            self.assertEqual(proxy.counts["refused"], 2)
        # The default policy: public unicast only, no exceptions.
        for address in ("127.0.0.1", "10.126.126.2", "192.168.5.2", "172.17.0.1", "169.254.169.254",
                        "100.64.0.1", "::1", "fe80::1", "::ffff:127.0.0.1", "0.0.0.0", "224.0.0.1"):
            self.assertFalse(egress.address_allowed(address), address)
        self.assertTrue(egress.address_allowed("151.101.0.223"))
        # A fake-IP resolver on the workbench machine (the real devbox-mac
        # answers deb.debian.org with 198.18.3.108) must still reach the
        # outside: the default policy adds 198.18.0.0/15 and nothing else.
        policy = egress.allow_policy()
        self.assertTrue(policy("198.18.3.108"))
        self.assertTrue(policy("198.19.255.1"))
        self.assertTrue(policy("151.101.0.223"))
        for address in ("127.0.0.1", "10.126.126.2", "192.168.5.2", "172.17.0.1", "169.254.169.254", "::1"):
            self.assertFalse(policy(address), address)
        self.assertFalse(egress.allow_policy(())("198.18.3.108"))
        self.assertFalse(egress.allow_policy(["127.0.0.0/8"])("127.0.0.1"))  # never loopback
        with self.assertRaises(ValueError):
            executors.parse({"name": "x", "kind": "ssh", "host": "h", "egress_allow": ["127.0.0.0/8"]})
        parsed = executors.parse({"name": "x", "kind": "ssh", "host": "h", "egress": "workbench",
                                  "egress_allow": ["198.18.0.0/15", "203.0.113.0/24"]})
        self.assertEqual(parsed.egress_allow, ("198.18.0.0/15", "203.0.113.0/24"))
        self.assertEqual(parsed.spec()["egress_allow"], ["198.18.0.0/15", "203.0.113.0/24"])
        with egress.EgressProxy() as proxy:
            proxy.resolve = lambda *_a: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("198.18.3.108", 80))]
            proxy.connect_timeout = 0.2  # nothing listens there; only the policy is under test
            try:
                proxy.destination("deb.debian.org", 80).close()
                refused = ""
            except egress.Refused as exc:
                refused = str(exc)
            self.assertNotIn("non-public", refused)
        with egress.EgressProxy() as proxy:
            for target, status in (("127.0.0.1:443", "403"), (f"127.0.0.1:{port}", "403"), ("[::1]:443", "403"),
                                   ("localhost:443", "502")):
                line, sock, _ = proxy_request(proxy.port, f"CONNECT {target} HTTP/1.1\r\n\r\n")
                sock.close()
                self.assertTrue(line.startswith("HTTP/1.1 " + status), (target, line))

    def test_plain_http_is_forwarded_in_origin_form_without_proxy_credentials(self):
        from http.server import BaseHTTPRequestHandler
        from scripts.eval.harbor.bench import egress
        seen = []

        class Origin(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, dict(self.headers)))
                body = b"origin says hi"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass
        origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
        self.addCleanup(origin.server_close)
        self.addCleanup(origin.shutdown)
        port = origin.server_address[1]
        with egress.EgressProxy([port], allow=lambda _a: True) as proxy:
            line, sock, rest = proxy_request(
                proxy.port, f"GET http://127.0.0.1:{port}/simple/pip/?x=1 HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                            "Proxy-Authorization: Basic c2VjcmV0\r\nProxy-Connection: keep-alive\r\n\r\n")
            while not rest.endswith(b"origin says hi"):
                chunk = sock.recv(4096)
                if not chunk:
                    break
                rest += chunk
            sock.close()
        self.assertEqual((line, rest), ("HTTP/1.0 200 OK", b"origin says hi"))
        path, headers = seen[0]
        self.assertEqual(path, "/simple/pip/?x=1")
        self.assertNotIn("Proxy-Authorization", headers)
        self.assertEqual(headers.get("Connection"), "close")

    def test_docker_config_holds_only_proxies_and_noproxy_names_relay_and_services(self):
        from scripts.eval.harbor.bench import egress
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        home = root / "home"
        (home / ".docker/cli-plugins").mkdir(parents=True)
        user_config = home / ".docker/config.json"
        user_config.write_text('{"auths": {"ghcr.io": {"auth": "c3RhbGU="}}}')
        before = user_config.read_bytes()
        dataset = root / "dataset"
        (dataset / "alfworld-1/environment").mkdir(parents=True)
        (dataset / "alfworld-1/environment/docker-compose.yaml").write_text(
            "services:\n  main:\n    build: .\n  alfworld-env:  # the sidecar\n    image: ghcr.io/x/alf:1\n"
            "    environment:\n      PORT: 8080\nnetworks:\n  inner: {}\n")
        (dataset / "alfworld-1/environment/Dockerfile").write_text(
            "FROM --platform=linux/amd64 ghcr.io/laude-institute/base:2025 AS build\nFROM ubuntu:24.04\n")
        (dataset / "other/environment").mkdir(parents=True)
        (dataset / "other/environment/Dockerfile").write_text("FROM ghcr.io/not/selected:1\n")
        self.assertEqual(egress.task_services(dataset, ["alfworld-1"]), ["main", "alfworld-env"])
        self.assertEqual(egress.ghcr_images(dataset, ["alfworld-1"]),
                         ["ghcr.io/laude-institute/base:2025", "ghcr.io/x/alf:1"])
        run_dir = root / "run"
        run_dir.mkdir()
        session = egress.Session({"mode": "proxy", "url": "http://proxy.corp:3128", "no_proxy": ["172.17.0.1"]},
                                 run_dir, ["10.0.0.5", *egress.task_services(dataset, ["alfworld-1"])], home=home)
        written = json.loads((session.directory / "config.json").read_text())
        self.assertEqual(set(written), {"proxies", "cliPluginsExtraDirs"})
        self.assertEqual(written["cliPluginsExtraDirs"], [str(home / ".docker/cli-plugins")])
        default = written["proxies"]["default"]
        self.assertEqual((default["httpProxy"], default["httpsProxy"]), ("http://proxy.corp:3128",) * 2)
        self.assertEqual(default["noProxy"].split(","),
                         ["localhost", "127.0.0.1", "::1", "10.0.0.5", "main", "alfworld-env", "172.17.0.1"])
        session.close()
        self.assertFalse(session.directory.exists())
        self.assertEqual(user_config.read_bytes(), before)


class EgressRunTest(SetupFixture):
    prepare_remote = SshRunTest.prepare_remote
    harbor_local_suite = SuiteOnExecutorTest.harbor_local_suite

    def egress_executor(self, **fields):
        cfg = self.cfg()
        entry = next(e for e in cfg["executors"] if e["name"] == "relay-4090")
        entry.update(fields)
        atomic_json(self.config, cfg)

    def test_workbench_egress_carries_reverse_forward_and_run_scoped_docker_config(self):
        manager, client, _ = self.prepare_remote()
        dataset = self.harbor_local_suite()
        (dataset / "humaneval-7/environment").mkdir()
        (dataset / "humaneval-7/environment/docker-compose.yaml").write_text(
            "services:\n  main:\n    build: .\n  judge-sidecar:\n    image: python:3.12\n")
        self.egress_executor(egress="workbench")
        # The shared user's own docker config on the executor (with a stale
        # credential) is never read, copied or changed.
        user_config = self.remote_home / ".docker/config.json"
        user_config.parent.mkdir()
        user_config.write_text('{"auths": {"ghcr.io": {"auth": "c3RhbGU="}}}')
        before = user_config.read_bytes()
        os.environ["FAKE_EGRESS_FETCH"] = "1"
        run = client.request("api/runs", {"suite": "humaneval", "model": "metask/session-model",
                                          "tasks": ["humaneval-7"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"], timeout=60)
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        session = next(c[1] for c in self.calls("ssh") if " node run " in c[1][-1])
        forward = session[session.index("-R") + 1]
        self.assertRegex(forward, r"^127\.0\.0\.1:\d+:127\.0\.0\.1:\d+$")
        self.assertIn("ExitOnForwardFailure=yes", session)
        # Only the run session carries the forward.
        self.assertEqual([c for c in self.calls("ssh") if "-R" in c[1] and " node run " not in c[1][-1]], [])
        local = manager.jobs_dir / run["name"]
        harbor_env = json.loads((local / "harbor-env.json").read_text())
        self.assertEqual(harbor_env["TZ"], "UTC")
        docker_config = Path(harbor_env["DOCKER_CONFIG"])
        self.assertEqual(docker_config.parent, (self.remote_home / ".metacodes-bench/runs" / run["name"]).resolve())
        self.assertFalse(docker_config.exists())  # removed after the run
        written = json.loads((local / "docker-config.json").read_text())
        self.assertNotIn("auths", written)
        default = written["proxies"]["default"]
        # The forwarder binds the host's docker0 gateway, else metrics_bind.
        from scripts.eval.harbor.bench import egress as egress_module
        gateway = egress_module.docker_gateway() or "127.0.0.1"
        self.assertRegex(default["httpProxy"], r"^http://" + re.escape(gateway) + r":\d+$")
        no_proxy = default["noProxy"].split(",")
        for host in ("localhost", "127.0.0.1", "main", "judge-sidecar"):
            self.assertIn(host, no_proxy)
        # container -> forwarder -> ssh -R -> the workbench proxy, end to end.
        self.assertEqual((local / "egress-probe.txt").read_bytes(), b"metacodes-bench-egress-ok")
        self.assertEqual(user_config.read_bytes(), before)
        self.assertFalse((self.home / ".docker/config.json").exists())
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertIn("出网代理已停止", log)

    def test_setup_hands_a_running_run_to_a_new_driver_without_stopping_it(self):
        """Setup after a node update (its `runs` step): Harbor goes on, the
        worker follows the new driver, and a model request and a container
        fetch after the switch go through the relay and forwarder it took
        over, with the CA and proxy address Harbor got at start."""
        manager, client, _ = self.prepare_remote(profile=True)
        self.harbor_local_suite()
        self.egress_executor(egress="workbench")
        release = self.root / "harbor-release"
        os.environ.update(FAKE_EGRESS_FETCH="1", FAKE_LATE_TRAFFIC="1", FAKE_BENCH_RELEASE_FILE=str(release))
        run = client.request("api/runs", {"suite": "humaneval", "model": "metask/session-model",
                                          "tasks": ["humaneval-7"], "executor": "relay-4090"})
        remote_job = self.remote_home / ".metacodes-bench/jobs" / run["name"]
        deadline = time.monotonic() + 60
        while not (remote_job / "egress-probe.txt").exists():
            self.assertLess(time.monotonic(), deadline, data.tail(manager.records / (run["name"] + ".log")))
            time.sleep(0.1)
        run_dir = self.remote_home / ".metacodes-bench/runs" / run["name"]
        before = (run_dir / remote.DRIVER_PID).read_text()
        progress = setup.Setup(self.config, "relay-4090").execute([("runs", "正在运行的评测", setup.step_runs)])
        step = progress["steps"][0]
        self.assertEqual((step["status"], step["detail"]), ("done", "1 个运行已换用新版本驱动"), step)
        self.assertNotEqual((run_dir / remote.DRIVER_PID).read_text(), before)
        release.touch()
        final = wait_run(manager, run["name"], timeout=60)
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertEqual((final["status"], final["exit_code"]), ("finished", 0), (final, log))
        self.assertIn("驱动已换成新版本", log)
        late = json.loads((manager.jobs_dir / run["name"] / "late-traffic.json").read_text())
        self.assertEqual((late["relay"], late["egress"]), (200, "metacodes-bench-egress-ok"), late)
        self.assertFalse((run_dir / remote.RELAY_TLS).exists())

    def run_refusing_forwards(self, refused, **env):
        manager, client, _ = self.prepare_remote()
        self.harbor_local_suite()
        self.egress_executor(egress="workbench")
        refusals = self.root / "refused-forwards"
        refusals.write_text(str(refused))
        os.environ.update(FAKE_REFUSED_FORWARDS=str(refusals), **env)
        run = client.request("api/runs", {"suite": "humaneval", "model": "metask/session-model",
                                          "tasks": ["humaneval-7"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"], timeout=60)
        sessions = [c[1] for c in self.calls("ssh") if "-R" in c[1]]
        self.assertTrue(all(" node run " in session[-1] for session in sessions), sessions)
        ports = [int(session[session.index("-R") + 1].split(":")[1]) for session in sessions]
        self.assertEqual(len(set(ports)), len(ports), ports)
        self.assertTrue(all(20000 <= port < LOWEST_EPHEMERAL_PORT for port in ports), ports)
        return manager, run["name"], final, ports, int(refusals.read_text())

    def test_a_refused_attach_forward_attaches_again_and_never_starts_the_run_twice(self):
        manager, client, _ = self.prepare_remote()
        self.harbor_local_suite()
        self.egress_executor(egress="workbench")
        drops, refusals = self.root / "drops", self.root / "refused-attach-forwards"
        drops.write_text("1")
        refusals.write_text("1")
        os.environ.update(FAKE_SSH_DROPS=str(drops), FAKE_SSH_DROP_AFTER="0", FAKE_SSH_DROP_SILENT="1",
                          FAKE_REFUSED_ATTACH_FORWARDS=str(refusals), FAKE_BENCH_DELAY="4")
        run = client.request("api/runs", {"suite": "humaneval", "model": "metask/session-model",
                                          "tasks": ["humaneval-7"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"], timeout=90)
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertEqual((final["status"], final["exit_code"]), ("finished", 0), (final, log))
        self.assertEqual(refusals.read_text(), "0")
        actions = [re.search(r" node (run|attach) ", c[1][-1]).group(1) for c in self.calls("ssh")
                   if re.search(r" node (run|attach) ", c[1][-1])]
        self.assertEqual(actions.count("run"), 1, actions)
        self.assertGreaterEqual(actions.count("attach"), 2, actions)
        sessions = [c[1] for c in self.calls("ssh") if "-R" in c[1]]
        ports = [int(session[session.index("-R") + 1].split(":")[1]) for session in sessions]
        self.assertEqual(len(set(ports)), len(ports), ports)

    def test_a_refused_tunnel_port_is_retried_on_another_one_and_the_run_finishes(self):
        manager, name, final, ports, left = self.run_refusing_forwards(1, FAKE_EGRESS_FETCH="1")
        log = data.tail(manager.records / (name + ".log"))
        self.assertEqual(final["status"], "finished", (final, log))
        self.assertEqual(left, 0)
        self.assertGreaterEqual(len(ports), 2)
        self.assertIn(f"Error: remote port forwarding failed for listen port {ports[0]}", log)
        relay = executors.find(self.cfg(), "relay-4090")
        self.assertIn(executors.tunnel_retry_note(relay, ports[0], ports[1], 2), log)
        self.assertEqual((manager.jobs_dir / name / "egress-probe.txt").read_bytes(), b"metacodes-bench-egress-ok")

    def test_a_tunnel_refused_on_every_port_fails_the_run_with_the_executor_side_cause(self):
        _, _, final, ports, left = self.run_refusing_forwards(100)
        self.assertEqual(final["status"], "failed", final)
        self.assertEqual(len(ports), executors.TUNNEL_ATTEMPTS)
        self.assertEqual(left, 100 - executors.TUNNEL_ATTEMPTS)
        relay = executors.find(self.cfg(), "relay-4090")
        self.assertEqual(final["error"], executors.tunnel_unbound(relay, ports))

    def test_ghcr_mirror_pulls_and_tags_only_ghcr_images_of_the_selected_tasks(self):
        manager, client, _ = self.prepare_remote()
        self.egress_executor(ghcr_mirror="ghcr.nju.edu.cn")
        os.environ["FAKE_TASK_FROM"] = ("FROM --platform=linux/amd64 ghcr.io/laude-institute/t-bench/python-3-13:2025 AS b\n"
                                        "FROM ubuntu:24.04\nFROM docker.io/library/alpine:3.20")
        run = client.request("api/runs", {"suite": "aime", "model": "metask/session-model",
                                          "tasks": ["aime_60"], "executor": "relay-4090"})
        final = wait_run(manager, run["name"], timeout=60)
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        docker = [c[1] for c in self.calls("docker", "remote")]
        self.assertIn(["pull", "ghcr.nju.edu.cn/laude-institute/t-bench/python-3-13:2025"], docker)
        self.assertIn(["tag", "ghcr.nju.edu.cn/laude-institute/t-bench/python-3-13:2025",
                       "ghcr.io/laude-institute/t-bench/python-3-13:2025"], docker)
        self.assertEqual([c for c in docker if c[:1] == ["pull"]],
                         [["pull", "ghcr.nju.edu.cn/laude-institute/t-bench/python-3-13:2025"]])
        # Present now: a second run pulls nothing.
        run = client.request("api/runs", {"suite": "aime", "model": "metask/session-model",
                                          "tasks": ["aime_61"], "executor": "relay-4090"})
        self.assertEqual(wait_run(manager, run["name"], timeout=60)["status"], "finished")
        self.assertEqual(len([c for c in self.calls("docker", "remote") if c[1][:1] == ["pull"]]), 1)
        self.assertFalse(any("DOCKER_CONFIG" in json.dumps(c) for c in self.calls("ssh")))


class NetworkSetupTest(SetupFixture):
    def closed_port_url(self):
        import socket
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        return f"http://127.0.0.1:{port}/"

    def remote_docker(self):
        os.symlink(self.templates / "docker", self.remote_bin / "docker")
        os.environ["FAKE_REMOTE_DOCKER_DAEMON"] = "1"

    def tunnel_ports(self, busy=0):
        chosen = []

        def pick(tried=()):
            candidates = [port for port in executors.TUNNEL_PORTS if port not in tried]
            random.shuffle(candidates)
            for port in candidates:
                sock = socket.socket()
                try:
                    sock.bind(("127.0.0.1", port))
                except OSError:
                    sock.close()
                    continue
                if len(chosen) < busy:
                    sock.listen()
                    self.addCleanup(sock.close)
                else:
                    sock.close()
                chosen.append(port)
                return port
            raise AssertionError(f"no free port in {executors.TUNNEL_PORTS}")
        patcher = patch.object(executors, "tunnel_port", pick)
        patcher.start()
        self.addCleanup(patcher.stop)
        return chosen

    def forwarded_ports(self):
        return [int(c[1][c[1].index("-R") + 1].split(":")[1]) for c in self.calls("ssh") if "-R" in c[1]]

    def local_external_probe(self):
        import importlib
        from http.server import BaseHTTPRequestHandler
        from urllib.parse import urlsplit
        egress = importlib.import_module("scripts.eval.harbor.bench.egress")
        probe = types.SimpleNamespace(served=[], proxy_checked=[])

        class Origin(BaseHTTPRequestHandler):
            def do_GET(self):
                probe.served.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass
        origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
        self.addCleanup(origin.server_close)
        self.addCleanup(origin.shutdown)
        probe.port = origin.server_port
        probe.path = urlsplit(setup.EGRESS_EXTERNAL_PROBE).path
        probe.url = f"http://127.0.0.1:{probe.port}{probe.path}"
        public_only = egress.allow_policy

        def admitting_the_origin(networks=egress.DEFAULT_ALLOW_NETWORKS):
            allowed = public_only(networks)

            def allow(address):
                probe.proxy_checked.append(address)
                return address == "127.0.0.1" or allowed(address)
            return allow
        for patcher in (patch.object(setup, "EGRESS_EXTERNAL_PROBE", probe.url),
                        patch.object(egress, "allow_policy", admitting_the_origin)):
            patcher.start()
            self.addCleanup(patcher.stop)
        return probe

    def test_blocked_registries_propose_mirrors_and_one_click_applies_them(self):
        probe = self.local_external_probe()
        tunnel_ports = self.tunnel_ports()
        self.add_ssh_executor(metrics_bind="127.0.0.1", egress_ports=[443, 80, probe.port])
        self.remote_docker()
        os.symlink(self.templates / "uv", self.local_bin / "uv")
        blocked = self.closed_port_url()
        targets = {"pypi": blocked, "dockerhub": blocked, "ghcr": blocked, "github": self.reachable}
        self.daemon_json.parent.mkdir()
        self.daemon_json.write_text('{"log-driver": "json-file", "registry-mirrors": ["https://mirror.corp"]}')
        os.environ["FAKE_REMOTE_SUDO"] = "1"
        with patch.object(setup, "NETWORK_TARGETS", targets):
            before = self.config.read_bytes()
            dry = setup.run_setup(self.config, "relay-4090", dry_run=True)
            network = self.step(dry, "network")
            self.assertEqual(network["status"], "planned", network)
            for text in ("pypi_index", "docker_mirrors", "ghcr_mirror", "egress"):
                self.assertIn(text, network["detail"])
            self.assertEqual(self.config.read_bytes(), before)
            self.assertTrue(any("sudo -n systemctl reload docker" in c for c in self.mutations(dry)), self.mutations(dry))
            self.assertEqual(self.step(dry, "egress")["status"], "planned")
            self.assertFalse(self.daemon_json.read_text().count("daocloud"))
            progress = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(progress["status"], "ready", json.dumps(progress, ensure_ascii=False, indent=1))
        entry = next(e for e in self.cfg()["executors"] if e["name"] == "relay-4090")
        self.assertEqual((entry["pypi_index"], entry["docker_mirrors"], entry["ghcr_mirror"], entry["egress"]),
                         (setup.DEFAULT_PYPI_INDEX, setup.DEFAULT_DOCKER_MIRRORS, setup.DEFAULT_GHCR_MIRROR, "workbench"))
        # pypi_index reaches the Harbor install as UV_DEFAULT_INDEX.
        install = next(c[1][-1] for c in self.calls("ssh") if "uv tool install" in c[1][-1])
        self.assertIn("env UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple uv tool install", install)
        # daemon.json: merged, written through sudo, applied by reload only.
        daemon = json.loads(self.daemon_json.read_text())
        self.assertEqual(daemon["registry-mirrors"], ["https://mirror.corp"] + setup.DEFAULT_DOCKER_MIRRORS)
        self.assertEqual(daemon["log-driver"], "json-file")
        self.assertTrue(any(c[1][:3] == ["-n", "sh", "-c"] and str(self.daemon_json) in c[1][3]
                            for c in self.calls("sudo", "remote")))
        self.assertEqual([c[1] for c in self.calls("systemctl")], [["reload", "docker"]])
        # The container egress probe went container -> forwarder -> ssh -R -> proxy.
        egress_step = self.step(progress, "egress")
        self.assertEqual(egress_step["status"], "ok", egress_step)
        self.assertIn("ssh -R", egress_step["detail"])
        self.assertIn(probe.url, egress_step["detail"])
        self.assertTrue(any("-R" in c[1] for c in self.calls("ssh")))
        self.assertTrue(any(c[1][:2] == ["network", "create"] for c in self.calls("docker", "remote")))
        self.assertTrue(any(c[1][:2] == ["network", "rm"] for c in self.calls("docker", "remote")))
        self.assertEqual(self.step(progress, "workbench_harbor")["status"], "done")
        # Idempotent: nothing more to write or reload.
        again = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(self.step(again, "docker_mirrors")["status"], "ok")
        self.assertEqual(self.step(again, "egress")["status"], "ok")
        self.assertEqual(len(self.calls("systemctl")), 1)
        self.assertFalse(any("restart" in json.dumps(c) for c in self.calls()))
        self.assertLessEqual(set(self.forwarded_ports()), set(tunnel_ports))
        self.assertEqual((probe.served, probe.proxy_checked), ([probe.path] * 2, ["127.0.0.1"] * 2))

    def test_apt_cache_starts_once_per_mirror_on_the_docker_gateway(self):
        class Report(SimpleHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if self.path == "/acng-report.html" else 404)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass
        cache = ThreadingHTTPServer(("127.0.0.1", 0), Report)
        threading.Thread(target=cache.serve_forever, daemon=True).start()
        self.addCleanup(cache.server_close)
        self.addCleanup(cache.shutdown)
        port = cache.server_port
        patcher = patch.object(executors, "APT_CACHE_PORT", port)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.add_ssh_executor(metrics_bind="127.0.0.1", container_mirrors={"apt": "http://mirrors.example/"})
        self.remote_docker()
        dry = setup.run_setup(self.config, "relay-4090", dry_run=True)
        self.assertEqual(self.step(dry, "apt_cache")["status"], "planned", self.step(dry, "apt_cache"))
        self.assertFalse([c for c in self.calls("docker", "remote") if c[1][:1] in (["build"], ["run"])])
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "apt_cache")
        self.assertEqual(step["status"], "done", step)
        docker = [c[1] for c in self.calls("docker", "remote")]
        self.assertIn(["build", "-q", "-t", setup.APT_CACHE_NAME, "--build-arg", "MIRROR=http://mirrors.example", "-"], docker)
        started = next(c for c in docker if c[:2] == ["run", "-d"])
        for flag in (["--restart", "unless-stopped"], ["--label", setup.APT_CACHE_LABEL + "=http://mirrors.example"],
                     ["-p", f"127.0.0.1:{port}:3142"], ["-v", setup.APT_CACHE_NAME + ":/var/cache/apt-cacher-ng"]):
            self.assertIn(flag, [started[i:i + 2] for i in range(len(started) - 1)])
        os.environ["FAKE_DOCKER_INSPECT"] = "http://mirrors.example true"
        again = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(self.step(again, "apt_cache")["status"], "ok", self.step(again, "apt_cache"))
        self.assertEqual(len([c for c in self.calls("docker", "remote") if c[1][:1] == ["build"]]), 1)

    def start_download_cache(self, routes=None):
        from scripts.eval.harbor import download_cache
        cache = download_cache.DownloadCache(self.root / "download-cache",
                                             routes or {"go": self.reachable.rstrip("/")}).start()
        self.addCleanup(cache.close)
        patcher = patch.object(executors, "DOWNLOAD_CACHE_PORT", cache.port)
        patcher.start()
        self.addCleanup(patcher.stop)
        return cache

    def test_download_cache_starts_once_per_script_and_routes(self):
        from scripts.eval.harbor import download_cache
        port = self.start_download_cache().port
        mirrors = {"apt": "http://mirrors.example", "pypi": "https://pypi.example/simple/", "go": "https://goproxy.example",
                   "github": "https://gh.example/https://github.com", "hf": "https://hf.example"}
        self.add_ssh_executor(metrics_bind="127.0.0.1", container_mirrors=mirrors)
        self.remote_docker()
        off = setup.run_setup(self.config, "relay-4090", dry_run=True)
        self.assertEqual(self.step(off, "download_cache")["status"], "skipped", self.step(off, "download_cache"))
        self.add_ssh_executor(metrics_bind="127.0.0.1", container_mirrors={"hf": "https://hf.example"}, download_cache=True)
        nothing = setup.run_setup(self.config, "relay-4090", dry_run=True)
        self.assertEqual(self.step(nothing, "download_cache")["status"], "skipped", self.step(nothing, "download_cache"))
        self.add_ssh_executor(metrics_bind="127.0.0.1", container_mirrors=mirrors, download_cache=True)
        name = setup.DOWNLOAD_CACHE_NAME
        builds = lambda: [c[1] for c in self.calls("docker", "remote") if c[1][:4] == ["build", "-q", "-t", name]]  # noqa: E731
        dry = setup.run_setup(self.config, "relay-4090", dry_run=True)
        self.assertEqual(self.step(dry, "download_cache")["status"], "planned", self.step(dry, "download_cache"))
        self.assertEqual(builds(), [])
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "download_cache")
        self.assertEqual(step["status"], "done", step)
        self.assertIn("pypi → https://pypi.example", step["detail"])
        self.assertEqual(builds(), [["build", "-q", "-t", name, "-"]])
        dockerfile = (self.root / "state-remote" / ("dockerfile-" + name)).read_text()
        script = (Path(download_cache.__file__)).read_text()
        self.assertIn("COPY <<'METACODES_DOWNLOAD_CACHE_SCRIPT' /opt/download_cache.py\n" + script
                      + "METACODES_DOWNLOAD_CACHE_SCRIPT\n", dockerfile)
        self.assertIn(f'"--port", "{port}", "--dir", "/cache"]', dockerfile)
        self.assertNotIn("# syntax", dockerfile)
        routes = {"pypi": "https://pypi.example", "go": "https://goproxy.example",
                  "github": "https://gh.example/https://github.com"}
        digest = setup.download_cache_image(routes)[1]
        started = next(c[1] for c in self.calls("docker", "remote") if c[1][:2] == ["run", "-d"] and name in c[1])
        pairs = [started[i:i + 2] for i in range(len(started) - 1)]
        for flag in (["--restart", "unless-stopped"], ["--label", setup.DOWNLOAD_CACHE_LABEL + "=" + digest],
                     ["-p", f"127.0.0.1:{port}:{port}"], ["-v", name + ":/cache"]):
            self.assertIn(flag, pairs)
        self.assertEqual(started[started.index(name, started.index("-v") + 2) + 1:],
                         ["--route", "github=https://gh.example/https://github.com", "--route", "go=https://goproxy.example",
                          "--route", "pypi=https://pypi.example"])
        os.environ["FAKE_DOCKER_INSPECT"] = digest + " true"
        again = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(self.step(again, "download_cache")["status"], "ok", self.step(again, "download_cache"))
        self.assertEqual(len(builds()), 1)
        self.add_ssh_executor(metrics_bind="127.0.0.1", container_mirrors={**mirrors, "go": "https://goproxy.other"},
                              download_cache=True)
        changed = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(self.step(changed, "download_cache")["status"], "done", self.step(changed, "download_cache"))
        self.assertEqual(len(builds()), 2)

    def test_setup_after_enabling_the_download_cache_keeps_the_direct_egress_it_needs(self):
        from scripts.eval.harbor.bench import monitor
        self.add_ssh_executor(metrics_bind="127.0.0.1", container_mirrors={"go": "https://goproxy.example"})
        self.remote_docker()
        monitor.save_mirrors(self.config, {"executor": "relay-4090", "settings": {"download_cache": True}})
        self.assertNotIn("egress", next(e for e in self.cfg()["executors"] if e["name"] == "relay-4090"))
        blocked = self.closed_port_url()
        targets = {"pypi": blocked, "dockerhub": self.reachable, "ghcr": self.reachable, "github": blocked}
        with patch.object(setup, "NETWORK_TARGETS", targets):
            progress = setup.run_setup(self.config, "relay-4090")
        network = self.step(progress, "network")
        self.assertEqual(network["status"], "done", network)
        self.assertIn("pypi_index", network["detail"])
        self.assertNotIn("egress", network["detail"])
        entry = next(e for e in self.cfg()["executors"] if e["name"] == "relay-4090")
        self.assertEqual((entry.get("egress"), entry["download_cache"], entry["pypi_index"]),
                         (None, True, setup.DEFAULT_PYPI_INDEX))
        relay = executors.find(self.cfg(), "relay-4090")
        self.assertEqual((relay.egress, relay.download_cache), ("direct", True))
        self.assertNotEqual(self.step(progress, "download_cache")["status"], "skipped")

    def test_a_run_uses_the_download_cache_only_while_it_answers(self):
        cache = self.start_download_cache({"pypi": "https://pypi.example", "go": "https://goproxy.example"})
        self.add_ssh_executor(metrics_bind="127.0.0.1", download_cache=True, container_mirrors={
            "pypi": "https://pypi.example/simple/", "go": "https://goproxy.example"})
        relay = executors.find(self.cfg(), "relay-4090")
        logged = []
        run = executors.RemoteRun({"name": "r", "executor": relay.spec()}, log=logged.append)
        base = f"http://127.0.0.1:{cache.port}"
        self.assertEqual(run.mirror_overlay(None), {"services": {"main": {"environment": {
            "PIP_TRUSTED_HOST": "127.0.0.1", "PIP_INDEX_URL": base + "/pypi/simple/",
            "UV_DEFAULT_INDEX": base + "/pypi/simple/", "GOPROXY": base + "/go,direct"}}}})
        self.assertTrue(any("先走缓存" in line for line in logged), logged)
        cache.close()
        del logged[:]
        self.assertEqual(run.mirror_overlay(None), {"services": {"main": {"environment": {
            "PIP_INDEX_URL": "https://pypi.example/simple/", "UV_DEFAULT_INDEX": "https://pypi.example/simple/",
            "GOPROXY": "https://goproxy.example,direct"}}}})
        self.assertTrue(any("没有响应" in line and "bench setup --executor relay-4090" in line for line in logged), logged)

    def test_a_run_uses_only_the_routes_the_running_cache_serves_from_the_configured_source(self):
        cache = self.start_download_cache({"pypi": "https://pypi.example", "go": "https://goproxy.old.example"})
        self.add_ssh_executor(metrics_bind="127.0.0.1", download_cache=True, container_mirrors={
            "pypi": "https://pypi.example/simple/", "go": "https://goproxy.example",
            "github": "https://gh-proxy.example/https://github.com"})
        relay = executors.find(self.cfg(), "relay-4090")
        logged = []
        run = executors.RemoteRun({"name": "r", "executor": relay.spec()}, log=logged.append)
        base = f"http://127.0.0.1:{cache.port}"
        self.assertEqual(run.mirror_overlay(None), {"services": {"main": {"environment": {
            "PIP_TRUSTED_HOST": "127.0.0.1", "PIP_INDEX_URL": base + "/pypi/simple/",
            "UV_DEFAULT_INDEX": base + "/pypi/simple/", "GOPROXY": "https://goproxy.example,direct",
            "UV_INSTALLER_GITHUB_BASE_URL": "https://gh-proxy.example/https://github.com",
            "UV_PYTHON_INSTALL_MIRROR": "https://gh-proxy.example/https://github.com/astral-sh/"
                                        "python-build-standalone/releases/download"}}}})
        self.assertTrue(any("pypi 先走缓存" in line for line in logged), logged)
        self.assertTrue(any("github、go" in line and "直接使用镜像源" in line
                            and "bench setup --executor relay-4090" in line for line in logged), logged)
        with self.assertRaises(urllib.error.HTTPError) as unserved:
            urllib.request.urlopen(base + "/github/astral-sh/uv/releases/download/0.9.5/uv.tar.gz", timeout=10)
        self.addCleanup(unserved.exception.close)
        self.assertEqual(unserved.exception.code, 404)

    def test_docker_mirrors_without_sudo_report_the_command_and_change_nothing(self):
        self.add_ssh_executor(docker_mirrors=["https://docker.m.daocloud.io"])
        self.remote_docker()
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "docker_mirrors")
        self.assertEqual(step["status"], "manual", step)
        self.assertIn("sudo tee " + str(self.daemon_json), step["command"])
        self.assertTrue(step["command"].endswith("&& sudo systemctl reload docker"))
        self.assertIn("https://docker.m.daocloud.io", step["command"])
        self.assertFalse(self.daemon_json.exists())
        self.assertEqual(self.calls("systemctl"), [])
        # Mirrors only fill gaps: a configured value is never proposed over.
        self.assertEqual(self.step(progress, "network")["status"], "ok")

    def test_workbench_egress_probe_failure_is_explained(self):
        self.tunnel_ports()
        self.add_ssh_executor(metrics_bind="127.0.0.1", egress="workbench")
        self.remote_docker()
        # A container cannot fetch (no route in this fixture's fake docker).
        (self.remote_bin / "docker").unlink()
        (self.remote_bin / "docker").write_text("#!/bin/sh\ncase \"$1\" in run) echo 'wget: timed out' >&2; exit 1;; esac\nexit 0\n")
        (self.remote_bin / "docker").chmod(0o755)
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "egress")
        self.assertEqual(step["status"], "failed", step)
        self.assertIn("容器无法经执行机器的 Docker 网关", step["detail"])
        self.assertIn("wget: timed out", step["detail"])
        self.assertIn("防火墙", step["detail"])

    def test_a_busy_tunnel_port_on_the_executor_is_retried_on_another_one(self):
        probe = self.local_external_probe()
        ports = self.tunnel_ports(busy=1)
        self.add_ssh_executor(metrics_bind="127.0.0.1", egress="workbench", egress_ports=[443, 80, probe.port])
        self.remote_docker()
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "egress")
        self.assertEqual(step["status"], "ok", step)
        self.assertEqual(len(ports), 2)
        self.assertEqual(self.forwarded_ports(), ports)
        relay = executors.find(self.cfg(), "relay-4090")
        self.assertIn(executors.tunnel_retry_note(relay, ports[0], ports[1], 2), step["log"])
        self.assertEqual(probe.served, [probe.path])

    def test_a_tunnel_port_refused_on_every_attempt_names_the_executor_side_cause(self):
        ports = self.tunnel_ports(busy=executors.TUNNEL_ATTEMPTS)
        self.add_ssh_executor(metrics_bind="127.0.0.1", egress="workbench")
        self.remote_docker()
        progress = setup.run_setup(self.config, "relay-4090")
        step = self.step(progress, "egress")
        self.assertEqual(step["status"], "failed", step)
        self.assertEqual(len(ports), executors.TUNNEL_ATTEMPTS)
        self.assertEqual(self.forwarded_ports(), ports)
        relay = executors.find(self.cfg(), "relay-4090")
        self.assertEqual(step["detail"], executors.tunnel_unbound(relay, ports))
        self.assertIn("绑不了隧道端口", step["detail"])
        self.assertNotIn("防火墙", step["detail"])

    def test_egress_config_is_validated(self):
        for bad in ({"egress": "tunnel"}, {"egress": {"proxy": "socks5://h:1"}}, {"egress_ports": [0]},
                    {"pypi_index": "file:///etc"}, {"docker_mirrors": ["https://ok", "x; rm -rf /"]},
                    {"ghcr_mirror": "-oProxy"}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                executors.parse({"name": "r", "kind": "ssh", "host": "h", **bad})
        relay = executors.parse({"name": "r", "kind": "ssh", "host": "h", "egress": {"proxy": "http://proxy:3128"}})
        self.assertEqual((relay.egress, relay.egress_proxy), ("proxy", "http://proxy:3128"))
        # The spec a worker receives parses back to the same executor.
        self.assertEqual(executors.parse({k: v for k, v in relay.spec().items() if v is not None}), relay)
        argv = executors.ssh_argv(relay, ["true"], reverse=(23456, 34567))
        self.assertEqual(argv[argv.index("-R") + 1], "127.0.0.1:23456:127.0.0.1:34567")
        self.assertNotIn("-R", executors.ssh_argv(relay, ["true"]))


class TunnelPortTest(unittest.TestCase):
    def test_a_tunnel_port_is_below_the_ephemeral_ranges_and_never_one_already_tried(self):
        ports = {executors.tunnel_port() for _ in range(2000)}
        self.assertTrue(all(20000 <= port < LOWEST_EPHEMERAL_PORT for port in ports), sorted(ports)[-5:])
        tried = set(range(20000, LOWEST_EPHEMERAL_PORT)) - {31000}
        self.assertEqual(executors.tunnel_port(tried), 31000)


if __name__ == "__main__":
    unittest.main()


class RegistryDownloadRetryTest(unittest.TestCase):
    """A transient `git clone` failure inside `harbor download` must not fail
    the run: on a real workbench one GitHub hiccup did exactly that."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def runner_failing(self, failures):
        calls = []

        def run(argv, **_kwargs):
            calls.append(list(argv))
            if len(calls) <= failures:
                return subprocess.CompletedProcess(argv, 1, "", "fatal: unable to access 'https://github.com/': timeout")
            out = Path(argv[argv.index("-o") + 1]) / "aime"
            for task in ("aime_60", "aime_i-1"):
                (out / task).mkdir(parents=True)
                (out / task / "task.toml").write_text("")
            return subprocess.CompletedProcess(argv, 0, "Successfully downloaded 2 task(s)", "")
        return run, calls

    def test_two_failures_then_success(self):
        run, calls = self.runner_failing(2)
        slept, logs = [], []
        dataset = executors.registry_dataset("aime@1.0", self.root / "cache", "/bin/harbor",
                                             expected=["aime_60"], log=logs.append, runner=run, sleep=slept.append)
        self.assertEqual(len(calls), 3)
        self.assertEqual(slept, list(executors.REGISTRY_BACKOFF))
        self.assertEqual(sorted(p.name for p in dataset.iterdir() if p.is_dir()), ["aime_60", "aime_i-1"])
        self.assertTrue(any("fatal: unable to access" in line for line in logs))

    def test_every_attempt_failing_reports_the_retries(self):
        run, calls = self.runner_failing(99)
        with self.assertRaisesRegex(ValueError, "已重试 3 次"):
            executors.registry_dataset("aime@1.0", self.root / "cache", "/bin/harbor", expected=["aime_60"],
                                       log=lambda _line: None, runner=run, sleep=lambda _s: None)
        self.assertEqual(len(calls), executors.REGISTRY_ATTEMPTS)
        self.assertEqual([p.name for p in (self.root / "cache").iterdir()], [])
