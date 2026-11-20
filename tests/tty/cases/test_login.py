"""/login (issue #33, #485), aligned with Claude Code 2.1.278's Login dialog.

`/login` alone opens the Metask browser sign-in in a bottom pane (#485; the
whole flow against a stand-in is tests/tty/cases/test_login_logout.py); Esc
leaves `⎿  Login interrupted · nothing was changed` under the echo. A provider
name starts that provider's sign-in directly; a typo'd flag fails closed
before anything starts. The provider flows need an authorization server: the
kernel flows are covered against mock servers by
tests/component/provider_oauth_login_test.zig, and the dialog's states by the
unit tests in src/repl/dialogs.zig. ChatGPT (Codex)'s sign-in is followed here
up to the URL it would open: its registered port, its parameters and its
notice; Esc ends it before anything is sent.
"""
import re
import socket

from tty_driver import run, runs_alone, submit, READY, wait_for
from asserts import TTYAssert
from e2e_helpers import SkipTest


def test_login_opens_the_metask_sign_in_and_esc_interrupts(bin_path):
    raw = run(bin_path, [READY, "type:/login", "key:enter", wait_for("Sign in to Metask", 10),
                         "key:esc", wait_for("Login interrupted", 10)], term_size=(30, 120))
    # The authorize URL is longer than a row: the terminal wraps it.
    a = TTYAssert(raw, rows=30, cols=120, autowrap=True)
    if not a.screens_with("Open this URL to authenticate"):
        a._fail("the pane should show the URL to open")
    # The other providers are still one command away.
    if not a.screens_with("/login <provider>"):
        a._fail("the pane should say how to sign in to another provider")
    echo = a.final.find_row("❯ /login")
    if echo is None:
        a._fail("the /login echo is missing")
    a.assert_line_contains(echo + 1, "⎿  Login interrupted · nothing was changed")
    if a.final.find_row("Sign in to Metask") is not None:
        a._fail("the Login pane should be erased after Esc")
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_login_unknown_flag_fails_closed(bin_path):
    # 与 CLI 一致:`--device-cod` 这类 typo 不能静默丢掉后启动一个用户没要的流程。
    raw = run(bin_path, submit("/login relay --device-cod", "Usage: /login"))
    a = TTYAssert(raw)
    a.assert_prose_contains("Unknown /login argument '--device-cod'")
    a.assert_prose_contains("Usage: /login")
    assert b"Select a provider" not in raw, "a refused /login must not open the dialog"


def test_login_unknown_provider(bin_path):
    raw = run(bin_path, submit("/login nosuch", "Unknown provider"))
    a = TTYAssert(raw)
    a.assert_prose_contains("Unknown provider 'nosuch'")
    assert b"Select a provider" not in raw


_ANSI = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]|\x1b[=>78]")
_CODEX_PARAMS = ("id_token_add_organizations=true", "codex_cli_simplified_flow=true", "originator=metacodes")
_CODEX_NOTICE = "ChatGPT (Codex): This sign-in is unofficial and may stop working at any time."
# Every browser sign-in waits on 1455 first, then 1457 (src/core/auth.zig); Codex's
# client registered those two only. A sign-in running beside these cases would take
# the port they assert on, so `run_tty_tests.py --jobs` runs them alone.
_CALLBACK_PORTS = "the fixed OAuth callback ports 1455 and 1457"


def _hold(port):
    """A listener on 127.0.0.1:`port`, or None when something else has it."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", port))
    except OSError:
        sock.close()
        return None
    sock.listen(1)
    return sock


def _codex_sign_in(bin_path):
    """`/login chatgpt-codex` up to its authorize URL, then Esc. `--no-browser`:
    nothing opens on any platform; the URL is in the pane."""
    raw = run(bin_path, [READY, "type:/login chatgpt-codex --no-browser", "key:enter",
                         wait_for("Waiting for the login callback", 15), "sleep:0.5",
                         "key:esc", wait_for("Login interrupted", 10)], term_size=(30, 200))
    text = _ANSI.sub(b"", raw).decode("utf-8", "replace")
    urls = re.findall(r"https://auth\.openai\.com/oauth/authorize\?\S+", text)
    assert urls, text[-2000:]
    return text, urls[-1]


@runs_alone(_CALLBACK_PORTS)
def test_login_chatgpt_codex_waits_on_its_registered_port_with_the_codex_parameters(bin_path):
    # The dialog signs in on a worker thread, from the worker's copy of the
    # profile (src/api/login_worker.zig). A copy that dropped the fields added
    # after it was written sent the browser to port 1456 without the Codex
    # client's parameters, and never said the sign-in is unofficial (#550).
    free = _hold(1455)
    if free is None:
        raise SkipTest("port 1455 is in use on this machine")
    free.close()
    text, url = _codex_sign_in(bin_path)
    assert _CODEX_NOTICE in text, text[-2000:]
    assert "Waiting for the login callback on http://localhost:1455." in text, text[-2000:]
    assert "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&" in url, url
    for param in _CODEX_PARAMS:
        assert param in url, f"{param} not in {url}"


@runs_alone(_CALLBACK_PORTS)
def test_login_chatgpt_codex_takes_1457_when_1455_is_held_and_sends_it_nothing(bin_path):
    # The client registered 1455 and 1457 only: with 1455 held the sign-in
    # waits on 1457, and whatever holds 1455 (another sign-in, perhaps) is
    # not connected to.
    holder = _hold(1455)
    if holder is None:
        raise SkipTest("port 1455 is in use on this machine")
    try:
        free = _hold(1457)
        if free is None:
            raise SkipTest("port 1457 is in use on this machine")
        free.close()
        text, url = _codex_sign_in(bin_path)
        holder.setblocking(False)
        try:
            conn, _ = holder.accept()
        except BlockingIOError:
            conn = None
        if conn is not None:
            conn.close()
            raise AssertionError("the sign-in connected to what holds 1455")
    finally:
        holder.close()
    assert _CODEX_NOTICE in text, text[-2000:]
    assert "Waiting for the login callback on http://localhost:1457." in text, text[-2000:]
    assert "redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback&" in url, url
    for param in _CODEX_PARAMS:
        assert param in url, f"{param} not in {url}"
