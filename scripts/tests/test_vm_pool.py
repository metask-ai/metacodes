"""scripts/ci/vm_pool.py, the pool hosts' controller, with tart, ssh,
PowerShell and GitHub replaced by fakes (doc/VM_POOLS.md), and the golden
images' provisioning scripts."""
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
import vm_pool as pool  # noqa: E402

NOW = 1_800_000_000.0
JIT = "eyJydW5uZXIiOiJ4In0="
MACOS_PROVISION = ROOT / "scripts" / "ci" / "macos_vm_provision.sh"
WINDOWS_PROVISION = ROOT / "scripts" / "ci" / "windows_vm_provision.ps1"


def base_config(tmp: Path, backend: str = "tart", **override) -> dict:
    common = {"backend": backend, "owner": "metask-ai", "app_id": 7, "installation_id": 8,
              "private_key": str(tmp / "app.pem"), "runner_group_id": 9, "state_dir": str(tmp / "state")}
    if backend == "tart":
        common.update(image="metacodes-macos-golden", vm_ssh_key=str(tmp / "vm_key"))
    else:
        common.update(image="metacodes-windows-golden", vhd_dir=str(tmp / "vhd"),
                      vm_password_file=str(tmp / "vm_password"), cpus=8, memory_mb=16384)
    return {**common, **override}


class Done:
    def __init__(self, code=0, stdout=b"", stderr=b""):
        self.returncode, self.stdout, self.stderr = code, stdout, stderr


class FakeBackend:
    """A backend that records what a turn asks of it."""
    tools = ("tart", "ssh", "openssl")
    host_ports = (22,)
    guest_ports = (22,)

    def __init__(self, calls, vms=(), create_fails=False, job=0, probe=None):
        self.calls, self.vms, self.create_fails, self.job, self._probe = calls, list(vms), create_fails, job, probe

    def names(self):
        return list(self.vms)

    def image_exists(self):
        return True

    def create(self, name):
        self.calls.append(("create", name))
        if self.create_fails:
            raise subprocess.CalledProcessError(1, ["tart", "clone"])
        self.vms.append(name)

    def start(self, name):
        self.calls.append(("start", name))

    def wait_ready(self, name):
        self.calls.append(("ready", name))

    def address(self, name):
        return "192.168.64.%d" % (2 + [c[1] for c in self.calls if c[0] == "create"].index(name))

    def run_job(self, name, jit):
        self.calls.append(("job", name, jit))
        if isinstance(self.job, Exception):
            raise self.job
        return self.job

    def probe(self, name, targets):
        self.calls.append(("probe", name, targets))
        return self._probe

    def destroy(self, name):
        self.calls.append(("destroy", name))
        if name in self.vms:
            self.vms.remove(name)

    def host_addresses(self):
        return ["192.168.31.20"]

    def host_gateway(self):
        return "192.168.31.1"


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

    def host(self, vm=None, github=None):
        clock = iter(NOW + i for i in range(10_000))
        return pool.Host(github or FakeGitHub(self.calls), vm or FakeBackend(self.calls),
                         now=lambda: next(clock), sleep=lambda _: None)


class ConfigTest(PoolTestCase):
    def test_each_backend_defaults_to_an_isolated_pool(self) -> None:
        tart = self.config
        self.assertEqual((tart.pool_label, tart.slots, tart.repository), ("metacodes-macos-vm", 2, ""))
        self.assertIn("--net-softnet", tart.tart_run_args)
        hyperv = pool.parse_config(base_config(self.tmp, "hyperv"))
        self.assertEqual(hyperv.pool_label, "metacodes-windows-vm")
        self.assertEqual(hyperv.switch, "Default Switch")
        self.assertEqual(set(hyperv.blocked_networks), set(pool.PRIVATE_NETWORKS))
        self.assertEqual(hyperv.vm_runner_dir, "C:\\actions-runner")

    def test_the_documented_examples_are_valid_configurations(self) -> None:
        doc = (ROOT / "doc" / "VM_POOLS.md").read_text(encoding="utf-8")
        switches = json.loads((ROOT / ".github" / "runner-pools.json").read_text(encoding="utf-8"))
        for backend, platform in (("tart", "macos"), ("hyperv", "windows")):
            with self.subTest(backend=backend):
                example = re.search(r"<!-- config example: %s -->\s*```json\n(.*?)\n```" % backend, doc, re.S)
                self.assertIsNotNone(example, f"doc/VM_POOLS.md lost its {backend} configuration example")
                config = pool.parse_config(json.loads(example.group(1)))
                self.assertEqual(config.backend, backend)
                self.assertEqual(config.pool_label, switches[platform]["label"])
                self.assertLessEqual(switches[platform]["slots"], pool.MAX_SLOTS[backend])

    def test_an_unsafe_or_broken_configuration_is_refused(self) -> None:
        for backend, override in (("tart", {"slots": 3}),                    # Apple: two macOS guests per Mac
                                  ("tart", {"tart_run_args": ["--no-graphics"]}),          # no Softnet
                                  ("tart", {"tart_run_args": ["--net-softnet", "--dir=c:/Users/ci-host"]}),
                                  ("tart", {"labels": ["self-hosted", "macOS"]}),          # no dedicated label
                                  ("tart", {"labels": ["metacodes-macos-vm"]}),            # not self-hosted
                                  ("tart", {"api_url": "http://api.github.com"}),
                                  ("tart", {"job_limit_seconds": 60}),
                                  ("tart", {"owner": "metask ai"}),
                                  ("tart", {"switch": "Default Switch"}),                  # another backend's field
                                  ("hyperv", {"blocked_networks": ["10.0.0.0/8"]}),        # private ranges open
                                  ("hyperv", {"blocked_networks": ["10.0.0.0/8; rm"]}),
                                  ("hyperv", {"switch": "x'; Remove-VM *"}),
                                  ("hyperv", {"vm_runner_dir": "C:\\a b"}),
                                  ("hyperv", {"memory_mb": 1024}),
                                  ("hyperv", {"tart_run_args": ["--net-softnet"]})):
            with self.subTest(backend=backend, override=override), self.assertRaises(pool.PoolError):
                pool.parse_config(base_config(self.tmp, backend, **override))
        with self.assertRaises(pool.PoolError):
            pool.parse_config({**base_config(self.tmp), "backend": "docker"})
        partial = base_config(self.tmp, "hyperv")
        del partial["vm_password_file"]
        with self.assertRaises(pool.PoolError):
            pool.parse_config(partial)


class TurnTest(PoolTestCase):
    def test_a_turn_runs_one_job_in_a_fresh_vm_and_destroys_it(self) -> None:
        record = pool.turn(self.config, 1, self.host())
        self.assertEqual([call[0] for call in self.calls], ["create", "jit", "start", "ready", "job", "destroy"])
        name = self.calls[0][1]
        self.assertTrue(name.startswith("metacodes-s1-"))
        self.assertEqual(self.calls[1][1], name)  # the runner is named after its VM
        self.assertEqual(self.calls[4][2], JIT)
        self.assertEqual(record["runner_exit"], 0)
        log = (self.tmp / "state" / "pool.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(json.loads(log[-1])["vm"], name)

    def test_the_vm_is_destroyed_whatever_happens(self) -> None:
        for case, parts in {"job fails": dict(vm=FakeBackend(self.calls, job=1)),
                            "job raises": dict(vm=FakeBackend(self.calls, job=pool.PoolError("lost the VM"))),
                            "no configuration": dict(github=FakeGitHub(self.calls, jit_fails=True))}.items():
            with self.subTest(case=case):
                self.calls.clear()
                pool.turn(self.config, 2, self.host(**parts))
                self.assertEqual(self.calls[-1], ("destroy", self.calls[0][1]))
        self.calls.clear()
        record = pool.turn(self.config, 1, self.host(github=FakeGitHub(self.calls, jit_fails=True)))
        self.assertNotIn("start", [call[0] for call in self.calls])  # no VM boots without a configuration
        self.assertIn("HTTP 403", record["error"])

    def test_a_failed_create_leaves_nothing_to_destroy(self) -> None:
        record = pool.turn(self.config, 1, self.host(vm=FakeBackend(self.calls, create_fails=True)))
        self.assertEqual([call[0] for call in self.calls], ["create"])
        self.assertIn("CalledProcessError", record["error"])


class CleanupTest(PoolTestCase):
    def test_only_the_slots_leftovers_go(self) -> None:
        vm = FakeBackend(self.calls, vms=["metacodes-s1-20261118", "metacodes-s2-20261118", "metacodes-macos-golden"])
        github = FakeGitHub(self.calls, runners=[
            {"id": 1, "name": "metacodes-s1-20261118", "status": "offline"},
            {"id": 2, "name": "metacodes-s1-20261119", "status": "online"},
            {"id": 3, "name": "metacodes-s2-20261118", "status": "offline"},
            {"id": 4, "name": "AIPC", "status": "offline"},
        ])
        removed = pool.cleanup(self.config, self.host(vm=vm, github=github), [1])
        self.assertEqual(removed, {"vms": ["metacodes-s1-20261118"], "runners": ["metacodes-s1-20261118"]})
        self.assertEqual(vm.vms, ["metacodes-s2-20261118", "metacodes-macos-golden"])
        self.assertEqual([c for c in self.calls if c[0] == "delete_runner"], [("delete_runner", 1)])


class SlotTest(PoolTestCase):
    def test_a_slot_backs_off_after_a_failed_turn(self) -> None:
        sleeps = []
        turns = iter([True, True, False])
        host = self.host(github=FakeGitHub(self.calls, jit_fails=True))
        host.sleep = sleeps.append
        pool.run_slot(self.config, 1, host, stop=lambda: not next(turns))
        self.assertEqual(sleeps, [30, 60])


class FakeRun:
    """subprocess.run for the backends' commands."""

    def __init__(self, calls, results=None, timeout_on=None):
        self.calls, self.results, self.timeout_on = calls, results or {}, timeout_on

    def __call__(self, argv, input=None, capture_output=False, timeout=None, text=False, check=False, env=None):
        self.calls.append(("run", tuple(argv), input, env))
        key = next((k for k in self.results if k in " ".join(argv)), None)
        if self.timeout_on and self.timeout_on in " ".join(argv):
            raise subprocess.TimeoutExpired(argv, timeout)
        value = self.results.get(key, Done()) if key else Done()
        return value(argv, env) if callable(value) else value


class FakePopen:
    def __init__(self, calls):
        self.calls = calls

    def __call__(self, argv, **kwargs):
        self.calls.append(("popen", tuple(argv)))
        return self

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass


class TartBackendTest(PoolTestCase):
    def backend(self, **results):
        run = FakeRun(self.calls, {"tart ip": Done(stdout="192.168.64.5\n"), **results})
        return pool.TartBackend(self.config, run=run, popen=FakePopen(self.calls), now=lambda: NOW, sleep=lambda _: None)

    def test_a_vm_runs_on_softnet_and_gets_the_configuration_on_stdin(self) -> None:
        vm = self.backend()
        vm.create("metacodes-s1-x")
        vm.start("metacodes-s1-x")
        vm.wait_ready("metacodes-s1-x")
        self.assertEqual(vm.run_job("metacodes-s1-x", JIT), 0)
        vm.destroy("metacodes-s1-x")
        argv = [call[1] for call in self.calls]
        self.assertEqual(argv[0], ("tart", "clone", "metacodes-macos-golden", "metacodes-s1-x"))
        self.assertEqual(argv[1], ("tart", "run", "metacodes-s1-x", "--no-graphics", "--net-softnet"))
        runner = next(call for call in self.calls if call[0] == "run" and "run.sh" in call[1][-1])
        self.assertIn('./run.sh --jitconfig "$(cat)"', runner[1][-1])
        self.assertEqual(runner[1][-2], "admin@192.168.64.5")
        self.assertEqual(runner[2], JIT.encode())
        self.assertFalse(any(JIT in " ".join(call[1]) for call in self.calls))  # never in argv
        self.assertEqual(argv[-1], ("tart", "delete", "metacodes-s1-x"))

    def test_the_job_limit_stops_the_runner(self) -> None:
        vm = self.backend()
        vm.addresses["metacodes-s1-x"] = "192.168.64.5"
        vm.run = FakeRun(self.calls, timeout_on="run.sh")
        self.assertIn("job limit", vm.run_job("metacodes-s1-x", JIT))


class HyperVBackendTest(PoolTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.config = pool.parse_config(base_config(self.tmp, "hyperv"))

    def backend(self, **results):
        return pool.HyperVBackend(self.config, run=FakeRun(self.calls, results), now=lambda: NOW, sleep=lambda _: None)

    def scripts(self):
        return [(call[1][-1], call[2], call[3]) for call in self.calls if call[0] == "run"]

    def test_every_value_reaches_powershell_through_its_environment(self) -> None:
        vm = self.backend()
        vm.create("metacodes-s1-x")
        script, _, env = self.scripts()[0]
        self.assertEqual(self.calls[0][1][:5], ("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"))
        self.assertNotIn("metacodes-s1-x", script)  # names and paths are never parsed as code
        self.assertNotIn(str(self.tmp), script)
        self.assertEqual((env["POOL_VM"], env["POOL_IMAGE"], env["POOL_SWITCH"]),
                         ("metacodes-s1-x", "metacodes-windows-golden", "Default Switch"))
        self.assertEqual(env["POOL_BLOCKED"].split(","), list(pool.PRIVATE_NETWORKS))

    def test_a_vm_is_a_differencing_disk_behind_deny_acls(self) -> None:
        script = pool.PS_CREATE
        self.assertIn("New-VHD -Path $disk -ParentPath $parent -Differencing", script)
        self.assertIn("Add-VMNetworkAdapterExtendedAcl -VMName $env:POOL_VM -Action Deny -Direction Outbound "
                      "-RemoteIPAddress $network", script)
        self.assertIn("Disable-VMIntegrationService -VMName $env:POOL_VM -Name 'Guest Service Interface'", script)
        allows = re.findall(r"-Action Allow .*-Weight (\d+)", script)
        self.assertEqual(len(allows), 3)  # DHCP and DNS only, weighed above every deny
        self.assertGreater(min(int(w) for w in allows), 200)
        self.assertNotRegex(script, r"Add-VMHardDiskDrive|Add-VMDvdDrive|Enable-VMIntegrationService|New-SmbShare")

    def test_the_configuration_goes_over_powershell_direct_on_stdin(self) -> None:
        states = iter(["Running", "Running", "Off"])
        vm = self.backend(**{"State.ToString": lambda argv, env: Done(stdout=next(states).encode())})
        self.assertEqual(vm.run_job("metacodes-s1-x", JIT), "powered off after its job")
        handover = next(s for s in self.scripts() if "C:\\pool\\jit" in s[0])
        self.assertIn("Invoke-Command -VMName $env:POOL_VM -Credential $cred", handover[0])
        self.assertEqual(handover[1], JIT.encode())
        self.assertFalse(any(JIT in script or JIT in json.dumps(env) for script, _, env in self.scripts()))
        self.assertTrue(all("POOL_PASSWORD_FILE" in env for _, _, env in self.scripts()))
        self.assertFalse(any((self.tmp / "vm_password").name in script for script, _, _ in self.scripts()))

    def test_a_job_past_its_limit_is_stopped_and_the_vm_destroyed(self) -> None:
        clock = iter(NOW + 600 * i for i in range(100))
        vm = pool.HyperVBackend(self.config, run=FakeRun(self.calls, {"State.ToString": Done(stdout=b"Running")}),
                                now=lambda: next(clock), sleep=lambda _: None)
        self.assertIn("job limit", vm.run_job("metacodes-s1-x", JIT))
        vm.destroy("metacodes-s1-x")
        self.assertIn("Stop-VM -VM $vm -TurnOff -Force", self.scripts()[-1][0])
        self.assertIn("Remove-Item -LiteralPath $disk -Force", self.scripts()[-1][0])

    def test_the_task_starts_the_slot_at_boot_under_the_pool_account(self) -> None:
        text = pool.HyperVBackend(self.config).service(1, "C:\\Python312\\python.exe", "C:\\m\\vm_pool.py",
                                                       "C:\\Users\\ci-host\\.metacodes-runner\\config.json")
        self.assertIn("New-ScheduledTaskTrigger -AtStartup", text)
        self.assertIn("-RunLevel Highest", text)
        self.assertIn("metacodes-vm-pool-slot1", text)
        self.assertIn("slot 1", text)


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
        subprocess.run(["openssl", "genrsa", "-out", str(self.tmp / "app.pem"), "2048"], check=True, capture_output=True)
        self.config = pool.parse_config(base_config(self.tmp, api_url="https://api.example"))

    def github(self, routes):
        opener = FakeOpener(routes)
        return pool.GitHub(self.config, opener=opener, now=lambda: NOW), opener

    def test_the_app_jwt_is_signed_by_the_private_key(self) -> None:
        github, _ = self.github({})
        header, payload, signature = github.app_jwt().split(".")
        def decode(part):
            return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))

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
                "gateway_open": [], "shared": [], "secret_files": [], "secret_env": [],
                "tools": {"python3": True, "rg": True}, "runner": True}

    def test_judge(self) -> None:
        blocked = [{"host": "192.168.31.20", "port": 22, "what": "the host", "host_reaches": True},
                   {"host": "10.0.0.1", "port": 80, "what": "a private range", "host_reaches": False}]
        verdicts = {(check, detail.split(" ")[0]): verdict for check, verdict, detail in pool.judge(self.PROBE_OK, blocked)}
        self.assertEqual(verdicts[("isolation", "192.168.31.20:22")], "PASS")
        self.assertEqual(verdicts[("isolation", "10.0.0.1:80")], "NOTE")
        self.assertNotIn("FAIL", verdicts.values())
        leaky = dict(self.PROBE_OK, tcp=self.PROBE_OK["tcp"] + [{"host": "192.168.31.20", "port": 22, "open": True}],
                     shared=["host on /Volumes/My Shared Files (virtiofs)"], secret_files=["/Users/admin/.ssh/id_rsa"],
                     secret_env=["GH_TOKEN"], gateway_open=[445], tools={"rg": False}, runner=False)
        failed = [check for check, verdict, _ in pool.judge(leaky, blocked) if verdict == "FAIL"]
        self.assertEqual(sorted(set(failed)), ["image runner", "image tools", "isolation", "no credentials",
                                               "no host directories", "no secret variables"])
        offline = dict(self.PROBE_OK, tcp=[{"host": "github.com", "port": 443, "open": False}])
        self.assertIn(("internet", "FAIL", "github.com:443"), pool.judge(offline, []))

    def test_verify_boots_two_vms_probes_from_the_first_and_destroys_both(self) -> None:
        vm = FakeBackend(self.calls, probe=self.PROBE_OK)
        out = io.StringIO()
        with redirect_stdout(out):
            code = pool.verify(self.config, self.host(vm=vm), reaches=lambda h, p: True)
        self.assertEqual(code, 0, out.getvalue())
        created = [c[1] for c in self.calls if c[0] == "create"]
        self.assertEqual(len(created), 2)
        self.assertEqual(sorted(c[1] for c in self.calls if c[0] == "destroy"), sorted(created))
        probe = next(c for c in self.calls if c[0] == "probe")
        self.assertEqual(probe[1], created[0])
        hosts = {t["host"] for t in probe[2]}
        self.assertTrue({"github.com", "192.168.31.20", "192.168.31.1", "192.168.64.3"} <= hosts)

    def test_a_failed_check_fails_verify_and_still_destroys(self) -> None:
        vm = FakeBackend(self.calls, probe=dict(self.PROBE_OK, gateway_open=[22]))
        with redirect_stdout(io.StringIO()):
            self.assertEqual(pool.verify(self.config, self.host(vm=vm), reaches=lambda h, p: True), 1)
        self.assertEqual(len([c for c in self.calls if c[0] == "destroy"]), 2)


class CheckTest(PoolTestCase):
    def test_check_reports_keys_image_retired_runners_and_groups(self) -> None:
        for name in ("app.pem", "vm_key"):
            (self.tmp / name).write_text("k", encoding="utf-8")
            os.chmod(self.tmp / name, 0o600)
        def which(tool):
            return f"/usr/bin/{tool}"

        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(pool.check(self.config, self.host(), which), 0, out.getvalue())
            if os.name != "nt":
                os.chmod(self.tmp / "app.pem", 0o644)
            github = FakeGitHub(self.calls, runners=[{"id": 1, "name": "AppledeMac-Studio"}, {"id": 2, "name": "AIPC"}])
            self.assertEqual(pool.check(self.config, self.host(github=github), which), 1)
        report = out.getvalue()
        if os.name != "nt":
            self.assertIn("FAIL  App private key", report)
        self.assertIn("FAIL  persistent runners retired: AppledeMac-Studio, AIPC", report)


class TartServiceTest(PoolTestCase):
    def test_each_slot_is_a_kept_alive_agent_in_the_users_session(self) -> None:
        plist = plistlib.loads(pool.TartBackend(self.config).service(
            2, "/usr/bin/python3", "/x/vm_pool.py", "/Users/ci-host/.metacodes-runner/config.json").encode())
        self.assertEqual(plist["Label"], "ai.metask.metacodes-vm-pool.slot2")
        self.assertEqual(plist["ProgramArguments"][-2:], ["slot", "2"])
        self.assertTrue(plist["KeepAlive"])
        self.assertEqual(plist["LimitLoadToSessionType"], "Aqua")


class ProvisionTest(unittest.TestCase):
    def runner_pin(self, text, variable):
        return re.search(r"^\$?%s ?= ?'?([^'\s]+)'?$" % variable, text, re.M).group(1)

    @unittest.skipIf(os.name == "nt", "bash")
    def test_the_macos_script_parses_and_refuses_anything_but_a_public_key(self) -> None:
        self.assertEqual(subprocess.run(["bash", "-n", str(MACOS_PROVISION)]).returncode, 0)
        for argv in ([], ["not a key"], ["-----BEGIN OPENSSH PRIVATE KEY-----"]):
            with self.subTest(argv=argv):
                proc = subprocess.run(["bash", str(MACOS_PROVISION), *argv], capture_output=True, text=True,
                                      env={"PATH": "/usr/bin:/bin", "HOME": tempfile.gettempdir()})
                self.assertNotEqual(proc.returncode, 0)
                self.assertNotIn("provisioned", proc.stdout)

    def test_both_images_pin_one_checked_runner(self) -> None:
        macos = MACOS_PROVISION.read_text(encoding="utf-8")
        windows = WINDOWS_PROVISION.read_text(encoding="utf-8")
        self.assertEqual(self.runner_pin(macos, "RUNNER_VERSION"), self.runner_pin(windows, "RunnerVersion"))
        self.assertRegex(self.runner_pin(macos, "RUNNER_SHA256"), r"^[0-9a-f]{64}$")
        self.assertRegex(self.runner_pin(windows, "RunnerSha256"), r"^[0-9a-f]{64}$")
        self.assertIn("shasum -a 256 -c", macos)
        self.assertIn("Get-FileHash -Algorithm SHA256", windows)
        self.assertIn("actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz", macos)
        self.assertIn("actions-runner-win-x64-$RunnerVersion.zip", windows)

    def test_the_windows_image_runs_one_job_per_boot_and_keeps_no_credential(self) -> None:
        text = WINDOWS_PROVISION.read_text(encoding="utf-8")
        job = re.search(r"@'\n(.*?)\n'@", text, re.S).group(1)
        self.assertIn("C:\\pool\\jit", job)
        self.assertIn("Remove-Item -LiteralPath $jitPath -Force", job)  # the configuration is gone before the job
        self.assertTrue(job.strip().endswith("Stop-Computer -Force"))   # one job, then the VM powers off
        self.assertIn("New-ScheduledTaskTrigger -AtStartup", text)
        self.assertIn("Disable-LocalUser -Name $InstallAccount", text)
        self.assertIn("'the runner password must be at least 24 characters'", text)
        # The account the host drives is the one that runs the job.
        self.assertIn("-User runner -Password $RunnerPassword", text)


if __name__ == "__main__":
    unittest.main()
