"""Benchmark catalog of the Bench workbench: suite -> real Harbor/WorkBuddy child.

Each suite is proven end to end with stand-in executables: the HTTP launch of
a suite reaches the worker's actual argv (dataset reference and `-i` task
filters), the WorkBuddy runner writes the job/model configuration the
official runner reads and its results appear in the job view, and the
catalog shown to the page and CLI reflects each suite's readiness. No
provider, Docker or Harbor process is used.
"""
from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli, suites
from scripts.eval.harbor import command as cmd
from scripts.eval.harbor.adapters import gaia2_cli
from scripts.eval.harbor.suites import workbuddy as wb
from scripts.eval.harbor.viewer import data, server
from scripts.eval.harbor.viewer.runner import RunManager, atomic_json
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_bench_workbench import fixture, session_fixture, wait_run
from scripts.eval.workbuddy import WORKBUDDY_JUDGE_KEY_ENV, WORKBUDDY_PINNED_COMMIT

REPO = Path(__file__).resolve().parents[3]

FAKE_UV = '''#!{python}
import json, os, pathlib, sys
args = sys.argv[1:]
slug = args[args.index('--job') + 1]
cwd = pathlib.Path.cwd()
job = json.loads((cwd / 'configs/jobs' / (slug + '.yaml')).read_text())
model = json.loads((cwd / 'configs/models' / (slug + '.yaml')).read_text())
jobs_dir = pathlib.Path(job['jobs_dir'])
spec = model['model']
(jobs_dir.parent / 'observed.json').write_text(json.dumps({{
    'argv': args, 'cwd': str(cwd), 'job': job, 'model': model,
    'base_url': os.environ.get(spec['backend_url_env']),
    'key_matches': os.environ.get(spec['backend_key_env']) == os.environ.get('FAKE_EXPECT_ACCOUNT_KEY'),
    'judge_key': os.environ.get('{judge}'), 'metask_key': 'METASK_API_KEY' in os.environ,
    'shard_concurrency': os.environ.get('SHARD_CONCURRENCY'), 'platform': os.environ.get('DOCKER_DEFAULT_PLATFORM')}}))
for run in ('2026-11-18__10-00-00',):
    for name in job['task_selection']['names']:
        trial = jobs_dir / run / (name + '__wb1')
        trial.mkdir(parents=True)
        (trial / 'config.json').write_text('{{}}')
        (trial / 'result.json').write_text(json.dumps({{'task_name': name,
            'started_at': '2026-11-18T10:00:00Z', 'finished_at': '2026-11-18T10:02:00Z',
            'verifier_result': {{'rewards': {{'reward': 1.0 if name.startswith('bug') else 0.0}}}}}}))
'''


def fake_adapter(module_name, tasks, **suite):
    """A harbor-local adapter module as the adapter interface defines it."""
    module = types.ModuleType("scripts.eval.harbor.adapters." + module_name)
    module.SUITE = suite

    def prepare(dest):
        for task in tasks:
            (Path(dest) / task).mkdir(parents=True, exist_ok=True)
            (Path(dest) / task / "task.toml").write_text("[task]\n")
        return Path(dest)

    module.prepare = prepare
    return module


class CatalogTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.ctx = suites.Context({}, self.root, env={})

    def test_every_requested_category_has_its_benchmark(self):
        categories = dict((c[0], c[1]) for c in suites.CATEGORIES)
        expected = {"humaneval": "代码生成", "mbpp": "基础编程", "alfworld": "交互规划", "searchqa": "问答",
                    "livemath": "数学推理", "aime": "竞赛数学", "aime-2025": "竞赛数学",
                    "terminal-bench-2.0": "终端工程", "terminal-bench-2.1": "终端工程",
                    "gaia2-cli": "通用 Agent", "workbuddy-code": "办公 Agent"}
        for suite_id, category in expected.items():
            self.assertEqual(categories[suites.get(suite_id).category], category, suite_id)

    def test_registry_task_ids_match_harbor_0_26(self):
        tb21, tb20 = suites.get("terminal-bench-2.1"), suites.get("terminal-bench-2.0")
        self.assertEqual((len(tb21.tasks), len(tb20.tasks)), (89, 89))
        self.assertIn("install-windows-3.11", tb20.tasks)
        self.assertEqual((tb21.dataset, tb20.dataset), ("terminal-bench/terminal-bench-2-1", "terminal-bench@2.0"))
        # Hub tasks are matched as org/name, legacy-registry ones by bare name.
        self.assertEqual(suites.task_filters(tb21, ["fix-git"]), ["terminal-bench/fix-git"])
        self.assertEqual(suites.task_filters(tb20, ["fix-git"]), ["fix-git"])
        aime, aime25 = suites.get("aime"), suites.get("aime-2025")
        self.assertEqual((aime.dataset, aime25.dataset), ("aime@1.0", "aime@1.0"))
        self.assertEqual(len(aime.tasks), 60)
        self.assertEqual(sorted(t for t in aime.tasks if re.fullmatch(r"aime_\d+", t)),
                         sorted(f"aime_{n}" for n in range(60, 90)))
        self.assertEqual(set(aime25.tasks), {f"aime_i-{n}" for n in range(1, 16)} | {f"aime_ii-{n}" for n in range(1, 16)})
        self.assertLess(set(aime25.tasks), set(aime.tasks))
        self.assertEqual(suites.task_filters(aime25, ["aime_ii-15"]), ["aime_ii-15"])

    def test_task_ids_are_strict_per_suite(self):
        tb = suites.get("terminal-bench-2.1")
        self.assertEqual(suites.validate_tasks(tb, self.ctx, ["terminal-bench/fix-git"]), ["fix-git"])
        for bad in (["aime_60"], ["fix-git", "fix-git"], ["fix-*"], [], list(tb.tasks) + ["x"]):
            with self.assertRaises(ValueError, msg=bad):
                suites.validate_tasks(tb, self.ctx, bad)
        with self.assertRaises(ValueError):
            suites.validate_tasks(suites.get("aime-2025"), self.ctx, ["aime_60"])
        self.assertEqual(len(suites.validate_tasks(suites.get("aime"), self.ctx, list(suites.get("aime").tasks))), 60)

    def test_missing_adapter_is_listed_as_not_yet_available(self):
        entry = suites.public(suites.get("humaneval"), self.ctx)
        self.assertFalse(entry["ready"] or entry["available"])
        self.assertIn("adapters/humaneval.py", entry["reasons"][0])
        self.assertIsNone(entry["task_count"])

    def test_registered_adapter_prepares_and_lists_local_tasks(self):
        adapter = fake_adapter("humaneval", ["humaneval-0", "humaneval-1", "bad name"],
                               name="HumanEval+", default_tasks=["humaneval-1"], max_tasks=2, max_concurrency=99)
        with patch.dict(sys.modules, {adapter.__name__: adapter}):
            suite = suites.resolved(suites.get("humaneval"))
            self.assertEqual((suite.name, suite.max_tasks, suite.max_concurrency), ("HumanEval+", 2, 8))
            self.assertIn("尚未准备", suites.readiness(suite, self.ctx)[0])
            adapter.prepare(self.ctx.dataset_dir(suite))
            self.assertEqual(suites.task_ids(suite, self.ctx), ["humaneval-0", "humaneval-1"])
            self.assertEqual(suites.readiness(suite, self.ctx), [])
            self.assertEqual(suites.harbor_dataset_args(suite, self.ctx),
                             ["-p", str((self.root / "datasets" / "humaneval").resolve())])
            with self.assertRaises(ValueError):
                suites.validate_tasks(suite, self.ctx, ["humaneval-0", "humaneval-1", "humaneval-2"])

    def test_gaia2_cli_lists_generated_dirs_and_needs_the_judge_key(self):
        dataset = self.root / "gaia2-cli"
        for name in ("gaia2-search-0001-abc", "gaia2-time-0002-def"):
            (dataset / name).mkdir(parents=True)
            (dataset / name / "task.toml").write_text("[task]\n")
        suite = suites.resolved(suites.get("gaia2-cli"))
        ctx = suites.Context({"datasets": {"gaia2-cli": str(dataset)}}, self.root, env={})
        self.assertEqual(suites.task_ids(suite, ctx), ["gaia2-search-0001-abc", "gaia2-time-0002-def"])
        self.assertIn("OPENAI_API_KEY", " ".join(suites.readiness(suite, ctx)))
        ctx.env = {"OPENAI_API_KEY": "judge"}
        self.assertEqual(suites.readiness(suite, ctx), [])
        self.assertEqual(suites.harbor_dataset_args(suite, ctx), ["-p", str(dataset.resolve())])
        source = self.root / "harbor"
        self.assertEqual(gaia2_cli.adapter_command(source, self.root / "out", "uv"),
                         ["uv", "run", "--project", str(source), "python",
                          str(source / "adapters/gaia2/run_adapter.py"), "--cli", "--output-dir",
                          str(self.root / "out"), "--overwrite"])

    def test_old_jobs_infer_their_suite(self):
        self.assertEqual(suites.infer("terminal-bench/terminal-bench-2-1"), "terminal-bench-2.1")
        self.assertEqual(suites.infer("/data/datasets/gaia2-cli"), "gaia2-cli")
        self.assertIsNone(suites.infer("aime"))  # aime and aime-2025 share it
        self.assertEqual(suites.label("aime-2025")["category_name"], "竞赛数学")

    def test_workbuddy_platform_matches_the_stager(self):
        from scripts.eval.workbuddy.stage_artifacts import TARGET_PLATFORM
        self.assertEqual(wb.TARGET_PLATFORM, TARGET_PLATFORM)

    def test_binary_carries_every_module_the_workbench_imports(self):
        assets = set(re.findall(r'\.path = "([^"]+)"', (REPO / "scripts/bench_assets.zig").read_text()))
        probe = ("import sys, json\n"
                 "import scripts.eval.harbor.cli, scripts.eval.harbor.viewer.server, scripts.eval.harbor.viewer.worker\n"
                 "import scripts.eval.harbor.suites.workbuddy, scripts.eval.harbor.adapters.gaia2_cli\n"
                 "print(json.dumps(sorted(m.__file__ for n, m in sys.modules.items() if n.startswith('scripts') and getattr(m, '__file__', None))))")
        loaded = json.loads(subprocess.run([sys.executable, "-c", probe], cwd=REPO, check=True,
                                           capture_output=True, text=True).stdout)
        missing = [p for p in (Path(f).resolve().relative_to(REPO).as_posix() for f in loaded) if p not in assets]
        self.assertEqual(missing, [])


class McpForwardingTest(unittest.TestCase):
    """GAIA2 CLI's sidecar tools reach metacodes' own MCP configuration."""

    def test_mcp_servers_config_maps_harbor_transports(self):
        servers = [{"name": "are", "transport": "streamable-http", "url": "http://are-sidecar:8000/mcp"},
                   types.SimpleNamespace(name="legacy", transport="sse", url="http://x/sse", headers={"X-A": "1"}),
                   {"name": "local", "transport": "stdio", "command": "tool", "args": ["--serve"]}]
        self.assertEqual(cmd.mcp_servers_config(servers), {
            "are": {"type": "http", "url": "http://are-sidecar:8000/mcp"},
            "legacy": {"type": "sse", "url": "http://x/sse", "headers": {"X-A": "1"}},
            "local": {"type": "stdio", "command": "tool", "args": ["--serve"]}})
        with self.assertRaises(ValueError):
            cmd.mcp_servers_config([{"name": "x", "transport": "streamable-http"}])

    def test_agent_uploads_task_mcp_servers_in_the_trial_config(self):
        with stubbed_harbor() as agent_module:
            agent = agent_module.MetacodesAgent.__new__(agent_module.MetacodesAgent)
            agent.__dict__.update(
                logs_dir=Path("/tmp/trial-x/agent"), mcp_servers=[types.SimpleNamespace(
                    name="are", transport="streamable-http", url="http://are-sidecar:8000/mcp", headers={})],
                config_source=None, _flags=["--model", "m"], _provider=None, _metrics_proxy=None,
                _account_gateway=None)
            environment = CapturingEnvironment()
            asyncio.run(agent.run("solve it", environment, None))
        configs = [json.loads(body) for path, body in environment.uploads if "metacodes-config-" in path]
        self.assertEqual(configs, [{"mcpServers": {"are": {"type": "http", "url": "http://are-sidecar:8000/mcp"}}}])
        self.assertTrue(any('/config.json"' in c for c in environment.agent_commands))


class CapturingEnvironment:
    def __init__(self):
        self.uploads, self.agent_commands = [], []

    async def upload_file(self, source, target):
        self.uploads.append((str(target), Path(source).read_bytes()))


@contextlib.contextmanager
def stubbed_harbor():
    """Load metacodes_agent.py against minimal Harbor doubles."""
    names = ("harbor", "harbor.agents", "harbor.agents.capabilities", "harbor.agents.installed",
             "harbor.agents.installed.base", "harbor.environments", "harbor.environments.base",
             "harbor.models", "harbor.models.agent", "harbor.models.agent.context", "harbor.models.trajectories")
    modules = {name: types.ModuleType(name) for name in names}
    modules["harbor.agents.capabilities"].AgentCapabilities = lambda **kw: kw

    class BaseInstalledAgent:
        async def exec_as_root(self, environment, command):
            environment.agent_commands.append(command)

        async def exec_as_agent(self, environment, command):
            environment.agent_commands.append(command)

    modules["harbor.agents.installed.base"].BaseInstalledAgent = BaseInstalledAgent
    modules["harbor.agents.installed.base"].with_prompt_template = lambda f: f
    modules["harbor.environments.base"].BaseEnvironment = object
    modules["harbor.models.agent.context"].AgentContext = object
    for name in ("Agent", "FinalMetrics", "Observation", "ObservationResult", "Step", "ToolCall", "Trajectory"):
        setattr(modules["harbor.models.trajectories"], name, type(name, (), {}))
    with patch.dict(sys.modules, modules):
        spec = importlib.util.spec_from_file_location("metacodes_agent_mcp_probe",
                                                      REPO / "scripts/eval/harbor/metacodes_agent.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module


def workbuddy_checkout(root, *, head=WORKBUDDY_PINNED_COMMIT):
    repo = root / "workbuddy-bench"
    (repo / ".git").mkdir(parents=True)
    (repo / ".git/HEAD").write_text(head + "\n")
    (repo / ".venv").mkdir()
    atomic_json(repo / wb.OVERLAY, {"workbuddy_commit": WORKBUDDY_PINNED_COMMIT})
    atomic_json(repo / wb.ARTIFACT_MANIFEST, {"target_platform": "linux/amd64", "synthetic_fixture": False})
    for task in ("bug_fix-easy-alpha", "data_quality-hard-beta", "data_quality-hard-gamma"):
        (repo / wb.dataset_rel("code") / task).mkdir(parents=True)
        (repo / wb.dataset_rel("code") / task / "task.toml").write_text("[task]\n")
    return repo


@unittest.skipUnless(POSIX, "fake executables and worker signals are POSIX")
class SuiteLaunchTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        config, self.binary_dir = fixture(self.root)
        uv = self.binary_dir / "uv"
        uv.write_text(FAKE_UV.format(python=sys.executable, judge=WORKBUDDY_JUDGE_KEY_ENV))
        uv.chmod(0o755)
        env = patch.dict(os.environ, {"PATH": str(self.binary_dir) + os.pathsep + os.environ.get("PATH", ""),
                                      "TOKENJOY_API_KEY": "private-test-value"})
        env.start()
        self.addCleanup(env.stop)
        self.manager = RunManager(self.root / "jobs", config)
        self.http = server.make_server(data.Library([self.manager.jobs_dir]), "127.0.0.1", 0, self.manager, "cap")
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.client = cli.Client(f"http://127.0.0.1:{self.http.server_address[1]}/", "cap")

    def launch(self, **request):
        run = self.client.request("api/runs", {"model": "tokenjoy/test-model", "attempts": 1, "concurrency": 1, **request})
        final = wait_run(self.manager, run["name"])
        self.assertEqual(final["status"], "finished", final)
        argv = json.loads((self.manager.jobs_dir / run["name"] / "argv.json").read_text())
        return run, argv

    def filters(self, argv):
        return [argv[i + 1] for i, a in enumerate(argv) if a == "-i"]

    def test_catalog_lists_categorized_suites_and_their_tasks(self):
        catalog = self.client.request("api/workbench")
        self.assertEqual([c["id"] for c in catalog["categories"]], list(suites.CATEGORY_IDS))
        by_id = {s["id"]: s for s in catalog["suites"]}
        self.assertTrue(by_id["aime-2025"]["ready"])
        self.assertEqual(by_id["aime-2025"]["task_count"], 30)
        self.assertFalse(by_id["mbpp"]["available"])
        self.assertTrue(catalog["ready"])  # the default suite, as before
        tasks = self.client.request("api/suite?id=terminal-bench-2.0")
        self.assertEqual(len(tasks["tasks"]), 89)
        self.assertIn("fix-git", tasks["default_tasks"])
        with self.assertRaises(ValueError):
            self.client.request("api/suite?id=no-such-suite")

    def test_aime_2025_reaches_harbor_with_its_dataset_and_filters(self):
        run, argv = self.launch(suite="aime-2025", tasks=["aime_i-1", "aime_ii-15"], concurrency=8)
        self.assertEqual(argv[argv.index("-d") + 1], "aime@1.0")
        self.assertEqual(self.filters(argv), ["aime_i-1", "aime_ii-15"])
        self.assertEqual(argv[argv.index("-n") + 1], "8")
        self.assertEqual((run["suite"], run["category"]), ("aime-2025", "competition-math"))
        job = self.client.request("api/job?name=" + run["name"])
        self.assertEqual((job["suite_name"], job["category_name"]), ("AIME 2025", "竞赛数学"))
        overview = self.client.request("api/jobs")["jobs"][0]
        self.assertEqual(overview["category"], "competition-math")

    def test_terminal_bench_versions_and_legacy_dataset_request(self):
        _, argv = self.launch(suite="terminal-bench-2.0", tasks=["fix-git", "install-windows-3.11"])
        self.assertEqual(argv[argv.index("-d") + 1], "terminal-bench@2.0")
        self.assertEqual(self.filters(argv), ["fix-git", "install-windows-3.11"])
        _, argv = self.launch(dataset="terminal-bench/terminal-bench-2-1", tasks=["fix-git"])
        self.assertEqual(argv[argv.index("-d") + 1], "terminal-bench/terminal-bench-2-1")
        self.assertEqual(self.filters(argv), ["terminal-bench/fix-git"])

    def test_suite_requests_are_validated_before_spawn(self):
        base = {"model": "tokenjoy/test-model", "attempts": 1, "concurrency": 1}
        for override in ({"suite": "aime", "tasks": ["fix-git"]}, {"suite": "nope", "tasks": ["fix-git"]},
                         {"suite": "aime", "dataset": "terminal-bench/terminal-bench-2-1", "tasks": ["aime_60"]},
                         {"dataset": "aime@1.0", "tasks": ["aime_60"]},
                         {"suite": "terminal-bench-2.1", "tasks": ["fix-git"], "concurrency": 4},
                         {"suite": "aime-2025", "tasks": list(suites.AIME_2025) + ["aime_60"]},
                         {"suite": "humaneval", "tasks": ["humaneval-0"]},
                         {"suite": "workbuddy-code", "tasks": ["bug_fix-easy-alpha"]}):
            with self.assertRaises(ValueError, msg=override):
                self.client.request("api/runs", {**base, **override})
        self.assertEqual(self.manager.runs(), [])

    def test_prepared_adapter_suite_runs_from_its_local_dataset(self):
        adapter = fake_adapter("humaneval", ["humaneval-0", "humaneval-7"])
        with patch.dict(sys.modules, {adapter.__name__: adapter}):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = cli.main(["prepare", "--state-root", str(self.root / "state"), "--suite", "humaneval", "--json"])
            self.assertEqual(code, 0)
            prepared = json.loads(out.getvalue())
            self.assertEqual(prepared["task_count"], 2)
            cfg = json.loads(self.manager.config_path.read_text())
            cfg["datasets"] = {"humaneval": prepared["dataset"]}
            atomic_json(self.manager.config_path, cfg)
            run, argv = self.launch(suite="humaneval", tasks=["humaneval-7"])
        self.assertEqual(argv[argv.index("-p") + 1], prepared["dataset"])
        self.assertNotIn("-d", argv)
        self.assertEqual(self.filters(argv), ["humaneval-7"])

    def test_cli_runs_a_suite_with_its_default_sample(self):
        with patch.dict(os.environ, {"METACODES_BENCH_TOKEN": "cap"}):
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = cli.main(["run", "--state-root", str(self.root / "state"), "--url", self.client.url,
                                 "--suite", "aime-2025", "--model", "tokenjoy/test-model", "--wait", "--json"])
        self.assertEqual(code, 0, out.getvalue())
        record = json.loads(out.getvalue())
        argv = json.loads((self.manager.jobs_dir / record["name"] / "argv.json").read_text())
        self.assertEqual(self.filters(argv), list(suites.AIME_2025))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            cli.main(["info", "--state-root", str(self.root / "state"), "--url", self.client.url])
        self.assertIn("竞赛数学：", out.getvalue())
        self.assertIn("aime-2025", out.getvalue())

    def test_workbuddy_launch_runs_the_official_runner_and_shows_its_trials(self):
        state, upstream, _ = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        repo = workbuddy_checkout(self.root)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode="metask", account_state_dir=str(state), workbuddy_checkout=str(repo))
        atomic_json(self.manager.config_path, cfg)
        with patch.dict(os.environ, {"METASK_SITE_URL": f"http://127.0.0.1:{upstream.server_port}",
                                     "FAKE_EXPECT_ACCOUNT_KEY": "session-access",
                                     WORKBUDDY_JUDGE_KEY_ENV: "judge-secret"}):
            catalog = self.client.request("api/workbench")
            by_id = {s["id"]: s for s in catalog["suites"]}
            self.assertTrue(by_id["workbuddy-code"]["ready"], by_id["workbuddy-code"]["reasons"])
            self.assertEqual(by_id["workbuddy-code"]["task_count"], 3)
            self.assertIn("LLM judge", " ".join(by_id["workbuddy-web"]["reasons"]))
            with self.assertRaises(ValueError):
                self.client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                                 "tasks": ["not-a-workbuddy-task"]})
            run = self.client.request("api/runs", {"suite": "workbuddy-code", "model": "metask/session-model",
                                                   "tasks": ["bug_fix-easy-alpha", "data_quality-hard-beta"],
                                                   "attempts": 1, "concurrency": 2})
            final = wait_run(self.manager, run["name"])
        self.assertEqual(final["status"], "finished", final)
        job_root = self.manager.jobs_dir / run["name"]
        observed = json.loads((job_root / "observed.json").read_text())
        slug = "metacodes-" + run["name"]
        self.assertEqual(observed["argv"][:2] + observed["argv"][3:], ["run", "--frozen", "scripts/run.sh", "--job", slug])
        self.assertEqual(Path(observed["cwd"]).resolve(), repo.resolve())
        job = observed["job"]
        self.assertEqual((job["harness"], job["dataset"], job["model"]),
                         ("metacodes/0.1.0", "datasets/wb-bench-code-v1.0/tasks", slug))
        self.assertEqual(job["task_selection"], {"mode": "name", "names": ["bug_fix-easy-alpha", "data_quality-hard-beta"]})
        self.assertEqual(job["jobs_dir"], str(job_root / "workbuddy"))
        self.assertEqual(job["orchestrator_override"], {"n_concurrent_trials": 2})
        self.assertEqual(job["harness_params_override"], {"METACODES_REASONING_EFFORT": "max"})
        self.assertEqual(observed["model"]["model"]["name"], "session-model")
        self.assertEqual(observed["base_url"], f"http://127.0.0.1:{upstream.server_port}/v1/messages")
        self.assertTrue(observed["key_matches"])
        self.assertEqual((observed["judge_key"], observed["metask_key"]), (None, False))
        self.assertEqual((observed["shard_concurrency"], observed["platform"]), ("2", "linux/amd64"))
        # Transient configs are removed; the checkout stays clean.
        self.assertFalse((repo / "configs/jobs" / (slug + ".yaml")).exists())
        self.assertFalse((repo / "configs/models" / (slug + ".yaml")).exists())
        view = self.client.request("api/job?name=" + run["name"])
        self.assertEqual((view["suite"], view["category_name"], view["running"]), ("workbuddy-code", "办公 Agent", False))
        self.assertEqual(view["summary"]["counts"]["pass"], 1)
        self.assertEqual(view["summary"]["counts"]["fail"], 1)
        self.assertEqual(view["dataset"], "workbuddy/wb-bench-code-v1.0")
        trial = self.client.request(f"api/trial?job={run['name']}&trial=bug_fix-easy-alpha__wb1")
        self.assertEqual(trial["row"]["status"], "pass")
        public = json.dumps(catalog) + "".join(p.read_text() for p in self.manager.records.iterdir())
        self.assertNotIn("session-access", public)

    def test_workbuddy_readiness_reports_an_unpinned_checkout(self):
        repo = workbuddy_checkout(self.root, head="0" * 40)
        ctx = suites.Context({"workbuddy_checkout": str(repo)}, self.root)
        reasons = suites.readiness(suites.get("workbuddy-code"), ctx)
        self.assertTrue(any("固定提交" in r for r in reasons), reasons)
        ctx = suites.Context({"workbuddy_checkout": str(repo), "provider_config": "/x"}, self.root)
        self.assertTrue(any("Metask" in r for r in suites.readiness(suites.get("workbuddy-sec"), ctx)))


if __name__ == "__main__":
    unittest.main()
