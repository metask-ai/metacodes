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
        script = script.replace(container_path, str(host_path))
    subprocess.run([BASH, "-c", script], check=True, capture_output=True)


def run_grader(task_dir: Path, grader: str, flag: str, artifact: Path, scratch: Path) -> Tuple[int, Dict[str, object]]:
    reward = scratch / "reward.txt"
    details = scratch / "grade.json"
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
            self.assertTrue(type(suite["max_concurrency"]) is int and 1 <= suite["max_concurrency"] <= 8)
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
        self.assertEqual(humaneval.tasks(first), ["humaneval-0", "humaneval-2"])

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
        self.assertEqual(humaneval.tasks(built["humaneval"]), ["humaneval-0", "humaneval-2"])
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
            "searchqa-104": (["Poe", "Edgar Allan Poe"], ["Edgar"]),
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
