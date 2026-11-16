"""`/login` and `/logout` switch between the Metask account and local configuration (#485).

- `/login` alone runs the Metask browser sign-in (`metacodes login`'s flow): the
  browser comes back to the loopback callback, then the API key, model and
  reasoning level are chosen in the pane. The sign-in is stored in `auth.json`,
  the session moves onto it at once, and the next start uses it. Esc stores
  and changes nothing.
- `/logout` removes both Metask sign-ins and moves the session to the provider
  `.env` configures, or to none; nothing is sent with the old credential again.

Everything runs against loopback stand-ins (`metask_mock.py`, a relay mock for
the `.env` provider): no account, no real request.
"""
import hashlib
import http.server
import json
import os
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty_driver import IS_WINDOWS, READY, case_tmpdir, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402
from metask_mock import KEY_SECRET, MODEL, MetaskMock, ACCESS_TOKEN, REFRESH_TOKEN  # noqa: E402
from test_unbound import KEY_VARIABLES  # noqa: E402
from test_key_login import _cli  # noqa: E402

RELAY_KEY = "sk-relay-tty-env-0001"

# Windows opens the browser with `cmd /c start` and never reads $BROWSER
# (`auth.openBrowser`), so the stub that plays the browser never runs there,
# and a sign-in that needs it waits until the case times out.
_NO_BROWSER_STUB = "Windows opens the browser with `cmd /c start`, not $BROWSER: the stub cannot play the browser"


class _Relay:
    """An OpenAI-wire provider defined in config.json, answering one text turn."""

    def __enter__(self):
        outer = self
        self.requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D401
                return

            def do_POST(self):  # noqa: N802
                length = int(self.headers.get("content-length", 0))
                body = json.loads(self.rfile.read(length) or b"{}")
                outer.requests.append((self.path, self.headers.get("authorization"), body.get("model")))
                chunks = (
                    'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"RELAY_REPLY"},"finish_reason":null}]}\n\n'
                    'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n'
                    'data: [DONE]\n\n'
                ).encode()
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.send_header("content-length", str(len(chunks)))
                self.send_header("connection", "close")
                self.end_headers()
                self.wfile.write(chunks)

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self._server.shutdown()
        self._server.server_close()

    def config(self):
        origin = f"http://127.0.0.1:{self._server.server_address[1]}"
        return {"custom_providers": {"house-relay": {
            "display_name": "House relay",
            "credential_kinds": ["api_key"],
            "env_aliases": [{"name": "HOUSE_RELAY_TOKEN", "kind": "api_key", "canonical": True}],
            "channels": [{"id": "primary", "base_url": f"{origin}/relay/v1", "protocol": "openai_chat"}],
            "models": [{"request_model_id": "relay-model", "display_name": "Relay model"}],
        }}}


def _case(mock, extra=None):
    home = case_tmpdir("cc-tty-login-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state, exist_ok=True)
    env = {name: None for name in KEY_VARIABLES}
    env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off", "HOUSE_RELAY_TOKEN": None})
    env.update(mock.env(home))
    env.update(extra or {})
    return home, state, env


def _write_signed_in(state, model=MODEL, effort="low"):
    """The auth.json `metacodes login` leaves: sign-in, key, model, effort."""
    path = os.path.join(state, "auth.json")
    with open(path, "w") as f:
        json.dump({"api_key": KEY_SECRET,
                   "oauth": {"access_token": ACCESS_TOKEN, "refresh_token": REFRESH_TOKEN,
                             "token_type": "Bearer", "expires_at": int(time.time()) + 86400},
                   "selected_model": model, "reasoning_effort": effort}, f)
    os.chmod(path, 0o600)


def _screen(a):
    return "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_login_signs_in_in_the_browser_and_the_session_and_next_start_use_it(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-login-work-")
        raw = run(bin_path, [
            READY,
            "type:/login",
            "key:enter",
            wait_for("Select an API key", 20),
            "key:enter",
            wait_for("Select a model", 15),
            "key:enter",
            wait_for("Select a reasoning level", 10),
            "key:enter",
            wait_for("Signed in to Metask", 10),
        ] + submit("hi", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert "Signed in to Metask · glm-5 · reasoning low · key \"dev key\"" in screen, screen
        # The browser was sent to the authorize URL, and came back with a code.
        with open(mock.browser_log) as f:
            assert f.read().startswith(f"{mock.origin}/oauth/authorize?"), "the browser should open the authorize URL"
        paths = [path for _, path, _ in mock.requests]
        assert any(p.startswith("/oauth/token") for p in paths), paths
        assert any(p.startswith("/api/v1/keys") for p in paths), paths
        # The session moved onto the sign-in at once: the turn went out with
        # the chosen key and model.
        assert mock.messages == [(f"Bearer {KEY_SECRET}", MODEL)], mock.messages
        # Stored as `metacodes login` stores it, readable by the owner only.
        auth = os.path.join(state, "auth.json")
        with open(auth) as f:
            stored = json.load(f)
        assert stored["api_key"] == KEY_SECRET and stored["selected_model"] == MODEL
        assert stored["reasoning_effort"] == "low" and stored["oauth"]["refresh_token"] == REFRESH_TOKEN
        assert os.stat(auth).st_mode & 0o077 == 0
        # No secret reached the terminal.
        for secret in (KEY_SECRET, ACCESS_TOKEN, REFRESH_TOKEN):
            assert secret.encode() not in raw, f"{secret} reached the terminal"

        # The next plain start is on Metask, with that sign-in.
        raw2 = run(bin_path, submit("hello", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        b = TTYAssert(raw2, rows=30, cols=140)
        b.assert_prose_contains("glm-5 · Metask")
        assert mock.messages[-1] == (f"Bearer {KEY_SECRET}", MODEL), mock.messages


def _metask_offer_id(model, endpoint="https://napi.metask-ai.com/v1/messages"):
    """The offer id of the compiled Metask route for `model` (src/provider/ids.zig
    `OfferId.derive`): what `/model` stores when it is chosen for every session."""
    digest = hashlib.sha256(b"metacodes.offer.v1")
    for field in ("metask", "default", "anthropic_messages", endpoint, model, ""):
        raw = field.encode()
        digest.update(struct.pack("<I", len(raw)))
        digest.update(raw)
    return "offer-" + digest.digest()[:16].hex()


def test_a_browser_sign_in_serves_a_stored_metask_default_at_the_next_start(bin_path):
    # Sign in in the browser, keep a Metask model as the default (what /model's
    # "every future session" writes), start again: the start is on that
    # default, authenticated by the browser sign-in. It used to look only for
    # the device-code sign-in and stop with `Metask session is unavailable`.
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-default-work-")
        run(bin_path, [
            READY, "type:/login", "key:enter",
            wait_for("Select an API key", 20), "key:enter",
            wait_for("Select a model", 15), "key:enter",
            wait_for("Select a reasoning level", 10), "key:enter",
            wait_for("Signed in to Metask", 10),
        ], env=env, base_url=None, cwd=work, term_size=(30, 140))
        assert os.path.exists(os.path.join(state, "auth.json"))
        config = os.path.join(state, "config.json")
        with open(config, "w") as f:
            json.dump({"global_selection": {
                "target": {"kind": "pinned_offer", "offer_id": _metask_offer_id("claude-sonnet-4-6"), "offer_revision": 1},
                "scope": "global"}}, f)
        before = len(mock.requests)
        # Nothing is typed: the stored route is Metask's own endpoint, and the
        # startup probe stays off (METACODES_NO_PROBE), so nothing is sent.
        raw = run(bin_path, [READY, "strictsleep:0.5"], env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        a.assert_prose_contains("claude-sonnet-4-6 · Metask")
        a.assert_box_present()
        for refused in (b"Metask session is unavailable", b"has no key or sign-in", b"not set"):
            assert refused not in raw, f"{refused!r} on the start:\n{_screen(a)}"
        assert len(mock.requests) == before


def test_cli_login_in_the_browser_forgets_a_stored_default(bin_path):
    # `metacodes login` is the most recent explicit choice, as /login is: a
    # stored /model default, which would outrank the sign-in at the next
    # start, is forgotten, and the run says so.
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        config = os.path.join(state, "config.json")
        with open(config, "w") as f:
            json.dump({"global_selection": {
                "target": {"kind": "pinned_offer", "offer_id": _metask_offer_id("claude-sonnet-4-6"), "offer_revision": 1},
                "scope": "global"}}, f)
        cli_env = {k: v for k, v in os.environ.items() if k not in KEY_VARIABLES}
        for name, value in env.items():
            if value is None:
                cli_env.pop(name, None)
            else:
                cli_env[name] = value
        # The model list is read from the mock; nothing else starts.
        cli_env.pop("METACODES_NO_PROBE", None)
        cli_env.update({"METACODES_KG_AUTOSTART": "0", "TERM": "xterm-256color"})
        code, out = _cli(os.path.abspath(bin_path), ["login"], cli_env, [
            ("Select API key", "1\r"),
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "Successfully logged in with Metask OAuth." in text, text
        assert "Forgot the stored default model: new sessions start on Metask." in text, text
        with open(config) as f:
            assert json.load(f).get("global_selection") is None
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f)["api_key"] == KEY_SECRET
        for secret in (KEY_SECRET, ACCESS_TOKEN, REFRESH_TOKEN):
            assert secret.encode() not in out, f"{secret} reached the terminal"


def test_login_cancelled_with_esc_changes_nothing(bin_path):
    # The browser never comes back (BROWSER=true opens nothing): Esc ends the wait.
    with MetaskMock() as mock:
        home, state, env = _case(mock, {"BROWSER": "true"})
        raw = run(bin_path, [
            READY,
            "type:/login",
            "key:enter",
            wait_for("Open this URL", 15),
            "key:esc",
            wait_for("nothing was changed", 10),
        ] + submit("hi", "No model is set up"), env=env, base_url=None, term_size=(30, 140))
        # The authorize URL is longer than a row: the terminal wraps it.
        a = TTYAssert(raw, rows=30, cols=140, autowrap=True)
        echo = a.final.find_row("❯ /login")
        if echo is None:
            a._fail("the /login echo is missing")
        a.assert_line_contains(echo + 1, "⎿  Login interrupted · nothing was changed")
        # While it waited, the pane said what a machine without a browser does.
        assert b"No browser on this machine? /login metask signs in with a short code instead." in raw
        assert not os.path.exists(os.path.join(state, "auth.json"))
        assert mock.messages == []
        assert not any(p.startswith("/oauth/token") for _, p, _ in mock.requests)


def test_login_on_an_account_without_keys_says_where_to_make_one(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock(keys=[]) as mock:
        home, state, env = _case(mock, {"METASK_SITE_URL": "http://127.0.0.1:9/site"})
        raw = run(bin_path, [
            READY,
            "type:/login",
            "key:enter",
            wait_for("has no API key yet", 20),
            "key:esc",
            wait_for("nothing was changed", 10),
        ], env=env, base_url=None, term_size=(30, 140))
        assert b"http://127.0.0.1:9/site" in raw
        assert not os.path.exists(os.path.join(state, "auth.json"))


def test_logout_switches_to_the_env_provider_and_never_uses_the_sign_in_again(bin_path):
    with MetaskMock() as mock, _Relay() as relay:
        home, state, env = _case(mock)
        _write_signed_in(state)
        with open(os.path.join(state, "config.json"), "w") as f:
            json.dump(relay.config(), f)
        with open(os.path.join(state, ".env"), "w") as f:
            f.write(f"HOUSE_RELAY_TOKEN={RELAY_KEY}\nMETACODES_PROVIDER=house-relay\n")
        os.makedirs(os.path.join(state, "oauth"), exist_ok=True)
        device = os.path.join(state, "oauth", "metask.json")
        with open(device, "w") as f:
            f.write("{}")
        work = case_tmpdir("cc-tty-logout-work-")
        raw = run(bin_path, submit("hi", "METASK_MOCK_REPLY") + submit("/logout", "Switched to House relay (from .env)")
                  + submit("again", "RELAY_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert "Signed out of Metask: removed the browser sign-in and the device-code sign-in." in screen, screen
        assert "Switched to House relay (from .env) · relay-model\n" in screen + "\n", screen
        # Started on Metask (the sign-in outranks .env), and said why the
        # file's provider is not in use (第七节第 3 条); one turn there ...
        a.assert_prose_contains("glm-5 · Metask")
        a.assert_prose_contains(".env configures House relay; the default is Metask. To use House relay: /model, or /logout")
        assert mock.messages == [(f"Bearer {KEY_SECRET}", MODEL)], mock.messages
        # ... and after /logout the turn went to the .env provider, with its key.
        assert relay.requests == [("/relay/v1/chat/completions", f"Bearer {RELAY_KEY}", "relay-model")], relay.requests
        assert not os.path.exists(os.path.join(state, "auth.json"))
        assert not os.path.exists(device)
        # The next plain start is on the .env provider, with nothing to explain.
        raw2 = run(bin_path, [READY, "strictsleep:0.3"], env=env, base_url=None, cwd=work, term_size=(30, 140))
        TTYAssert(raw2, rows=30, cols=140).assert_prose_contains("relay-model · from .env")
        assert b".env configures" not in raw2
        assert len(mock.messages) == 1, mock.messages


def test_logout_with_nothing_to_fall_back_to_leaves_the_session_unbound(bin_path):
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        _write_signed_in(state)
        raw = run(bin_path, submit("/logout", "No model is set up now") + [
            READY, "type:hi", "key:enter", wait_for("you signed out of Metask", 10),
        ], env=env, base_url=None, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        assert "you signed out of Metask" in _screen(a)
        assert mock.messages == [], mock.messages
        assert not os.path.exists(os.path.join(state, "auth.json"))


def test_a_named_provider_without_a_key_opens_unbound_and_names_the_variable(bin_path):
    # `--provider deepseek` and no DeepSeek key: the TUI does not quietly take
    # the Metask sign-in that is there; it says what DeepSeek needs.
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        _write_signed_in(state)
        raw = run(bin_path, [READY, "type:hi", "key:enter", wait_for("DeepSeek has no key", 10)],
                  env=env, base_url=None, extra_args=["--provider", "deepseek"], term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        a.assert_prose_contains("not set — /login, or configure .env")
        assert "DEEPSEEK_API_KEY" in screen, screen
        assert mock.messages == [], mock.messages
