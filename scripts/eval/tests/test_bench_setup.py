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
from scripts.eval.tests.test_bench_workbench import FAKE_HARBOR, session_fixture, wait_run

FAKES = r'''
import json, os, shutil, subprocess, sys
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
elif name == "colima":
    if args[:1] == ["status"]:
        sys.exit(0 if (state / "colima-running").exists() else 1)
    if args[:1] == ["start"]:
        (state / "colima-running").touch()
elif name == "ssh":
    i = 0
    while args[i].startswith("-"):
        i += 2 if args[i] in ("-o", "-p", "-i") else 1
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
                "FAKE_EXPECT_ACCOUNT_KEY", "FAKE_BREW_PREFIX"):
        if key in env:
            remote[key] = env[key]
    os.chdir(home)
    os.execve("/bin/sh", ["sh", "-c", command], remote)
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

SIMPLE = ("uname", "brew", "uv", "curl", "sudo", "docker", "colima", "ssh", "zig", "metacodes")
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
        for tool in ("uname", "curl", "sudo", "ssh", "zig"):
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
        self.state = root / "bench-state"
        self.config = self.state / "bench" / "workbench.json"
        native = root / "provider.json"
        atomic_json(native, {"custom_providers": {"tokenjoy": {"models": [{"request_model_id": "test-model"}]}}})
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
    def prepare_remote(self, profile=False):
        state, upstream, calls = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        os.environ["METASK_SITE_URL"] = f"http://127.0.0.1:{upstream.server_port}"
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
        # The key reached the remote Harbor process; it is in no argv or file.
        self.assertTrue(json.loads((local / "credential-check.json").read_text())["account_key_matches"])
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
        manager, client, _ = self.prepare_remote()
        os.environ["FAKE_EXPECT_ACCOUNT_KEY"] = "session-access"
        run = client.request("api/runs", {"suite": "aime-2025", "model": "metask/session-model",
                                          "tasks": ["aime_i-1", "aime_ii-15"], "executor": "relay-4090"})
        self.assertEqual((run["suite"], run["executor"]), ("aime-2025", "relay-4090"))
        final = wait_run(manager, run["name"])
        self.assertEqual(final["status"], "finished", (final, data.tail(manager.records / (run["name"] + ".log"))))
        argv = json.loads((manager.jobs_dir / run["name"] / "argv.json").read_text())
        self.assertEqual(argv[argv.index("-d") + 1], "aime@1.0")
        self.assertEqual([argv[i + 1] for i, a in enumerate(argv) if a == "-i"], ["aime_i-1", "aime_ii-15"])
        # Synced back, ingested by the worker: the store serves it without files.
        shutil.rmtree(manager.jobs_dir / run["name"])
        view = client.request("api/job?name=" + run["name"])
        self.assertEqual((view["suite"], view["category_name"]), ("aime-2025", "竞赛数学"))
        self.assertEqual(view["summary"]["counts"]["pass"], 1)

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


if __name__ == "__main__":
    unittest.main()
