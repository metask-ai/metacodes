"""OpenRouter's sign-in in the TUI: `/login openrouter` and its three ways.

OpenRouter's PKCE sign-in creates an API key on the user's own account. The
dialog asks which way: the browser here (a loopback callback), another device
(the page shows a code to paste back), or a key the user already has. Every
OpenRouter address is moved onto a local mock with METACODES_OPENROUTER_URL,
and the browser case delivers a code only after checking the page address it
was given is on that mock: no made-up code reaches openrouter.ai. The flows
themselves are covered by apps/cli/tests/component/openrouter_login_test.zig.
"""
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import IS_WINDOWS, READY, WAIT_S, case_tmpdir, run, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402

KEY = "sk-or-v1-tty0e6f44a47a05f1dad2ad7e88c4c1d6"
PASTED_KEY = "sk-or-v1-ttypasted9b1c2d3e4f"
BROWSER_CODE = "auth-code-tty"
SHOWN_CODE = "shown-code-tty"
LISTING = {"data": [
    {"id": "deepseek/deepseek-v4.1-flash", "name": "DeepSeek: DeepSeek V4.1 Flash", "context_length": 1048576,
     "pricing": {"prompt": "0.0000001", "completion": "0.0000004"},
     "supported_parameters": ["tools", "reasoning"], "endpoints": ["/api/v1/chat/completions"]},
    {"id": "inclusionai/ling-3.2-flash:free", "name": "inclusionAI: Ling 3.2 Flash (free)", "context_length": 262144,
     "pricing": {"prompt": "0", "completion": "0"},
     "supported_parameters": ["tools"], "endpoints": ["/api/v1/chat/completions"]},
    {"id": "some/no-tools", "name": "No Tools", "supported_parameters": ["temperature"],
     "endpoints": ["/api/v1/chat/completions"]},
]}
DESCRIBED = {"data": {"label": "sk-or-v1-0e6...1c96", "limit": None, "expires_at": None, "is_free_tier": False}}
LISTING_LARGE = {"data": [dict(LISTING["data"][0], description="x" * 96 * 1024)] + LISTING["data"][1:]}

VENDOR_KEYS = ["OPENROUTER_API_KEY", "DEEPSEEK_API_KEY", "MOONSHOT_API_KEY", "KIMI_API_KEY", "KIMI_CODE_API_KEY",
               "ZAI_API_KEY", "GLM_API_KEY", "Z_AI_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
               "DASHSCOPE_API_KEY", "MINIMAX_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "METASK_API_KEY",
               "METACODES_PROVIDER", "SSH_CONNECTION", "SSH_TTY"]


class _OpenRouter(http.server.BaseHTTPRequestHandler):
    """OpenRouter's exchange, key description and listing."""

    def log_message(self, fmt, *args):  # noqa: D401
        return

    def _send(self, status, document):
        body = json.dumps(document).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode("utf-8")
        self.server.seen.append(("POST", self.path, self.headers.get("authorization"), body))
        if self.path != "/api/v1/auth/keys":
            self.send_error(404)
            return
        document = json.loads(body or "{}")
        if document.get("code") in (BROWSER_CODE, SHOWN_CODE) and document.get("code_challenge_method") == "S256" \
                and document.get("code_verifier"):
            self._send(200, {"key": KEY, "user_id": "user_tty"})
        else:
            self._send(403, {"error": {"code": 403, "message": "Invalid code or code_verifier"}})

    def do_GET(self):  # noqa: N802
        auth = self.headers.get("authorization")
        self.server.seen.append(("GET", self.path, auth, ""))
        if auth not in (f"Bearer {KEY}", f"Bearer {PASTED_KEY}"):
            self._send(401, {"error": {"code": 401, "message": "Missing Authentication header"}})
        elif self.path == "/api/v1/key":
            self._send(200, {"data": dict(DESCRIBED["data"], is_free_tier=self.server.free_tier)})
        elif self.path == "/api/v1/models/user":
            self._answer_listing()
        else:
            self.send_error(404)

    def _answer_listing(self):
        if self.server.drop_listing > 0:
            self.server.drop_listing -= 1
            self.close_connection = True
            return
        if not self.server.hold_listing_s:
            self._send(200, self.server.listing)
            return
        body = json.dumps(self.server.listing).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body[:len(body) // 2])
        self.wfile.flush()
        time.sleep(self.server.hold_listing_s)
        self.wfile.write(body[len(body) // 2:])


class _Case:
    """A scratch HOME, an OpenRouter mock every address is moved onto, and a
    $BROWSER that records the URL it is asked to open."""

    def __init__(self, free_tier=False, listing=None, hold_listing_s=0.0, drop_listing=0):
        self.free_tier = free_tier
        self.listing = listing or LISTING
        self.hold_listing_s = hold_listing_s
        self.drop_listing = drop_listing

    def __enter__(self):
        self.home = case_tmpdir("cc-tty-openrouter-")
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _OpenRouter)
        self.server.seen = []
        self.server.free_tier = self.free_tier
        self.server.listing = self.listing
        self.server.hold_listing_s = self.hold_listing_s
        self.server.drop_listing = self.drop_listing
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.origin = f"http://127.0.0.1:{self.server.server_port}"
        self.opened = os.path.join(self.home, "opened.txt")
        self.browser = os.path.join(self.home, "record-browser")
        with open(self.browser, "w") as f:
            f.write(f"#!/bin/sh\nprintf '%s\\n' \"$1\" >> '{self.opened}'\n")
        os.chmod(self.browser, 0o755)
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    def env(self):
        env = {name: None for name in VENDOR_KEYS}
        env.update({"HOME": self.home, "BROWSER": self.browser, "METACODES_OPENROUTER_URL": self.origin})
        return env

    def key_file(self):
        return os.path.join(self.home, ".metacodes", "keys", "openrouter.json")

    def stored(self):
        with open(self.key_file()) as f:
            return json.load(f)

    def store_key(self):
        keys = os.path.join(self.home, ".metacodes", "keys")
        os.makedirs(keys, exist_ok=True)
        with open(self.key_file(), "w") as f:
            json.dump({"schema_version": 1, "kind": "api_key", "key": KEY}, f)
        os.chmod(self.key_file(), 0o600)

    def seen(self, method, path):
        return [entry for entry in self.server.seen if entry[0] == method and entry[1] == path]

    def answer_the_browser(self, approve_after_s=2.0):
        """Play OpenRouter's page: once the dialog has sent the browser to the
        mock's page, redirect to the callback it named, with its state.

        It waits first, as a person approving the key would: the browser is
        opened before the dialog draws what it shows while waiting, and on a
        fast machine (Linux CI) an immediate callback signed in before that
        screen was ever drawn."""

        def play():
            deadline = time.monotonic() + WAIT_S
            while time.monotonic() < deadline:
                if os.path.exists(self.opened):
                    with open(self.opened) as f:
                        urls = [line.strip() for line in f if line.strip()]
                    if urls:
                        page = urls[0]
                        # Never a code to anything but the mock's page.
                        assert page.startswith(self.origin + "/auth?"), page
                        query = urllib.parse.parse_qs(urllib.parse.urlsplit(page).query)
                        callback = query["callback_url"][0]
                        state = query["state"][0]
                        assert callback.startswith("http://localhost:"), callback
                        target = f"{callback}?code={BROWSER_CODE}&state={urllib.parse.quote(state)}"
                        time.sleep(approve_after_s)
                        urllib.request.urlopen(target, timeout=5).read()
                        return
                time.sleep(0.05)

        thread = threading.Thread(target=play, daemon=True)
        thread.start()
        return thread


def _screen(raw, rows, cols):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_login_openrouter_asks_which_way_and_signs_in_with_the_browser(bin_path):
    if IS_WINDOWS:
        raise SkipTest("$BROWSER is not how Windows opens a page")
    with _Case() as case:
        player = case.answer_the_browser()
        events = [READY, "type:/login openrouter", "key:enter",
                  wait_for("Paste an API key you already have", 10),
                  "key:enter",
                  wait_for("Signed in to OpenRouter", WAIT_S),
                  # Signed in: the picker opens by itself, applying from now on.
                  wait_for("apply to", 10),
                  "type:deepseek-v4.1", wait_for("DeepSeek: DeepSeek V4.1 Flash", 10),
                  "key:enter", wait_for("from now on", 10), "sleep:0.5",
                  "type:/logout openrouter", "key:enter",
                  wait_for("It still works on OpenRouter", 10)]
        raw = run(bin_path, events, term_size=(40, 140), env=case.env(), per_key_drain=0.05)
        player.join(1)
        a, text = _screen(raw, 40, 140)
        if not a.screens_with("1. Sign in with the browser on this computer"):
            a._fail("the dialog should ask which way")
        if not a.screens_with("2. Sign in on another device (SSH, no browser here)"):
            a._fail("the other device should be offered")
        if not a.screens_with('OpenRouter shows this sign-in as "localhost:'):
            a._fail("the dialog should say how OpenRouter names the sign-in")
        a.assert_prose_contains('Signed in to OpenRouter · key sk-or-v1-0e6...1c96 on your account · no spending limit · never expires')
        if a.screens_with("/model to choose a model"):
            a._fail("the picker opens by itself: no need to point at /model")
        if not a.screens_with("[from now on]"):
            a._fail("the picker should open applying from now on")
        if not a.screens_with("switched to deepseek/deepseek-v4.1-flash from now on"):
            a._fail("Enter in that picker should apply the model from now on")
        # The exchange: the browser's code, S256, a verifier.
        exchanges = case.seen("POST", "/api/v1/auth/keys")
        assert len(exchanges) == 1, case.server.seen
        body = json.loads(exchanges[0][3])
        assert body["code"] == BROWSER_CODE and body["code_challenge_method"] == "S256" and body["code_verifier"], body
        # The key was described and the account's models listed with it.
        assert [entry[2] for entry in case.seen("GET", "/api/v1/key")] == [f"Bearer {KEY}"], case.server.seen
        assert [entry[2] for entry in case.seen("GET", "/api/v1/models/user")] == [f"Bearer {KEY}"], case.server.seen
        # Logged out: the key is gone from this machine, and its page named.
        a.assert_prose_contains("Removed the OpenRouter key stored on this machine.")
        # The page goes on a line of its own when the line wraps.
        a.assert_prose_contains("It still works on OpenRouter until you delete it there:")
        if not a.screens_with(f"{case.origin}/keys/"):
            a._fail("the key's page on OpenRouter should be named")
        assert not os.path.exists(case.key_file()), "the key survived /logout"
        assert KEY.encode() not in raw, "the key reached the terminal"


def test_login_openrouter_on_another_device_takes_the_code_pasted_back(bin_path):
    # An account without credits: the picker that follows opens on its free models.
    with _Case(free_tier=True) as case:
        events = [READY, "type:/login openrouter --device-code", "key:enter",
                  wait_for("Paste the code here", 10),
                  f"type:{SHOWN_CODE}", wait_for(f"({len(SHOWN_CODE)} characters)", 10),
                  "key:enter", wait_for("Signed in to OpenRouter", WAIT_S),
                  wait_for("inclusionAI: Ling 3.2 Flash (free)", 10), "sleep:0.3"]
        raw = run(bin_path, events, term_size=(40, 160), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 40, 160)
        if not a.screens_with("Sign in to OpenRouter on another device"):
            a._fail("--device-code should start on the other device")
        # The page is the mock's, without a callback: it shows the code.
        if not a.screens_with(f"{case.origin}/auth?code_challenge="):
            a._fail("the page address should be shown whole")
        if a.screens_with("callback_url"):
            a._fail("the other-device page carries no callback")
        assert SHOWN_CODE.encode() not in raw, "the pasted code was echoed"
        body = json.loads(case.seen("POST", "/api/v1/auth/keys")[0][3])
        assert body["code"] == SHOWN_CODE, body
        stored = case.stored()
        assert stored["key"] == KEY and stored["obtained"] == "browser_sign_in", stored
        if not a.screens_with("has no credits yet"):
            a._fail("an account without credits should be told so")
        picker = a.screens_with("inclusionAI: Ling 3.2 Flash (free)")
        if not picker:
            a._fail("the picker should open on the free models")
        last = "\n".join(picker[-1].line_text(r) for r in range(picker[-1].rows))
        assert ":free" in last and "[from now on]" in last, last
        assert "DeepSeek: DeepSeek V4.1 Flash" not in last, "a paid model listed for an account without credits:\n" + last


def test_login_lists_the_providers_it_signs_in_to_and_logout_the_keys_stored(bin_path):
    """Typing `/login` shows what can follow it; `/logout`, the keys stored here."""
    with _Case() as case:
        events = [READY, "type:/login", wait_for("/login openrouter", 10), "sleep:0.3",
                  "key:ctrl_u", "sleep:0.3", "type:/logout", "sleep:0.8"]
        raw = run(bin_path, events, term_size=(40, 140), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 40, 140)
        if not a.screens_with("Sign in to OpenRouter: in the browser, on another device, or with a key"):
            a._fail("/login should list OpenRouter, and how it signs in")
        if a.screens_with("/logout openrouter"):
            a._fail("/logout lists only the keys stored here, and none is")
        assert case.server.seen == [], "nothing was asked of OpenRouter"
    with _Case() as case:
        keys = os.path.join(case.home, ".metacodes", "keys")
        os.makedirs(keys)
        with open(os.path.join(keys, "openrouter.json"), "w") as f:
            json.dump({"schema_version": 1, "kind": "api_key", "key": KEY}, f)
        os.chmod(os.path.join(keys, "openrouter.json"), 0o600)
        events = [READY, "type:/logout", wait_for("/logout openrouter", 10), "sleep:0.3"]
        raw = run(bin_path, events, term_size=(40, 140), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 40, 140)
        if not a.screens_with("Forget the OpenRouter key stored here"):
            a._fail("/logout should list the OpenRouter key stored here")


def test_login_openrouter_takes_a_key_the_user_already_has(bin_path):
    with _Case() as case:
        events = [READY, "type:/login openrouter", "key:enter",
                  wait_for("Paste an API key you already have", 10),
                  "type:3", wait_for("paste it here", 10),
                  f"type:{PASTED_KEY}", wait_for(f"({len(PASTED_KEY)} characters)", 10),
                  "key:enter", wait_for("Stored the key for OpenRouter", WAIT_S)]
        raw = run(bin_path, events, term_size=(40, 140), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 40, 140)
        a.assert_prose_contains('Stored the key for OpenRouter · key sk-or-v1-0e6...1c96 on your account · no spending limit · never expires')
        if not a.screens_with("apply to"):
            a._fail("a stored key goes on to choosing a model too")
        assert PASTED_KEY.encode() not in raw, "the pasted key was echoed"
        assert [entry[2] for entry in case.seen("GET", "/api/v1/key")] == [f"Bearer {PASTED_KEY}"], case.server.seen
        assert case.seen("POST", "/api/v1/auth/keys") == [], "a pasted key needs no exchange"
        stored = case.stored()
        assert stored["key"] == PASTED_KEY and stored["obtained"] == "pasted", stored


def _sign_in_on_another_device():
    return [READY, "type:/login openrouter --device-code", "key:enter",
            wait_for("Paste the code here", 10),
            f"type:{SHOWN_CODE}", wait_for(f"({len(SHOWN_CODE)} characters)", 10),
            "key:enter", wait_for("Signed in to OpenRouter", WAIT_S)]


def test_login_openrouter_opens_the_picker_at_once_and_fills_it_in_when_the_list_comes(bin_path):
    with _Case(free_tier=True, listing=LISTING_LARGE, hold_listing_s=5.0) as case:
        events = _sign_in_on_another_device() + [
            wait_for("Downloading the models your OpenRouter account can use", 10),
            wait_for("nothing matches yet", 10),
            wait_for("inclusionAI: Ling 3.2 Flash (free)", 20), "sleep:0.3"]
        raw = run(bin_path, events, term_size=(40, 140), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 40, 140)
        waiting = a.screens_with("Downloading the models your OpenRouter account can use")
        if not waiting:
            a._fail("the picker should say the list is on its way")
        text = "\n".join(waiting[-1].line_text(r) for r in range(waiting[-1].rows))
        assert "[from now on]" in text and ":free" in text, text
        assert " KB" in text, text
        assert "nothing matches yet — OpenRouter's models are still downloading" in text, text
        assert "nothing matches this filter" not in text, text
        filled = a.screens_with("inclusionAI: Ling 3.2 Flash (free)")
        last = "\n".join(filled[-1].line_text(r) for r in range(filled[-1].rows))
        assert ":free" in last and "[from now on]" in last, last
        assert "Downloading the models" not in last, last
        assert "DeepSeek: DeepSeek V4.1 Flash" not in last, last
        assert len(case.seen("GET", "/api/v1/models/user")) == 1, case.server.seen
        assert KEY.encode() not in raw, "the key reached the terminal"


def test_a_list_that_did_not_come_says_why_and_ctrl_r_fetches_it_again(bin_path):
    with _Case(free_tier=True, drop_listing=2) as case:
        events = _sign_in_on_another_device() + [
            wait_for("did not download (no connection) · ctrl+r retries", 20),
            "key:ctrl_r",
            wait_for("inclusionAI: Ling 3.2 Flash (free)", 20), "sleep:0.3"]
        raw = run(bin_path, events, term_size=(40, 140), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 40, 140)
        failed = a.screens_with("OpenRouter's model list did not download (no connection) · ctrl+r retries")
        if not failed:
            a._fail("a list that did not come should say why and that ctrl+r retries")
        text = "\n".join(failed[-1].line_text(r) for r in range(failed[-1].rows))
        assert "nothing matches this filter — Esc clears it" in text, text
        filled = a.screens_with("inclusionAI: Ling 3.2 Flash (free)")
        last = "\n".join(filled[-1].line_text(r) for r in range(filled[-1].rows))
        assert "did not download" not in last, last
        assert len(case.seen("GET", "/api/v1/models/user")) == 3, case.server.seen


def test_a_start_with_a_key_and_no_list_downloads_it_and_model_says_so(bin_path):
    with _Case(listing=LISTING_LARGE, hold_listing_s=5.0) as case:
        case.store_key()
        env = case.env()
        env["METACODES_NO_PROBE"] = None
        events = [READY, "type:/model", "key:enter",
                  wait_for("Downloading the models your OpenRouter account can use", 10),
                  wait_for("DeepSeek: DeepSeek V4.1 Flash", 20), "sleep:0.3"]
        raw = run(bin_path, events, term_size=(40, 140), env=env, per_key_drain=0.05)
        a, _ = _screen(raw, 40, 140)
        waiting = a.screens_with("Downloading the models your OpenRouter account can use")
        if not waiting:
            a._fail("/model should say the list is on its way")
        text = "\n".join(waiting[-1].line_text(r) for r in range(waiting[-1].rows))
        assert "Auto Router" in text, text
        filled = a.screens_with("DeepSeek: DeepSeek V4.1 Flash")
        last = "\n".join(filled[-1].line_text(r) for r in range(filled[-1].rows))
        assert "Downloading the models" not in last, last
        assert [entry[2] for entry in case.seen("GET", "/api/v1/models/user")] == [f"Bearer {KEY}"], case.server.seen
