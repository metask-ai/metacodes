"""`/login` and `/logout` switch between the Metask account and local configuration (#485, #527).

- `/login` alone runs the Metask browser sign-in (`metacodes login`'s flow) as
  the client `metacodes`: the browser comes back to the loopback callback,
  then the model and reasoning level are chosen in the pane, from the
  `/v1/models` of the gateway the token response names. The sign-in is stored
  as the Metask session (`oauth/metask.json`), its choice in `auth.json`; the
  session moves onto it at once, and the next start uses it. Esc stores and
  changes nothing.
- `/login metask` and `metacodes login --provider metask` are the same with
  the device code: the code is confirmed elsewhere, then the model and
  reasoning level are chosen (at a terminal, for the CLI).
- `/logout` revokes the session at Metask, removes both Metask sign-ins and
  moves the session to the provider `.env` configures, or to none; nothing is
  sent with the old credential again.

Everything runs against loopback stand-ins (`metask_mock.py`, a relay mock for
the `.env` provider): no account, no real request.
"""
import hashlib
import http.client
import http.server
import json
import os
import re
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty_driver import IS_WINDOWS, READY, case_tmpdir, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402
from metask_mock import (  # noqa: E402
    ACCOUNT_NAME, DEFAULT_MODELS, DEVICE_CODE, KEY_SECRET, MODEL, USER_CODE, MetaskMock, ACCESS_TOKEN, REFRESH_TOKEN,
    session_tokens,
)
from test_unbound import KEY_VARIABLES  # noqa: E402
from test_key_login import _cli  # noqa: E402

RELAY_KEY = "sk-relay-tty-env-0001"

# Windows opens the browser through rundll32 and never reads $BROWSER
# (`auth.openBrowser`), so the stub that plays the browser never runs there,
# and a sign-in that needs it waits until the case times out.
_NO_BROWSER_STUB = "Windows opens the browser through rundll32, not $BROWSER: the stub cannot play the browser"


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
    env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off", "HOUSE_RELAY_TOKEN": None,
                "SSH_CONNECTION": None, "SSH_TTY": None, "METACODES_LOGIN_CALLBACK_TIMEOUT_MS": None})
    env.update(mock.env(home))
    env.update(extra or {})
    return home, state, env


def _write_signed_in(state, model=MODEL, effort="low"):
    """The auth.json an older `metacodes login` left (before #527): sign-in,
    key, model, effort. Its key route needs the mock's `key_route_env()`."""
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
            wait_for("Select a model", 20),
            "key:enter",
            wait_for("Select a reasoning level", 10),
            "key:enter",
            wait_for("Signed in to Metask", 10),
        ] + submit("hi", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert f"Signed in to Metask as {ACCOUNT_NAME} · glm-5 · reasoning low" in screen, screen
        # No API key to choose, and the gateway's image-only model is not offered.
        assert b"Select an API key" not in raw
        assert b"image-model-only" not in raw
        # The browser was sent to the authorize URL as the `metacodes` client,
        # asking for model access, back on its registered path.
        with open(mock.browser_log) as f:
            opened = f.read()
        assert opened.startswith(f"{mock.origin}/oauth/authorize?"), opened
        for part in ("client_id=metacodes", "%2Fauth%2Fmetask%2Fcallback", "scope=read%20model%3Ainvoke"):
            assert part in opened, f"{part} not in {opened}"
        paths = [path for _, path, _ in mock.requests]
        assert any(p.startswith("/api/oauth/token") for p in paths), paths
        assert not any(p.startswith("/api/v1/keys") for p in paths), paths
        # The models were listed at the gateway with the sign-in's own token.
        assert ("GET", "/v1/models", f"Bearer {ACCESS_TOKEN}") in mock.requests, mock.requests
        # Who signed in was asked with the same token.
        assert ("GET", "/api/oauth/userinfo", f"Bearer {ACCESS_TOKEN}") in mock.requests, mock.requests
        # The session moved onto the sign-in at once: the turn went out with
        # the session's token and the chosen model.
        assert mock.messages == [(f"Bearer {ACCESS_TOKEN}", MODEL)], mock.messages
        # Stored as `metacodes login` stores it, readable by the owner only:
        # the session (naming its gateway), and the choice in auth.json.
        session = os.path.join(state, "oauth", "metask.json")
        with open(session) as f:
            stored_session = json.load(f)
        assert stored_session["gateway_url"] == mock.origin and stored_session["refresh_token"] == REFRESH_TOKEN
        assert os.stat(session).st_mode & 0o077 == 0
        auth = os.path.join(state, "auth.json")
        with open(auth) as f:
            assert json.load(f) == {"selected_model": MODEL, "reasoning_effort": "low"}
        assert os.stat(auth).st_mode & 0o077 == 0
        # No secret reached the terminal.
        for secret in (ACCESS_TOKEN, REFRESH_TOKEN):
            assert secret.encode() not in raw, f"{secret} reached the terminal"

        # The next plain start is on Metask, with that session.
        raw2 = run(bin_path, submit("hello", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        b = TTYAssert(raw2, rows=30, cols=140)
        b.assert_prose_contains("glm-5 · Metask")
        assert mock.messages[-1] == (f"Bearer {ACCESS_TOKEN}", MODEL), mock.messages


def _metask_offer_id(model, endpoint="https://napi.metask-ai.com/v1/messages"):
    """The offer id of the compiled Metask route for `model` (packages/ai/src/provider/ids.zig
    `OfferId.derive`): what `/model` stores when it is chosen for every session."""
    digest = hashlib.sha256(b"metacodes.offer.v1")
    for field in ("metask", "default", "anthropic_messages", endpoint, model, ""):
        raw = field.encode()
        digest.update(struct.pack("<I", len(raw)))
        digest.update(raw)
    return "offer-" + digest.digest()[:16].hex()


def test_login_ends_without_the_account_name_when_userinfo_does_not_answer(bin_path):
    # Who signed in is only said: a userinfo that never answers costs the name
    # after a bounded wait, not the sign-in.
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock(userinfo_stalls=True) as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-login-work-")
        raw = run(bin_path, [
            READY,
            "type:/login",
            "key:enter",
            # Well under the mock's hold (60 s): only a bounded wait gets here.
            wait_for("Select a model", 15),
            "key:enter",
            wait_for("Select a reasoning level", 10),
            "key:enter",
            wait_for("Signed in to Metask", 10),
        ], env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert "Signed in to Metask · glm-5 · reasoning low" in screen, screen
        assert ("GET", "/api/oauth/userinfo", f"Bearer {ACCESS_TOKEN}") in mock.requests, mock.requests
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))


def test_a_browser_sign_in_serves_a_stored_metask_default_at_the_next_start(bin_path):
    # Sign in in the browser, keep a Metask model as the default (what /model's
    # "every future session" writes), start again: the start is on that
    # default, authenticated by the session, at the session's gateway (#527):
    # never at the compiled endpoint with the session's token.
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    models = DEFAULT_MODELS + [{"id": "claude-sonnet-4-6",
                                "capabilities": {"endpoints": {"messages": {"supported": True}}}}]
    with MetaskMock(models=models) as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-default-work-")
        run(bin_path, [
            READY, "type:/login", "key:enter",
            wait_for("Select a model", 20), "key:enter",
            wait_for("Select a reasoning level", 10), "key:enter",
            wait_for("Signed in to Metask", 10),
        ], env=env, base_url=None, cwd=work, term_size=(30, 140))
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))
        config = os.path.join(state, "config.json")
        with open(config, "w") as f:
            json.dump({"global_selection": {
                "target": {"kind": "pinned_offer", "offer_id": _metask_offer_id("claude-sonnet-4-6"), "offer_revision": 1},
                "scope": "global"}}, f)
        raw = run(bin_path, submit("hello", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        a.assert_prose_contains("claude-sonnet-4-6 · Metask")
        for refused in (b"Metask session is unavailable", b"has no key or sign-in", b"not set"):
            assert refused not in raw, f"{refused!r} on the start:\n{_screen(a)}"
        # The turn reached the session's gateway, with its token.
        assert mock.messages[-1] == (f"Bearer {ACCESS_TOKEN}", "claude-sonnet-4-6"), mock.messages


def _pin_gateway_model(mock, state, model="glm-5-air"):
    offer = _metask_offer_id(model, endpoint=f"{mock.origin}/v1/messages")
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump({"global_selection": {
            "target": {"kind": "pinned_offer", "offer_id": offer, "offer_revision": 1},
            "scope": "global"}}, f)
    return offer


def test_a_stored_default_on_a_gateway_model_starts_the_tui_on_the_metask_sign_in(bin_path):
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        mock.write_session(state)
        offer = _pin_gateway_model(mock, state)
        work = case_tmpdir("cc-tty-unfound-default-work-")
        raw = run(bin_path, submit("hello", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 220))
        a = TTYAssert(raw, rows=30, cols=220)
        a.assert_prose_contains(f"The default model stored with /model (offer {offer}) cannot be found right now, "
                                f"so this session started on your Metask sign-in: {MODEL} · Metask. Choose again with /model.")
        assert b"which the current catalog does not offer" not in raw, _screen(a)
        assert mock.messages == [(f"Bearer {ACCESS_TOKEN}", MODEL)], mock.messages
        with open(os.path.join(state, "config.json")) as f:
            assert json.load(f)["global_selection"]["target"]["offer_id"] == offer


def test_a_stored_default_on_a_gateway_model_still_stops_the_tui_without_a_metask_sign_in(bin_path):
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        offer = _pin_gateway_model(mock, state)
        work = case_tmpdir("cc-tty-unfound-default-work-")
        raw = run(bin_path, ["sleep:3"], env=env, base_url=None, cwd=work, term_size=(30, 220))
        a = TTYAssert(raw, rows=30, cols=220)
        a.assert_prose_contains(f"error: the stored selection pins offer {offer}, which the current catalog does not offer")
        assert b"cannot be found right now" not in raw, _screen(a)
        assert mock.messages == [], mock.messages


def test_cli_login_in_the_browser_forgets_a_stored_default(bin_path):
    # `metacodes login` is the most recent explicit choice, as /login is: a
    # stored /model default, which would outrank the sign-in at the next
    # start, is forgotten, and the run says so. It stores what /login stores.
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
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert f"Signed in to Metask in the browser as {ACCOUNT_NAME}. Model glm-5, reasoning low." in text, text
        # The gateway's levels, not its all-false `effort` block; and no `none`
        # for a model whose reasoning cannot be turned off.
        assert "1. low" in text and "2. high" in text and ". none" not in text, text
        assert "Select API key" not in text, text
        assert "image-model-only" not in text, text
        assert "Forgot the stored default model: new sessions start on Metask." in text, text
        with open(config) as f:
            assert json.load(f).get("global_selection") is None
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": MODEL, "reasoning_effort": "low"}
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))
        for secret in (KEY_SECRET, ACCESS_TOKEN, REFRESH_TOKEN):
            assert secret.encode() not in out, f"{secret} reached the terminal"


def _cli_env(env):
    """The CLI's environment for a case: this process's, without provider keys,
    with the case's overrides (None removes a variable)."""
    cli_env = {k: v for k, v in os.environ.items() if k not in KEY_VARIABLES}
    for name, value in env.items():
        if value is None:
            cli_env.pop(name, None)
        else:
            cli_env[name] = value
    # The model list is read from the mock; nothing else starts.
    cli_env.pop("METACODES_NO_PROBE", None)
    cli_env.update({"METACODES_KG_AUTOSTART": "0", "TERM": "xterm-256color"})
    return cli_env


def _expect_device_request(mock):
    """One device code was asked for, as the `metacodes` client, with model access."""
    assert len(mock.device_requests) == 1, mock.device_requests
    assert json.loads(mock.device_requests[0]) == {"client_id": "metacodes", "scope": "read model:invoke"}, mock.device_requests


def test_login_metask_signs_in_with_the_device_code_then_chooses_a_model(bin_path):
    # `/login metask` (#527): the code is confirmed elsewhere, then the model and
    # reasoning level are chosen in the pane as after the browser sign-in. Without
    # them the next start would run the compiled default, which the gateway does
    # not serve.
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-login-work-")
        raw = run(bin_path, [
            READY,
            "type:/login metask --no-browser",
            "key:enter",
            wait_for("Select a model", 20),
            "key:enter",
            wait_for("Select a reasoning level", 10),
            "key:enter",
            wait_for("Signed in to Metask", 10),
        ] + submit("hi", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert f"Signed in to Metask as {ACCOUNT_NAME} · glm-5 · reasoning low" in screen, screen
        # The pane showed the code to confirm, and no browser hint.
        assert f"enter the code {USER_CODE}".encode() in raw, raw[-2000:]
        assert b"No browser on this machine?" not in raw
        assert b"Select an API key" not in raw
        assert b"image-model-only" not in raw
        _expect_device_request(mock)
        assert ("POST", "/api/oauth/token", None) in mock.requests, mock.requests
        assert ("GET", "/v1/models", f"Bearer {ACCESS_TOKEN}") in mock.requests, mock.requests
        # The session moved onto the sign-in at once.
        assert mock.messages == [(f"Bearer {ACCESS_TOKEN}", MODEL)], mock.messages
        with open(os.path.join(state, "oauth", "metask.json")) as f:
            assert json.load(f)["gateway_url"] == mock.origin
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": MODEL, "reasoning_effort": "low"}
        for secret in (ACCESS_TOKEN, REFRESH_TOKEN, DEVICE_CODE):
            assert secret.encode() not in raw, f"{secret} reached the terminal"

        # The next plain start runs the chosen model on that session.
        raw2 = run(bin_path, submit("hello", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        TTYAssert(raw2, rows=30, cols=140).assert_prose_contains("glm-5 · Metask")
        assert mock.messages[-1] == (f"Bearer {ACCESS_TOKEN}", MODEL), mock.messages


def test_cli_device_login_at_a_terminal_asks_for_the_model(bin_path):
    # `metacodes login --provider metask` (#527) asks for the model and reasoning
    # level at a terminal, as `metacodes login` does, and stores what it stores.
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        code, out = _cli(os.path.abspath(bin_path), ["login", "--provider", "metask", "--no-browser"], _cli_env(env), [
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert f"METASK_USER_CODE={USER_CODE}" in text, text
        assert f"Signed in to Metask with the device code as {ACCOUNT_NAME}. Model glm-5, reasoning low." in text, text
        assert "image-model-only" not in text, text
        _expect_device_request(mock)
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": MODEL, "reasoning_effort": "low"}
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))
        for secret in (ACCESS_TOKEN, REFRESH_TOKEN, DEVICE_CODE):
            assert secret.encode() not in out, f"{secret} reached the terminal"


def test_cli_device_login_without_a_terminal_stores_the_session_and_says_no_model_was_chosen(bin_path):
    # A script confirms the code elsewhere (the device-code e2e does): nothing
    # can be asked, so only the session is stored, as before, and the run says
    # how a start gets its model.
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        proc = subprocess.run([os.path.abspath(bin_path), "login", "--provider", "metask", "--no-browser"],
                              stdin=subprocess.DEVNULL, capture_output=True, env=_cli_env(env), timeout=60)
        err = proc.stderr.decode("utf-8", "replace")
        assert proc.returncode == 0, f"exit {proc.returncode}:\n{err}"
        assert "Stored Metask OAuth session. No secret was printed." in err, err
        assert "No model was chosen (not at a terminal): start with --model <id>, or choose one with /model." in err, err
        _expect_device_request(mock)
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))
        assert not os.path.exists(os.path.join(state, "auth.json"))
        for secret in (ACCESS_TOKEN, REFRESH_TOKEN, DEVICE_CODE):
            assert secret.encode() not in proc.stdout + proc.stderr, f"{secret} reached the output"


_GATEWAY_EFFORT_BLOCK = DEFAULT_MODELS[0]["capabilities"]["effort"]
_SWITCHED_THINKING = {"reasoning": {"supported": True, "disable": {"supported": True}, "translated": True},
                      "thinking": {"types": {"enabled": {"supported": True}, "adaptive": {"supported": False}},
                                   "supported": True}}
_SWITCHED_MODELS = [
    {"id": "kimi-k3.1-pro", "max_input_tokens": 1048576, "max_tokens": 1048576,
     "capabilities": dict({"endpoints": {"messages": {"supported": True, "status": "supported"}},
                           "effort": _GATEWAY_EFFORT_BLOCK}, **_SWITCHED_THINKING)},
    {"id": "glm-5-air", "max_input_tokens": 128000, "max_tokens": 16000,
     "capabilities": {"endpoints": {"messages": {"supported": True, "status": "supported"}},
                      "effort": _GATEWAY_EFFORT_BLOCK}},
]


def test_cli_login_offers_off_and_on_where_the_gateway_names_no_level_and_the_first_message_goes_out(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock(models=_SWITCHED_MODELS) as mock:
        home, state, env = _case(mock)
        code, out = _cli(os.path.abspath(bin_path), ["login", "--provider", "metask", "--no-browser"], _cli_env(env), [
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "2\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "1. off" in text and "2. on" in text and ". none" not in text, text
        assert f"Signed in to Metask with the device code as {ACCOUNT_NAME}. Model kimi-k3.1-pro, reasoning on." in text, text
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": "kimi-k3.1-pro", "reasoning_effort": "high"}

        work = case_tmpdir("cc-tty-login-work-")
        proc = subprocess.run([os.path.abspath(bin_path), "-p", "hello"], stdin=subprocess.DEVNULL,
                              capture_output=True, env=_cli_env(env), cwd=work, timeout=60)
        said = (proc.stdout + proc.stderr).decode("utf-8", "replace")
        assert proc.returncode == 0, f"exit {proc.returncode}:\n{said}"
        assert "context blocking limit" not in said, said
        assert "METASK_MOCK_REPLY" in said, said
        request = mock.message_bodies[-1]
        sent = {k: request.get(k) for k in ("model", "max_tokens", "thinking", "output_config")}
        assert sent == {"model": "kimi-k3.1-pro", "max_tokens": 524288, "thinking": {"type": "enabled"},
                        "output_config": None}, sent


def test_cli_login_does_not_ask_for_a_reasoning_effort_a_model_has_one_choice_of(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock(models=_SWITCHED_MODELS) as mock:
        home, state, env = _case(mock)
        code, out = _cli(os.path.abspath(bin_path), ["login", "--provider", "metask", "--no-browser"], _cli_env(env), [
            ("Select model:", "2\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "Select reasoning effort:" not in text, text
        assert "Reasoning effort: none (the only choice glm-5-air offers)" in text, text
        assert f"Signed in to Metask with the device code as {ACCOUNT_NAME}. Model glm-5-air, reasoning none." in text, text
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": "glm-5-air", "reasoning_effort": "none"}


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
        assert not os.path.exists(os.path.join(state, "oauth", "metask.json"))
        assert mock.messages == []
        assert not any("/oauth/token" in p for _, p, _ in mock.requests)


# `/login` in the TUI, through the model and reasoning level.
_TUI_SIGN_IN = [
    "type:/login", "key:enter",
    wait_for("Select a model", 20), "key:enter",
    wait_for("Select a reasoning level", 10), "key:enter",
]


def _revocation_of(pair):
    """What the revocation of the session with these (access, refresh) tokens sends."""
    return f"token={pair[1]}&token_type_hint=refresh_token&client_id=metacodes"


def _sign_in_transcript(screen):
    lines = [line.strip() for line in screen.splitlines() if line.strip()]
    return lines[lines.index("❯ /login"):lines.index("❯ hi")]


def _stored_refresh_token(state):
    with open(os.path.join(state, "oauth", "metask.json")) as f:
        return json.load(f)["refresh_token"]


def test_signing_in_again_revokes_the_session_it_replaced_once_each_time(bin_path):
    # #560: a sign-in that replaces the stored Metask session revokes that
    # one at Metask once the new one is stored and bound, as /logout would;
    # left alone it would stay valid there with nothing here that could end
    # it. Twice with /login, once with `metacodes login`, once with the
    # device code. Each sign-in is its own authorization (`distinct_sessions`).
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock(distinct_sessions=True) as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-relogin-work-")
        first, second, third, fourth = (session_tokens(n) for n in range(1, 5))
        raw = run(bin_path, [READY] + _TUI_SIGN_IN + [wait_for("Signed in to Metask", 10)]
                  + [READY] + _TUI_SIGN_IN + [wait_for("Metask revoked the previous sign-in.", 15)]
                  + submit("hi", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(40, 140))
        screen = _screen(TTYAssert(raw, rows=40, cols=140, autowrap=True))
        # The first /login replaced nothing; the second revoked the first, once,
        # after its own token response, and said so.
        assert mock.revocations == [_revocation_of(first)], mock.revocations
        assert screen.count("Metask revoked the previous sign-in.") == 1, screen
        paths = [path for _, path, _ in mock.requests]
        grants = [i for i, path in enumerate(paths) if path.startswith("/api/oauth/token")]
        assert len(grants) == 2 and paths.index("/api/oauth/revoke") > grants[1], paths
        # The session went on with the second sign-in.
        assert mock.messages == [(f"Bearer {second[0]}", MODEL)], mock.messages
        assert _stored_refresh_token(state) == second[1]

        # `metacodes login` replaces the second ...
        code, out = _cli(os.path.abspath(bin_path), ["login"], _cli_env(env), [
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert text.count("Metask revoked the previous sign-in.") == 1, text
        assert mock.revocations == [_revocation_of(first), _revocation_of(second)], mock.revocations
        assert _stored_refresh_token(state) == third[1]

        # ... and the device code the third.
        code, device_out = _cli(os.path.abspath(bin_path), ["login", "--provider", "metask", "--no-browser"], _cli_env(env), [
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = device_out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert text.count("Metask revoked the previous sign-in.") == 1, text
        assert mock.revocations == [_revocation_of(pair) for pair in (first, second, third)], mock.revocations
        assert _stored_refresh_token(state) == fourth[1]
        for secret in [token for pair in (first, second, third, fourth) for token in pair]:
            assert secret.encode() not in raw + out + device_out, f"{secret} reached the terminal"


def test_a_revocation_refused_or_not_answered_leaves_the_login_done_and_says_so(bin_path):
    # #560: revoking the replaced session is best effort and bounded: a refusal
    # or no answer within the wait never fails the sign-in, and the line says
    # what stays valid, in /logout's words.
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock(distinct_sessions=True, revoke_answers=[500, None]) as mock:
        home, state, env = _case(mock)
        work = case_tmpdir("cc-tty-relogin-work-")
        first, second, third = (session_tokens(n) for n in range(1, 4))
        raw = run(bin_path, [READY] + _TUI_SIGN_IN + [wait_for("Signed in to Metask", 10)]
                  + [READY] + _TUI_SIGN_IN + [wait_for("could not revoke the previous sign-in", 15)]
                  # The TUI waits 3 seconds for the answer that never comes.
                  + [READY] + _TUI_SIGN_IN + [wait_for("did not answer the revocation", 20)]
                  + submit("hi", "METASK_MOCK_REPLY"), env=env, base_url=None, cwd=work, term_size=(40, 140))
        screen = _screen(TTYAssert(raw, rows=40, cols=140, autowrap=True))
        signed_in = "⎿  Signed in to Metask as Mock User · glm-5 · reasoning low"
        assert _sign_in_transcript(screen) == [
            "❯ /login", signed_in, "New sessions start on Metask too.",
            "❯ /login", signed_in,
            "Metask could not revoke the previous sign-in; it stays valid there until it expires.",
            "New sessions start on Metask too.",
            "❯ /login", signed_in,
            "Metask did not answer the revocation of the previous sign-in in time; "
            "it may stay valid there until it expires.",
            "New sessions start on Metask too.",
        ], screen
        assert mock.revocations == [_revocation_of(first), _revocation_of(second)], mock.revocations
        # Both sign-ins stood: the session went on with the third.
        assert mock.messages == [(f"Bearer {third[0]}", MODEL)], mock.messages
        assert _stored_refresh_token(state) == third[1]


def test_a_login_cancelled_with_esc_revokes_nothing_and_keeps_the_stored_session(bin_path):
    # #560: nothing is revoked before the new session is stored and bound. Esc
    # stores nothing, so the session that was there stays, unrevoked and in use.
    with MetaskMock() as mock:
        home, state, env = _case(mock, {"BROWSER": "true"})
        session = mock.write_session(state)
        with open(session) as f:
            before = f.read()
        raw = run(bin_path, [
            READY,
            "type:/login",
            "key:enter",
            wait_for("Open this URL", 15),
            "key:esc",
            wait_for("nothing was changed", 10),
        ] + submit("hi", "METASK_MOCK_REPLY"), env=env, base_url=None, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140, autowrap=True)
        assert "Login interrupted · nothing was changed" in _screen(a)
        assert mock.revocations == [], mock.revocations
        with open(session) as f:
            assert f.read() == before
        assert mock.messages == [(f"Bearer {ACCESS_TOKEN}", MODEL)], mock.messages


def test_login_with_no_chat_model_says_so_and_stores_nothing(bin_path):
    # The gateway lists only models it does not serve on /v1/messages: the
    # sign-in has nothing to run a session on, says so, and stores nothing.
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock(models=[DEFAULT_MODELS[2]]) as mock:
        home, state, env = _case(mock)
        raw = run(bin_path, [
            READY,
            "type:/login",
            "key:enter",
            wait_for("no model this account can chat with", 20),
            "key:esc",
            wait_for("nothing was changed", 10),
        ], env=env, base_url=None, term_size=(30, 140))
        assert b"Sign-in failed: no model this account can chat with" in raw
        assert not os.path.exists(os.path.join(state, "auth.json"))
        assert not os.path.exists(os.path.join(state, "oauth", "metask.json"))


def test_logout_switches_to_the_env_provider_and_never_uses_the_sign_in_again(bin_path):
    with MetaskMock() as mock, _Relay() as relay:
        home, state, env = _case(mock)
        session = mock.write_session(state)
        with open(os.path.join(state, "config.json"), "w") as f:
            json.dump(relay.config(), f)
        with open(os.path.join(state, ".env"), "w") as f:
            f.write(f"HOUSE_RELAY_TOKEN={RELAY_KEY}\nMETACODES_PROVIDER=house-relay\n")
        work = case_tmpdir("cc-tty-logout-work-")
        raw = run(bin_path, submit("hi", "METASK_MOCK_REPLY") + submit("/logout", "Switched to House relay (from .env)")
                  + submit("again", "RELAY_REPLY"), env=env, base_url=None, cwd=work, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        assert "Signed out of Metask: removed the sign-in." in screen, screen
        assert "Metask revoked it too." in screen, screen
        assert "Switched to House relay (from .env) · relay-model\n" in screen + "\n", screen
        # Started on Metask (the session outranks .env), and said why the
        # file's provider is not in use (第七节第 3 条); one turn there ...
        a.assert_prose_contains("glm-5 · Metask")
        a.assert_prose_contains(".env configures House relay; the default is Metask. To use House relay: /model, or /logout")
        assert mock.messages == [(f"Bearer {ACCESS_TOKEN}", MODEL)], mock.messages
        # ... the session revoked at Metask, as the metacodes client ...
        assert mock.revocations == [f"token={REFRESH_TOKEN}&token_type_hint=refresh_token&client_id=metacodes"], mock.revocations
        # ... and after /logout the turn went to the .env provider, with its key.
        assert relay.requests == [("/relay/v1/chat/completions", f"Bearer {RELAY_KEY}", "relay-model")], relay.requests
        assert not os.path.exists(os.path.join(state, "auth.json"))
        assert not os.path.exists(session)
        # The next plain start is on the .env provider, with nothing to explain.
        raw2 = run(bin_path, [READY, "strictsleep:0.3"], env=env, base_url=None, cwd=work, term_size=(30, 140))
        TTYAssert(raw2, rows=30, cols=140).assert_prose_contains("relay-model · from .env")
        assert b".env configures" not in raw2
        assert len(mock.messages) == 1, mock.messages


def test_logout_with_nothing_to_fall_back_to_leaves_the_session_unbound(bin_path):
    # On an older sign-in's key (auth.json, before #527): /logout removes it;
    # there is no session to revoke.
    with MetaskMock() as mock:
        home, state, env = _case(mock, mock.key_route_env())
        _write_signed_in(state)
        raw = run(bin_path, submit("/logout", "No model is set up now") + [
            READY, "type:hi", "key:enter", wait_for("you signed out of Metask", 10),
        ], env=env, base_url=None, term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        assert "you signed out of Metask" in _screen(a)
        assert "Signed out of Metask: removed the browser sign-in." in _screen(a)
        assert mock.messages == [], mock.messages
        assert mock.revocations == [], mock.revocations
        assert not os.path.exists(os.path.join(state, "auth.json"))


def test_a_named_provider_without_a_key_opens_unbound_and_names_the_variable(bin_path):
    # `--provider deepseek` and no DeepSeek key: the TUI does not quietly take
    # the Metask sign-in that is there; it says what DeepSeek needs.
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        mock.write_session(state)
        raw = run(bin_path, [READY, "type:hi", "key:enter", wait_for("DeepSeek has no key", 10)],
                  env=env, base_url=None, extra_args=["--provider", "deepseek"], term_size=(30, 140))
        a = TTYAssert(raw, rows=30, cols=140)
        screen = _screen(a)
        a.assert_prose_contains("not set — /login, or configure .env")
        assert "DEEPSEEK_API_KEY" in screen, screen
        assert mock.messages == [], mock.messages


_SSH = {"SSH_CONNECTION": "192.0.2.10 50022 192.0.2.20 22", "SSH_TTY": "/dev/pts/7"}
_SSH_LINE = "This looks like an SSH session: sign in on another device instead."
_CODE_WAY = "❯ 2. Sign in with a code on another device (SSH, no browser here)"
_PASTE_LINE = "paste that page's address here and press Enter."
_CLI_SSH_LINE = "This looks like an SSH session: signing in with a code you confirm on any device. (--no-browser keeps the browser sign-in.)"


def _plain(raw):
    return re.sub(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\r", "",
                  raw.decode("utf-8", "replace"))


def _forward_line(text):
    found = re.search(r"Starting local login server on http://localhost:(\d+)\.", text)
    assert found, text[-2000:]
    port = found.group(1)
    return f"Over SSH? Forward the port first: ssh -L {port}:127.0.0.1:{port} <you>@<this machine>"


def _recorder(home):
    log = os.path.join(home, "browser-recorded.txt")
    stub = os.path.join(home, "browser-recorder")
    with open(stub, "w") as f:
        f.write(f"#!/bin/sh\nprintf '%s\\n' \"$1\" >> '{log}'\n")
    os.chmod(stub, 0o755)
    return stub, log


def _final_address(authorize_url, state=None):
    import urllib.parse
    query = urllib.parse.parse_qs(urllib.parse.urlparse(authorize_url).query)
    back = {"code": "tty-code-0001", "state": state or query["state"][0]}
    return query["redirect_uri"][0] + "?" + urllib.parse.urlencode(back)


def _recorded(log, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(log):
            with open(log) as f:
                lines = [line.strip() for line in f if line.strip()]
            if lines:
                return lines[-1]
        time.sleep(0.05)
    raise AssertionError("the browser was never handed the sign-in address")


def test_login_over_ssh_asks_which_way_and_signs_in_with_the_code_by_default(bin_path):
    with MetaskMock() as mock:
        home, state, env = _case(mock, _SSH)
        work = case_tmpdir("cc-tty-login-work-")
        raw = run(bin_path, [
            READY, "type:/login", "key:enter",
            wait_for("Sign in with a code on another device", 15), "key:enter",
            wait_for("Select a model", 20), "key:enter",
            wait_for("Select a reasoning level", 10), "key:enter",
            wait_for("Signed in to Metask", 10),
        ], env=env, base_url=None, cwd=work, term_size=(30, 160))
        a = TTYAssert(raw, rows=30, cols=160)
        if not a.screens_with(_CODE_WAY):
            a._fail("over SSH the pane should offer the code first")
        if not a.screens_with(_SSH_LINE):
            a._fail("the pane should say why it offers the code first")
        assert f"Signed in to Metask as {ACCOUNT_NAME} · glm-5 · reasoning low" in _screen(a), _screen(a)
        _expect_device_request(mock)
        assert not os.path.exists(mock.browser_log), "no browser may be opened over SSH"
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))


def test_login_no_browser_over_ssh_keeps_the_browser_sign_in_and_names_the_forward(bin_path):
    with MetaskMock() as mock:
        home, state, env = _case(mock, _SSH)
        work = case_tmpdir("cc-tty-login-work-")
        raw = run(bin_path, [
            READY, "type:/login --no-browser", "key:enter",
            wait_for("Over SSH?", 15), "sleep:0.5",
            "key:esc", wait_for("Login interrupted", 10),
        ], env=env, base_url=None, cwd=work, term_size=(30, 200))
        text = _plain(raw)
        assert _forward_line(text) in text, text[-2000:]
        assert _PASTE_LINE in text, text[-2000:]
        assert "Sign in with a code on another device" not in text, text[-2000:]
        assert mock.device_requests == [], mock.device_requests
        assert not os.path.exists(mock.browser_log)


def test_login_takes_the_address_a_browser_on_another_computer_ended_on(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        stub, log = _recorder(home)
        env["BROWSER"] = stub
        work = case_tmpdir("cc-tty-login-work-")

        def events():
            yield READY
            yield "type:/login"
            yield "key:enter"
            yield wait_for(_PASTE_LINE, 15)
            authorize = _recorded(log)
            yield "raw:\x1b[200~" + _final_address(authorize, state="from-another-sign-in") + "\x1b[201~"
            yield "key:enter"
            yield wait_for("That address is from another sign-in.", 10)
            yield "raw:\x1b[200~" + _final_address(authorize) + "\x1b[201~"
            yield "key:enter"
            yield wait_for("Select a model", 20)
            yield "key:enter"
            yield wait_for("Select a reasoning level", 10)
            yield "key:enter"
            yield wait_for("Signed in to Metask", 10)

        raw = run(bin_path, events(), env=env, base_url=None, cwd=work, term_size=(30, 200), per_key_drain=0.05)
        a = TTYAssert(raw, rows=30, cols=200)
        if not a.screens_with("That address is from another sign-in."):
            a._fail("an address from another sign-in should be refused in the pane")
        assert f"Signed in to Metask as {ACCOUNT_NAME} · glm-5 · reasoning low" in _screen(a), _screen(a)
        tokens = [path for _, path, _ in mock.requests if path.startswith("/api/oauth/token")]
        assert len(tokens) == 1, mock.requests
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))
        assert b"tty-code-0001" not in raw, "the pane should not show the pasted code"


def test_login_over_ssh_the_browser_way_opens_the_browser_here_and_names_the_forward(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock() as mock:
        home, state, env = _case(mock, _SSH)
        stub, log = _recorder(home)
        env["BROWSER"] = stub
        work = case_tmpdir("cc-tty-login-work-")

        def events():
            yield READY
            yield "type:/login"
            yield "key:enter"
            yield wait_for("Sign in with a code on another device", 15)
            yield "key:up"
            yield "key:enter"
            yield wait_for(_PASTE_LINE, 15)
            yield "raw:\x1b[200~" + _final_address(_recorded(log)) + "\x1b[201~"
            yield "key:enter"
            yield wait_for("Select a model", 20)
            yield "key:enter"
            yield wait_for("Select a reasoning level", 10)
            yield "key:enter"
            yield wait_for("Signed in to Metask", 10)

        raw = run(bin_path, events(), env=env, base_url=None, cwd=work, term_size=(30, 200), per_key_drain=0.05)
        text = _plain(raw)
        assert _forward_line(text) in text, text[-2000:]
        a = TTYAssert(raw, rows=30, cols=200)
        assert f"Signed in to Metask as {ACCOUNT_NAME} · glm-5 · reasoning low" in _screen(a), _screen(a)
        assert mock.device_requests == [], mock.device_requests
        assert os.path.exists(os.path.join(state, "oauth", "metask.json"))


def test_cli_login_takes_the_address_a_browser_on_another_computer_ended_on(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        stub, log = _recorder(home)
        env["BROWSER"] = stub
        code, out = _cli(os.path.abspath(bin_path), ["login"], _cli_env(env), [
            (_PASTE_LINE, lambda _: _final_address(_recorded(log), state="from-another-sign-in") + "\r"),
            ("That address is from another sign-in.", lambda _: _final_address(_recorded(log)) + "\r"),
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert f"Signed in to Metask in the browser as {ACCOUNT_NAME}. Model glm-5, reasoning low." in text, text
        tokens = [path for _, path, _ in mock.requests if path.startswith("/api/oauth/token")]
        assert len(tokens) == 1, mock.requests
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": MODEL, "reasoning_effort": "low"}


def test_cli_login_over_ssh_signs_in_with_the_device_code_and_says_why(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock, _SSH)
        code, out = _cli(os.path.abspath(bin_path), ["login"], _cli_env(env), [
            ("Select model:", "1\r"),
            ("Select reasoning effort:", "1\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert _CLI_SSH_LINE in text, text
        assert f"METASK_USER_CODE={USER_CODE}" in text, text
        assert f"Signed in to Metask with the device code as {ACCOUNT_NAME}. Model glm-5, reasoning low." in text, text
        assert "Starting local login server" not in text, text
        _expect_device_request(mock)
        assert not os.path.exists(mock.browser_log), "no browser may be opened over SSH"
        with open(os.path.join(state, "auth.json")) as f:
            assert json.load(f) == {"selected_model": MODEL, "reasoning_effort": "low"}


def test_cli_login_no_browser_over_ssh_names_the_forward_and_stops_waiting_after_the_bound(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock, dict(_SSH, METACODES_LOGIN_CALLBACK_TIMEOUT_MS="3000"))
        started = time.monotonic()
        code, out = _cli(os.path.abspath(bin_path), ["login", "--no-browser"], _cli_env(env), [])
        elapsed = time.monotonic() - started
        text = out.decode("utf-8", "replace")
        assert code == 1, f"exit {code}:\n{text}"
        assert _forward_line(text) in text, text
        assert _CLI_SSH_LINE not in text, text
        assert "No answer from the browser in 3 seconds; nothing was stored." in text, text
        assert elapsed < 15, f"took {elapsed:.1f}s"
        assert mock.device_requests == [], mock.device_requests


def test_cli_login_stops_waiting_for_the_browser_after_the_bound_and_stores_nothing(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock, {"BROWSER": "true", "METACODES_LOGIN_CALLBACK_TIMEOUT_MS": "2000"})
        started = time.monotonic()
        code, out = _cli(os.path.abspath(bin_path), ["login"], _cli_env(env), [])
        elapsed = time.monotonic() - started
        text = out.decode("utf-8", "replace")
        assert code == 1, f"exit {code}:\n{text}"
        assert ("No answer from the browser in 2 seconds; nothing was stored. "
                "Signing in on another computer? Run `metacodes login --provider metask`.") in text, text
        assert "Over SSH?" not in text, text
        assert 1.5 < elapsed < 15, f"took {elapsed:.1f}s"
        assert not os.path.exists(os.path.join(state, "auth.json"))
        assert not os.path.exists(os.path.join(state, "oauth", "metask.json"))
        assert not any(path.startswith("/api/oauth/token") for _, path, _ in mock.requests), mock.requests


def _refuse(authorize_url):
    import urllib.parse
    query = urllib.parse.parse_qs(urllib.parse.urlparse(authorize_url).query)
    callback = urllib.parse.urlsplit(query["redirect_uri"][0])
    state = urllib.parse.quote(query["state"][0], safe="")
    conn = http.client.HTTPConnection("127.0.0.1", callback.port, timeout=5)
    try:
        conn.request("GET", f"{callback.path}?error=access_denied&error_description=The%20user%20said%20no&state={state}")
        conn.getresponse().read()
    finally:
        conn.close()
    return ""


def test_cli_login_ends_when_the_authorization_page_refuses_and_stores_nothing(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI's choices are answered over a POSIX pty here")
    with MetaskMock() as mock:
        home, state, env = _case(mock, {"METACODES_LOGIN_CALLBACK_TIMEOUT_MS": "8000"})
        stub, log = _recorder(home)
        env["BROWSER"] = stub
        started = time.monotonic()
        code, out = _cli(os.path.abspath(bin_path), ["login"], _cli_env(env), [
            (_PASTE_LINE, lambda _: _refuse(_recorded(log))),
        ])
        elapsed = time.monotonic() - started
        text = out.decode("utf-8", "replace")
        assert code == 1, f"exit {code}:\n{text}"
        assert "The sign-in was refused: access_denied (The user said no)." in text, text
        assert "No answer from the browser" not in text, text
        assert elapsed < 6, f"took {elapsed:.1f}s"
        assert not os.path.exists(os.path.join(state, "auth.json"))
        assert not os.path.exists(os.path.join(state, "oauth", "metask.json"))
        assert not any(path.startswith("/api/oauth/token") for _, path, _ in mock.requests), mock.requests


def test_login_ends_when_the_authorization_page_refuses_and_stores_nothing(bin_path):
    if IS_WINDOWS:
        raise SkipTest(_NO_BROWSER_STUB)
    with MetaskMock() as mock:
        home, state, env = _case(mock)
        stub, log = _recorder(home)
        env["BROWSER"] = stub
        work = case_tmpdir("cc-tty-login-work-")

        def events():
            yield READY
            yield "type:/login"
            yield "key:enter"
            yield wait_for(_PASTE_LINE, 15)
            _refuse(_recorded(log))
            yield wait_for("Sign-in failed", 10)

        raw = run(bin_path, events(), env=env, base_url=None, cwd=work, term_size=(30, 200), per_key_drain=0.05)
        a = TTYAssert(raw, rows=30, cols=200)
        if not a.screens_with("Sign-in failed: OAuthAccessDenied"):
            a._fail("a refusal on the authorization page should end the sign-in in the pane")
        if not a.screens_with("Nothing was stored."):
            a._fail("the pane should say that nothing was stored")
        assert not os.path.exists(os.path.join(state, "oauth", "metask.json"))
        assert not any(path.startswith("/api/oauth/token") for _, path, _ in mock.requests), mock.requests
