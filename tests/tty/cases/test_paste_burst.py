import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import READY, run, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from slow_mock_server import SlowMockServer, simple_text  # noqa: E402

REPLY = "BURST_REPLY"


def _raw(data):
    return "raw:" + "".join("\\x%02x" % c for c in data)


def _run(bin_path, keys):
    with SlowMockServer([simple_text(REPLY)]) as srv:
        raw = run(bin_path, [READY] + keys, base_url=srv.url, per_key_drain=0.05)
        requests = list(srv.requests)
    return TTYAssert(raw), requests


def _last_user_text(request_body):
    for message in reversed(json.loads(request_body)["messages"]):
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            return content
        texts = [block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"]
        return texts[-1] if texts else ""
    return ""


def _box_rows(a):
    top, bottom = a.box_top_row(), a.box_bottom_row()
    if top is None or bottom is None:
        return None
    return [a.final.line_text(r).strip() for r in range(top + 1, bottom)]


def test_a_multiline_paste_without_markers_waits_for_enter(bin_path):
    a, requests = _run(bin_path, [_raw(b"FIRST_LINE\rSECOND_LINE\rTHIRD_LINE"), "strictsleep:1.0"])
    if requests:
        a._fail(f"the paste was sent before Enter: {[_last_user_text(body) for body in requests]}")
    if _box_rows(a) != ["❯ FIRST_LINE", "SECOND_LINE", "THIRD_LINE"]:
        a._fail(f"the box does not hold the three lines: {_box_rows(a)}")


def test_enter_after_a_paste_without_markers_sends_it_as_one_message(bin_path):
    a, requests = _run(bin_path, [_raw(b"FIRST_LINE\r\nSECOND_LINE\r"), "strictsleep:0.5", "key:enter",
                                  wait_for(REPLY), "strictsleep:0.5"])
    texts = [_last_user_text(body) for body in requests]
    if len(texts) != 1 or "FIRST_LINE\nSECOND_LINE" not in texts[0] or "SECOND_LINE\n\n" in texts[0]:
        a._fail(f"expected one message holding both lines once each: {texts}")


def test_a_line_written_together_with_its_enter_is_sent(bin_path):
    a, requests = _run(bin_path, [_raw(b"ONE_LINE_AND_ENTER\r"), wait_for(REPLY), "strictsleep:0.5"])
    texts = [_last_user_text(body) for body in requests]
    if len(texts) != 1 or texts[0].strip() != "ONE_LINE_AND_ENTER":
        a._fail(f"a line written with its Enter, as tmux send-keys writes it, was not sent: {texts}")


def test_enter_150ms_after_an_ime_commit_still_submits(bin_path):
    a, requests = _run(bin_path, [_raw("你好世界".encode("utf-8")), "strictsleep:0.15", _raw(b"\r"),
                                  wait_for(REPLY), "strictsleep:0.5"])
    texts = [_last_user_text(body) for body in requests]
    if len(texts) != 1 or texts[0].strip() != "你好世界":
        a._fail(f"the committed text was not sent by Enter: {texts}")


def test_a_bracketed_paste_keeps_its_line_breaks_and_enter_sends_it(bin_path):
    a, requests = _run(bin_path, ["raw:\\x1b[200~MARKED_ONE\\x0dMARKED_TWO\\x1b[201~", "strictsleep:0.5", "key:enter",
                                  wait_for(REPLY), "strictsleep:0.5"])
    texts = [_last_user_text(body) for body in requests]
    if len(texts) != 1 or "MARKED_ONE\nMARKED_TWO" not in texts[0]:
        a._fail(f"expected the bracketed paste as one two-line message: {texts}")
