"""An MCP tool asks before it runs in the TUI (#473).

The server is the test mock (its `echo` tool has no annotations) behind a
shell loop that appends each line it is sent to a log before passing it on,
so a case reads what the server received. In `default` mode the model's call
to `mcp__plc__echo` opens the permission dialog, which names the tool. `n`
refuses it: the server receives no `tools/call` and the model reads the
user's refusal. `y` runs it: the server receives the call and the echo comes
back to the model.
"""
import json
import os

from tty_driver import READY, case_tmpdir, run, wait_for
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, slow_text_then_end, slow_text_then_tooluse
from e2e_helpers import SkipTest

ZIG_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
MOCK_MCP = os.path.join(ZIG_ROOT, "zig-out", "bin", "mock_mcp_server")
TOOL = "mcp__plc__echo"
MESSAGE = "set line 3 to 900 rpm"
# Logs every line the client sends ($1) before handing it to the server ($2).
WIRE_LOGGER = """while IFS= read -r line; do
  printf '%s\\n' "$line" >> "$1"
  printf '%s\\n' "$line"
done | "$2"
"""


def _home():
    """A HOME whose config.json names the `plc` server: the mock behind
    WIRE_LOGGER, which logs to `plc-wire.log`."""
    if os.name == "nt":
        raise SkipTest("the server runs behind a /bin/sh logger")
    if not os.access(MOCK_MCP, os.X_OK):
        raise SkipTest("no mock_mcp_server (zig build test:harness first)")
    home = case_tmpdir("cc-tty-mcp-perm-home-")
    os.makedirs(os.path.join(home, ".metacodes"), exist_ok=True)
    wire = os.path.join(home, "plc-wire.log")
    logger = os.path.join(home, "plc-wire.sh")
    with open(logger, "w") as f:
        f.write(WIRE_LOGGER)
    with open(os.path.join(home, ".metacodes", "config.json"), "w") as f:
        json.dump({"mcpServers": {"plc": {"command": "/bin/sh", "args": [logger, wire, MOCK_MCP]}}}, f)
    return home, wire


def _calls(wire):
    try:
        with open(wire) as f:
            return f.read().count('"tools/call"')
    except FileNotFoundError:
        return 0


def _tool_result(request_body):
    for message in json.loads(request_body)["messages"]:
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if block.get("type") == "tool_result" and block.get("tool_use_id") == "t1":
                    return block
    return None


def _result_text(result):
    content = result.get("content")
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return str(content)


def _answer(bin_path, key):
    """One MCP call in default mode whose dialog gets `key`: the screens, the
    tool_result the next request carried (None if there was none) and the
    number of `tools/call` the server received."""
    home, wire = _home()
    turns = [
        slow_text_then_tooluse(n_chunks=1, delay=0.1, tool=TOOL, tool_input=json.dumps({"message": MESSAGE})),
        slow_text_then_end(n_chunks=1, delay=0.1),
    ]
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for("Permission required", 20), "strictsleep:0.5",
             f"type:{key}", "sleep:2.0"],
            env={"HOME": home, "METACODES_JEV_URL": "off"},
            base_url=srv.url,
            permission="default",
            cwd=case_tmpdir("cc-tty-mcp-perm-project-"),
            term_size=(24, 100),
            startup_drain=0.8,
            per_key_drain=0.05,
        )
        requests = list(srv.requests)
    a = TTYAssert(raw, rows=24, cols=100)
    if not a.screens_with("Permission required"):
        a._fail("an MCP tool call in default mode should open the permission dialog")
    if not any(sc.find_row(TOOL) is not None for sc in a.screens_with("Permission required")):
        a._fail(f"the permission dialog should name the tool ({TOOL})")
    result = _tool_result(requests[1]) if len(requests) >= 2 else None
    if result is None:
        a._fail("the dialog never answered: no tool_result reached the model")
    return a, result, _calls(wire)


def test_mcp_tool_call_opens_the_permission_dialog_and_n_refuses_it(bin_path):
    a, result, calls = _answer(bin_path, "n")
    if calls != 0:
        a._fail(f"n refused the call, yet the server received {calls} tools/call")
    text = _result_text(result)
    if not result.get("is_error") or "declined" not in text:
        a._fail(f"n should reach the model as the user's refusal: {text!r}")


def test_mcp_tool_call_runs_after_y(bin_path):
    a, result, calls = _answer(bin_path, "y")
    if calls != 1:
        a._fail(f"y should run the call once; the server received {calls} tools/call")
    text = _result_text(result)
    if result.get("is_error") or MESSAGE not in text:
        a._fail(f"y should return the server's echo to the model: {text!r}")
