"""Contract tests for the Harbor dataset adapters (scripts/eval/harbor/adapters).

No network and no Docker: every adapter is built from the small fixtures in
scripts/eval/fixtures/harbor_adapters/, the generated task directories are
checked against the Harbor 0.26 task schema, and the real graders run against
each task's oracle answer and against wrong answers. The ALFWorld sidecar API
and the agent's CLI run over loopback with a scripted game in place of
TextWorld. What only a Docker host can check (image builds, `harbor run -a
oracle`, the TextWorld backend in compose) is listed in the adapters README.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Dict, List, Tuple
from unittest import mock

from scripts.eval.harbor.adapters import _common as c
from scripts.eval.harbor.adapters import alfworld, humaneval, livemath, mbpp, mbpp_sanitized, searchqa
from scripts.eval.tests.posix_only import POSIX

ROOT = Path(__file__).resolve().parents[3]
ADAPTER_DIR = ROOT / "scripts" / "eval" / "harbor" / "adapters"
FIXTURES = ROOT / "scripts" / "eval" / "fixtures" / "harbor_adapters"
BASH = shutil.which("bash")


def load_module(path: Path, name: str):
    import importlib.util

    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


# --- a TOML reader for the subset task_toml writes (py3.9 has no tomllib) ----


def parse_task_toml(text: str) -> Dict[str, object]:
    root: Dict[str, object] = {}
    current = root
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[["):
            path = line[2:-2].split(".")
            parent = root
            for key in path[:-1]:
                parent = parent.setdefault(key, {})  # type: ignore[assignment]
            current = {}
            parent.setdefault(path[-1], []).append(current)  # type: ignore[union-attr]
        elif line.startswith("["):
            current = root
            for key in line[1:-1].split("."):
                current = current.setdefault(key, {})  # type: ignore[assignment]
        else:
            key, _, value = line.partition(" = ")
            if not re.fullmatch(r"[A-Za-z0-9_-]+", key):
                raise ValueError("bad key %r" % key)
            current[key] = json.loads(value)
    return root


# Harbor 0.26 src/harbor/models/task/config.py field names.
SCHEMA = {
    "": {"schema_version", "task", "metadata", "verifier", "agent", "environment", "solution", "source",
         "multi_step_reward_strategy", "steps", "artifacts"},
    "task": {"name", "version", "description", "authors", "keywords"},
    "agent": {"timeout_sec", "user", "network_mode", "allowed_hosts"},
    "verifier": {"timeout_sec", "env", "user", "environment_mode", "environment", "collect", "network_mode",
                 "allowed_hosts"},
    "environment": {"build_timeout_sec", "docker_image", "os", "cpus", "memory_mb", "storage_mb", "gpus",
                    "gpu_types", "tpu", "mcp_servers", "env", "skills_dir", "healthcheck", "workdir",
                    "allow_internet", "network_mode", "allowed_hosts"},
    "collect": {"command", "service", "timeout_sec", "user"},
    "artifact": {"source", "destination", "exclude", "service"},
}
ORG_NAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*/[a-zA-Z0-9][a-zA-Z0-9._-]*$")
PINNED_FROM = re.compile(r"^FROM (--platform=linux/amd64 )?[a-z0-9.:/_-]+@sha256:[0-9a-f]{64}$")


class TaskChecks(unittest.TestCase):
    """Harbor 0.26 structure checks shared by every adapter's tests."""

    def check_task_dir(self, task_dir: Path) -> Dict[str, object]:
        for rel in ("instruction.md", "task.toml", "environment/Dockerfile", "solution/solve.sh",
                    "tests/test.sh", "tests/Dockerfile"):
            self.assertTrue((task_dir / rel).is_file(), f"{task_dir.name}: missing {rel}")
        if POSIX:
            for rel in ("solution/solve.sh", "tests/test.sh"):
                self.assertTrue(os.access(task_dir / rel, os.X_OK), f"{task_dir.name}: {rel} not executable")
        config = parse_task_toml((task_dir / "task.toml").read_text(encoding="utf-8"))
        self.assertLessEqual(set(config), SCHEMA[""])
        self.assertEqual(config["schema_version"], "1.4")
        for section in ("task", "agent", "verifier", "environment"):
            self.assertLessEqual(set(config[section]), SCHEMA[section], section)  # type: ignore[arg-type]
        task = config["task"]
        self.assertRegex(task["name"], ORG_NAME)  # type: ignore[index]
        self.assertEqual(task["name"].split("/", 1)[1], task_dir.name)  # type: ignore[index]
        verifier = config["verifier"]
        self.assertEqual(verifier["environment_mode"], "separate")  # type: ignore[index]
        self.assertLessEqual(set(verifier["environment"]), SCHEMA["environment"])  # type: ignore[index]
        self.assertEqual(verifier["environment"]["network_mode"], "no-network")  # type: ignore[index]
        for hook in verifier.get("collect", []):  # type: ignore[union-attr]
            self.assertLessEqual(set(hook), SCHEMA["collect"])
        artifacts = config["artifacts"]
        self.assertTrue(artifacts)
        for item in artifacts:  # type: ignore[union-attr]
            if isinstance(item, dict):
                self.assertLessEqual(set(item), SCHEMA["artifact"])
            else:
                self.assertTrue(item.startswith("/"))
        for dockerfile in task_dir.rglob("Dockerfile"):
            froms = [line for line in dockerfile.read_text(encoding="utf-8").splitlines() if line.startswith("FROM")]
            self.assertTrue(froms)
            for line in froms:
                self.assertRegex(line, PINNED_FROM, f"{dockerfile}: base image not pinned by digest")
        # The verifier image owns /tests (separate mode does not upload tests/).
        verifier_docker = (task_dir / "tests/Dockerfile").read_text(encoding="utf-8")
        self.assertIn("test.sh", verifier_docker)
        self.assertIn("/tests/", verifier_docker)
        return config

    def assert_hidden(self, task_dir: Path, secret: str) -> None:
        """`secret` (a gold answer, hidden tests) is nowhere the agent can read."""
        self.assertNotIn(secret, (task_dir / "instruction.md").read_text(encoding="utf-8"))
        for path in (task_dir / "environment").rglob("*"):
            if path.is_file():
                self.assertNotIn(secret.encode("utf-8"), path.read_bytes(), str(path))


def run_solve(task_dir: Path, mapping: Dict[str, Path]) -> None:
    """Run solution/solve.sh with its absolute paths mapped into a scratch dir."""
    script = (task_dir / "solution/solve.sh").read_text(encoding="utf-8")
    for container_path, host_path in mapping.items():
        script = script.replace(container_path, str(host_path).replace("\\", "/"))
    subprocess.run([BASH, "-c", script], check=True, capture_output=True)


def run_grader(task_dir: Path, grader: str, flag: str, artifact: Path, scratch: Path) -> Tuple[int, Dict[str, object]]:
    reward = scratch / "reward.txt"
    details = scratch / "grade.json"
    if os.name == "nt":
        # The graders run only inside the Linux task containers (uid switches,
        # pass_fds, POSIX process groups); a Windows host cannot run them.
        raise unittest.SkipTest("graders run only in Linux task containers")
    for path in (reward, details):
        if path.exists():
            path.unlink()
    proc = subprocess.run(
        [sys.executable, str(task_dir / "tests" / grader), "--spec", str(task_dir / "tests/spec.json"),
         flag, str(artifact), "--reward", str(reward), "--details", str(details)],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr
    return int(reward.read_text().strip()), json.loads(details.read_text())


# --- catalog contract ----------------------------------------------------------


MODULES = {
    "humaneval": humaneval,
    "mbpp": mbpp,
    "mbpp-sanitized": mbpp_sanitized,
    "alfworld": alfworld,
    "searchqa": searchqa,
    "livemath": livemath,
}
CATALOG_TASK = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,160}$")  # suites.TASK
HAN = re.compile("[一-鿿]")


class AdapterContractTest(unittest.TestCase):
    def test_every_adapter_exposes_the_catalog_contract(self) -> None:
        for suite_id, module in MODULES.items():
            self.assertEqual(module.SUITE_ID, suite_id)
            suite = module.SUITE
            self.assertLessEqual(
                set(suite), {"name", "description", "default_tasks", "max_tasks", "max_concurrency", "arch"}
            )
            self.assertRegex(suite["description"], HAN)
            self.assertTrue(type(suite["max_tasks"]) is int and 1 <= suite["max_tasks"] <= 200)
            if "max_concurrency" in suite:
                self.assertTrue(type(suite["max_concurrency"]) is int and suite["max_concurrency"] >= 1)
            self.assertTrue(callable(module.prepare) and callable(module.tasks))
            self.assertTrue(suite["default_tasks"], suite_id)
            for tid in suite["default_tasks"]:
                self.assertRegex(tid, CATALOG_TASK)

    def test_livemath_check_reports_a_missing_token(self) -> None:
        class Ctx:
            env: Dict[str, str] = {}

            def dataset_dir(self, suite):
                return Path(tempfile.gettempdir()) / "no-such-livemath-dataset"

        with mock.patch.object(c, "huggingface_token", lambda: None):
            self.assertTrue(livemath.check(Ctx()))
            ctx = Ctx()
            ctx.env = {"HF_TOKEN": "x"}
            self.assertEqual(livemath.check(ctx), [])


class BenchAssetsTest(unittest.TestCase):
    def test_bench_assets_embed_every_runtime_file(self) -> None:
        listed = set(re.findall(r'\.path = "([^"]+)"', (ROOT / "scripts/bench_assets.zig").read_text()))
        for path in ADAPTER_DIR.rglob("*.py"):
            rel = path.relative_to(ROOT).as_posix()
            self.assertIn(rel, listed, f"{rel} is not embedded in scripts/bench_assets.zig")


# --- pins and the idempotent prepare flow ---------------------------------------


class PrepareFlowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _source(self, data: bytes) -> Path:
        path = self.tmp / "upstream.bin"
        path.write_bytes(data)
        return path

    def test_fetch_verifies_and_fails_closed(self) -> None:
        source = self._source(b"pinned bytes")
        good = c.Pin(name="f.bin", url=source.as_uri(), sha256=c.sha256_bytes(b"pinned bytes"), size=12)
        cache = self.tmp / "cache"
        self.assertEqual(c.fetch(good, cache).read_bytes(), b"pinned bytes")
        # A cached, verified copy is used without touching the URL.
        source.unlink()
        self.assertEqual(c.fetch(good, cache).read_bytes(), b"pinned bytes")
        source = self._source(b"tampered bytes")
        bad = c.Pin(name="g.bin", url=source.as_uri(), sha256=c.sha256_bytes(b"pinned bytes"))
        with self.assertRaises(c.SourceIntegrityError):
            c.fetch(bad, cache)
        self.assertEqual(sorted(p.name for p in cache.iterdir()), ["f.bin"])

    def test_git_blob_pin(self) -> None:
        data = b"{\"question\": 1}\n"
        blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        source = self._source(data)
        pin = c.Pin(name="x.jsonl", url=source.as_uri(), git_blob_sha1=blob, size=len(data))
        self.assertEqual(c.fetch(pin, self.tmp / "cache").read_bytes(), data)
        wrong = c.Pin(name="y.jsonl", url=source.as_uri(), git_blob_sha1="0" * 40)
        with self.assertRaises(c.SourceIntegrityError):
            c.fetch(wrong, self.tmp / "cache")
        with self.assertRaises(ValueError):
            c.Pin(name="z", url="u")  # no content check at all

    def test_gated_source_needs_a_token(self) -> None:
        pin = c.Pin(name="a.jsonl", url="https://huggingface.co/x", git_blob_sha1="0" * 40, hf_auth=True)
        with mock.patch.dict(os.environ, {"HF_HOME": str(self.tmp)}, clear=True):
            with self.assertRaises(c.SourceUnavailableError):
                c.fetch(pin, self.tmp / "cache")

    def test_prepare_is_idempotent_and_repairs(self) -> None:
        calls: List[str] = []

        def fetch_sources(cache: Path) -> Dict[str, Path]:
            calls.append("fetch")
            cache.mkdir(parents=True, exist_ok=True)
            (cache / "in.txt").write_text("v1")
            return {"in.txt": cache / "in.txt"}

        def build(inputs: Dict[str, Path], out: Path) -> None:
            for name in ("t-1", "t-2"):
                c.write_task(out / name, {"task.toml": "x = 1\n", "instruction.md": inputs["in.txt"].read_text()})

        def prepare(fingerprint: str = "fp1") -> Path:
            return c.prepare_dataset(self.tmp / "dest", suite_id="demo", fingerprint=fingerprint,
                                     fetch_sources=fetch_sources, build=build, provenance={})

        dataset = prepare()
        self.assertEqual(dataset, self.tmp / "dest")
        self.assertEqual(c.task_ids(dataset), ["t-1", "t-2"])
        self.assertTrue((dataset / c.MARKER_NAME).is_file())
        self.assertEqual(prepare(), dataset)
        self.assertEqual(calls, ["fetch"], "a complete dataset must not fetch again")
        (dataset / "t-2" / "instruction.md").write_text("tampered")
        prepare()
        self.assertEqual((dataset / "t-2" / "instruction.md").read_text(), "v1")
        self.assertEqual(len(calls), 2)
        prepare("fp2")  # changed pins or templates rebuild
        self.assertEqual(len(calls), 3)
        self.assertEqual(sorted(p.name for p in dataset.iterdir()), [".cache", c.MARKER_NAME, "t-1", "t-2"])
        # An interrupted rebuild (marker gone) is not mistaken for a complete dataset.
        (dataset / c.MARKER_NAME).unlink()
        prepare("fp2")
        self.assertEqual(len(calls), 4)

    def test_adapter_prepare_uses_the_pins_once(self) -> None:
        fixture = self.tmp / "he.jsonl.gz"
        with gzip.open(fixture, "wb") as handle:
            handle.write((FIXTURES / "humaneval.sample.jsonl").read_bytes())
        fetched: List[str] = []

        def fake_fetch(pin: c.Pin, cache: Path) -> Path:
            self.assertEqual(pin, humaneval.PIN)
            fetched.append(pin.name)
            return fixture

        with mock.patch.object(c, "fetch", fake_fetch):
            first = humaneval.prepare(self.tmp / "dest")
            second = humaneval.prepare(self.tmp / "dest")
        self.assertEqual(first, second)
        self.assertEqual(fetched, ["HumanEval.jsonl.gz"])
        self.assertEqual(humaneval.tasks(first), ["humaneval-0", "humaneval-2", "humaneval-38"])

    def test_remote_zip_reads_members(self) -> None:
        archive = self.tmp / "a.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("a.json", json.dumps({"k": "v" * 500}))
            zf.writestr("b.txt", b"plain", compress_type=zipfile.ZIP_STORED)
        remote = c.RemoteZip(c.FileRangeSource(archive))
        self.assertEqual(sorted(remote.names()), ["a.json", "b.txt"])
        self.assertEqual(json.loads(remote.read("a.json"))["k"], "v" * 500)
        self.assertEqual(remote.read("b.txt"), b"plain")

    def test_task_toml_is_valid_toml(self) -> None:
        config = c.base_task_config(
            task_id="x-1", description='quote " and \\ and \u00e9 and \x7f', keywords=["k"], metadata={"n": 1},
            artifacts=[{"source": "/a", "service": "s"}], agent_timeout_sec=1, verifier_timeout_sec=2,
            collect=[{"service": "s", "command": "echo \"hi\"", "timeout_sec": 3.0}],
        )
        text = c.task_toml(config)
        parsed = parse_task_toml(text)
        self.assertEqual(parsed["task"]["description"], config["task"]["description"])  # type: ignore[index]
        self.assertEqual(parsed["artifacts"], [{"source": "/a", "service": "s"}])
        try:
            import tomllib  # type: ignore[import-not-found]
        except ImportError:  # Python < 3.11
            return
        self.assertEqual(tomllib.loads(text), parsed)


# --- code tasks -----------------------------------------------------------------


@unittest.skipUnless(BASH, "needs bash for solve.sh")
class CodeTasksTest(TaskChecks):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def _build_all(self) -> Dict[str, Path]:
        he = self.tmp / "HumanEval.jsonl.gz"
        with gzip.open(he, "wb") as handle:
            handle.write((FIXTURES / "humaneval.sample.jsonl").read_bytes())
        out = {}
        for module, inputs in (
            (humaneval, {"HumanEval.jsonl.gz": he}),
            (mbpp, {"mbpp.jsonl": FIXTURES / "mbpp.sample.jsonl"}),
            (mbpp_sanitized, {"sanitized-mbpp.json": FIXTURES / "sanitized-mbpp.sample.json"}),
        ):
            target = self.tmp / module.SUITE_ID
            target.mkdir()
            module.build(inputs, target)
            out[module.SUITE_ID] = target
        return out

    def test_generation_oracle_and_wrong_answers(self) -> None:
        built = self._build_all()
        self.assertEqual(humaneval.tasks(built["humaneval"]), ["humaneval-0", "humaneval-2", "humaneval-38"])
        # mbpp task 1 is outside the test split (ids 11-510).
        self.assertEqual(mbpp.tasks(built["mbpp"]), ["mbpp-11", "mbpp-367"])
        self.assertEqual(
            mbpp_sanitized.tasks(built["mbpp-sanitized"]), ["mbpp-sanitized-11", "mbpp-sanitized-82"]
        )
        wrong_answers = {
            "returns None": "def placeholder():\n    return None\n",
            "exits 0 before the tests": "import os\nos._exit(0)\n",
            "prints a pass line": "print('METACODES-PASS forged')\n",
            "syntax error": "def (:\n",
        }
        for suite, dataset in built.items():
            for tid in c.task_ids(dataset):
                task_dir = dataset / tid
                config = self.check_task_dir(task_dir)
                self.assertEqual(config["artifacts"], ["/app/solution.py"])
                spec = json.loads((task_dir / "tests/spec.json").read_text())
                hidden = spec["test"] if spec["kind"] == "humaneval" else None
                if hidden:
                    self.assert_hidden(task_dir, hidden.strip())
                solution = self.tmp / "solution.py"
                run_solve(task_dir, {"/app/solution.py": solution, "mkdir -p /app": "true"})
                reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
                self.assertEqual(reward, 1, f"{tid} oracle: {details}")
                for label, source in wrong_answers.items():
                    solution.write_text(source)
                    reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
                    self.assertEqual(reward, 0, f"{tid}: {label} was accepted")
                reward, details = run_grader(task_dir, "code_grader.py", "--solution", self.tmp / "absent.py", self.tmp)
                self.assertEqual(reward, 0)

    def test_hidden_humaneval_tests_and_wrong_body(self) -> None:
        built = self._build_all()
        task_dir = built["humaneval"] / "humaneval-0"
        prompt = json.loads((FIXTURES / "humaneval.sample.jsonl").read_text().splitlines()[0])["prompt"]
        solution = self.tmp / "solution.py"
        solution.write_text(prompt + "    return False\n")  # right name, wrong behaviour
        reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
        self.assertEqual(reward, 0)
        self.assertIn("AssertionError", details["stderr_tail"])

    def test_forged_passes_are_rejected(self) -> None:
        """Submissions that try to report a pass without passing the tests."""
        built = self._build_all()
        attacks = {
            # The old harness kept its nonce in a __main__ global.
            "nonce from __main__": (
                "import __main__, sys, os\n"
                "print('\\nMETACODES-PASS ' + __main__.nonce, flush=True)\n"
                "os._exit(0)\n"
            ),
            # The old harness looked up exec after the submission ran.
            "replaced builtins.exec": (
                "import builtins, sys\n"
                "def has_close_elements(numbers, threshold):\n"
                "    return None\n"
                "def fake_exec(code, *args, **kwargs):\n"
                "    if getattr(code, 'co_filename', '') == 'test.py':\n"
                "        sys.stdout.write('\\nMETACODES-PASS ' + sys.modules['__main__'].nonce + '\\n')\n"
                "        sys.stdout.flush()\n"
                "        import os; os._exit(0)\n"
                "    return real_exec(code, *args, **kwargs)\n"
                "real_exec = builtins.exec\n"
                "builtins.exec = fake_exec\n"
            ),
            # Equality that always holds defeats `assert candidate(x) == y` in-process.
            "always-equal result": (
                "class Equal:\n"
                "    def __eq__(self, other):\n"
                "        return True\n"
                "    __hash__ = object.__hash__\n"
                "def has_close_elements(numbers, threshold):\n"
                "    return Equal()\n"
            ),
            # Ending a test's iteration early from inside the candidate.
            "StopIteration from the candidate": (
                "def has_close_elements(numbers, threshold):\n"
                "    raise StopIteration\n"
            ),
            # Shadowing a builtin the tests use.
            "shadowed builtins": (
                "def has_close_elements(numbers, threshold):\n"
                "    return None\n"
                "def abs(x):\n"
                "    return 0\n"
                "__builtins__ = {}\n"
            ),
            # Writing a pass line to every descriptor, then exiting 0.
            "pass line on every fd": (
                "import os\n"
                "for fd in range(3, 64):\n"
                "    try:\n"
                "        os.write(fd, b'\\nMETACODES-PASS\\n')\n"
                "    except OSError:\n"
                "        pass\n"
                "print('METACODES-PASS', flush=True)\n"
                "os._exit(0)\n"
            ),
        }
        # A hand-written reply that names a callable outside the whitelist.
        planted = self.tmp / "planted"
        attacks["crafted reply pickle"] = (
            "import os, struct, sys\n"
            "wfd = int(sys.argv[sys.argv.index('--wfd') + 1])\n"
            f"payload = b'cos\\nsystem\\n(S' + repr('touch ' + {str(planted)!r}).encode() + b'\\ntR.'\n"
            "os.write(wfd, struct.pack('>I', len(payload)) + payload)\n"
            "os._exit(0)\n"
        )
        task_dir = built["humaneval"] / "humaneval-0"
        solution = self.tmp / "solution.py"
        accepted = []
        for label, source in attacks.items():
            solution.write_text(source)
            reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
            if reward:
                accepted.append(label)
        self.assertEqual(accepted, [])
        self.assertFalse(planted.exists(), "the test driver ran a callable the submission named")

    def test_humaneval_runs_the_prompt_before_the_solution(self) -> None:
        """HumanEval/38's tests and its canonical body call encode_cyclic, which only the prompt defines."""
        built = self._build_all()
        task_dir = built["humaneval"] / "humaneval-38"
        solution = self.tmp / "solution.py"
        # A correct completion that relies on the prompt's helper, as the
        # reference harness (prompt + completion + test) allows.
        solution.write_text("def decode_cyclic(s: str):\n    return encode_cyclic(encode_cyclic(s))\n")
        reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
        self.assertEqual(reward, 1, details)
        # A self-contained module that redefines nothing from the prompt.
        solution.write_text(
            "def decode_cyclic(s):\n"
            "    groups = [s[(3 * i):min((3 * i + 3), len(s))] for i in range((len(s) + 2) // 3)]\n"
            "    groups = [(g[-1] + g[:-1]) if len(g) == 3 else g for g in groups]\n"
            "    return ''.join(groups)\n"
        )
        reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
        self.assertEqual(reward, 1, details)
        # Returning the input unchanged is still wrong.
        solution.write_text("def decode_cyclic(s):\n    return s\n")
        self.assertEqual(run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)[0], 0)

    @unittest.skipUnless(POSIX, "process groups are POSIX")
    def test_no_submission_process_outlives_grading(self) -> None:
        """A background child of the submission is killed before reward.txt is written."""
        built = self._build_all()
        task_dir = built["humaneval"] / "humaneval-0"
        late = self.tmp / "late-write"
        solution = self.tmp / "solution.py"
        solution.write_text(
            "import os, time\n"
            "if os.fork() == 0:\n"
            "    time.sleep(1.5)\n"
            f"    open({str(late)!r}, 'w').write('1')\n"
            "    os._exit(0)\n"
            "def has_close_elements(numbers, threshold):\n"
            "    return any(abs(a - b) < threshold for i, a in enumerate(numbers) for b in numbers[i + 1:])\n"
        )
        reward, details = run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)
        self.assertEqual(reward, 1, details)
        import time

        time.sleep(2.5)
        self.assertFalse(late.exists(), "a process the submission forked survived grading")

    def test_verifier_image_hides_the_tests_from_the_sandbox(self) -> None:
        built = self._build_all()
        dockerfile = (built["humaneval"] / "humaneval-0" / "tests/Dockerfile").read_text()
        self.assertIn("chmod 0600 /tests/spec.json", dockerfile)
        self.assertIn("chmod 0755 /logs /logs/verifier", dockerfile)

    def test_mbpp_tests_reach_only_the_reference_names(self) -> None:
        names = mbpp.solution_names
        # MBPP 126: the reference itself shadows the builtin the test calls.
        self.assertEqual(names("def sum(a, b):\n    return a + b\n", "", ["assert sum(10,15) == 6"]), ["sum"])
        # A builtin the reference does not define stays the driver's own.
        self.assertEqual(names("def f(x):\n    return x\n", "", ["assert abs(f(-1)) == 1"]), ["f"])
        # Objects built by test_setup_code (MBPP 367) and solution classes.
        self.assertEqual(
            names("class Node:\n    pass\ndef height(n):\n    return 0\n", "root = Node()\n",
                  ["assert height(root) == 3"]),
            ["height", "root"],
        )
        built = self._build_all()
        spec = json.loads((built["mbpp"] / "mbpp-367" / "tests/spec.json").read_text())
        self.assertIn("root", spec["names"])
        # A submission's own builtin shadow cannot reach an MBPP assert.
        task_dir = built["mbpp"] / "mbpp-11"
        tests = json.loads((task_dir / "tests/spec.json").read_text())["tests"]
        function = re.match(r"assert\s+(\w+)", tests[0]).group(1)
        solution = self.tmp / "solution.py"
        solution.write_text(
            f"def {function}(*args):\n    return None\n"
            "class Equal:\n    def __eq__(self, other):\n        return True\n"
            "def str(*args):\n    return Equal()\n"
            "def repr(*args):\n    return Equal()\n"
        )
        self.assertEqual(run_grader(task_dir, "code_grader.py", "--solution", solution, self.tmp)[0], 0)

    def test_mbpp_setup_and_imports_reach_the_tests(self) -> None:
        built = self._build_all()
        spec = json.loads((built["mbpp-sanitized"] / "mbpp-sanitized-82" / "tests/spec.json").read_text())
        self.assertTrue(spec["imports"])
        spec = json.loads((built["mbpp"] / "mbpp-367" / "tests/spec.json").read_text())
        self.assertTrue(spec["setup"])


# --- SearchQA -------------------------------------------------------------------


def searchqa_zip(path: Path) -> List[str]:
    members = json.loads((FIXTURES / "searchqa.sample.json").read_text())["members"]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for member in members:
            zf.writestr(member["name"], json.dumps(member["record"]))
    return [m["name"] for m in members]


@unittest.skipUnless(BASH, "needs bash for solve.sh")
class SearchQATest(TaskChecks):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.archive = self.tmp / "test.zip"
        searchqa_zip(self.archive)

    def _subset(self, size: int):
        remote = c.RemoteZip(c.FileRangeSource(self.archive))
        return searchqa.select_subset(remote, size, None)

    def test_subset_is_deterministic_and_pinned(self) -> None:
        chosen = self._subset(3)
        names = [name for name, _ in chosen]
        self.assertNotIn("000103-1000_jeopardy_unanswered_600.json", names)  # no answer
        self.assertEqual(names, sorted(names, key=lambda n: hashlib.sha256(n.encode()).hexdigest()))
        digest = searchqa.subset_digest(chosen)
        remote = c.RemoteZip(c.FileRangeSource(self.archive))
        self.assertEqual(searchqa.select_subset(remote, 3, digest), chosen)
        with self.assertRaises(c.SourceIntegrityError):
            searchqa.select_subset(remote, 3, "0" * 64)
        with self.assertRaises(c.SourceIntegrityError):
            searchqa.select_subset(remote, 4, None)  # only three usable questions

    def test_prepare_fetches_once_and_builds(self) -> None:
        digest = searchqa.subset_digest(self._subset(3))
        sources: List[str] = []

        def fake_source(url: str, size: int) -> c.RangeSource:
            sources.append(url)
            return c.FileRangeSource(self.archive)

        with mock.patch.object(searchqa, "SUBSET_SIZE", 3), mock.patch.object(searchqa, "SUBSET_SHA256", digest), \
                mock.patch.object(c, "HttpRangeSource", fake_source):
            dataset = searchqa.prepare(self.tmp / "dest")
            searchqa.prepare(self.tmp / "dest")
        self.assertEqual(sources, [searchqa.ZIP_URL])
        ids = searchqa.tasks(dataset)
        self.assertEqual(sorted(ids), ["searchqa-101", "searchqa-102", "searchqa-104"])
        cases = {
            "searchqa-101": (["Federal Reserve", "What is the Federal Reserve?"], ["the central bank", "Fed"]),
            "searchqa-102": (["cocoa", "Chocolate", "cocoa (or chocolate)"], ["coffee", "cocoa beans"]),
            "searchqa-104": (["Poe", "Edgar Allan Poe"], ["Edgar", "Edgar Allan"]),
        }
        for tid, (right, wrong) in cases.items():
            task_dir = dataset / tid
            self.check_task_dir(task_dir)
            gold = json.loads((task_dir / "tests/spec.json").read_text())["answer"]
            for path in (task_dir / "environment").rglob("*"):
                self.assertNotIn(gold.encode(), path.read_bytes() if path.is_file() else b"")
            answer = self.tmp / "answer.txt"
            run_solve(task_dir, {"/app/answer.txt": answer, "mkdir -p /app": "true"})
            self.assertEqual(run_grader(task_dir, "qa_grader.py", "--answer", answer, self.tmp)[0], 1, tid)
            for text in right:
                answer.write_text(text + "\n")
                self.assertEqual(run_grader(task_dir, "qa_grader.py", "--answer", answer, self.tmp)[0], 1, text)
            for text in wrong:
                answer.write_text(text + "\n")
                reward, details = run_grader(task_dir, "qa_grader.py", "--answer", answer, self.tmp)
                self.assertEqual(reward, 0, text)
                self.assertIn("f1", details)
            self.assertEqual(run_grader(task_dir, "qa_grader.py", "--answer", self.tmp / "none", self.tmp)[0], 0)
            instruction = (task_dir / "instruction.md").read_text()
            self.assertIn("Retrieved snippets", instruction)
            self.assertIn("/app/answer.txt", instruction)

    def test_parenthetical_aliases(self) -> None:
        """Answer formats from the pinned subset: a parenthetical is optional
        text, an alternate only when J! Archive marks it ("or X", "X accepted")."""
        grader = load_module(ADAPTER_DIR / "graders/qa_grader.py", "qa_grader_under_test")
        cases = {
            "(Ken) Lay": (["Ken Lay", "Lay"], ["Ken"]),
            "Victor Emmanuel (III)": (["Victor Emmanuel III", "Victor Emmanuel"], ["III"]),
            "ado (in Ecuador)": (["ado", "ado in Ecuador"], ["in Ecuador", "Ecuador"]),
            "Washington (state)": (["Washington", "Washington state"], ["state"]),
            "(John) Adams": (["John Adams", "Adams"], ["John"]),
            "New Mexico (or Colorado)": (["New Mexico", "Colorado"], ["or Colorado"]),
            "referred pain (referral accepted)": (["referred pain", "referral"], ["referral accepted"]),
        }
        for gold, (right, wrong) in cases.items():
            accepted = grader.aliases(gold)
            for text in right:
                self.assertIn(grader.normalize(text), accepted, (gold, text))
            for text in wrong:
                self.assertNotIn(grader.normalize(text), accepted, (gold, text))


# --- LiveMathBench ----------------------------------------------------------------


@unittest.skipUnless(BASH, "needs bash for solve.sh")
class LiveMathTest(TaskChecks):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.grader = load_module(ADAPTER_DIR / "graders/math_grader.py", "math_grader_under_test")

    def test_generation_oracle_and_wrong_answers(self) -> None:
        sets = json.loads((FIXTURES / "livemath.sample.json").read_text())
        inputs = {}
        for name, _, _ in livemath.SETS:
            path = self.tmp / f"{name}_en.jsonl"
            path.write_text("".join(json.dumps(row) + "\n" for row in sets[name]))
            inputs[path.name] = path
        out = self.tmp / "livemath"
        out.mkdir()
        livemath.build(inputs, out)
        ids = livemath.tasks(out)
        self.assertEqual(
            ids, ["livemath-amc-1", "livemath-amc-2", "livemath-ccee-1", "livemath-cnmo-1", "livemath-wlpmc-1"]
        )
        wrong = {"livemath-amc-1": "\\frac{1}{6}", "livemath-amc-2": "1024", "livemath-ccee-1": "A",
                 "livemath-cnmo-1": "\\sqrt{3}", "livemath-wlpmc-1": "(1, 2)"}
        for tid in ids:
            task_dir = out / tid
            self.check_task_dir(task_dir)
            answer = self.tmp / "answer.txt"
            run_solve(task_dir, {"/app/answer.txt": answer, "mkdir -p /app": "true"})
            self.assertEqual(run_grader(task_dir, "math_grader.py", "--answer", answer, self.tmp)[0], 1, tid)
            answer.write_text(wrong[tid] + "\n")
            self.assertEqual(run_grader(task_dir, "math_grader.py", "--answer", answer, self.tmp)[0], 0, tid)

    def test_equivalence_rules(self) -> None:
        eq = self.grader.equivalent
        accepted = [
            ("\\frac{5}{6}", "$\\frac{5}{6}$"), ("5/6", "$\\dfrac{5}{6}$"), ("0.8333333333", "\\frac{5}{6}"),
            ("1000", "$1000$"), ("x = 1000", "1000"), ("1000.", "1000"), ("2\\sqrt{3}", "\\sqrt{12}"),
            ("\\frac{2n+2}{3}", "$\\frac{2n+2}{3}$"), ("(2, 1)", "$(2,1)$"), ("\\{3, 1, 2\\}", "\\{1,2,3\\}"),
            ("(B)", "B"), ("b", "B"), ("30^\\circ", "30"), ("50\\%", "50"), ("\\pi/2", "\\frac{\\pi}{2}"),
            ("\\text{yes}", "yes"),
        ]
        rejected = [
            ("\\frac{1}{6}", "\\frac{5}{6}"), ("1001", "1000"), ("A", "B"), ("(1, 2)", "(2,1)"), ("", "1"),
            ("\\frac{2n+1}{3}", "\\frac{2n+2}{3}"), ("2", "\\sqrt{2}"),
        ]
        for pred, gold in accepted:
            self.assertTrue(eq(pred, gold), (pred, gold))
        for pred, gold in rejected:
            self.assertFalse(eq(pred, gold), (pred, gold))
        self.assertEqual(self.grader.extract("work...\nso \\boxed{\\frac{1}{2}} done"), "\\frac{1}{2}")

    def test_brackets_keep_their_meaning(self) -> None:
        """An interval, a tuple and a set are different answers; only a set is order-free."""
        eq = self.grader.equivalent
        accepted = [
            ("[1, 2]", "[1,2]"), ("(1, 2]", "$(1,2]$"), ("\\left[1,2\\right)", "[1,2)"),
            ("\\{2, 1\\}", "\\{1,2\\}"), ("1, 2", "\\{1,2\\}"), ("\\{2, 1\\}", "1, 2"), ("2, 1", "1, 2"),
            ("(\\frac{1}{2}, 1)", "(0.5, 1)"),
        ]
        rejected = [
            ("[1,2]", "(1,2)"), ("(1,2)", "[1,2]"), ("\\{1,2\\}", "(1,2)"), ("(1,2)", "\\{1,2\\}"),
            ("[1,2)", "(1,2)"), ("(1,2]", "[1,2]"), ("[1,2]", "\\{1,2\\}"), ("[2,1]", "[1,2]"),
            ("1, 2", "(1,2)"), ("(1,2)", "1, 2"),
        ]
        for pred, gold in accepted:
            self.assertTrue(eq(pred, gold), (pred, gold))
        for pred, gold in rejected:
            self.assertFalse(eq(pred, gold), (pred, gold))

    def test_braceless_fractions(self) -> None:
        eq = self.grader.equivalent
        for pred in ("\\frac12", "\\frac1{2}", "\\frac{1}2", "\\dfrac12", "\\tfrac12", "\\dfrac{1}{2}", "0.5"):
            self.assertTrue(eq(pred, "\\frac{1}{2}"), pred)
            self.assertTrue(eq("\\frac{1}{2}", pred), pred)
        self.assertTrue(eq("\\frac\\pi2", "\\frac{\\pi}{2}"))
        self.assertTrue(eq("\\frac123", "\\frac{1}{2}3"))  # LaTeX: \frac12 then 3
        self.assertTrue(eq("\\sqrt2", "\\sqrt{2}"))
        self.assertFalse(eq("\\frac13", "\\frac{1}{2}"))
        self.assertIsNone(self.grader.evaluate("\\frac"))
        self.assertIsNone(self.grader.evaluate("\\frac1"))
        answer = self.tmp / "answer.txt"
        answer.write_text("\\boxed{\\frac12}\n")
        spec = self.tmp / "spec.json"
        spec.write_text(json.dumps({"answer": "$\\frac{1}{2}$", "question_type": "x"}))
        self.assertEqual(self.grader.grade(spec, answer)[0], 1)
        self.assertEqual(self.grader.extract("lots of work\n\nFinal answer: 42\n"), "42")


# --- ALFWorld --------------------------------------------------------------------


class ScriptedGame:
    """Stands in for TextWorld: win by `take key 1` then `open door 1`."""

    SOLUTION = ["take key 1 from table 1", "open door 1"]

    def __init__(self) -> None:
        self.progress = 0

    def reset(self) -> str:
        self.progress = 0
        return "-= Welcome =-\nYour task is to: open the door."

    def step(self, action: str) -> Tuple[str, bool]:
        if self.progress < len(self.SOLUTION) and action == self.SOLUTION[self.progress]:
            self.progress += 1
            return "Done: " + action, self.progress == len(self.SOLUTION)
        return "Nothing happens.", False

    def admissible(self) -> List[str]:
        return ["look", "inventory", *self.SOLUTION]

    def expert_plan(self, limit: int) -> List[str]:
        return list(self.SOLUTION)[:limit]


class AlfworldTest(TaskChecks):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.server = load_module(ADAPTER_DIR / "alfworld_env/server.py", "alfworld_server_under_test")
        self.cli = load_module(ADAPTER_DIR / "alfworld_env/alfworld_cli.py", "alfworld_cli_under_test")
        self.grader = load_module(ADAPTER_DIR / "graders/alfworld_grader.py", "alfworld_grader_under_test")

    def _archive(self) -> Path:
        games = json.loads((FIXTURES / "alfworld.sample.json").read_text())["games"]
        archive = self.tmp / alfworld.PIN.name
        with zipfile.ZipFile(archive, "w") as zf:
            for name, body in games.items():
                zf.writestr(name, json.dumps(body))
        return archive

    def _build(self) -> Path:
        out = self.tmp / "alfworld"
        out.mkdir()
        alfworld.build({alfworld.PIN.name: self._archive()}, out)
        return out

    def test_per_task_build_files_never_share_size_and_mtime(self) -> None:
        # BuildKit reuses a context file whose path, size and mtime match an
        # earlier build's; on a real host one task's sidecar got another
        # task's 33-byte oracle token that way and the oracle scored 0.
        out = self._build()
        seen = {}
        for task in alfworld.tasks(out):
            for path in (out / task / "environment").rglob("*"):
                if not path.is_file():
                    continue
                key = (path.relative_to(out / task).as_posix(), path.stat().st_size, int(path.stat().st_mtime))
                if key in seen:
                    self.assertEqual(seen[key], path.read_bytes(), key)
                seen[key] = path.read_bytes()
        tokens = [(out / t / "environment/alfworld-env/oracle_token") for t in alfworld.tasks(out)]
        self.assertEqual(len({p.stat().st_size for p in tokens}), 1)
        self.assertEqual(len({int(p.stat().st_mtime) for p in tokens}), len(tokens))
        self.assertEqual(c.content_mtime(b"same"), c.content_mtime(b"same"))

    def test_generation_and_structure(self) -> None:
        out = self._build()
        ids = alfworld.tasks(out)
        # unsolvable, movable-receptacle and valid_seen games are excluded
        self.assertEqual(len(ids), 2)
        self.assertEqual({i.split("-")[1] for i in ids}, {"look_at_obj_in_light", "pick_and_place_simple"})
        for tid in ids:
            task_dir = out / tid
            config = self.check_task_dir(task_dir)
            self.assertEqual(config["artifacts"], [{"source": alfworld.RESULT_PATH, "service": alfworld.SIDECAR}])
            self.assertEqual(config["verifier"]["collect"][0]["service"], alfworld.SIDECAR)  # type: ignore[index]
            token = (task_dir / "environment/alfworld-env/oracle_token").read_text().strip()
            self.assertIn(token, (task_dir / "solution/solve.sh").read_text())
            agent_docker = (task_dir / "environment/Dockerfile").read_text()
            self.assertNotIn("game.tw-pddl", agent_docker)
            self.assertNotIn("oracle_token", agent_docker)
            self.assertNotIn(token, (task_dir / "instruction.md").read_text())
            compose = (task_dir / "environment/docker-compose.yaml").read_text()
            self.assertIn("platform: linux/amd64", compose)
            self.assertIn("condition: service_healthy", compose)
            task_json = json.loads((task_dir / "environment/alfworld-env/task.json").read_text())
            game = (task_dir / "environment/alfworld-env/game.tw-pddl").read_bytes()
            self.assertEqual(task_json["game_sha256"], hashlib.sha256(game).hexdigest())
            self.assertEqual(json.loads((task_dir / "tests/spec.json").read_text()), task_json)

    def _serve(self, spec: Dict[str, object], token: str):
        episode = self.server.Episode(
            ScriptedGame(), task_id=spec["task_id"], game_sha256=spec["game_sha256"],
            max_steps=spec["max_steps"], result_path=self.tmp / "var/result.json",
        )
        httpd = self.server.serve(episode, token, "127.0.0.1", 0)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        return episode, "http://127.0.0.1:%d" % httpd.server_address[1]

    def _cli(self, base: str, *argv: str) -> Tuple[int, str]:
        buffer = io.StringIO()
        with mock.patch.object(self.cli, "BASE", base), redirect_stdout(buffer), redirect_stderr(io.StringIO()):
            code = self.cli.main(list(argv))
        return code, buffer.getvalue()

    def _grade(self, spec: Dict[str, object]) -> int:
        spec_path = self.tmp / "spec.json"
        spec_path.write_text(json.dumps(spec))
        return self.grader.grade(spec_path, self.tmp / "var/result.json")[0]

    def test_cli_reaches_the_sidecar_with_a_container_proxy_set(self) -> None:
        # Docker injects HTTP_PROXY into task containers when the executor
        # routes egress through a proxy; the proxy cannot resolve the
        # sidecar's service name and answered HTTP 500 to every call.
        spec = {"task_id": "alfworld-demo", "game_sha256": "ab" * 32, "max_steps": 5}
        _episode, base = self._serve(spec, "secret")
        dead = "http://127.0.0.1:9"
        with mock.patch.dict(os.environ, {"HTTP_PROXY": dead, "http_proxy": dead, "NO_PROXY": "", "no_proxy": ""}):
            code, out = self._cli(base, "look")
        self.assertEqual(code, 0, out)
        self.assertIn("Your task is to: open the door.", out)

    def test_agent_play_through_cli_and_verifier(self) -> None:
        spec = {"task_id": "alfworld-demo", "game_sha256": "ab" * 32, "max_steps": 5}
        episode, base = self._serve(spec, "secret")
        code, out = self._cli(base, "look")
        self.assertIn("Your task is to: open the door.", out)
        self.assertIn("[steps 0/5", out)
        self.assertIn("take key 1 from table 1", self._cli(base, "actions")[1])
        self.assertIn("Nothing happens.", self._cli(base, "act", "look")[1])
        self._cli(base, "act", "take key 1 from table 1")
        code, out = self._cli(base, "act", "open", "door", "1")
        self.assertIn("task COMPLETE", out)
        self.assertEqual(self._cli(base, "act", "inventory")[0], 1)  # closed after the win
        self.assertEqual(self._grade(spec), 0, "not frozen by the collect hook yet")
        # /finalize is loopback-only; the collect hook runs inside the sidecar.
        episode.finalize()
        self.assertEqual(self._grade(spec), 1)
        self.assertEqual(self._grade({**spec, "task_id": "other"}), 0)
        self.assertEqual(self._grade({**spec, "game_sha256": "cd" * 32}), 0)
        record = json.loads((self.tmp / "var/result.json").read_text())
        self.assertEqual(record["steps"], 3)

    def test_wrong_play_budget_and_forgery(self) -> None:
        spec = {"task_id": "alfworld-demo", "game_sha256": "ab" * 32, "max_steps": 3}
        episode, base = self._serve(spec, "secret")
        for _ in range(3):
            self._cli(base, "act", "look")
        code, _ = self._cli(base, "act", "take key 1 from table 1")
        self.assertEqual(code, 1, "the budget is enforced by the sidecar")
        episode.finalize()
        self.assertEqual(self._grade(spec), 0)
        # A record claiming a win the trajectory does not show is rejected.
        record = json.loads((self.tmp / "var/result.json").read_text())
        record["won"] = True
        (self.tmp / "var/result.json").write_text(json.dumps(record))
        self.assertEqual(self._grade(spec), 0)
        (self.tmp / "var/result.json").unlink()
        self.assertEqual(self._grade(spec), 0)

    def test_oracle_needs_the_token(self) -> None:
        spec = {"task_id": "alfworld-demo", "game_sha256": "ab" * 32, "max_steps": 50}
        episode, base = self._serve(spec, "secret")
        code, out = self._cli(base, "oracle", "guess")
        self.assertEqual(code, 1)
        self.assertEqual(episode.steps, 0)
        code, out = self._cli(base, "oracle", "secret")
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)["won"])
        episode.finalize()
        self.assertEqual(self._grade(spec), 1)

    def test_finalize_is_loopback_only_over_http(self) -> None:
        import urllib.error
        import urllib.request

        spec = {"task_id": "alfworld-demo", "game_sha256": "ab" * 32, "max_steps": 5}
        _, base = self._serve(spec, "secret")
        request = urllib.request.Request(base + "/finalize", data=b"{}", method="POST")
        with urllib.request.urlopen(request) as response:  # 127.0.0.1 is loopback
            self.assertTrue(json.loads(response.read())["finalized"])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(urllib.request.Request(base + "/step", data=b'{"action": "look"}', method="POST"))
        self.assertEqual(caught.exception.code, 409)


if __name__ == "__main__":
    unittest.main()
