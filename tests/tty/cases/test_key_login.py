"""Guided API-key login for a provider without OAuth (the GLM Coding Plan, Kimi Code).

Z.AI offers no third-party sign-in, so `/login zai-coding-plan` and
`metacodes login --provider zai-coding-plan` show the plan pages a key is
created on, take the pasted key without showing it, check it with a GET the
provider does not bill, and store it in that provider's own key file. The
`/model` picker takes no key (#488), and does not list a provider without one.

The check is pointed at a local mock with METACODES_KEY_CHECK_URL; the page a
key is created on is "opened" through a $BROWSER recorder. The kernel flow and
the credential scoping are covered by tests/component/provider_key_login_test.zig.
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

GOOD_KEY = "plan-key-7c1e93"
BAD_KEY = "plan-key-wrong5"
CN_PERSONAL = "https://bigmodel.cn/coding-plan/personal/overview"
GLOBAL_PERSONAL = "https://z.ai/manage-apikey/apikey-list"
KIMI_CONSOLE = "https://www.kimi.com/code/console"


class _KeyCheck(http.server.BaseHTTPRequestHandler):
    seen = None  # list of (path, authorization), per server

    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        self.server.seen.append((self.path, self.headers.get("authorization")))
        if not self.path.endswith("/models"):
            self.send_error(404)
            return
        ok = self.headers.get("authorization") == f"Bearer {GOOD_KEY}"
        body = json.dumps({"object": "list", "data": [{"id": "glm-5.3"}]} if ok
                          else {"error": {"code": "1000", "message": "unauthorized"}}).encode("utf-8")
        self.send_response(200 if ok else 401)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)


class _Case:
    """A scratch HOME, a key-check mock, and a $BROWSER that records URLs."""

    def __enter__(self):
        self.home = case_tmpdir("cc-tty-keylogin-")
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _KeyCheck)
        self.server.seen = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
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
        return {
            "HOME": self.home,
            "ZAI_API_KEY": None,
            "GLM_API_KEY": None,
            "Z_AI_API_KEY": None,
            "BROWSER": self.browser,
            "METACODES_KEY_CHECK_URL": f"http://127.0.0.1:{self.server.server_port}/api/coding/paas/v4/models",
        }

    def key_file(self):
        return os.path.join(self.home, ".metacodes", "keys", "zai-coding-plan.json")

    def opened_urls(self, expect=0):
        # The opener is spawned detached: it may still be writing when the
        # process that started it has exited, and right after a build, when
        # the system is still assessing the new binaries, it can take
        # seconds to start. The wait ends as soon as the URL is there.
        deadline = time.monotonic() + (15.0 if expect else 0.0)
        while True:
            urls = []
            if os.path.exists(self.opened):
                with open(self.opened) as f:
                    urls = [line.strip() for line in f if line.strip()]
            if len(urls) >= expect or time.monotonic() >= deadline:
                return urls
            time.sleep(0.05)

    def checks(self):
        return [auth for path, auth in self.server.seen if path.endswith("/models")]

    def assert_stored(self, key, kind="zai_coding_plan_api_key"):
        path = self.key_file()
        assert os.path.exists(path), f"no key file at {path}"
        with open(path) as f:
            document = json.load(f)
        assert document["key"] == key and document["kind"] == kind, document.get("kind")
        if not IS_WINDOWS:
            mode = stat.S_IMODE(os.stat(path).st_mode)
            assert mode == 0o600, f"key file mode {oct(mode)}, expected 0o600"
        # The key lives in its own file, never in config.json.
        config = os.path.join(self.home, ".metacodes", "config.json")
        if os.path.exists(config):
            with open(config) as f:
                assert key not in f.read(), "the key leaked into config.json"


class _KimiCase(_Case):
    """The same scratch HOME and recorder, for the Kimi Code subscription:
    every Kimi and Moonshot variable cleared, the check on the coding path."""

    def env(self):
        env = super().env()
        env.update({
            "KIMI_CODE_API_KEY": None,
            "KIMI_API_KEY": None,
            "MOONSHOT_API_KEY": None,
            "METACODES_KEY_CHECK_URL": f"http://127.0.0.1:{self.server.server_port}/coding/v1/models",
        })
        return env

    def key_file(self):
        return os.path.join(self.home, ".metacodes", "keys", "kimi-code.json")


def _screen(raw, rows, cols):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def _login_events(key, extra=""):
    flag = " --no-browser" if IS_WINDOWS else ""
    return [READY, f"type:/login zai-coding-plan{flag}{extra}", "key:enter",
            wait_for("Which plan is the key for?", 10),
            "key:enter", wait_for("paste it here", 10),
            f"type:{key}", wait_for(f"({len(key)} characters)", 10),
            "key:enter"]


def test_login_dialog_checks_and_stores_a_pasted_key(bin_path):
    with _Case() as case:
        events = _login_events(GOOD_KEY) + [wait_for("Stored the key for Z.AI GLM Coding Plan", WAIT_S)]
        raw = run(bin_path, events, term_size=(30, 120), env=case.env(), per_key_drain=0.05)
        a, text = _screen(raw, 30, 120)
        a.assert_prose_contains("Stored the key for Z.AI GLM Coding Plan · /model to choose a model")
        if not a.screens_with("standard API Key page is billed to your balance"):
            a._fail("the plan-key note was never shown")
        if not a.screens_with(CN_PERSONAL):
            a._fail("the key page URL was never shown whole")
        # Typed blind: no frame ever carried the key.
        assert GOOD_KEY.encode() not in raw, "the pasted key was echoed to the terminal"
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        if not IS_WINDOWS:
            assert case.opened_urls(1) == [CN_PERSONAL], case.opened_urls()
        case.assert_stored(GOOD_KEY)


def test_login_dialog_refused_key_stores_nothing_and_says_why(bin_path):
    with _Case() as case:
        events = _login_events(BAD_KEY) + [wait_for("was not stored", WAIT_S), "key:esc",
                                           wait_for("Login interrupted", 10)]
        raw = run(bin_path, events, term_size=(30, 120), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 30, 120)
        if not a.screens_with("The key for Z.AI GLM Coding Plan was not stored: KeyRefused"):
            a._fail("a refused key should be named as refused")
        if not a.screens_with("The provider refused this key"):
            a._fail("a refused key should say what to check")
        assert BAD_KEY.encode() not in raw, "the pasted key was echoed to the terminal"
        assert case.checks() == [f"Bearer {BAD_KEY}"], case.checks()
        assert not os.path.exists(case.key_file()), "a refused key was stored"


def test_model_takes_no_key_and_does_not_list_a_provider_without_one(bin_path):
    # #488: /model no longer opens a key field, and a provider without a key is
    # not listed: typing the plan's name finds nothing, and Enter there starts
    # nothing. It checks nothing, opens nothing, stores nothing:
    # `/login zai-coding-plan` (above) is where a key is pasted.
    with _Case() as case:
        events = [READY, "type:/model", "key:enter", wait_for("apply to", 10),
                  "type:zai", wait_for("nothing matches", 10), "key:enter", "sleep:0.8"]
        raw = run(bin_path, events, term_size=(40, 120), env=case.env(), per_key_drain=0.05)
        a, text = _screen(raw, 40, 120)
        assert "nothing matches this filter" in text, text
        for gone in ("ZAI_API_KEY", "not configured", "Not configured", "switched to"):
            assert gone not in text, f"{gone!r} should not be on screen:\n" + text
        if a.screens_with("paste it"):
            a._fail("/model should not offer a key field")
        assert case.checks() == [], case.checks()
        assert case.opened_urls() == [], case.opened_urls()
        assert not os.path.exists(case.key_file()), "a key was stored from /model"


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
    # Read to EOF after the exit. macOS holds the exit until the output is
    # read, but on Linux the child can be reaped with its last lines (the
    # "Stored the key" line) still in the pty buffer.
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


def test_cli_login_reads_the_key_without_echo(bin_path):
    if IS_WINDOWS:
        raise SkipTest("the CLI paste prompt is driven over a POSIX pty here")
    with _Case() as case:
        env = dict(os.environ)
        env.update({k: v for k, v in case.env().items() if v is not None})
        for name in ("ZAI_API_KEY", "GLM_API_KEY", "Z_AI_API_KEY", "CODEX_HOME"):
            env.pop(name, None)
        env["METACODES_KG_AUTOSTART"] = "0"
        code, out = _cli(os.path.abspath(bin_path), ["login", "--provider", "zai-coding-plan"], env, [
            ("Choose [1-4] (Enter = 1): ", "3\r"),
            ("Paste the key (it is not shown) and press Enter: ", GOOD_KEY + "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "Which plan is the key for?" in text and "Global · Personal Coding Plan" in text, text
        assert GLOBAL_PERSONAL in text, text
        assert "Stored the key for Z.AI GLM Coding Plan." in text, text
        assert GOOD_KEY not in text, "the pasted key was echoed to the terminal"
        assert case.opened_urls(1) == [GLOBAL_PERSONAL], case.opened_urls()
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        case.assert_stored(GOOD_KEY)


def test_login_dialog_lists_kimi_code_as_an_api_key_provider(bin_path):
    with _KimiCase() as case:
        # `/login` alone is the Metask sign-in (#485); it names the providers
        # `/login <provider>` signs in to, the API-key ones among them.
        events = [READY, "type:/login", "key:enter", wait_for("/login <provider>", 10),
                  "key:esc", wait_for("Login interrupted", 10)]
        raw = run(bin_path, events, term_size=(30, 200), env=dict(case.env(), BROWSER="true"), per_key_drain=0.05)
        a, _ = _screen(raw, 30, 200)
        # The names come from the profiles' api_key_setup, the GLM plan's too.
        if not a.screens_with("kimi-code"):
            a._fail("/login should name Kimi Code as a provider it signs in to")
        if not a.screens_with("zai-coding-plan"):
            a._fail("/login should still name the GLM Coding Plan")
        assert case.checks() == [], case.checks()


def test_login_dialog_stores_a_kimi_code_key_checked_on_the_coding_path(bin_path):
    with _KimiCase() as case:
        flag = " --no-browser" if IS_WINDOWS else ""
        events = [READY, f"type:/login kimi-code{flag}", "key:enter",
                  wait_for("Which plan is the key for?", 10),
                  "key:enter", wait_for("paste it here", 10),
                  f"type:{GOOD_KEY}", wait_for(f"({len(GOOD_KEY)} characters)", 10),
                  "key:enter", wait_for("Stored the key for Kimi Code", WAIT_S)]
        raw = run(bin_path, events, term_size=(30, 120), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 30, 120)
        a.assert_prose_contains("Stored the key for Kimi Code · /model to choose a model")
        if not a.screens_with("A Moonshot open-platform key does not work here"):
            a._fail("the subscription-key note was never shown")
        if not a.screens_with("China · Kimi Code Console"):
            a._fail("the key step should list the Kimi Code Console")
        if not a.screens_with(KIMI_CONSOLE):
            a._fail("the Console URL was never shown whole")
        assert GOOD_KEY.encode() not in raw, "the pasted key was echoed to the terminal"
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        assert [path for path, _ in case.server.seen] == ["/coding/v1/models"], case.server.seen
        if not IS_WINDOWS:
            assert case.opened_urls(1) == [KIMI_CONSOLE], case.opened_urls()
        case.assert_stored(GOOD_KEY, kind="kimi_code_api_key")


# ── phase 2: every built-in vendor takes a pasted key ───────────────────────

OPENAI_KEYS = "https://platform.openai.com/api-keys"
AISTUDIO_KEYS = "https://aistudio.google.com/apikey"


class _GeminiKeyCheck(http.server.BaseHTTPRequestHandler):
    """Gemini's model listing as Google answers it (2026-11-17): the key in
    `x-goog-api-key`, a wrong one refused with 400 `API_KEY_INVALID`."""

    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        self.server.seen.append((self.path, self.headers.get("authorization"), self.headers.get("x-goog-api-key")))
        self.server.agents.append(self.headers.get("user-agent") or "")
        ok = self.headers.get("x-goog-api-key") == GOOD_KEY
        body = json.dumps({"models": [{"name": "models/gemini-4-argon"}]} if ok else {"error": {
            "code": 400, "message": "API key not valid. Please pass a valid API key.", "status": "INVALID_ARGUMENT",
            "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "API_KEY_INVALID"}]}}).encode("utf-8")
        self.send_response(200 if ok else 400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)


class _GeminiCase(_Case):
    def __enter__(self):
        super().__enter__()
        self.server.shutdown()
        self.server.server_close()
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _GeminiKeyCheck)
        self.server.seen = []
        self.server.agents = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def env(self):
        env = super().env()
        env.update({"GEMINI_API_KEY": None, "GOOGLE_API_KEY": None,
                    "METACODES_KEY_CHECK_URL": f"http://127.0.0.1:{self.server.server_port}/v1beta/models"})
        return env

    def key_file(self):
        return os.path.join(self.home, ".metacodes", "keys", "gemini.json")


def test_login_dialog_checks_a_gemini_key_in_its_own_header_and_refuses_a_wrong_one(bin_path):
    # Gemini reads the key from x-goog-api-key; as a bearer token Google takes
    # it for an OAuth token and answers 401 whatever the key, so a check sent
    # that way would refuse every key. A wrong key is a 400 API_KEY_INVALID.
    with _GeminiCase() as case:
        flag = " --no-browser" if IS_WINDOWS else ""

        def attempt(key):
            return [READY, f"type:/login gemini{flag}", "key:enter",
                    wait_for("Which plan is the key for?", 10),
                    "key:enter", wait_for("paste it here", 10),
                    f"type:{key}", wait_for(f"({len(key)} characters)", 10), "key:enter"]

        events = attempt(BAD_KEY) + [wait_for("was not stored", WAIT_S), "key:esc", wait_for("Login interrupted", 10)]
        events += attempt(GOOD_KEY) + [wait_for("Stored the key for Google Gemini", WAIT_S)]
        raw = run(bin_path, events, term_size=(30, 120), env=case.env(), per_key_drain=0.05)
        a, _ = _screen(raw, 30, 120)
        if not a.screens_with("The key for Google Gemini was not stored: KeyRefused"):
            a._fail("a wrong Gemini key should be named as refused, not as a failed check")
        if not a.screens_with("Google AI Studio"):
            a._fail("the key step should name Google AI Studio")
        if not a.screens_with(AISTUDIO_KEYS):
            a._fail("the key page URL was never shown whole")
        a.assert_prose_contains("Stored the key for Google Gemini · /model to choose a model")
        assert BAD_KEY.encode() not in raw and GOOD_KEY.encode() not in raw, "a pasted key was echoed"
        # Both checks carried the key in x-goog-api-key, never as a bearer token.
        assert [(auth, goog) for _path, auth, goog in case.server.seen] == [(None, BAD_KEY), (None, GOOD_KEY)], \
            case.server.seen
        # The check names metacodes, as every request does.
        assert all(agent.startswith("metacodes/") for agent in case.server.agents), case.server.agents
        case.assert_stored(GOOD_KEY, kind="api_key")


class _OpenAICase(_Case):
    def env(self):
        env = super().env()
        env.update({"OPENAI_API_KEY": None,
                    "METACODES_KEY_CHECK_URL": f"http://127.0.0.1:{self.server.server_port}/v1/models"})
        return env

    def key_file(self):
        return os.path.join(self.home, ".metacodes", "keys", "openai.json")


def test_cli_login_takes_a_pasted_openai_key_while_no_oauth_client_is_configured(bin_path):
    # OpenAI declares an OAuth grant but no client to present with it, so the
    # CLI used to start that grant and stop on the missing client id. With a
    # key page, `login --provider openai` takes a pasted key, as /login does.
    if IS_WINDOWS:
        raise SkipTest("the CLI paste prompt is driven over a POSIX pty here")
    with _OpenAICase() as case:
        env = dict(os.environ)
        env.update({k: v for k, v in case.env().items() if v is not None})
        for name in ("OPENAI_API_KEY", "CODEX_HOME"):
            env.pop(name, None)
        env["METACODES_KG_AUTOSTART"] = "0"
        code, out = _cli(os.path.abspath(bin_path), ["login", "--provider", "openai"], env, [
            ("Paste the key (it is not shown) and press Enter: ", GOOD_KEY + "\r"),
        ])
        text = out.decode("utf-8", "replace")
        assert code == 0, f"exit {code}:\n{text}"
        assert "Create an API key for OpenAI." in text, text
        assert "not to a ChatGPT Plus or Pro plan" in text, text
        assert OPENAI_KEYS in text, text
        assert "client id" not in text, text
        assert "Stored the key for OpenAI." in text, text
        assert GOOD_KEY not in text, "the pasted key was echoed to the terminal"
        assert case.opened_urls(1) == [OPENAI_KEYS], case.opened_urls()
        assert case.checks() == [f"Bearer {GOOD_KEY}"], case.checks()
        case.assert_stored(GOOD_KEY, kind="api_key")


def test_login_dialog_says_a_shell_key_is_read_before_the_key_it_stored(bin_path):
    # GEMINI_API_KEY in the shell is read before a stored key (environment,
    # then .env, then the key store): the login stores the pasted key and says
    # which variable wins, by name, never its value.
    shell_key = "tty-shell-gemini-key-31"
    with _GeminiCase() as case:
        flag = " --no-browser" if IS_WINDOWS else ""
        env = dict(case.env(), GEMINI_API_KEY=shell_key)
        events = [READY, f"type:/login gemini{flag}", "key:enter",
                  wait_for("Which plan is the key for?", 10),
                  "key:enter", wait_for("paste it here", 10),
                  f"type:{GOOD_KEY}", wait_for(f"({len(GOOD_KEY)} characters)", 10),
                  "key:enter", wait_for("used before the stored key", WAIT_S)]
        raw = run(bin_path, events, term_size=(30, 160), env=env, per_key_drain=0.05)
        a, _ = _screen(raw, 30, 160)
        a.assert_prose_contains("Stored the key for Google Gemini · /model to choose a model")
        a.assert_prose_contains("GEMINI_API_KEY is set in your shell and is used before the stored key: "
                                "unset it to use the key you just stored.")
        assert shell_key.encode() not in raw and GOOD_KEY.encode() not in raw, "a key value reached the terminal"
        case.assert_stored(GOOD_KEY, kind="api_key")
