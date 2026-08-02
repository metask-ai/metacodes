import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.eval.e2e_adapter import (
    finalize_evaluation_fd,
    import_run,
    prepare_runtime_metadata,
)
from scripts.eval.model import load_json
from tests.tty.slow_mock_server import SlowMockServer, simple_text, slow_text_then_tooluse


REPO_ROOT = Path(__file__).resolve().parents[3]
BIN = os.environ.get("METACODES_NATIVE_E2E_BIN")


@unittest.skipUnless(BIN, "set METACODES_NATIVE_E2E_BIN to run the native runtime smoke test")
class NativeRuntimeTest(unittest.TestCase):
    def test_real_repl_writes_execution_grounded_events(self):
        binary = Path(BIN).resolve()
        self.assertTrue(binary.is_file(), binary)
        suite = load_json(REPO_ROOT / "evals/suites/core-e2e.json")
        task = next(item for item in suite["tasks"] if item["id"] == "00_smoke")
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "native-run"
            workspace = run / "00_smoke"
            home = workspace / ".home"
            home.mkdir(parents=True)
            debug_log = run / "00_smoke.debug.log"
            events = workspace / "events.jsonl"
            metadata_path = workspace / "eval-metadata.json"
            metadata = prepare_runtime_metadata(
                suite,
                REPO_ROOT,
                task["id"],
                output=metadata_path,
                events_path=str(events),
                run_id="native-runtime:00_smoke:0",
                trial=0,
                model_provider="anthropic",
                model_id="claude-sonnet-4-20250514",
                harness_config_id="native-runtime-test",
                harness_revision="test",
                permission_mode="bypass_permissions",
                binary_path=binary,
            )
            self.assertIsNotNone(metadata)
            metadata_fd = os.open(metadata_path, os.O_RDONLY)
            metadata_path.unlink()
            events_file = tempfile.TemporaryFile()
            tool_input = json.dumps(
                {
                    "file_path": "hello-test/hello.txt",
                    "content": "hello from cc-zig e2e\n",
                },
                separators=(",", ":"),
            )
            with SlowMockServer(
                turns=[
                    slow_text_then_tooluse(
                        n_chunks=0, delay=0, tool="Write", tool_input=tool_input
                    ),
                    simple_text("done"),
                ]
            ) as server:
                env = {
                    **os.environ,
                    "HOME": str(home),
                    "METACODES_EVAL_METADATA_FD": str(metadata_fd),
                    "METACODES_EVAL_FD": str(events_file.fileno()),
                    "METACODES_LOG": "agent:debug,permission:debug,*:info",
                    "METACODES_LOG_FILE": str(debug_log),
                }
                completed = subprocess.run(
                    [
                        str(binary),
                        "--api-key",
                        "test-key",
                        "--base-url",
                        server.url,
                        "--model",
                        "claude-sonnet-4-20250514",
                        "--permission",
                        "bypassPermissions",
                    ],
                    input="create the requested file\n/exit\n",
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    cwd=workspace,
                    env=env,
                    timeout=30,
                    check=False,
                    pass_fds=(metadata_fd, events_file.fileno()),
                )
            os.close(metadata_fd)
            finalize_evaluation_fd(events_file.fileno(), events)
            events_file.close()
            (run / "00_smoke.log").write_text(completed.stdout, encoding="utf-8")
            (run / "REPORT.md").write_text(
                f"## 场景: 00_smoke\n\n- session 退出码: `{completed.returncode}`\n",
                encoding="utf-8",
            )
            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertTrue(events.is_file(), completed.stdout)
            raw = events.read_text(encoding="utf-8")
            self.assertIn('"task_fingerprint_provenance":"recorded_at_execution"', raw)
            self.assertIn('"runtime_model_provider":"anthropic"', raw)
            self.assertIn('"policy_decision"', raw)
            self.assertIn('"estimated_cost_usd"', raw)
            self.assertIn('"model_request_finished"', raw)
            self.assertIn('"tool_stage_finished"', raw)
            rollout = import_run(suite, REPO_ROOT, run)[0]
            self.assertEqual(rollout["task_fingerprint_provenance"], "recorded_at_execution")
            self.assertEqual(rollout["metrics"]["policy_violations"], 0)
            self.assertEqual(rollout["metrics"]["model_request_count"], 2)
            self.assertIsNotNone(rollout["metrics"]["model_request_time_ms"])
            self.assertIsNotNone(rollout["metrics"]["tool_stage_time_ms"])
            self.assertIsNotNone(rollout["metrics"]["harness_time_ms"])
            self.assertEqual(
                rollout["metrics"]["wall_time_ms"],
                rollout["metrics"]["model_request_time_ms"]
                + rollout["metrics"]["tool_stage_time_ms"]
                + rollout["metrics"]["harness_time_ms"],
            )
            self.assertTrue(rollout["judgement"]["trustworthy_success"])


if __name__ == "__main__":
    unittest.main()
