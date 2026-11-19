"""Scripted Anthropic-Messages endpoint for the zero-cost Harbor smoke.

Two requests, then the run is over:

1. The request must offer the `Bash` tool; the answer is one `Bash` call that
   writes the smoke task's expected file.
2. The request must carry that call's result; the answer is a final text.

Anything else is a 409, so a drifted adapter fails the smoke instead of being
graded.  Every accepted request is appended to a log the smoke driver checks.
The SSE encoding is the WorkBuddy mock's (`scripts/eval/workbuddy/mock_provider`).
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, List, Mapping, Optional

from scripts.eval.workbuddy.mock_provider import _final_sse, _tool_sse

SMOKE_CREDENTIAL = "metacodes-harbor-smoke-only"
SMOKE_KEY_ENV = "METACODES_HARBOR_SMOKE_KEY"
SMOKE_PROVIDER = "harbor-smoke"
SMOKE_MODEL = "smoke-model"
CALL_ID = "harbor-smoke-bash"
# What the fixture task's verifier checks (fixtures/smoke-task/tests/test.sh).
EXPECTED_FILE = "/app/hello.txt"
EXPECTED_TEXT = "Hello from metacodes"
BASH_COMMAND = f"printf '%s\\n' '{EXPECTED_TEXT}' > {EXPECTED_FILE} && cat {EXPECTED_FILE}"
FINAL_TEXT = "Wrote /app/hello.txt."
MAX_REQUEST_BYTES = 16 * 1024 * 1024


class ScenarioError(ValueError):
    """The request is not the next step of the scripted run."""


def _tool_result(request: Mapping[str, Any], call_id: str) -> Optional[str]:
    messages = request.get("messages")
    if not isinstance(messages, list) or not messages:
        return None
    last = messages[-1]
    if not isinstance(last, Mapping) or last.get("role") != "user":
        return None
    content = last.get("content")
    if not isinstance(content, list):
        return None
    for block in content:
        if (
            isinstance(block, Mapping)
            and block.get("type") == "tool_result"
            and block.get("tool_use_id") == call_id
        ):
            value = block.get("content")
            if isinstance(value, list):
                return "".join(
                    str(part.get("text", "")) for part in value if isinstance(part, Mapping)
                )
            return str(value)
    return None


def scripted_response(number: int, request: Mapping[str, Any]) -> bytes:
    """The SSE body for the `number`-th request (from 1)."""

    if request.get("model") != SMOKE_MODEL:
        raise ScenarioError(f"unexpected model {request.get('model')!r}")
    if number == 1:
        tools = request.get("tools")
        names = {
            tool.get("name") for tool in tools or [] if isinstance(tool, Mapping)
        }
        if "Bash" not in names:
            raise ScenarioError("the first request does not offer the Bash tool")
        return _tool_sse(number, CALL_ID, "Bash", {"command": BASH_COMMAND})
    if number == 2:
        result = _tool_result(request, CALL_ID)
        if result is None:
            raise ScenarioError("the second request does not carry the Bash result")
        if EXPECTED_TEXT not in result:
            raise ScenarioError(f"the Bash result lacks the expected text: {result[:200]!r}")
        return _final_sse(number, FINAL_TEXT)
    raise ScenarioError(f"request {number} is past the end of the scripted run")


class _Handler(BaseHTTPRequestHandler):
    server_version = "metacodes-harbor-smoke/1"

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.path.rstrip("/") != "/v1/messages":
            self.send_error(404)
            return
        server: SmokeServer = self.server  # type: ignore[assignment]
        authorized = self.headers.get("Authorization") == "Bearer " + SMOKE_CREDENTIAL if server.bearer else self.headers.get("x-api-key") == SMOKE_CREDENTIAL
        if not authorized:
            self.send_error(401)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_error(400)
            return
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_error(413)
            return
        try:
            request = json.loads(self.rfile.read(length))
        except (UnicodeError, json.JSONDecodeError):
            self.send_error(400)
            return
        if not isinstance(request, dict):
            self.send_error(400)
            return
        server: SmokeServer = self.server  # type: ignore[assignment]
        with server.lock:
            number = len(server.requests) + 1
            try:
                payload = scripted_response(number, request)
            except ScenarioError as exc:
                server.errors.append(str(exc))
                self.send_error(409, str(exc))
                return
            server.requests.append(
                {
                    "number": number,
                    "model": request.get("model"),
                    "tool_names": sorted(
                        tool.get("name")
                        for tool in request.get("tools") or []
                        if isinstance(tool, Mapping) and isinstance(tool.get("name"), str)
                    ),
                }
            )
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args: object) -> None:
        return


class SmokeServer(ThreadingHTTPServer):
    """The scripted endpoint; `requests` and `errors` record what it saw."""

    daemon_threads = True

    def __init__(self, host: str, port: int, *, bearer: bool = False):
        super().__init__((host, port), _Handler)
        self.lock = threading.Lock()
        self.requests: List[dict] = []
        self.errors: List[str] = []
        self.bearer = bearer

    def server_bind(self) -> None:
        # Skip HTTPServer's reverse DNS lookup of the bind address.
        import socketserver

        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)


def provider_config(base_url: str) -> dict:
    """The metacodes `config.json` that routes `harbor-smoke/*` to the mock.

    The channel is plain HTTP to a non-loopback name, which the endpoint
    policy refuses unless the provider states it (`require_tls: false`).
    """

    return {
        "schema_version": 1,
        "custom_providers": {
            SMOKE_PROVIDER: {
                "display_name": "Harbor smoke mock",
                "auth": {"kind": "api_key_header", "header": "x-api-key"},
                "env_aliases": [
                    {"name": SMOKE_KEY_ENV, "kind": "api_key", "canonical": True}
                ],
                "endpoint_policy": {"require_tls": False},
                "channels": [
                    {
                        "id": "mock",
                        "base_url": base_url.rstrip("/"),
                        "protocol": "anthropic_messages",
                    }
                ],
                "models": [{"request_model_id": SMOKE_MODEL}],
            }
        },
    }


def write_config(path: Path, base_url: str) -> None:
    path.write_text(json.dumps(provider_config(base_url), indent=2) + "\n", encoding="utf-8")
