"""/login (issue #33, #485), aligned with Claude Code 2.1.278's Login dialog.

`/login` alone opens the Metask browser sign-in in a bottom pane (#485; the
whole flow against a stand-in is tests/tty/cases/test_login_logout.py); Esc
leaves `⎿  Login interrupted · nothing was changed` under the echo. A provider
name starts that provider's sign-in directly; a typo'd flag fails closed
before anything starts. The provider flows need an authorization server: the
kernel flows are covered against mock servers by
tests/component/provider_oauth_login_test.zig, and the dialog's states by the
unit tests in src/repl/dialogs.zig.
"""
from tty_driver import run, submit, READY, wait_for
from asserts import TTYAssert


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
