"""The last line of a failed request says what to do when a retry cannot help.

A rejected sign-in or key, or a balance that ran out, used to end with the advice every failure
got, `Retry with /retry, …`. It now says what helps (src/repl/next_step.zig); every other failure
keeps that advice. Offline: the slow mock server answers the one request with the error.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from asserts import TTYAssert  # noqa: E402
from slow_mock_server import HttpError, SlowMockServer  # noqa: E402
from tty_driver import READY, case_tmpdir, run, wait_for  # noqa: E402

# Wide enough that the line naming a temporary state root does not wrap.
ROWS, COLS = 30, 220

REJECTED = HttpError(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
NO_BALANCE = HttpError(402, {"error": "insufficient_balance", "message": "Your balance is insufficient. Please top up."})
BAD_REQUEST = HttpError(400, {"type": "error", "error": {"type": "invalid_request_error", "message": "max_tokens is too large"}})
RETRY_ADVICE = "Retry with /retry, or switch models or compact the context first."


def _failed_turn(bin_path, answer, last_line, env=None, extra_args=None, origin_only=False):
    """Submit `hi` and have the server answer `answer`. Returns the screen once `last_line`
    is on it, and the requests the server saw."""
    with SlowMockServer([answer]) as srv:
        raw = run(
            bin_path,
            [READY, "type:hi", "key:enter", wait_for(last_line)],
            term_size=(ROWS, COLS),
            # Another provider's route appends its own path to an origin.
            base_url="http://127.0.0.1:%d" % srv.port if origin_only else srv.url,
            env=env,
            extra_args=extra_args,
        )
        requests = list(srv.requests)
    a = TTYAssert(raw, rows=ROWS, cols=COLS)
    return "\n".join(a.final.line_text(r) for r in range(a.final.rows)), requests


def _expect_last_line(screen, requests, last_line):
    assert len(requests) == 1, "expected one request, the server saw %d:\n%s" % (len(requests), screen)
    lines = [line.strip() for line in screen.split("\n")]
    assert "API request failed; the turn stopped." in lines, "no failure notice:\n" + screen
    notice = lines.index("API request failed; the turn stopped.")
    # The notice, the raw error, then the next step.
    assert lines[notice + 2] == last_line, "expected the next step %r after the error:\n%s" % (last_line, screen)
    assert "/retry" not in screen, "a retry cannot help here, yet /retry is suggested:\n" + screen


def test_rejected_metask_sign_in_says_sign_in_again(bin_path):
    last_line = "Your Metask sign-in is no longer valid. Sign in again: /login"
    screen, requests = _failed_turn(bin_path, REJECTED, last_line)
    _expect_last_line(screen, requests, last_line)


def test_used_up_metask_balance_says_top_up_or_switch(bin_path):
    last_line = "Your Metask balance has run out. Top up your Metask account, or switch provider: /model"
    screen, requests = _failed_turn(bin_path, NO_BALANCE, last_line)
    _expect_last_line(screen, requests, last_line)


def test_rejected_provider_key_names_its_variable_and_the_install_env_file(bin_path):
    state = case_tmpdir("cc-tty-next-step-")
    last_line = "DeepSeek rejected the API key. Check DEEPSEEK_API_KEY in %s or your shell, then restart." % (
        os.path.join(state, ".env"))
    screen, requests = _failed_turn(
        bin_path,
        REJECTED,
        last_line,
        # DeepSeek's key only: no Metask key reaches this session.
        env={"METACODES_HOME": state, "METASK_API_KEY": None, "DEEPSEEK_API_KEY": "tty-dummy-deepseek-key"},
        extra_args=["--provider", "deepseek"],
        origin_only=True,
    )
    _expect_last_line(screen, requests, last_line)
    assert "tty-dummy-deepseek-key" not in screen, "the key itself reached the screen:\n" + screen


def test_other_failures_keep_the_retry_advice(bin_path):
    screen, requests = _failed_turn(bin_path, BAD_REQUEST, RETRY_ADVICE)
    assert len(requests) == 1, "expected one request, the server saw %d:\n%s" % (len(requests), screen)
    lines = [line.strip() for line in screen.split("\n")]
    assert "API request failed; the turn stopped." in lines, "no failure notice:\n" + screen
    assert lines[lines.index("API request failed; the turn stopped.") + 2] == RETRY_ADVICE, screen
