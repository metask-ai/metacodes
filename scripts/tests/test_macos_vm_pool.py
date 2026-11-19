"""scripts/ci/macos_vm_pool.py, the pool host's controller, with tart, ssh and
GitHub replaced by fakes (doc/MACOS_VM_POOL.md), and the golden image's
provisioning script."""
from __future__ import annotations

import base64
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import macos_vm_pool as pool  # noqa: E402

NOW = 1_800_000_000.0
JIT = "eyJydW5uZXIiOiJ4In0="
PROVISION = ROOT / "scripts" / "ci" / "macos_vm_provision.sh"


def base_config(tmp: Path, **override) -> dict:
    return {"owner": "metask-ai", "app_id": 7, "installation_id": 8, "private_key": str(tmp / "app.pem"),
            "runner_group_id": 9, "image": "metacodes-macos-golden", "vm_ssh_key": str(tmp / "vm_key"),
            "state_dir": str(tmp / "state"), **override}


class Done:
    def __init__(self, code=0, stdout=b"", stderr=b""):
        self.returncode, self.stdout, self.stderr = code, stdout, stderr


class FakeProcess:
    def __init__(self):
        self.waited = self.killed = False

    def wait(self, timeout=None):
        self.waited = True
        return 0

    def kill(self):
        self.killed = True


class FakeTart:
    def __init__(self, calls, vms=(), clone_fails=False):
        self.calls, self.vms, self.clone_fails = calls, list(vms), clone_fails
        self.processes = []

    def names(self):
        return list(self.vms)

    def clone(self, source, name):
        self.calls.append(("clone", source, name))
        if self.clone_fails:
            raise subprocess.CalledProcessError(1, ["tart", "clone"])
        self.vms.append(name)

    def start(self, name, args, log):
        self.calls.append(("start", name, tuple(args)))
        process = FakeProcess()
        self.processes.append(process)
        return process

    def ip(self, name, wait):
        self.calls.append(("ip", name))
        return "192.168.64.%d" % (len(self.processes) + 1)

    def stop(self, name):
        self.calls.append(("stop", name))

    def delete(self, name):
        self.calls.append(("delete", name))
        if name in self.vms:
            self.vms.remove(name)


class FakeGitHub:
    def __init__(self, calls, runners=(), jit_fails=False):
        self.calls, self._runners, self.jit_fails = calls, list(runners), jit_fails

    def jit_config(self, name):
        self.calls.append(("jit", name))
        if self.jit_fails:
            raise pool.PoolError("HTTP 403")
        return JIT

    def runners(self):
        return list(self._runners)

    def delete_runner(self, runner_id):
        self.calls.append(("delete_runner", runner_id))

    def token(self):
        return "token"

    def runner_group(self, group_id):
        if group_id == 1:
            return {"name": "Default", "allows_public_repositories": False}
        return {"name": "metacodes-public-ephemeral", "visibility": "selected", "allows_public_repositories": True}


class FakeRun:
    """subprocess.run for ssh and the host's own commands."""

    def __init__(self, calls, runner_exit=0, timeout=False, probe=None):
        self.calls, self.runner_exit, self.timeout, self.probe = calls, runner_exit, timeout, probe

    def __call__(self, argv, input=None, capture_output=False, timeout=None, text=False, check=False):
        self.calls.append(("run", tuple(argv), input))
        if argv[0] == "ifconfig":
            return Done(stdout="lo0: inet 127.0.0.1\nen0: inet 192.168.31.20 netmask\n")
        if argv[0] == "route":
            return Done(stdout="   gateway: 192.168.31.1\n")
        command = argv[-1]
        if command == "true":
            return Done()
        if command.startswith("python3 - "):
            return Done(stdout=json.dumps(self.probe).encode())
        if self.timeout:
            raise subprocess.TimeoutExpired(argv, timeout)
        return Done(self.runner_exit)


class PoolTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.config = pool.parse_config(base_config(self.tmp))
        self.calls: list = []
        # The controller logs each turn to stdout as well as pool.log.
        self._quiet = redirect_stdout(io.StringIO())
        self._quiet.__enter__()

    def tearDown(self) -> None:
        self._quiet.__exit__(None, None, None)
        self._tmp.cleanup()

    def host(self, tart=None, github=None, run=None):
        clock = iter(NOW + i for i in range(10_000))
        return pool.Host(github or FakeGitHub(self.calls), tart or FakeTart(self.calls), run or FakeRun(self.calls),
                         now=lambda: next(clock), sleep=lambda _: None)


class ConfigTest(PoolTestCase):
    def test_defaults_isolate_every_vm(self) -> None:
        self.assertEqual(self.config.pool_label, "metacodes-macos-vm")
        self.assertEqual(self.config.slots, 2)
        self.assertIn("--net-softnet", self.config.tart_run_args)
        self.assertEqual(self.config.repository, "")

    def test_the_documented_example_is_a_valid_configuration(self) -> None:
        doc = (ROOT / "doc" / "MACOS_VM_POOL.md").read_text(encoding="utf-8")
        example = re.search(r"<!-- config example -->\s*```json\n(.*?)\n```", doc, re.S)
        self.assertIsNotNone(example, "doc/MACOS_VM_POOL.md lost its configuration example")
        config = pool.parse_config(json.loads(example.group(1)))
        self.assertEqual(config.pool_label, json.loads((ROOT / ".github/macos-runner.json").read_text())["label"])

    def test_an_unsafe_or_broken_configuration_is_refused(self) -> None:
        for override in ({"slots": 3},                                   # Apple: two macOS guests per Mac
                         {"tart_run_args": ["--no-graphics"]},            # no Softnet
                         {"tart_run_args": ["--net-softnet", "--dir=cache:/Users/ci-host/cache"]},
                         {"labels": ["self-hosted", "macOS"]},            # no dedicated label
                         {"labels": ["metacodes-macos-vm"]},              # not self-hosted
                         {"api_url": "http://api.github.com"},
                         {"job_limit_seconds": 60},
                         {"owner": "metask ai"},
                         {"unknown": 1}):
            with self.subTest(override=override), self.assertRaises(pool.PoolError):
                pool.parse_config(base_config(self.tmp, **override))
        partial = base_config(self.tmp)
        del partial["runner_group_id"]
        with self.assertRaises(pool.PoolError):
            pool.parse_config(partial)


class TurnTest(PoolTestCase):
    def test_a_turn_runs_one_job_in_a_fresh_vm_and_destroys_it(self) -> None:
        record = pool.turn(self.config, 1, self.host())
        kinds = [call[0] for call in self.calls]
        self.assertEqual(kinds, ["clone", "jit", "start", "ip", "run", "run", "stop", "delete"])
        name = self.calls[0][2]
        self.assertTrue(name.startswith("metacodes-s1-"))
        self.assertEqual(self.calls[0][1], "metacodes-macos-golden")
        self.assertEqual(self.calls[2][2], ("--no-graphics", "--net-softnet"))
        runner = self.calls[5]
        self.assertIn("./run.sh --jitconfig \"$(cat)\"", runner[1][-1])
        self.assertEqual(runner[2], JIT.encode())  # on standard input...
        self.assertFalse(any(JIT in " ".join(call[1]) for call in self.calls if call[0] == "run"))  # ...never argv
        self.assertEqual(record["runner_exit"], 0)
        self.assertNotIn("error", record)
        log = (self.tmp / "state" / "pool.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(json.loads(log[-1])["vm"], name)

    def test_the_vm_is_destroyed_whatever_happens(self) -> None:
        cases = {
            "runner fails": dict(run=FakeRun(self.calls, runner_exit=1)),
            "job limit": dict(run=FakeRun(self.calls, timeout=True)),
            "no configuration": dict(github=FakeGitHub(self.calls, jit_fails=True)),
        }
        for case, parts in cases.items():
            with self.subTest(case=case):
                self.calls.clear()
                record = pool.turn(self.config, 2, self.host(**parts))
                self.assertEqual(self.calls[-1][0], "delete")
                self.assertEqual(self.calls[-1][1], self.calls[0][2])
        self.assertIn("job limit", str(pool.turn(self.config, 2, self.host(run=FakeRun(self.calls, timeout=True)))))
        self.calls.clear()
        record = pool.turn(self.config, 1, self.host(github=FakeGitHub(self.calls, jit_fails=True)))
        self.assertNotIn("start", [call[0] for call in self.calls])  # no VM boots without a configuration
        self.assertIn("HTTP 403", record["error"])

    def test_a_failed_clone_leaves_nothing_to_destroy(self) -> None:
        record = pool.turn(self.config, 1, self.host(tart=FakeTart(self.calls, clone_fails=True)))
        self.assertEqual([call[0] for call in self.calls], ["clone"])
        self.assertIn("CalledProcessError", record["error"])


class CleanupTest(PoolTestCase):
    def test_only_the_slots_leftovers_go(self) -> None:
        tart = FakeTart(self.calls, vms=["metacodes-s1-20261118", "metacodes-s2-20261118", "metacodes-macos-golden"])
        github = FakeGitHub(self.calls, runners=[
            {"id": 1, "name": "metacodes-s1-20261118", "status": "offline"},
            {"id": 2, "name": "metacodes-s1-20261119", "status": "online"},
            {"id": 3, "name": "metacodes-s2-20261118", "status": "offline"},
            {"id": 4, "name": "AIPC", "status": "offline"},
        ])
        removed = pool.cleanup(self.config, self.host(tart=tart, github=github), [1])
        self.assertEqual(removed, {"vms": ["metacodes-s1-20261118"], "runners": ["metacodes-s1-20261118"]})
        self.assertEqual(tart.vms, ["metacodes-s2-20261118", "metacodes-macos-golden"])
        self.assertEqual([c for c in self.calls if c[0] == "delete_runner"], [("delete_runner", 1)])


class SlotTest(PoolTestCase):
    def test_a_slot_backs_off_after_a_failed_turn(self) -> None:
        sleeps = []
        turns = iter([True, True, False])
        host = self.host(github=FakeGitHub(self.calls, jit_fails=True))
        host.sleep = sleeps.append
        pool.run_slot(self.config, 1, host, stop=lambda: not next(turns))
        self.assertEqual(sleeps, [30, 60])


class FakeOpener:
    def __init__(self, routes):
        self.routes, self.requests = routes, []

    def __call__(self, request, timeout=None):
        self.requests.append(request)
        key = (request.get_method(), request.full_url.split("https://api.example", 1)[1])
        value = self.routes[key]
        if isinstance(value, urllib.error.HTTPError):
            raise value
        return io.BytesIO(json.dumps(value).encode() if value is not None else b"")


@unittest.skipIf(shutil.which("openssl") is None, "openssl")
class GitHubTest(PoolTestCase):
    def setUp(self) -> None:
        super().setUp()
        key = self.tmp / "app.pem"
        subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
        self.config = pool.parse_config(base_config(self.tmp, api_url="https://api.example"))

    def github(self, routes):
        opener = FakeOpener(routes)
        return pool.GitHub(self.config, opener=opener, now=lambda: NOW), opener

    def test_the_app_jwt_is_signed_by_the_private_key(self) -> None:
        github, _ = self.github({})
        header, payload, signature = github.app_jwt().split(".")
        decode = lambda part: base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
        self.assertEqual(json.loads(decode(header)), {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(json.loads(decode(payload)), {"iat": NOW - 60, "exp": NOW + 540, "iss": 7})
        public = self.tmp / "app.pub"
        subprocess.run(["openssl", "rsa", "-in", str(self.tmp / "app.pem"), "-pubout", "-out", str(public)],
                       check=True, capture_output=True)
        (self.tmp / "sig").write_bytes(decode(signature))
        verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature",
                                   str(self.tmp / "sig")], input=f"{header}.{payload}".encode(), capture_output=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_the_jit_configuration_uses_the_installation_token(self) -> None:
        github, opener = self.github({
            ("POST", "/app/installations/8/access_tokens"): {"token": "itoken", "expires_at": "2027-01-15T09:00:00Z"},
            ("POST", "/orgs/metask-ai/actions/runners/generate-jitconfig"): {"encoded_jit_config": JIT},
        })
        self.assertEqual(github.jit_config("metacodes-s1-x"), JIT)
        self.assertEqual(github.jit_config("metacodes-s1-y"), JIT)  # the token is reused
        token_requests = [r for r in opener.requests if "access_tokens" in r.full_url]
        self.assertEqual(len(token_requests), 1)
        self.assertTrue(token_requests[0].get_header("Authorization").startswith("Bearer ey"))
        jit_request = opener.requests[-1]
        self.assertEqual(jit_request.get_header("Authorization"), "Bearer itoken")
        self.assertEqual(json.loads(jit_request.data), {"name": "metacodes-s1-y", "runner_group_id": 9,
                                                        "labels": ["self-hosted", "macOS", "ARM64",
                                                                   "metacodes-macos-vm"],
                                                        "work_folder": "_work"})

    def test_repository_runners_and_refusals(self) -> None:
        self.config = pool.parse_config(base_config(self.tmp, api_url="https://api.example", repository="metacodes"))
        github, _ = self.github({
            ("POST", "/app/installations/8/access_tokens"): {"token": "itoken"},
            ("POST", "/repos/metask-ai/metacodes/actions/runners/generate-jitconfig"): {"encoded_jit_config": "x y"},
            ("GET", "/repos/metask-ai/metacodes/actions/runners?per_page=100&page=1"): {"runners": [{"id": 1}]},
        })
        with self.assertRaises(pool.PoolError):
            github.jit_config("metacodes-s1-x")  # not a configuration
        self.assertEqual(github.runners(), [{"id": 1}])
        forbidden = urllib.error.HTTPError("u", 403, "Forbidden", {}, io.BytesIO(b'{"message":"no"}'))
        github, _ = self.github({("POST", "/app/installations/8/access_tokens"): forbidden})
        with self.assertRaises(pool.PoolError):
            github.token()


class VerifyTest(PoolTestCase):
    PROBE_OK = {"tcp": [{"host": "github.com", "port": 443, "open": True}], "gateway": "192.168.64.1",
                "gateway_ssh": False, "mounts": ["/dev/disk3s1 on / (apfs)"], "secret_files": [], "secret_env": [],
                "tools": {"python3": True, "rg": True}, "runner": True}

    def test_judge(self) -> None:
        blocked = [{"host": "192.168.31.20", "port": 22, "what": "host", "host_reaches": True},
                   {"host": "10.0.0.1", "port": 80, "what": "private range", "host_reaches": False}]
        verdicts = {(check, detail.split(" ")[0]): verdict for check, verdict, detail in pool.judge(self.PROBE_OK, blocked)}
        self.assertEqual(verdicts[("isolation", "192.168.31.20:22")], "PASS")
        self.assertEqual(verdicts[("isolation", "10.0.0.1:80")], "NOTE")
        self.assertNotIn("FAIL", verdicts.values())
        leaky = dict(self.PROBE_OK, tcp=self.PROBE_OK["tcp"] + [{"host": "192.168.31.20", "port": 22, "open": True}],
                     mounts=["host on /Volumes/My Shared Files (virtiofs)"], secret_files=["/Users/admin/.ssh/id_rsa"],
                     secret_env=["GH_TOKEN"], gateway_ssh=True, tools={"rg": False}, runner=False)
        failed = [check for check, verdict, _ in pool.judge(leaky, blocked) if verdict == "FAIL"]
        self.assertEqual(sorted(set(failed)), ["image runner", "image tools", "isolation", "no credentials",
                                               "no host directories", "no secret variables"])
        offline = dict(self.PROBE_OK, tcp=[{"host": "github.com", "port": 443, "open": False}])
        self.assertIn(("internet", "FAIL", "github.com:443"), pool.judge(offline, []))

    def test_verify_boots_both_slots_probes_and_destroys(self) -> None:
        tart = FakeTart(self.calls)
        run = FakeRun(self.calls, probe=self.PROBE_OK)
        with io.StringIO() as out:
            sys_stdout, sys.stdout = sys.stdout, out
            try:
                code = pool.verify(self.config, self.host(tart=tart, run=run), reaches=lambda h, p: True)
            finally:
                sys.stdout = sys_stdout
            report = out.getvalue()
        self.assertEqual(code, 0, report)
        self.assertEqual(len([c for c in self.calls if c[0] == "clone"]), 2)
        self.assertEqual(sorted(c[1] for c in self.calls if c[0] == "delete"),
                         sorted(c[2] for c in self.calls if c[0] == "clone"))
        probe = next(c for c in self.calls if c[0] == "run" and c[1][-1].startswith("python3 - "))
        targets = json.loads(re.search(r"python3 - '(.*)'$", probe[1][-1]).group(1))
        hosts = {t["host"] for t in targets}
        self.assertIn("192.168.31.20", hosts)  # the host itself
        self.assertIn("192.168.31.1", hosts)   # the host's router
        self.assertEqual(probe[1][-2], "admin@192.168.64.2")  # probed from the first VM...
        self.assertIn("192.168.64.3", hosts)   # ...toward the other pool VM
        self.assertEqual(probe[2], pool.PROBE.encode())


class CheckTest(PoolTestCase):
    def test_check_reports_keys_image_and_groups(self) -> None:
        for name in ("app.pem", "vm_key"):
            (self.tmp / name).write_text("k", encoding="utf-8")
            os.chmod(self.tmp / name, 0o600)
        tart = FakeTart(self.calls, vms=["metacodes-macos-golden"])
        which = lambda tool: f"/usr/bin/{tool}"
        with io.StringIO() as out:
            sys_stdout, sys.stdout = sys.stdout, out
            try:
                self.assertEqual(pool.check(self.config, self.host(tart=tart), which), 0, out.getvalue())
                os.chmod(self.tmp / "app.pem", 0o644)
                github = FakeGitHub(self.calls, runners=[{"id": 1, "name": "AppledeMac-Studio"}])
                self.assertEqual(pool.check(self.config, self.host(tart=tart, github=github), which), 1)
            finally:
                sys.stdout = sys_stdout
            report = out.getvalue()
        self.assertIn("FAIL  App private key", report)
        self.assertIn("FAIL  persistent runner retired: AppledeMac-Studio", report)


class LaunchdTest(PoolTestCase):
    def test_each_slot_is_a_kept_alive_agent_in_the_users_session(self) -> None:
        plist = plistlib.loads(pool.launchd_plist(self.config, 2, "/usr/bin/python3", "/x/macos_vm_pool.py",
                                                  "/Users/ci-host/.metacodes-runner/config.json"))
        self.assertEqual(plist["Label"], "ai.metask.metacodes-vm-pool.slot2")
        self.assertEqual(plist["ProgramArguments"][-2:], ["slot", "2"])
        self.assertTrue(plist["KeepAlive"])
        self.assertEqual(plist["LimitLoadToSessionType"], "Aqua")


@unittest.skipIf(os.name == "nt", "bash")
class ProvisionTest(unittest.TestCase):
    def test_the_script_parses_and_pins_the_runner(self) -> None:
        self.assertEqual(subprocess.run(["bash", "-n", str(PROVISION)]).returncode, 0)
        text = PROVISION.read_text(encoding="utf-8")
        version = re.search(r"^RUNNER_VERSION=(\d+\.\d+\.\d+)$", text, re.M).group(1)
        self.assertRegex(re.search(r"^RUNNER_SHA256=(\S+)$", text, re.M).group(1), r"^[0-9a-f]{64}$")
        self.assertIn("actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz", text)
        self.assertIn("shasum -a 256 -c", text)
        self.assertTrue(version)

    def test_the_script_refuses_anything_but_a_public_key(self) -> None:
        for argv in ([], ["not a key"], ["-----BEGIN OPENSSH PRIVATE KEY-----"]):
            with self.subTest(argv=argv):
                proc = subprocess.run(["bash", str(PROVISION), *argv], capture_output=True, text=True,
                                      env={"PATH": "/usr/bin:/bin", "HOME": tempfile.gettempdir()})
                self.assertNotEqual(proc.returncode, 0)
                self.assertNotIn("provisioned", proc.stdout)


if __name__ == "__main__":
    unittest.main()
