import http.server
import json
import os
import socketserver
import subprocess
import threading

from tty_driver import READY, case_tmpdir, run, wait_for
from e2e_helpers import SkipTest

ROWS, COLS = 40, 110
MARK = "PROCESS-TEAMMATE-ROUTE-MARK"
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
                       '"id":"toolu_route_%04d","name":"%s","input":{}}}\n\n' % (i, _TOOL_IDS[0], name))
            out.append('data: {"type":"content_block_delta","index":%d,"delta":{"type":"input_json_delta",'
                       '"partial_json":%s}}\n\n' % (i, json.dumps(json.dumps(args))))
            stop_reason = "tool_use"
        out.append('data: {"type":"content_block_stop","index":%d}\n\n' % i)
    out.append('data: {"type":"message_delta","delta":{"stop_reason":"%s"},"usage":{"output_tokens":5}}\n\n' % stop_reason)
    out.append('data: {"type":"message_stop"}\n\n')
    return "".join(out).encode()


LEAD_TURNS = [
    _sse([("text", "making team"), ("tool", ("TeamCreate", {"name": "route-team", "description": "tty"}))]),
    _sse([("text", "spawning"), ("tool", ("Task", {"name": "worker", "description": "w", "prompt": MARK + " reply briefly"}))]),
    _sse([("text", "telling"), ("tool", ("SendMessage", {"to": "worker", "message": MARK + " please answer"}))]),
    _sse([("text", "LEAD-TURN-ENDED")]),
    _sse([("text", "LEAD-SAW-TEAMMATE")]),
]
TEAMMATE_TURN = _sse([("text", "TEAMMATE-REPLY")])


def _from_teammate(messages):
    return bool(messages) and MARK in json.dumps(messages[0])


class _Providers:
    def __init__(self):
        self.lead = []
        self.teammate = []
        self.lock = threading.Lock()

    def __enter__(self):
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(404)
                self.end_headers()

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))))
                seen = {"path": self.path, "model": body.get("model"), "thinking": body.get("thinking"),
                        "output_config": body.get("output_config")}
                with outer.lock:
                    if _from_teammate(body.get("messages", [])):
                        outer.teammate.append(seen)
                        reply = TEAMMATE_TURN
                    else:
                        outer.lead.append(seen)
                        reply = LEAD_TURNS[min(len(outer.lead), len(LEAD_TURNS)) - 1]
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
    def origin(self):
        return "http://127.0.0.1:%d" % self._server.server_address[1]

    def __exit__(self, *exc):
        self._server.shutdown()
        self._server.server_close()


def _provider(letter, origin):
    return {"display_name": "Prov " + letter.upper(), "credential_kinds": ["api_key"],
            "env_aliases": [{"name": "PROV_%s_TOKEN" % letter.upper(), "kind": "api_key", "canonical": True}],
            "channels": [{"id": "primary", "base_url": "%s/%s" % (origin, letter), "protocol": "anthropic_messages"}],
            "models": [{"request_model_id": letter + "-model", "display_name": letter.upper() + " model"}]}


def _workspace(origin, global_default):
    home = case_tmpdir("cc-tty-teammate-route-home-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state, exist_ok=True)
    config = {
        "custom_providers": {"prov-%s" % letter: _provider(letter, origin) for letter in "abc"},
        "presets": {"a": {"target": {"kind": "auto_route", "selector": "a-model"},
                          "controls": {"reasoning_effort": {"text": "high"}}},
                    "b": {"target": {"kind": "auto_route", "selector": "b-model"}},
                    "c": {"target": {"kind": "auto_route", "selector": "c-model"}}},
    }
    if not global_default:
        config["global_default"] = False
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump(config, f)
    with open(os.path.join(state, ".env"), "w") as f:
        f.write("METACODES_PRESET=c\n")
    project = case_tmpdir("cc-tty-teammate-route-project-")
    subprocess.run(["git", "init", "-q", project], check=True)
    with open(os.path.join(project, "README"), "w") as f:
        f.write("route\n")
    subprocess.run(["git", "-C", project, "add", "README"], check=True)
    subprocess.run(["git", "-C", project, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                    "commit", "-q", "-m", "init"], check=True)
    env = {"HOME": home, "PROV_A_TOKEN": "sk-a", "PROV_B_TOKEN": "sk-b", "PROV_C_TOKEN": "sk-c", "METACODES_JEV_URL": "off"}
    return env, project


def _run_team(bin_path, global_default, before=()):
    if os.name == "nt":
        raise SkipTest("process teammates are POSIX-only")
    with _Providers() as providers:
        env, project = _workspace(providers.origin, global_default)
        run(bin_path, [READY] + list(before) + ["type:go", "key:enter", wait_for("LEAD-TURN-ENDED", 30), "sleep:0.5",
                                                wait_for("LEAD-SAW-TEAMMATE", 30), "sleep:0.5"],
            term_size=(ROWS, COLS), env=env, base_url=None, cwd=project, per_key_drain=0.05,
            extra_args=["--preset", "a", "--teammate-mode", "process"])
        return list(providers.lead), list(providers.teammate)


def _assert_teammate_on_the_leads_route(lead, teammate, letter):
    assert lead, "the lead sent nothing"
    assert all(seen["path"] == "/%s/v1/messages" % letter and seen["model"] == letter + "-model" for seen in lead), lead
    assert teammate, "the process teammate sent no request"
    for seen in teammate:
        assert seen["path"] == "/%s/v1/messages" % letter, "the teammate went to another provider: %r" % seen
        assert seen["model"] == letter + "-model", "the teammate asked for another model: %r" % seen
        assert seen["thinking"] == lead[0]["thinking"] and seen["output_config"] == lead[0]["output_config"], (
            "the teammate's reasoning differs from the lead's: %r vs %r" % (seen, lead[0]))


def test_a_process_teammate_runs_on_the_route_the_lead_was_started_on(bin_path):
    lead, teammate = _run_team(bin_path, global_default=True)
    _assert_teammate_on_the_leads_route(lead, teammate, "a")


def test_a_process_teammate_starts_on_the_leads_route_when_global_default_is_off(bin_path):
    lead, teammate = _run_team(bin_path, global_default=False)
    _assert_teammate_on_the_leads_route(lead, teammate, "a")


def test_a_process_teammate_follows_the_route_the_lead_moved_to_with_model(bin_path):
    lead, teammate = _run_team(bin_path, global_default=True,
                               before=["type:/model use b-model", "key:enter", wait_for("switched to", 10), "sleep:0.5"])
    _assert_teammate_on_the_leads_route(lead, teammate, "b")
