"""A scripted Anthropic Messages SSE server on loopback, for tests only.

Each request pops the next step of the script:

* ``("text", "...")`` answers with one text block and ``end_turn``;
* ``("tool", name, input_dict)`` answers with one ``tool_use`` block;
* ``("echo",)`` answers with the text of the last tool_result it received,
  prefixed by ``"saw: "``, so a test can prove the result reached the model;
* ``("status", code, headers_dict, body_dict)`` answers with that non-2xx JSON.

Every request body is kept in ``requests`` for assertions, and the
``authorization`` header each one carried in ``authorizations``.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, List


def _sse(events: List[tuple]) -> bytes:
    return "".join(
        "event: %s\ndata: %s\n\n" % (name, json.dumps(data)) for name, data in events
    ).encode("utf-8")


def _start(index: int) -> tuple:
    return (
        "message_start",
        {
            "type": "message_start",
            "message": {
                "id": "msg_%d" % index,
                "type": "message",
                "role": "assistant",
                "model": "mock-model",
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {"input_tokens": 11, "output_tokens": 1},
            },
        },
    )


def _finish(stop_reason: str) -> List[tuple]:
    return [
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": 7},
            },
        ),
        ("message_stop", {"type": "message_stop"}),
    ]


def text_response(index: int, text: str) -> bytes:
    return _sse(
        [
            _start(index),
            (
                "content_block_start",
                {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            ),
            (
                "content_block_delta",
                {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ]
        + _finish("end_turn")
    )


def tool_response(index: int, name: str, arguments: dict) -> bytes:
    return _sse(
        [
            _start(index),
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "tool_use", "id": "toolu_%d" % index, "name": name, "input": {}},
                },
            ),
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": json.dumps(arguments)},
                },
            ),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ]
        + _finish("tool_use")
    )


def openai_text_response(text: str) -> bytes:
    """OpenAI Chat Completions SSE: one content delta, `stop`, then usage."""
    chunks = [
        {"choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]},
        {"choices": [{"index": 0, "delta": {"content": text}}]},
        {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        {"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 7}},
    ]
    return ("".join("data: %s\n\n" % json.dumps(chunk) for chunk in chunks) + "data: [DONE]\n\n").encode("utf-8")


def last_tool_result(body: dict) -> str:
    for message in reversed(body.get("messages", [])):
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                value = block.get("content")
                if isinstance(value, list):
                    return "".join(part.get("text", "") for part in value if isinstance(part, dict))
                return str(value)
    return ""


class MockProvider:
    def __init__(self, script: List[tuple]) -> None:
        self.script = list(script)
        self.requests: List[dict] = []
        self.authorizations: List[str] = []
        self._lock = threading.Lock()
        provider = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: Any) -> None:
                pass

            def do_POST(self) -> None:  # noqa: N802 - http.server contract
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
                with provider._lock:
                    provider.requests.append(body)
                    provider.authorizations.append(self.headers.get("authorization", ""))
                    index = len(provider.requests)
                    step = provider.script.pop(0) if provider.script else ("text", "script exhausted")
                if step[0] == "status":
                    failure = json.dumps(step[3]).encode("utf-8")
                    self.send_response(step[1])
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(failure)))
                    for name, value in step[2].items():
                        self.send_header(name, value)
                    self.end_headers()
                    self.wfile.write(failure)
                    return
                if self.path.endswith("/chat/completions"):
                    # OpenAI protocol: text steps only.
                    payload = openai_text_response(step[1] if step[0] == "text" else "unsupported step")
                elif step[0] == "tool":
                    payload = tool_response(index, step[1], step[2])
                elif step[0] == "echo":
                    payload = text_response(index, "saw: " + last_tool_result(body))
                else:
                    payload = text_response(index, step[1])
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )

    @property
    def base_url(self) -> str:
        return "http://127.0.0.1:%d/v1/messages" % self._server.server_port

    @property
    def openai_url(self) -> str:
        return "http://127.0.0.1:%d/v1/chat/completions" % self._server.server_port

    def __enter__(self) -> "MockProvider":
        self._thread.start()
        return self

    def __exit__(self, *_: Any) -> None:
        self._server.shutdown()
        self._server.server_close()
