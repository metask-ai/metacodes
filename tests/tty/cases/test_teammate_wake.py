import http.server
import json
import socketserver
import threading
import time

from tty_driver import READY, case_tmpdir, run, wait_for
from asserts import TTYAssert

ROWS, COLS = 40, 110
MARK = "LATE-TEAMMATE-MARK"
_TOOL_IDS = [0]


def _sse(blocks):
    out = ['data: {"type":"message_start","message":{"id":"m","role":"assistant","model":"x",'
           '"usage":{"input_tokens":1,"output_tokens":1}}}\n\n']
    stop_reason = "end_turn"
    for i, (kind, value) in enumerate(blocks):
        if kind == "text":
            out.append('data: {"type":"content_block_start","index":%d,"content_block":{"type":"text","text":""}}\n\n' % i)
            out.append('data: {"type":"content_block_delta","index":%d,"delta":{"type":"text_delta","text":%s}}\n\n'
                       % (i, json.dumps(value)))
        else:
            name, args = value
            _TOOL_IDS[0] += 1
            out.append('data: {"type":"content_block_start","index":%d,"content_block":{"type":"tool_use",'
                       '"id":"toolu_wake_%04d","name":"%s","input":{}}}\n\n' % (i, _TOOL_IDS[0], name))
            out.append('data: {"type":"content_block_delta","index":%d,"delta":{"type":"input_json_delta",'
                       '"partial_json":%s}}\n\n' % (i, json.dumps(json.dumps(args))))
            stop_reason = "tool_use"
        out.append('data: {"type":"content_block_stop","index":%d}\n\n' % i)
    out.append('data: {"type":"message_delta","delta":{"stop_reason":"%s"},"usage":{"output_tokens":5}}\n\n' % stop_reason)
    out.append('data: {"type":"message_stop"}\n\n')
    return "".join(out).encode()


LEAD_TURNS = [
    _sse([("text", "making team"), ("tool", ("TeamCreate", {"name": "wake-team", "description": "tty"}))]),
    _sse([("text", "spawning"), ("tool", ("Task", {"name": "slowpoke", "description": "slow",
                                                   "prompt": MARK + " take your time"}))]),
    _sse([("text", "LEAD-TURN-ENDED")]),
    _sse([("text", "LEAD-SAW-TEAMMATE")]),
]
TEAMMATE_TURN = _sse([("text", "TEAMMATE-LATE-REPLY")])


def _last_text(messages):
    if not messages:
        return ""
    content = messages[-1].get("content")
    if isinstance(content, str):
        return content
    return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")


class _TeamServer:
    def __init__(self, delay):
        self.delay = delay
        self.lead_requests = []
        self.teammate_requests = 0
        self.lock = threading.Lock()

    def __enter__(self):
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("content-length", 0)))
                messages = json.loads(body).get("messages", [])
                if MARK in _last_text(messages):
                    with outer.lock:
                        outer.teammate_requests += 1
                    time.sleep(outer.delay)
                    reply = TEAMMATE_TURN
                else:
                    with outer.lock:
                        outer.lead_requests.append(messages)
                        reply = LEAD_TURNS[min(len(outer.lead_requests), len(LEAD_TURNS)) - 1]
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                self.wfile.write(reply)
                self.wfile.flush()

        socketserver.ThreadingTCPServer.allow_reuse_address = True
        self._server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1/messages" % self._server.server_address[1]

    def __exit__(self, *exc):
        self._server.shutdown()
        self._server.server_close()


def _run(bin_path, keys, delay):
    with _TeamServer(delay) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("LEAD-TURN-ENDED", 30), "sleep:0.5"] + keys,
                  term_size=(ROWS, COLS), env={"METACODES_JEV_URL": "off"}, base_url=srv.url,
                  cwd=case_tmpdir("cc-tty-teammate-wake-"), per_key_drain=0.05)
        return TTYAssert(raw, rows=ROWS, cols=COLS), list(srv.lead_requests), srv.teammate_requests


def test_an_idle_lead_takes_a_teammate_report_without_a_key(bin_path):
    a, lead_requests, teammate_requests = _run(bin_path, [wait_for("LEAD-SAW-TEAMMATE", 30), "sleep:1.0"], delay=5.0)
    if teammate_requests != 1:
        a._fail(f"the teammate was asked {teammate_requests} times")
    if len(lead_requests) != 4:
        a._fail(f"the lead made {len(lead_requests)} requests; the fourth comes only if the idle prompt woke for the report")
    if "teammate" not in json.dumps(lead_requests[3][-1]):
        a._fail(f"the woken turn did not carry the teammate's report: {lead_requests[3][-1]!r}")
    if a.final.find_last_row("LEAD-SAW-TEAMMATE") is None:
        a._fail("the woken turn's reply is not on the screen")


def test_a_lead_with_a_draft_in_the_box_is_not_woken_by_a_teammate_report(bin_path):
    a, lead_requests, teammate_requests = _run(bin_path, ["type:draft", "strictsleep:9.0"], delay=5.0)
    if teammate_requests != 1:
        a._fail(f"the teammate was asked {teammate_requests} times")
    if len(lead_requests) != 3:
        a._fail(f"a turn started over the draft: {len(lead_requests)} lead requests")
    a.assert_input_echo("draft")
