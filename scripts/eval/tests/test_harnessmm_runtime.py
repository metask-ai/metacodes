"""Native EDG/GDR/CCS: identical tool effects with fewer physical model calls."""
import copy
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[3]
BIN = os.environ.get("METACODES_NATIVE_E2E_BIN")
OPEN, CLOSE = "<HARNESSMM_PLAN>", "</HARNESSMM_PLAN>"


def response(text, action=None, call_id="actor_root"):
    events = [{"type": "message_start", "message": {"id": "m", "role": "assistant", "model": "fixture",
               "usage": {"input_tokens": 100, "output_tokens": 1}}},
              {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
              {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
              {"type": "content_block_stop", "index": 0}]
    if action:
        events += [
            {"type": "content_block_start", "index": 1, "content_block": {"type": "tool_use", "id": call_id, "name": action["tool"], "input": {}}},
            {"type": "content_block_delta", "index": 1, "delta": {"type": "input_json_delta", "partial_json": json.dumps(action["arguments"])}},
            {"type": "content_block_stop", "index": 1},
        ]
    events += [{"type": "message_delta", "delta": {"stop_reason": "tool_use" if action else "end_turn"}, "usage": {"output_tokens": 10}},
               {"type": "message_stop"}]
    return b"".join(b"data: " + json.dumps(event).encode() + b"\n\n" for event in events)


def tool_results(request):
    return [block for message in request["messages"] for block in message.get("content", [])
            if isinstance(block, dict) and block.get("type") == "tool_result"]


def receipt_text(result):
    content = result["content"]
    return content if isinstance(content, str) else "".join(part.get("text", "") for part in content)


class Actor(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, plan):
        super().__init__(("127.0.0.1", 0), Handler)
        self.plan, self.requests = plan, []

    def __enter__(self):
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.shutdown()
        self.server_close()
        self.thread.join()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_error(404)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(request)
        results = tool_results(request)
        if not results:
            plan = OPEN + json.dumps(self.server.plan, separators=(",", ":")) + CLOSE
            data = response(plan, self.server.plan["root"])
        else:
            result = json.loads(receipt_text(results[-1]))
            step = {"root": 0, "one": 1, "two": 2}.get(result.get("stdout"))
            if results[-1].get("is_error") or step is None:
                data = response("done")
            else:
                action = {"tool": "Bash", "arguments": {"command": ("printf one", "printf two", "printf three")[step]}}
                data = response("", action, f"actor_{step}")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


@unittest.skipUnless(BIN, "native product binary is provided by test:product")
class HarnessMMRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.plan = json.loads((ROOT / "sdk/fixtures/harnessmm-plan-v1.json").read_text())
        self.policy = self.root / "policy.json"
        self.policy.write_bytes((ROOT / "sdk/fixtures/skill-rsi-v1.json").read_bytes())

    def run_actor(self, flags, *, plan=None, extra=()):
        # A stable state root keeps unrelated memory-path prompt bytes equal.
        home = self.root / "home"
        if home.exists():
            shutil.rmtree(home)
        home.mkdir()
        with Actor(plan or self.plan) as actor:
            result = subprocess.run([str(Path(BIN).resolve()), "--api-key", "fixture", "--base-url", f"http://127.0.0.1:{actor.server_port}",
                "--model", "claude-sonnet-4-20250514", "--no-theme", "--no-lsp", "--no-progress-updates", "--permission", "bypassPermissions",
                "--rsi-policy", str(self.policy), *flags, *extra, "-p", "read before editing", "--json"],
                cwd=self.root, env={**{k: v for k, v in os.environ.items() if k not in {"CODEX_HOME", "METACODES_HOME"}},
                                   "HOME": str(home), "METACODES_KG_AUTOSTART": "0"},
                capture_output=True, text=True, timeout=90)
            requests = actor.requests
        certificates = [json.loads(line) for path in home.rglob("harnessmm.jsonl") for line in path.read_text().splitlines() if line]
        return result, requests, certificates

    def test_harnessmm_and_rsi_are_independent_product_features(self):
        system, tools = None, None
        for flags, reuse, rsi in (([], False, False), (["--harnessmm"], True, False),
                (["--rsi"], False, True), (["--harnessmm", "--rsi"], True, True)):
            with self.subTest(flags=flags):
                result, requests, certificates = self.run_actor(flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(requests), 2 if reuse else 5)
                self.assertEqual(len(certificates), 3 if reuse else 0)
                first = json.dumps(requests[0])
                self.assertEqual("<procedural-skill>" in first, rsi)
                self.assertEqual("<harnessmm-authoring>" in first, reuse)
                self.assertNotIn(str(self.policy), first)
                if system is None:
                    system, tools = requests[0].get("system"), requests[0]["tools"]
                self.assertEqual(requests[0].get("system"), system)
                self.assertEqual(requests[0]["tools"], tools)
                results = tool_results(requests[-1])
                self.assertEqual([json.loads(receipt_text(row))["stdout"] for row in results], ["root", "one", "two", "three"])
                if reuse:
                    calls = {block["id"]: block for message in requests[-1]["messages"] for block in message.get("content", [])
                             if isinstance(block, dict) and block.get("type") == "tool_use"}
                    receipts = {row["tool_use_id"]: row for row in results}
                    for i, cert in enumerate(certificates):
                        self.assertEqual(cert["decision_id"], "ABC"[i])
                        self.assertEqual(cert["omitted_callback_turn"], i + 2)
                        self.assertEqual(json.loads(cert["arguments_json"]), calls[cert["native_call_id"]]["input"])
                        self.assertEqual(cert["arguments_sha256"], hashlib.sha256(cert["arguments_json"].encode()).hexdigest())
                        self.assertEqual(cert["native_receipt_sha256"], hashlib.sha256(receipt_text(receipts[cert["native_call_id"]]).encode()).hexdigest())
                        self.assertEqual(cert["predecessor_receipt_sha256"], hashlib.sha256(receipt_text(receipts[cert["predecessor_call_id"]]).encode()).hexdigest())

    def test_negative_flags_restore_original_callback_loop(self):
        result, requests, certificates = self.run_actor(["--harnessmm", "--rsi", "--no-harnessmm", "--no-rsi"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 5)
        self.assertEqual(certificates, [])
        first = json.dumps(requests[0])
        self.assertNotIn("<harnessmm-authoring>", first)
        self.assertNotIn("<procedural-skill>", first)

    def test_false_guard_and_ambiguous_branches_fall_back_without_reuse(self):
        for mode in ("false", "ambiguous", "cycle", "unresolved_tool"):
            with self.subTest(mode=mode):
                plan = copy.deepcopy(self.plan)
                if mode == "false":
                    plan["nodes"][0]["guard"]["literal"] = "not-the-observed-root"
                elif mode == "ambiguous":
                    plan["nodes"][1]["after"] = "root"
                    plan["nodes"][1]["guard"] = {"kind": "exit_zero"}
                elif mode == "cycle":
                    plan["nodes"][0]["after"] = "A"
                else:
                    plan["nodes"][0]["tool"] = "Write"
                result, requests, certificates = self.run_actor(["--harnessmm"], plan=plan)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(requests), 5)
                self.assertEqual(certificates, [])

    def test_native_permission_denial_stops_the_remaining_graph(self):
        result, requests, certificates = self.run_actor(["--harnessmm"], extra=["--disallowed-tools", "Bash(printf one)"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(requests), 2)
        self.assertEqual(len(certificates), 1)
        self.assertTrue(certificates[0]["native_receipt_is_error"])
        self.assertTrue(tool_results(requests[-1])[-1]["is_error"])

if __name__ == "__main__":
    unittest.main()
