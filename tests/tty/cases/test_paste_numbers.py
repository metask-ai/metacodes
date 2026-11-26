import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import IDLE, READY, case_tmpdir, run, wait_for
from asserts import AssertError, TTYAssert
from slow_mock_server import SlowMockServer, simple_text

FIRST_PASTE = [f"FIRST_SESSION_LINE_{i}" for i in range(5)]
SECOND_PASTE = [f"SECOND_SESSION_LINE_{i}" for i in range(6)]


def _paste(lines):
    return "raw:\\x1b[200~" + "\\x0d".join(lines) + "\\x1b[201~"


def _shared_state():
    return {"extra_args": ["--state-dir", case_tmpdir("cc-tty-paste-state-")],
            "cwd": case_tmpdir("cc-tty-paste-work-"), "per_key_drain": 0.05}


def _last_user_text(body):
    users = [m for m in json.loads(body)["messages"] if m.get("role") == "user"]
    content = users[-1].get("content", "") if users else ""
    if isinstance(content, list):
        content = "".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return content


def _carries(text):
    first, second = "\n".join(FIRST_PASTE) in text, "\n".join(SECOND_PASTE) in text
    if first and not second:
        return "first"
    if second and not first:
        return "second"
    return repr(text)


def _shown(a, text):
    return any(sc.find_row(text) is not None for sc in a.frame_screens + [a.final])


def test_a_long_paste_sent_from_another_session_does_not_replace_one_waiting_in_the_box(bin_path):
    shared = _shared_state()
    second = {}
    with SlowMockServer([simple_text("SECOND_SESSION_REPLY"), simple_text("FIRST_SESSION_REPLY")]) as srv:
        def first_session():
            yield READY
            yield _paste(FIRST_PASTE)
            yield wait_for("[Pasted text #", 10)
            second["raw"] = run(bin_path, [READY, _paste(SECOND_PASTE), wait_for("[Pasted text #", 10), "key:enter",
                                           wait_for("SECOND_SESSION_REPLY", 15), IDLE],
                                base_url=srv.url, **shared)
            yield "key:enter"
            yield wait_for("FIRST_SESSION_REPLY", 15)
            yield IDLE

        first = TTYAssert(run(bin_path, first_session(), base_url=srv.url, **shared))
        requests = list(srv.requests)
    second_screen = TTYAssert(second["raw"])
    if not _shown(first, "[Pasted text #1 +4 lines]"):
        first._fail("the first session did not hold its paste as [Pasted text #1 +4 lines]")
    if not _shown(second_screen, "[Pasted text #2 +5 lines]"):
        second_screen._fail("the second session's paste did not take the next number while #1 waited in "
                            "the first session's box")
    if len(requests) != 2:
        raise AssertError(f"expected one request from each session, got {len(requests)}")
    sent_second, sent_first = _carries(_last_user_text(requests[0])), _carries(_last_user_text(requests[1]))
    if sent_second != "second":
        second_screen._fail(f"the second session sent {sent_second} instead of its own paste")
    if sent_first != "first":
        first._fail(f"the first session sent {sent_first} instead of the paste in its box")


def test_a_long_paste_recalled_from_an_earlier_session_sends_that_sessions_text(bin_path):
    shared = _shared_state()
    with SlowMockServer([simple_text("FIRST_REPLY"), simple_text("SECOND_REPLY"),
                         simple_text("RECALLED_REPLY")]) as srv:
        run(bin_path, [READY, _paste(FIRST_PASTE), wait_for("[Pasted text #1 +4 lines]", 10), "key:enter",
                       wait_for("FIRST_REPLY", 15), IDLE, "type:/exit", "key:enter", "sleep:3"],
            base_url=srv.url, **shared)
        a = TTYAssert(run(bin_path, [READY, _paste(SECOND_PASTE), wait_for("[Pasted text #", 10), "key:enter",
                                     wait_for("SECOND_REPLY", 15), IDLE, "key:up", "key:up",
                                     wait_for("[Pasted text #1 +4 lines]", 5), "key:enter",
                                     wait_for("RECALLED_REPLY", 15), IDLE],
                              base_url=srv.url, **shared))
        requests = list(srv.requests)
    if len(requests) != 3:
        a._fail(f"expected the first session's message, the second's and the recalled one, got {len(requests)}")
    if _carries(_last_user_text(requests[1])) != "second":
        a._fail(f"the second session's own paste sent {_carries(_last_user_text(requests[1]))}")
    recalled = _carries(_last_user_text(requests[2]))
    if recalled != "first":
        a._fail(f"[Pasted text #1 +4 lines] recalled from the first session sent {recalled} "
                "instead of the first session's paste")
