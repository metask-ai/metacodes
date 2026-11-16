"""No model set up (#484): the TUI opens anyway, unbound, and sends nothing.

With an empty state root and no key, `metacodes` used to print
`Authentication required` and exit before the splash. It now opens: the
banner's model line reads `not set — /login, or configure .env`, slash
commands work, and a prompt gets a red reminder instead of a request. The
prompt stays in the history (↑ brings it back once a model is set up) and
leaves no session record.

Every case points the session at a counting mock and turns the startup
`/v1/models` probe back on, so a request of any kind would be seen.
"""
import http.server
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import READY, case_tmpdir, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402

NOT_SET = "not set — /login, or configure .env"
GUIDE = "https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md"
PLACEHOLDER = "sk-placeholder-never-shown-4711"

# Every variable a built-in provider reads its key from, and the ones that
# choose a provider: the developer's environment must not decide the case.
KEY_VARIABLES = (
    "METASK_API_KEY", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
    "ZAI_API_KEY", "GLM_API_KEY", "Z_AI_API_KEY", "DEEPSEEK_API_KEY",
    "KIMI_API_KEY", "MOONSHOT_API_KEY", "KIMI_CODE_API_KEY", "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY", "AWS_BEARER_TOKEN_BEDROCK", "METACODES_PROVIDER",
    "METACODES_MODEL", "METACODES_API_KEY_FD", "METACODES_AUTH_FILE",
)


class _Counting(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):  # noqa: D401
        return

    def _record(self):
        self.server.seen.append(f"{self.command} {self.path}")
        self.send_error(500)

    do_GET = _record
    do_POST = _record


class _Case:
    """A scratch HOME (its state root is `<home>/.metacodes`) and a counting mock."""

    def __init__(self, extra_env=None):
        self.extra_env = extra_env or {}

    def __enter__(self):
        self.home = case_tmpdir("cc-tty-unbound-")
        self.state = os.path.join(self.home, ".metacodes")
        self.work = case_tmpdir("cc-tty-unbound-work-")
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Counting)
        self.server.seen = []
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server.server_port}/v1/messages"

    def env(self):
        env = {name: None for name in KEY_VARIABLES}
        env.update({
            "HOME": self.home,
            # The probe is what an unbound start must not run either.
            "METACODES_NO_PROBE": None,
            "METACODES_JEV_URL": "off",
            "METACODES_HOME": None,
        })
        env.update(self.extra_env)
        return env

    def run(self, events, **kwargs):
        return run(self.bin, events, env=self.env(), base_url=self.base_url, cwd=self.work, **kwargs)

    def session_entries(self):
        """Everything under `<state>/projects/<project>/` but the memory directory,
        and every transcript anywhere in the state root."""
        found = []
        projects = os.path.join(self.state, "projects")
        if os.path.isdir(projects):
            for project in os.listdir(projects):
                for entry in os.listdir(os.path.join(projects, project)):
                    if entry != "memory":
                        found.append(os.path.join(project, entry))
        for root, _dirs, files in os.walk(self.state):
            found.extend(os.path.join(root, f) for f in files if f == "transcript.jsonl")
        return found


def _assert_nothing_sent(case):
    # The mock answers 500 to anything, so a request would also have been visible
    # on screen; the count is the evidence.
    time.sleep(0.2)
    assert case.server.seen == [], f"an unbound session sent {case.server.seen}"


def test_unbound_start_reminds_and_sends_nothing(bin_path):
    with _Case() as case:
        case.bin = bin_path
        # 180 columns hold the whole `.env` path on one row. Windows' temp
        # path is long enough to wrap at 80, and the wrapped part starts
        # indented, so the path could not be read back across the rows.
        raw = case.run([
            READY,
            "type:hi",
            "key:enter",
            wait_for("No model is set up.", 10),
            READY,
            "key:up",
            "strictsleep:0.5",
        ], term_size=(40, 180))
        a = TTYAssert(raw, rows=40, cols=180)
        a.assert_prose_contains(NOT_SET)
        # The reminder hangs off the prompt's echo, in words.
        echo = a.final.find_row("❯ hi")
        if echo is None:
            a._fail("the prompt's echo is missing")
        a.assert_line_contains(echo + 1, "⎿  No model is set up.")
        for text in ("Sign in to Metask:", "/login", "Or use your own provider key: edit",
                     os.path.join(case.state, ".env"), "then restart", "How to:"):
            if a.final.find_row(text) is None and text not in "".join(a.final.line_text(r) for r in range(a.final.rows)):
                a._fail(f"the reminder should say {text!r}")
        # No template was written to this state root: none is named.
        if a.final.find_row("template") is not None:
            a._fail("no .env.example is there, yet the reminder names one")
        # The reminder is in the danger colour (red), not only in words.
        assert b"\x1b[31mNo model is set up." in raw or b"\x1b[91mNo model is set up." in raw, \
            "the reminder should be in the danger colour"
        # ↑ brings the prompt back into the input box.
        content = a.content_row()
        if content is None or "hi" not in a.final.line_text(content):
            a._fail("↑ should restore the refused prompt")
        a.assert_box_present()
        _assert_nothing_sent(case)
        assert case.session_entries() == [], f"an unbound session left a session record: {case.session_entries()}"


def test_unbound_reminder_names_the_template_and_slash_commands_still_work(bin_path):
    with _Case() as case:
        case.bin = bin_path
        os.makedirs(case.state, exist_ok=True)
        with open(os.path.join(case.state, ".env.example"), "w") as f:
            f.write("# template\n")
        raw = case.run([
            READY,
            "type:hi",
            "key:enter",
            wait_for("No model is set up.", 10),
        ] + submit("/compact", "Nothing to compact") + submit("/cost", "Total cost:") + [
            READY,
            "type:/retry",
            "key:enter",
            # The note is already on screen once (under `hi`): settle instead.
            "sleep:3",
        ], term_size=(40, 180))
        a = TTYAssert(raw, rows=40, cols=180)
        screen = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
        assert "(template: .env.example)" in screen, screen
        # The refused prompt never joined the conversation.
        assert "Nothing to compact: 0 messages" in screen, screen
        # A local command answers as usual, and names no model while none is
        # set up; one that would ask the model gets the reminder.
        assert "Total cost:" in screen, screen
        assert "Model:       not set" in screen, screen
        echo = a.final.find_row("❯ /retry")
        if echo is None:
            a._fail("the /retry echo is missing")
        a.assert_line_contains(echo + 1, "⎿  No model is set up.")
        _assert_nothing_sent(case)
        assert case.session_entries() == []


def test_unbound_names_shell_keys_without_using_them(bin_path):
    # A vendor key only in the shell never selects its provider (#484 item 6):
    # the session stays unbound and the reminder names the variable, never its value.
    with _Case({"DEEPSEEK_API_KEY": PLACEHOLDER}) as case:
        case.bin = bin_path
        raw = case.run([READY, "type:hello", "key:enter", wait_for("Or use a key in your shell", 10)])
        a = TTYAssert(raw)
        a.assert_prose_contains(NOT_SET)
        screen = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
        assert "DEEPSEEK_API_KEY" in screen, screen
        assert "/model" in screen, screen
        assert PLACEHOLDER.encode() not in raw, "the key's value reached the terminal"
        _assert_nothing_sent(case)
        assert case.session_entries() == []


def test_incomplete_metask_login_opens_unbound(bin_path):
    # A Metask sign-in whose key and model were never chosen used to stop the
    # start (`Metask login is incomplete`); the TUI now opens unbound.
    with _Case() as case:
        case.bin = bin_path
        os.makedirs(case.state, exist_ok=True)
        auth = os.path.join(case.state, "auth.json")
        with open(auth, "w") as f:
            json.dump({"oauth": {"access_token": "at-never-sent", "refresh_token": "rt-never-sent",
                                 "token_type": "Bearer", "expires_at": int(time.time()) + 86400}}, f)
        os.chmod(auth, 0o600)
        raw = case.run([READY, "type:hi", "key:enter", wait_for("Metask sign-in has no API key", 10)])
        a = TTYAssert(raw)
        a.assert_prose_contains(NOT_SET)
        a.assert_box_present()
        assert b"at-never-sent" not in raw
        _assert_nothing_sent(case)
        assert case.session_entries() == []
