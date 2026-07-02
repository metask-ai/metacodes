"""TTY coverage for local goal/loop/compact slash commands.

These cases are intentionally offline: they exercise the user-visible command
surface and final input-box recovery without sending a model request.
"""

import http.server
import threading

from tty_driver import run
from asserts import TTYAssert


class _AnthropicMock(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        if b'"stream":false' in body:
            payload = b'{"content":[{"type":"text","text":"COMPACT_SUMMARY"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        sse = (
            b'data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
            b'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"done"}}\n\n'
            b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        )
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(sse)))
        self.end_headers()
        self.wfile.write(sse)


def _start_mock():
    server = http.server.HTTPServer(("127.0.0.1", 0), _AnthropicMock)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_port}/v1/messages"


def test_tty_goal_command_lifecycle(bin_path):
    raw = run(bin_path, [
        "sleep:0.8",
        "type:/goal set ship tty goal",
        "key:enter",
        "sleep:0.2",
        "type:/goal budget 42",
        "key:enter",
        "sleep:0.2",
        "type:/goal pause",
        "key:enter",
        "sleep:0.2",
        "type:/goal resume",
        "key:enter",
        "sleep:0.2",
        "type:/exit",
        "key:enter",
        "sleep:0.3",
    ])
    a = TTYAssert(raw)
    a.assert_prose_contains("Goal set.")
    a.assert_prose_contains("target:  ship tty goal")
    a.assert_prose_contains("budget:  42 tokens")
    a.assert_prose_contains("Goal [paused]")
    a.assert_prose_contains("Goal [active]")
    a.assert_clean_exit()


def test_tty_loop_requires_goal_then_enables_and_stops(bin_path):
    raw = run(bin_path, [
        "sleep:0.8",
        "type:/loop on 2",
        "key:enter",
        "sleep:0.2",
        "type:/goal set continue tty work",
        "key:enter",
        "sleep:0.2",
        "type:/loop on 2",
        "key:enter",
        "sleep:0.2",
        "type:/loop off",
        "key:enter",
        "sleep:0.2",
        "type:/exit",
        "key:enter",
        "sleep:0.3",
    ], permission="plan")
    a = TTYAssert(raw)
    a.assert_prose_contains("Set a goal first")
    a.assert_prose_contains("Loop continuation: on (2 remaining)")
    a.assert_prose_contains("Goal status: active")
    a.assert_prose_contains("Loop continuation stopped.")
    a.assert_clean_exit()


def test_tty_compact_command_recovers_input_box(bin_path):
    raw = run(bin_path, [
        "sleep:0.8",
        "type:/compact",
        "key:enter",
        "sleep:0.3",
    ])
    a = TTYAssert(raw)
    a.assert_prose_contains("Compacted")
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_tty_auto_compact_event_is_visible(bin_path):
    server, base_url = _start_mock()
    try:
        raw = run(bin_path, [
            "sleep:0.8",
            "type:/compact-stress-test",
            "key:enter",
            "sleep:0.2",
            "type:trigger auto compact",
            "key:enter",
            "sleep:2.0",
        ], base_url=base_url, env={"METACODES_TEST_HOOKS": "1"})
    finally:
        server.shutdown()
    a = TTYAssert(raw)
    a.assert_prose_contains("[compact-stress-test] injected large history")
    a.assert_prose_contains("[auto-compacted")
