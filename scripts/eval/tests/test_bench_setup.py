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
import shutil
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
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.command import BUNDLE_EXECUTABLES, check_bundle
from scripts.eval.harbor.viewer import data, executors, server, setup
from scripts.eval.harbor.viewer.runner import RunManager, atomic_json
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_bench_workbench import (FAKE_HARBOR, RotatingGateway, gaia2_dataset, session_fixture,
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
        try:
            with urllib.request.urlopen(args[-1], timeout=10) as response:
                sys.stdout.write(response.read().decode())
        except Exception as exc:
            print("wget: " + str(exc), file=sys.stderr)
            sys.exit(1)
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
                "FAKE_EGRESS_FETCH", "FAKE_JUDGE_REQUEST"):
        if key in env:
            remote[key] = env[key]
    if " pack " in command:
        # A slow or broken copy-back of the job directory.
        if env.get("FAKE_SSH_PACK_FAIL"):
            print("pack refused", file=sys.stderr)
            sys.exit(1)
        time.sleep(float(env.get("FAKE_SSH_PACK_DELAY") or 0))
    os.chdir(home)
    if reverse:
        # `-R 127.0.0.1:R:127.0.0.1:L`: the "executor" is this machine, so
        # the remote end listens on loopback port R and relays to L, for the
        # life of the session (ExitOnForwardFailure: a busy port fails it).
        import socket, threading
        _, rport, _, lport = reverse.split(":")
        listener = socket.socket()
        try:
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

SIMPLE = ("uname", "brew", "uv", "curl", "sudo", "docker", "colima", "ssh", "zig", "metacodes", "sysctl",
          "systemctl")
SYSTEM_TOOLS = ("sh", "env", "mkdir", "tar", "cp", "chmod", "rm", "mv", "mktemp", "touch", "cat", "python3",
                "openssl", "grep", "sed", "ls", "id", "head", "tail", "dirname", "basename", "true", "false", "git")


def release_fixture(root, version="9.9.9", corrupt=False):
    """A release directory laid out like GitHub's download URLs."""
    name = f"metacodes-{version}-x86_64-linux-gnu"
    unit = root / "unit" / name
    for file in BUNDLE_EXECUTABLES:
        path = unit / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"release " + file.encode())
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
                                  "metacodes": {"binary": str(self.templates / "metacodes"), "version": "9.9.9"}})

    def calls(self, tool=None, side=None):
        if not self.log.exists():
            return []
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [r for r in rows if (tool is None or r[0] == tool) and (side is None or r[2] == side)]

    def cfg(self):
        return json.loads(self.config.read_text())

    def add_ssh_executor(self, **extra):
        cfg = self.cfg()
        cfg["executors"] = [{"name": "devbox-mac", "kind": "local"},
                            {"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1", "user": "bench", **extra}]
        atomic_json(self.config, cfg)

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
        with patch.object(executors.os, "uname", return_value=os.uname_result(("Darwin", "h", "", "", "arm64"))), \
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
        for step_id in ("python", "uv", "harbor", "docker", "openssl", "remote_files"):
            self.assertEqual(self.step(progress, step_id)["status"], "skipped")
        self.assertEqual(self.step(progress, "bundle")["status"], "done")

    def test_remote_setup_installs_over_ssh_and_ships_runtime_once(self):
        self.add_ssh_executor()
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
        runtime = list((self.remote_home / ".metacodes-bench/runtime").iterdir())
        bundles = list((self.remote_home / ".metacodes-bench/bundles").iterdir())
        self.assertEqual(len(runtime), 1)
        self.assertTrue((runtime[0] / "scripts/eval/harbor/viewer/remote.py").is_file())
        self.assertTrue(os.access(bundles[0] / "bin/metacodes", os.X_OK))
        catalog = RunManager(self.state / "bench/jobs", self.config).catalog()
        relay_state = next(e for e in catalog["executors"] if e["name"] == "relay-4090")
        self.assertTrue(relay_state["ready"], relay_state["reasons"])
        shipped = len([c for c in self.calls("ssh") if "tar -xf -" in c[1][-1]])
        setup.run_setup(self.config, "relay-4090")
        self.assertEqual(len([c for c in self.calls("ssh") if "tar -xf -" in c[1][-1]]), shipped)


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
        bundle = self.root / "bundle"
        for file in BUNDLE_EXECUTABLES:
            (bundle / file).parent.mkdir(parents=True, exist_ok=True)
            (bundle / file).write_bytes(b"fake")
        atomic_json(bundle / "manifest.json", {"target": {"os": "linux"}})
        self.add_ssh_executor(metrics_bind="127.0.0.1", metrics_enabled=profile)
        cfg = self.cfg()
        cfg.update(auth_mode="metask", account_state_dir=str(state), bundle=str(bundle), metrics_enabled=profile,
                   harbor=str(self.templates / "harbor"))
        atomic_json(self.config, cfg)
        manager = RunManager(self.state / "bench/jobs", self.config)
        http = server.make_server(data.Library([manager.jobs_dir]), "127.0.0.1", 0, manager, "cap")
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        return manager, cli.Client(f"http://127.0.0.1:{http.server_address[1]}/", "cap"), calls

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
        self.assertTrue(all(left > 0 for left in gateway.refreshes), gateway.refreshes)
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
        runtime = executors.ship_runtime(relay, log=lambda _t: None)
        remote_dir = self.remote_home / "jobs" / "grow"
        (remote_dir / "t__1").mkdir(parents=True)
        for index in range(5):
            (remote_dir / "t__1" / f"small-{index}.json").write_text(json.dumps({"index": index}))
        log = remote_dir / "t__1" / "agent.log"
        log.write_bytes(os.urandom(300 * 1024))
        local = self.root / "local-jobs" / "grow"
        sync = executors.JobSync(relay, runtime, "jobs/grow", local, log=lambda _t: None)
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

    def test_closed_channel_stops_remote_harbor(self):
        manager, _, _ = self.prepare_remote()
        relay = executors.find(self.cfg(), "relay-4090")
        runtime = executors.ship_runtime(relay, log=lambda _t: None)
        jobs = self.remote_home / "jobs"
        spec = {"argv": [str(self.remote_home / ".local/bin/harbor"), "run", "-m", "metask/x", "-k", "1",
                         "-o", str(jobs), "--job-name", "eof"], "key_env": "METASK_API_KEY", "relay": None,
                "runtime": runtime}
        (self.remote_home / "spec.json").write_text(json.dumps(spec))
        argv = executors.ssh_argv(relay, ["env", "PYTHONPATH=" + runtime, "python3", "-m",
                                          "scripts.eval.harbor.viewer.remote", "run", "spec.json"])
        env = {**os.environ, "FAKE_BENCH_DELAY": "30"}
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        process.stdin.write(b'{"env": {"METASK_API_KEY": "k"}}\n')
        process.stdin.flush()
        self.assertEqual(json.loads(process.stdout.readline())["event"], "started")
        process.stdin.close()
        events = [json.loads(line) for line in process.stdout]
        process.stdout.close()
        process.wait(30)
        self.assertEqual(events[-1]["event"], "exit")
        self.assertTrue(events[-1]["cancelled"])


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
        on_ssh = wb["executors"]["relay-4090"]["reasons"]
        self.assertTrue(any("只能在本机执行器" in r for r in on_ssh), on_ssh)
        # WorkBuddy brings its own Harbor: the local executor's Harbor/Docker
        # probe is not its readiness (it checks its own tools).
        self.assertFalse(set(local["reasons"]) & set(wb["executors"]["devbox-mac"]["reasons"]) - set(wb["suite_reasons"]))
        with self.assertRaisesRegex(ValueError, "只能在本机执行器"):
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
        self.assertIn("[relay-4090] WorkBuddy 评测只能在本机执行器运行", text)

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
        from scripts.eval.harbor.viewer.runner import settings
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
        http = server.make_server(data.Library([self.manager.jobs_dir]), "127.0.0.1", 0, self.manager, "cap")
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        self.url = f"http://127.0.0.1:{http.server_address[1]}/"
        self.client = cli.Client(self.url, "cap")

    def test_setup_endpoint_requires_capability_and_same_origin(self):
        with self.assertRaisesRegex(ValueError, "授权"):
            cli.Client(self.url).request("api/setup", {"dry_run": True})
        with self.assertRaisesRegex(ValueError, "授权"):
            cli.Client(self.url).request("api/setup")
        request = urllib.request.Request(self.url + "api/setup", data=b'{"dry_run": true}', headers={
            "Content-Type": "application/json", "Authorization": "Bearer cap", "Origin": "https://evil.example"})
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
        with self.assertRaisesRegex(ValueError, "授权"):
            cli.Client(self.url).request("api/login")
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
    return listener.getsockname()[1], listener.close


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
        from scripts.eval.harbor.viewer import egress
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

    def test_proxy_tunnels_allowed_ports_and_refuses_the_rest(self):
        from scripts.eval.harbor.viewer import egress
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
        with egress.EgressProxy() as proxy:
            for target, status in (("127.0.0.1:443", "403"), (f"127.0.0.1:{port}", "403"), ("[::1]:443", "403"),
                                   ("localhost:443", "502")):
                line, sock, _ = proxy_request(proxy.port, f"CONNECT {target} HTTP/1.1\r\n\r\n")
                sock.close()
                self.assertTrue(line.startswith("HTTP/1.1 " + status), (target, line))

    def test_plain_http_is_forwarded_in_origin_form_without_proxy_credentials(self):
        from http.server import BaseHTTPRequestHandler
        from scripts.eval.harbor.viewer import egress
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
        from scripts.eval.harbor.viewer import egress
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
        session = next(c[1] for c in self.calls("ssh") if ".remote run " in c[1][-1])
        forward = session[session.index("-R") + 1]
        self.assertRegex(forward, r"^127\.0\.0\.1:\d+:127\.0\.0\.1:\d+$")
        self.assertIn("ExitOnForwardFailure=yes", session)
        # Only the run session carries the forward.
        self.assertEqual(len([c for c in self.calls("ssh") if "-R" in c[1]]), 1)
        local = manager.jobs_dir / run["name"]
        harbor_env = json.loads((local / "harbor-env.json").read_text())
        docker_config = Path(harbor_env["DOCKER_CONFIG"])
        self.assertEqual(docker_config.parent, (self.remote_home / ".metacodes-bench/runs" / run["name"]).resolve())
        self.assertFalse(docker_config.exists())  # removed after the run
        written = json.loads((local / "docker-config.json").read_text())
        self.assertNotIn("auths", written)
        default = written["proxies"]["default"]
        self.assertRegex(default["httpProxy"], r"^http://127\.0\.0\.1:\d+$")  # the forwarder (metrics_bind fallback)
        no_proxy = default["noProxy"].split(",")
        for host in ("localhost", "127.0.0.1", "main", "judge-sidecar"):
            self.assertIn(host, no_proxy)
        # container -> forwarder -> ssh -R -> the workbench proxy, end to end.
        self.assertEqual((local / "egress-probe.txt").read_bytes(), b"metacodes-bench-egress-ok")
        self.assertEqual(user_config.read_bytes(), before)
        self.assertFalse((self.home / ".docker/config.json").exists())
        log = data.tail(manager.records / (run["name"] + ".log"))
        self.assertIn("出网代理已停止", log)

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

    def test_blocked_registries_propose_mirrors_and_one_click_applies_them(self):
        self.add_ssh_executor(metrics_bind="127.0.0.1")
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
        self.assertTrue(any("-R" in c[1] for c in self.calls("ssh")))
        self.assertTrue(any(c[1][:2] == ["network", "create"] for c in self.calls("docker", "remote")))
        self.assertTrue(any(c[1][:2] == ["network", "rm"] for c in self.calls("docker", "remote")))
        self.assertEqual(self.step(progress, "workbench_harbor")["status"], "done")
        # Idempotent: nothing more to write or reload.
        again = setup.run_setup(self.config, "relay-4090")
        self.assertEqual(self.step(again, "docker_mirrors")["status"], "ok")
        self.assertEqual(len(self.calls("systemctl")), 1)
        self.assertFalse(any("restart" in json.dumps(c) for c in self.calls()))

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
        self.assertIn("防火墙", step["detail"])

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


if __name__ == "__main__":
    unittest.main()
