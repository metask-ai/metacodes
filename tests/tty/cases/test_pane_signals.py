import os

from tty_driver import IDLE, READY, case_tmpdir, run, wait_for
from asserts import TTYAssert
from e2e_helpers import SkipTest
from slow_mock_server import SlowMockServer, simple_text

HINT = "Resume this session with:"
ROWS, COLS = 30, 120


def _signal_with_the_pane_open(bin_path, command, pane_text, signals):
    if os.name == "nt":
        raise SkipTest("SIGHUP and SIGTERM are POSIX; a closed console reaches Windows through its own handler")
    with SlowMockServer([simple_text("SEEDED")]) as srv:
        raw = run(bin_path, [READY, "type:seed", "key:enter", wait_for("SEEDED"), IDLE,
                             f"type:{command}", "key:enter", wait_for(pane_text, 10),
                             f"signal:{signals}", wait_for(HINT, 8)],
                  term_size=(ROWS, COLS), env={"SSH_CONNECTION": None, "SSH_TTY": None},
                  cwd=case_tmpdir("cc-tty-pane-signal-cwd-"), base_url=srv.url)
    a = TTYAssert(raw, rows=ROWS, cols=COLS, autowrap=True)
    if not a.screens_with(pane_text):
        a._fail(f"{command} never showed its pane")
    if a.final.find_last_row(HINT) is None:
        a._fail(f"{signals} with the {command} pane open did not leave through the prompt's way out")
    if a.final.find_row(pane_text) is not None:
        a._fail(f"the {command} pane was left on the screen")
    return a


def test_sigterm_with_the_help_pane_open_leaves_at_once(bin_path):
    _signal_with_the_pane_open(bin_path, "/help", "Esc to close", "TERM")


def test_closing_the_terminal_with_the_skills_pane_open_leaves_at_once(bin_path):
    _signal_with_the_pane_open(bin_path, "/skills", "Search skills", "HUP+0.02+HUP")


def test_sigterm_during_the_metask_sign_in_interrupts_it_and_leaves_at_once(bin_path):
    a = _signal_with_the_pane_open(bin_path, "/login", "Sign in to Metask", "TERM")
    echo = a.final.find_row("❯ /login")
    if echo is None:
        a._fail("the /login echo is missing")
    a.assert_line_contains(echo + 1, "Login interrupted · nothing was changed")
