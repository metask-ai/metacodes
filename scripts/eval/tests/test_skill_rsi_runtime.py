"""L2: product flags change actual provider bytes using the shared policy fixture."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from scripts.eval.skill_rsi import PREFIX, SUFFIX, Settings, route, run_rsi, stable
from tests.tty.slow_mock_server import SlowMockServer, simple_text, slow_text_then_tooluse

ROOT = Path(__file__).resolve().parents[3]
BIN = os.environ.get("METACODES_NATIVE_E2E_BIN")
FIXTURE = ROOT / "sdk/fixtures/skill-rsi-v1.json"


@unittest.skipUnless(BIN, "native product binary is provided by test:product")
class SkillRSIRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.policy = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.path = self.root / "policy.json"
        self.path.write_bytes(stable(self.policy))

    def invoke(self, prompt, flags, *, policy_path=None, turns=None, preview=True):
        with SlowMockServer(turns=turns or [simple_text("done")]) as server:
            result = subprocess.run([
                str(Path(BIN).resolve()), "--api-key", "fixture", "--base-url", server.url,
                "--model", self.policy["model"], "--no-theme", "--no-lsp", "--no-progress-updates",
                "--state-dir", str(self.home / ".metacodes"),
                *(["--preview"] if preview else []),
                "--rsi-policy", str(policy_path or self.path), *flags, "-p", prompt, "--json",
            ], cwd=self.root, env={**{k: v for k, v in os.environ.items() if k not in {"CODEX_HOME", "METACODES_HOME"}},
                                   "HOME": str(self.home), "METACODES_KG_AUTOSTART": "0"},
                capture_output=True, text=True, timeout=60)
            requests = [json.loads(raw) for raw in server.requests]
        return result, requests

    def notes(self, request):
        result = []
        for message in request.get("messages", []):
            content = message.get("content", [])
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            for block in content:
                text = block.get("text", "")
                if text.startswith(PREFIX):
                    result.append(text)
        return result

    def test_rsi_is_one_feature_with_evolution_and_routing_inside_it(self):
        scenarios = [
            ([], "count 2 items before editing", None),
            (["--rsi"], "read before editing", "evolved"),
            (["--rsi"], "count 2 items", None),
            (["--rsi", "--no-rsi"], "read before editing", None),
            (["--harnessmm"], "read before editing", None),
            (["--harnessmm", "--rsi"], "read before editing", "evolved"),
        ]
        system, tools = None, None
        for flags, prompt, selected in scenarios:
            with self.subTest(flags=flags, prompt=prompt):
                result, requests = self.invoke(prompt, flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(requests), 1)
                request = requests[0]
                expected = [] if selected is None else [PREFIX + self.policy[selected]["instruction"] + SUFFIX]
                self.assertEqual(self.notes(request), expected)
                if system is None:
                    system, tools = request.get("system"), request.get("tools")
                self.assertEqual(request.get("system"), system)
                self.assertEqual(request.get("tools"), tools)
                self.assertNotIn(str(self.path), json.dumps(request))

    def test_disabled_does_not_open_policy_and_enabled_rejects_stale_binding(self):
        missing = self.root / "missing.json"
        result, requests = self.invoke("count", [], policy_path=missing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.notes(requests[0]), [])
        bad = copy.deepcopy(self.policy)
        bad["evolved"]["router"]["instruction_sha256"] = "0" * 64
        self.path.write_bytes(stable(bad))
        result, requests = self.invoke("count", ["--rsi"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, [])

    def test_preview_off_skips_policy_io_even_when_rsi_is_selected(self):
        for path in (self.root / "missing.json", self.root):
            for flags in (["--rsi"], ["--preview", "--rsi", "--no-preview"]):
                with self.subTest(path=path, flags=flags):
                    result, requests = self.invoke("read before editing", flags, policy_path=path, preview=False)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(requests), 1)
                    self.assertEqual(self.notes(requests[0]), [])

    def test_missing_head_and_model_mismatch_abstain(self):
        for mode in ("missing_head", "model_mismatch"):
            with self.subTest(mode=mode):
                policy = copy.deepcopy(self.policy)
                if mode == "missing_head":
                    policy["evolved"]["router"] = None
                else:
                    policy["model"] = "different-model"
                self.path.write_bytes(stable(policy))
                result, requests = self.invoke("read before editing", ["--rsi"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.notes(requests[0]), [])

    def test_note_is_persisted_once_across_tool_rounds(self):
        target = self.root / "input.txt"
        target.write_text("input", encoding="utf-8")
        result, requests = self.invoke("read before editing", ["--rsi"], turns=[
            slow_text_then_tooluse(n_chunks=0, delay=0, tool="Read", tool_input=json.dumps({"file_path": str(target)})),
            simple_text("done")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 2)
        note = PREFIX + self.policy["evolved"]["instruction"] + SUFFIX
        self.assertEqual([self.notes(request) for request in requests], [[note], [note]])

    def test_python_and_native_router_share_feature_contract(self):
        self.path.write_bytes(stable({**self.policy, "evolved": self.policy["seed"]}))
        for prompt in ("总数是多少", "copyright", "read AFTER this", "'quoted'", "İ K 多少", "count " * 10000):
            with self.subTest(prompt=prompt[:40]):
                result, requests = self.invoke(prompt, ["--rsi"])
                self.assertEqual(result.returncode, 0, result.stderr)
                effective = route(self.policy["seed"], prompt, True)
                self.assertEqual(self.notes(requests[0]), [PREFIX + effective + SUFFIX] if effective else [])

    def test_generated_instruction_and_trained_head_reach_native_request(self):
        def call(request):
            result = {"model": request["model"], "input_tokens": 10, "output_tokens": 5, "cost_microusd": 0}
            if request["kind"] == "propose":
                result.update(instruction="Learned from paired executions.", supporting_task_ids=["t0", "t1"])
            else:
                result["score"] = 1.0 if request["instruction"] else 0.0
            return result
        data = {"model": self.policy["model"], "seed_instruction": "",
                "train": [{"id": f"t{i}", "unit_id": f"u{i}", "prompt": f"count {i} items"} for i in range(6)],
                "validation": [{"id": "v0", "unit_id": "v0", "prompt": "count 1 items"}]}
        policy, _ = run_rsi(data, call, Settings(evolution=True, routing=True, rounds=1))
        self.assertIsNotNone(policy["evolved"]["router"])
        self.path.write_bytes(stable(policy))
        result, requests = self.invoke("count 1 items", ["--rsi"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.notes(requests[0]), [PREFIX + "Learned from paired executions." + SUFFIX])


if __name__ == "__main__":
    unittest.main()
