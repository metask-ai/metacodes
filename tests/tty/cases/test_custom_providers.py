"""A provider of one's own (a relay, a local server), at a terminal.

`metacodes providers add` with no arguments asks for each part; with
`--probe` at a terminal it takes the pasted key, asks the endpoint which
models it serves and lets the user pick. `/login <id>` and
`metacodes login --provider <id>` take a pasted key for it with no page to
open, check it at the endpoint's model listing, and store it in the
provider's own key file. A local mock stands in for the relay; nothing goes
anywhere else. The non-terminal paths are covered by
tests/component/custom_providers_cli_test.zig.
"""
import http.server
import json
import os
import select
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


class _Relay(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        self.server.seen.append((self.path, self.headers.get("authorization")))
        if not self.path.startswith("/v1/models"):
            self.send_error(404)
            return
        ok = self.headers.get("authorization") == f"Bearer {GOOD_KEY}"
        body = json.dumps(MODELS if ok else {"error": {"message": "invalid key"}}).encode("utf-8")
        self.send_response(200 if ok else 401)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)


class _Case:
    """A scratch HOME (state root ~/.metacodes) and the relay mock."""

    def __enter__(self):
        self.home = case_tmpdir("cc-tty-custom-")
        self.state = os.path.join(self.home, ".metacodes")
        os.makedirs(self.state, exist_ok=True)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Relay)
        self.server.seen = []
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

    def env(self):
        env = {k: v for k, v in os.environ.items() if not k.endswith("_API_KEY")}
        env.update({"HOME": self.home, "METACODES_KG_AUTOSTART": "0", "METACODES_JEV_URL": "off",
                    "METACODES_NO_PROBE": "1", "BROWSER": "true"})
        for name in ("METACODES_HOME", "METACODES_CONFIG_FILE", "METACODES_KEY_CHECK_URL", "METACODES_PROVIDER", "CODEX_HOME"):
            env.pop(name, None)
        return env


def _cli(bin_path, args, env, answers, timeout=WAIT_S):
    """Run `metacodes <args>` on a pty; answer each (prompt, reply) in turn."""
    import pty  # POSIX only

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.clear()
        os.environ.update(env)
        os.execv(bin_path, [bin_path] + args)
    out = b""
    pending = list(answers)
    deadline = time.monotonic() + timeout
    status = None
    while time.monotonic() < deadline:
        if pending and pending[0][0].encode() in out:
            os.write(fd, pending.pop(0)[1].encode())
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            break
    else:
        os.kill(pid, 9)
    if status is None or not os.WIFEXITED(status):
        _, status = os.waitpid(pid, 0)
    while True:
        r, _, _ = select.select([fd], [], [], 0.5)
        if not r:
            break
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.close(fd)
    return os.waitstatus_to_exitcode(status), out


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
