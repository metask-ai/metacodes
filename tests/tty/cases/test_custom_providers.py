"""A provider of one's own (a relay, a local server), at a terminal.

`metacodes providers add` with no arguments asks for each part; with
`--probe` at a terminal it takes the pasted key, asks the endpoint which
models it serves and lets the user pick. `/login <id>` and
`metacodes login --provider <id>` take a pasted key for it with no page to
open, check it at the endpoint's model listing, and store it in the
provider's own key file. A server that needs no key gets the placeholder
`none` in its place, so it starts. A local mock stands in for the relay;
nothing goes anywhere else. The non-terminal paths are covered by
tests/component/custom_providers_cli_test.zig.

`_cli`, which runs the CLI on a pty here, is checked on its own against
small Python children: the exit code it reports is the child's, also when
the pty closes before the child exits, and a child still running at the
deadline fails the call.
"""
import http.server
import json
import os
import re
import select
import signal
import stat
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import IS_WINDOWS, READY, WAIT_S, case_tmpdir, run, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402

GOOD_KEY = "sk-relay-7c1e93"
MODELS = {"object": "list", "data": [
    {"id": "glm-4.6", "max_input_tokens": 200000, "max_tokens": 128000},
    {"id": "kimi-k2", "name": "Kimi K2"},
    {"id": "qwen3-coder-plus"},
]}
CHAT_SSE = (
    'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"KEYLESS_REPLY"},"finish_reason":null}]}\n\n'
    'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n'
    'data: [DONE]\n\n'
).encode()


class _Relay(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        self.server.seen.append((self.path, self.headers.get("authorization")))
        if not self.path.startswith("/v1/models"):
            self.send_error(404)
            return
        # A server that needs no key (Ollama) answers whatever comes.
        ok = self.server.keyless or self.headers.get("authorization") == f"Bearer {GOOD_KEY}"
        body = json.dumps(MODELS if ok else {"error": {"message": "invalid key"}}).encode("utf-8")
        self.send_response(200 if ok else 401)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length") or 0)
        self.rfile.read(length)
        self.server.seen.append((self.path, self.headers.get("authorization")))
        if not (self.server.keyless and self.path.startswith("/v1/chat/completions")):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(CHAT_SSE)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(CHAT_SSE)


class _Case:
    """A scratch HOME (state root ~/.metacodes) and the relay mock."""

    def __enter__(self):
        self.home = case_tmpdir("cc-tty-custom-")
        self.state = os.path.join(self.home, ".metacodes")
        os.makedirs(self.state, exist_ok=True)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Relay)
        self.server.seen = []
        self.server.keyless = False
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    def base(self):
        return f"http://127.0.0.1:{self.server.server_port}/v1"

    def define(self):
        """The relay, written as `providers add` writes it."""
        with open(os.path.join(self.state, "config.json"), "w") as f:
            json.dump({"custom_providers": {"relay": {
                "display_name": "House relay",
                "channels": [{"id": "openai", "base_url": self.base(), "protocol": "openai_chat"}],
                "models": [{"request_model_id": "glm-4.6"}],
            }}}, f)

    def definition(self):
        with open(os.path.join(self.state, "config.json")) as f:
            return json.load(f)["custom_providers"]["relay"]

    def checks(self):
        return [auth for path, auth in self.server.seen if path.startswith("/v1/models")]

    def assert_stored(self, key):
        path = os.path.join(self.state, "keys", "relay.json")
        assert os.path.exists(path), f"no key file at {path}"
        with open(path) as f:
            document = json.load(f)
        assert document["key"] == key and document["kind"] == "api_key", document.get("kind")
        assert "page" not in document, "a pasted key names no page"
        if not IS_WINDOWS:
            mode = stat.S_IMODE(os.stat(path).st_mode)
            assert mode == 0o600, f"key file mode {oct(mode)}, expected 0o600"
        with open(os.path.join(self.state, "config.json")) as f:
            assert key not in f.read(), "the key leaked into config.json"

    def assert_placeholder_stored(self):
        """The key file holds the placeholder a server that needs no key gets."""
        path = os.path.join(self.state, "keys", "relay.json")
        assert os.path.exists(path), f"no key file at {path}"
        with open(path) as f:
            document = json.load(f)
        assert document["key"] == "none" and document["kind"] == "api_key", document
        assert "page" not in document, "the placeholder names no page"

    def chats(self):
        return [auth for path, auth in self.server.seen if path.startswith("/v1/chat/completions")]

    def env(self):
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update({"HOME": self.home, "METACODES_KG_AUTOSTART": "0", "METACODES_JEV_URL": "off",
                    "METACODES_NO_PROBE": "1", "BROWSER": "true"})
        for name in ("METACODES_HOME", "METACODES_CONFIG_FILE", "METACODES_KEY_CHECK_URL", "METACODES_PROVIDER", "CODEX_HOME"):
            env.pop(name, None)
        return env


def _cli(bin_path, args, env, answers, timeout=WAIT_S):
    """Run `metacodes <args>` on a pty; answer each (prompt, reply) in turn.

    Returns (exit code, output). The exit code is the child's own: it comes
    only from a waitpid that returned this child's pid (a WNOHANG waitpid on
    a running child returns pid 0 and status 0, which reads as "exited 0").
    EOF on the pty says only that the output closed; the child is still
    reaped in the time left. One still running at the deadline is killed and
    reaped, and the call fails: a timeout is never an exit code.
    """
    import pty  # POSIX only

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.clear()
        os.environ.update(env)
        os.execv(bin_path, [bin_path] + args)
    out = b""
    pending = list(answers)
    deadline = time.monotonic() + timeout
    status = None  # set only once the child is reaped
    killed = False
    output_open = True
    try:
        while True:
            reaped, raw = os.waitpid(pid, os.WNOHANG)
            if reaped == pid:
                status = raw
                break
            if time.monotonic() >= deadline:
                os.kill(pid, signal.SIGKILL)
                killed = True
                _, status = os.waitpid(pid, 0)
                break
            if not output_open:
                time.sleep(0.05)
                continue
            if pending and pending[0][0].encode() in out:
                os.write(fd, pending.pop(0)[1].encode())
            chunk = _read_pty(fd, 0.1)
            if chunk:
                out += chunk
            elif chunk == b"":
                output_open = False
        # Reaped; on Linux its last lines can still be in the pty buffer.
        while output_open:
            chunk = _read_pty(fd, 0.5)
            if not chunk:
                break
            out += chunk
    finally:
        if status is None:  # an error above: leave nothing running
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            except OSError:
                pass
        os.close(fd)
    if killed:
        raise AssertionError(f"still running after {timeout}s, killed: {args}\n{out.decode('utf-8', 'replace')}")
    return os.waitstatus_to_exitcode(status), out


def _read_pty(fd, wait):
    """What the pty has within `wait` seconds: None if nothing came, b"" at EOF."""
    r, _, _ = select.select([fd], [], [], wait)
    if not r:
        return None
    try:
        return os.read(fd, 4096)
    except OSError:  # Linux: EIO once the child's side is closed
        return b""


def test_add_asks_for_each_part_then_probes_and_stores_the_pasted_key(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI prompts are driven over a POSIX pty here")
    with _Case() as case:
        code, out = _cli(os.path.abspath(bin_path), ["--state-dir", case.state, "providers", "add"], case.env(), [
            ("Id (lowercase, e.g. my-relay): ", "relay\r"),
            ("Display name (Enter: relay): ", "House relay\r"),
            ("Base URL (https://", case.base() + "\r"),
            ("Choose (several: 1,3): ", "1\r"),
            ("Choose [1-3]: ", "1\r"),
            ("Paste the API key (it is not shown) and press Enter: ", GOOD_KEY + "\r"),
            ("Ask the endpoint which models it serves? [Y/n]: ", "\r"),
            ("Add which?", "1,3\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "glm-4.6" in text and "Kimi K2" in text, text
        assert "Added relay in " in text and "This takes effect at the next start" in text, text
        assert GOOD_KEY not in text, "the pasted key was echoed to the terminal"
        # One probe, with the key pasted once.
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        relay = case.definition()
        assert relay["display_name"] == "House relay", relay
        assert [m["request_model_id"] for m in relay["models"]] == ["glm-4.6", "qwen3-coder-plus"], relay["models"]
        assert relay["models"][0]["limits"] == {"context_window": 200000, "max_output_tokens": 128000}, relay["models"][0]
        case.assert_stored(GOOD_KEY)


def test_add_with_probe_at_a_terminal_takes_the_key_and_the_pick(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI prompts are driven over a POSIX pty here")
    with _Case() as case:
        code, out = _cli(os.path.abspath(bin_path), [
            "--state-dir", case.state, "providers", "add", "relay",
            "--base-url", case.base(), "--protocol", "openai_chat", "--probe",
        ], case.env(), [
            ("Enter if it needs none): ", GOOD_KEY + "\r"),
            ("Add which?", "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert GOOD_KEY not in text, "the pasted key was echoed to the terminal"
        # Enter takes every listed model.
        assert [m["request_model_id"] for m in case.definition()["models"]] == ["glm-4.6", "kimi-k2", "qwen3-coder-plus"]
        case.assert_stored(GOOD_KEY)


def test_add_for_a_server_that_needs_no_key_stores_the_placeholder_and_the_provider_starts(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI prompts are driven over a POSIX pty here")
    with _Case() as case:
        case.server.keyless = True
        code, out = _cli(os.path.abspath(bin_path), ["--state-dir", case.state, "providers", "add"], case.env(), [
            ("Id (lowercase, e.g. my-relay): ", "relay\r"),
            ("Display name (Enter: relay): ", "House relay\r"),
            ("Base URL (https://", case.base() + "\r"),
            ("Choose (several: 1,3): ", "1\r"),
            ("Choose [1-3]: ", "3\r"),
            ("Ask the endpoint which models it serves? [Y/n]: ", "\r"),
            ("Add which?", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "Stored the placeholder `none` as its key" in text, text
        assert "It has no key yet" not in text, text
        # The probe sent the placeholder the way every request will.
        assert case.checks() == ["Bearer none"], case.checks()
        case.assert_placeholder_stored()
        # And a start on it runs: with no key it stopped at
        # "Authentication required for provider 'relay'".
        code, out = _cli(os.path.abspath(bin_path), [
            "--state-dir", case.state, "--provider", "relay", "--model", "glm-4.6", "-p", "hi",
        ], case.env(), [])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "KEYLESS_REPLY" in text, text
        assert case.chats() == ["Bearer none"], case.server.seen


def test_enter_at_the_probe_key_prompt_sends_and_stores_the_placeholder(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI prompts are driven over a POSIX pty here")
    with _Case() as case:
        case.server.keyless = True
        code, out = _cli(os.path.abspath(bin_path), [
            "--state-dir", case.state, "providers", "add", "relay",
            "--base-url", case.base(), "--protocol", "openai_chat", "--probe",
        ], case.env(), [
            ("Enter if it needs none): ", "\r"),
            ("Add which?", "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "the placeholder `none` stands in for one" in text, text
        assert case.checks() == ["Bearer none"], case.checks()
        case.assert_placeholder_stored()


def test_a_relay_that_wants_a_key_refuses_the_placeholder_and_nothing_is_written(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI prompts are driven over a POSIX pty here")
    with _Case() as case:
        code, out = _cli(os.path.abspath(bin_path), [
            "--state-dir", case.state, "providers", "add", "relay",
            "--base-url", case.base(), "--protocol", "openai_chat", "--probe",
        ], case.env(), [
            ("Enter if it needs none): ", "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 1, f"exit {code}:\n{text}"
        assert "it wants a real key (it refused the placeholder `none`); nothing was written" in text, text
        assert case.checks() == ["Bearer none"], case.checks()
        assert not os.path.exists(os.path.join(case.state, "keys", "relay.json")), "a refused placeholder was stored"
        config = os.path.join(case.state, "config.json")
        if os.path.exists(config):
            with open(config) as f:
                assert "relay" not in json.load(f).get("custom_providers", {}), "a refused add wrote its definition"


def test_cli_login_takes_a_pasted_key_for_a_provider_of_ones_own(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI paste prompt is driven over a POSIX pty here")
    with _Case() as case:
        case.define()
        code, out = _cli(os.path.abspath(bin_path), ["--state-dir", case.state, "login", "--provider", "relay"], case.env(), [
            ("Paste the API key for House relay (it is not shown) and press Enter: ", GOOD_KEY + "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        # No page to open: the key comes from whoever runs the relay.
        assert "Open this page" not in text and "Create an API key" not in text, text
        assert "Stored the key for House relay." in text, text
        assert GOOD_KEY not in text, "the pasted key was echoed to the terminal"
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        case.assert_stored(GOOD_KEY)


def test_login_dialog_goes_straight_to_the_paste_for_a_provider_of_ones_own(bin_path):
    with _Case() as case:
        case.define()
        events = [READY, "type:/login relay", "key:enter",
                  wait_for("Paste the API key for House relay:", 10),
                  f"type:{GOOD_KEY}", wait_for(f"({len(GOOD_KEY)} characters)", 10),
                  "key:enter", wait_for("Stored the key for House relay", WAIT_S)]
        raw = run(bin_path, events, term_size=(30, 120), env=case.env(), per_key_drain=0.05,
                  extra_args=["--state-dir", case.state])
        a = TTYAssert(raw, rows=30, cols=120)
        a.assert_prose_contains("Stored the key for House relay · /model to choose a model")
        if a.screens_with("Which plan is the key for?"):
            a._fail("a provider of one's own has no plan page to choose")
        assert GOOD_KEY.encode() not in raw, "the pasted key was echoed to the terminal"
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        case.assert_stored(GOOD_KEY)


# ── _cli itself: the exit code it reports is the child's ─────────────────────
# Small Python children stand in for metacodes, so these need no binary.

def _python(code):
    """`_cli`'s first three arguments for a Python child that runs `code`."""
    return sys.executable, ["-I", "-c", code], {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}


def _helper_pid(data):
    found = re.search(rb"helper-pid (\d+)", data)
    assert found, f"the child did not print its pid: {data!r}"
    return int(found.group(1))


def test_cli_helper_reports_an_exit_0_with_the_whole_output(bin_path):
    if IS_WINDOWS:
        raise SkipTest("_cli drives a POSIX pty")
    code, out = _cli(*_python("print('helper says ok')"), [])
    assert code == 0, f"exit {code}: {out!r}"
    assert b"helper says ok" in out, out


def test_cli_helper_reports_a_nonzero_exit_that_comes_after_the_last_line(bin_path):
    # What the refused placeholder case does: the last line, then the exit a
    # moment later, with the pty's EOF ahead of any waitpid that sees it.
    if IS_WINDOWS:
        raise SkipTest("_cli drives a POSIX pty")
    code, out = _cli(*_python("import sys, time\nprint('helper fails', flush=True)\ntime.sleep(0.3)\nsys.exit(7)"), [])
    assert code == 7, f"exit {code}: {out!r}"
    assert b"helper fails" in out, out


def test_cli_helper_reaps_a_child_that_outlives_its_pty(bin_path):
    # EOF says only that the output closed: the child runs on and its exit
    # decides the code.
    if IS_WINDOWS:
        raise SkipTest("_cli drives a POSIX pty")
    code, out = _cli(*_python(
        "import os, time\n"
        "print('closing the pty', flush=True)\n"
        "time.sleep(0.3)\n"
        "for fd in (0, 1, 2):\n"
        "    os.close(fd)\n"
        "time.sleep(1.0)\n"
        "os._exit(3)\n"), [])
    assert code == 3, f"exit {code}: {out!r}"
    assert b"closing the pty" in out, out


def test_cli_helper_fails_a_child_still_running_at_the_deadline_and_reaps_it(bin_path):
    if IS_WINDOWS:
        raise SkipTest("_cli drives a POSIX pty")
    started = time.monotonic()
    try:
        code, out = _cli(*_python("import os, time\nprint('helper-pid', os.getpid(), flush=True)\ntime.sleep(60)"), [], timeout=2.0)
    except AssertionError as failure:
        message = str(failure)
    else:
        try:
            os.waitpid(_helper_pid(out), 0)
        except (AssertionError, OSError):
            pass
        raise AssertionError(f"a child still running at the deadline came back as exit {code}: {out!r}")
    assert time.monotonic() - started < 10, "the deadline did not end the wait"
    assert "still running after 2.0s, killed" in message, message
    # Killed and reaped: nothing is left of it, not even a zombie.
    try:
        left = os.waitpid(_helper_pid(message.encode()), os.WNOHANG)
    except ChildProcessError:
        left = None
    assert left is None, f"the killed child was not reaped: waitpid gave {left}"
