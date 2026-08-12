import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from scripts.eval.workbuddy.mock_provider import (
    MOCK_CREDENTIAL,
    ScenarioError,
    _control_plane_sse,
    _private_new,
)


class WorkBuddyMockProviderTest(unittest.TestCase):
    @staticmethod
    def _control_request(results=()):
        names = (
            "KgRemember",
            "KgRecall",
            "KgContext",
            "TaskCreate",
            "TaskUpdate",
            "Write",
        )
        messages = [{"role": "user", "content": "synthetic W0.5"}]
        for call_id, value in results:
            messages.extend(
                [
                    {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "tool_use",
                                "id": call_id,
                                "name": "fixture",
                                "input": {},
                            }
                        ],
                    },
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": call_id,
                                "content": json.dumps(value),
                                "is_error": False,
                            }
                        ],
                    },
                ]
            )
        return {
            "model": "glm-5.2",
            "stream": True,
            "messages": messages,
            "tools": [{"name": name} for name in names],
        }

    def test_control_scenario_requires_real_prior_results_and_closes_task(self):
        results = []
        payload = _control_plane_sse(1, self._control_request(results))
        self.assertIn(b'"name":"KgRemember"', payload)

        results.append(("w05-remember", {"remembered": {"node_id": 7}}))
        payload = _control_plane_sse(2, self._control_request(results))
        self.assertIn(b'"name":"KgRecall"', payload)

        results.append(
            (
                "w05-recall",
                {"count": 1, "hits": [{"node_id": 7, "seen_before": False}]},
            )
        )
        payload = _control_plane_sse(3, self._control_request(results))
        self.assertIn(b'"name":"KgContext"', payload)

        results.append(
            (
                "w05-context",
                {
                    "knowledge_governance": {
                        "schema_version": "metacodes-knowledge-governance-v1"
                    }
                },
            )
        )
        self.assertIn(
            b'"name":"TaskCreate"',
            _control_plane_sse(4, self._control_request(results)),
        )
        results.append(("w05-task-create", {"task": {"id": "kg-11"}}))
        self.assertIn(
            b'"name":"TaskUpdate"',
            _control_plane_sse(5, self._control_request(results)),
        )
        results.append(
            ("w05-task-claim", {"claimed": True, "claimed_by": "agent-l2"})
        )
        self.assertIn(
            b'"name":"Write"',
            _control_plane_sse(6, self._control_request(results)),
        )
        results.append(("w05-write", {"ok": True}))
        self.assertIn(
            b'"w05-task-complete"',
            _control_plane_sse(7, self._control_request(results)),
        )
        results.append(("w05-task-complete", {"closed": True}))
        final = _control_plane_sse(8, self._control_request(results))
        self.assertIn(b'"stop_reason":"end_turn"', final)
        self.assertNotIn(b"control_metrics", final)

    def test_control_scenario_rejects_order_drift_before_next_tool(self):
        with self.assertRaisesRegex(ScenarioError, "w05-remember"):
            _control_plane_sse(2, self._control_request())
        with self.assertRaisesRegex(ScenarioError, "persist a TinyKG task"):
            _control_plane_sse(
                5,
                self._control_request(
                    [
                        ("w05-context", {"knowledge_governance": {}}),
                        ("w05-task-create", {"task": {"id": "1"}}),
                    ]
                ),
            )

    def test_control_scenario_rejects_failed_write_before_task_completion(self):
        request = self._control_request(
            [
                ("w05-task-create", {"task": {"id": "kg-11"}}),
                ("w05-write", {"error": "disk full"}),
            ]
        )
        request["messages"][-1]["content"][0]["is_error"] = True
        with self.assertRaisesRegex(ScenarioError, "Write reported an error"):
            _control_plane_sse(7, request)

    def test_private_artifact_handles_short_writes_and_is_durable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            output = root / "artifact.json"
            original_write = os.write

            def short_write(descriptor: int, payload: bytes) -> int:
                return original_write(descriptor, payload[:2])

            with mock.patch(
                "scripts.eval.workbuddy.mock_provider.os.write",
                side_effect=short_write,
            ):
                _private_new(output, b"complete-payload")

            self.assertEqual(output.read_bytes(), b"complete-payload")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "overwrite"):
                _private_new(output, b"replacement")

    def test_cli_serves_anthropic_sse_and_audits_request_without_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            ready = root / "ready.json"
            request_log = root / "requests.jsonl"
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "scripts.eval.workbuddy.mock_provider",
                    "--ready",
                    str(ready),
                    "--request-log",
                    str(request_log),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    if process.poll() is not None:
                        self.fail(f"mock provider exited early: {process.stderr.read()}")
                    time.sleep(0.02)
                self.assertTrue(ready.is_file(), "mock provider did not become ready")
                port = json.loads(ready.read_text(encoding="utf-8"))["port"]
                body = json.dumps(
                    {
                        "model": "glm-5.2",
                        "messages": [{"role": "user", "content": "test"}],
                        "stream": True,
                    }
                ).encode("utf-8")
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/v1/messages",
                    data=body,
                    headers={
                        "Authorization": f"Bearer {MOCK_CREDENTIAL}",
                        "Content-Type": "application/json",
                    },
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=5) as response:
                    payload = response.read()
                self.assertIn(b'"type":"message_stop"', payload)
                rows = request_log.read_text(encoding="utf-8").splitlines()
                self.assertEqual(len(rows), 1)
                audit = json.loads(rows[0])
                self.assertEqual(audit["path"], "/v1/messages")
                self.assertEqual(audit["model"], "glm-5.2")
                self.assertNotIn(MOCK_CREDENTIAL, rows[0])

                bad = urllib.request.Request(
                    f"http://127.0.0.1:{port}/wrong",
                    data=body,
                    headers={"Authorization": f"Bearer {MOCK_CREDENTIAL}"},
                    method="POST",
                )
                with self.assertRaises(urllib.error.HTTPError) as error:
                    urllib.request.urlopen(bad, timeout=5)
                self.assertEqual(error.exception.code, 404)
                self.assertEqual(len(request_log.read_text().splitlines()), 1)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                if process.stderr is not None:
                    process.stderr.close()


if __name__ == "__main__":
    unittest.main()
