"""#328: generation redraws go through a ~16 ms merge window.

Event -> UiState dispatch stays synchronous; only the paint is scheduled. A
request with nothing painted in the last window paints at once; requests
inside the window share one frame at its end, drawing the state as it is then.
Submit, tool completion, interrupt and the phase/overlay boundaries paint at
once. These cases drive the real binary through busy streams from the local
slow mock server and check what the merge window must not break: every line
arrives, in order; the spinner keeps moving; typed keys all echo; a resize
leaves one box; an interrupt and an exit right after a stream are clean; a
WebSearch result line is painted before its card goes. Frame counts are only
asserted on POSIX: ConPTY re-encodes the stream, so its bytes are not ours.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import IDLE, IS_WINDOWS, READY, run, wait_for  # noqa: E402
from asserts import TTYAssert, split_frames  # noqa: E402

SYNC_BEGIN = b"\x1b[?2026h"
ANSI = re.compile(rb"\x1b\[[0-9;?>]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[78=>]")


def _sse(deltas, stop_reason="end_turn"):
    """One text block from `deltas` [(delay_seconds, text)], SlowMockServer bytes."""
    import json
    parts = [
        b'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n',
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
    ]
    for delay, text in deltas:
        if delay:
            parts.append(b"__DELAY__%f\n" % delay)
        parts.append(('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":%s}}\n\n'
                      % json.dumps(text)).encode())
    parts += [
        b'data: {"type":"content_block_stop","index":0}\n\n',
        ('data: {"type":"message_delta","delta":{"stop_reason":"%s"},"usage":{"output_tokens":5}}\n\n' % stop_reason).encode(),
        b'data: {"type":"message_stop"}\n\n',
    ]
    return b"".join(parts)


def burst_turn(n_deltas=40, lines_per_delta=4, delay=0.01, lead=0.4):
    """A fast model writing many short lines: `n_deltas` deltas of several lines each."""
    deltas = [(lead, "")]
    row = 0
    for _ in range(n_deltas):
        text = ""
        for _ in range(lines_per_delta):
            text += "row %03d of the burst\n" % row
            row += 1
        deltas.append((delay, text))
    return _sse(deltas), row


def _plain(raw):
    return ANSI.sub(b"", raw).decode("utf-8", "replace")


def _rows_in_order(raw, n):
    """Every `row NNN` line reached the terminal, each once in the scrollback, in order."""
    text = _plain(b"".join(c for k, c in split_frames(raw) if k == "prose"))
    at = 0
    for i in range(n):
        needle = "row %03d of the burst" % i
        idx = text.find(needle, at)
        if idx < 0:
            return f"{needle!r} missing (or out of order) in the scrollback"
        at = idx + len(needle)
    return None


def test_burst_stream_keeps_every_line_and_coalesces_frames(bin_path):
    from slow_mock_server import SlowMockServer

    turn, n = burst_turn()
    with SlowMockServer([turn]) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("row %03d of the burst" % (n - 1), 30),
                             "sleep:3", IDLE],
                  term_size=(30, 100), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05)
    problem = _rows_in_order(raw, n)
    assert problem is None, problem
    a = TTYAssert(raw, rows=30, cols=100)
    a.assert_single_box()
    if not IS_WINDOWS:
        # Before #328 every line was its own erase+print+redraw frame (>= n of them).
        # 160 lines inside ~0.4 s fit in a few dozen 16 ms windows.
        frames = raw.count(SYNC_BEGIN)
        assert frames < n // 2, f"{frames} synchronized frames for {n} streamed lines: the stream was not coalesced"


def test_spinner_keeps_moving_while_nothing_streams(bin_path):
    from slow_mock_server import SlowMockServer

    # 2 s before the first byte: only spinner ticks paint.
    with SlowMockServer([_sse([(2.0, "after the wait\n")])]) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("after the wait", 20), "sleep:2", IDLE],
                  term_size=(24, 80), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05)
    a = TTYAssert(raw)
    shown = [s for s in a.frame_screens if "esc to interrupt" in "\n".join(s.line_text(r) for r in range(s.rows))]
    assert shown, "the spinner never showed during the wait"
    if not IS_WINDOWS:
        frames = [c for k, c in split_frames(raw) if k == "frame" and b"esc to interrupt" in c]
        # ~10 ticks a second for ~2 s; a stalled timer or a swallowed tick shows as a handful.
        assert len(frames) >= 10, f"only {len(frames)} spinner frames in a 2 s wait"
        assert len(set(frames)) >= 5, "the spinner frames did not change: the spinner is not animating"


def test_typing_during_a_reply_echoes_every_key(bin_path):
    from slow_mock_server import SlowMockServer, slow_text_then_end

    # A paste / IME commit / key-repeat burst: the keys arrive in one write, so
    # they share frames; then single keys, each waiting for its own echo.
    burst = "the quick brown fox jumps over the lazy dog 0123456789"
    tail = " end"
    with SlowMockServer([slow_text_then_end(n_chunks=20, delay=0.25)]) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("esc to interrupt"),
                             "raw:" + burst, wait_for("❯ " + burst, 10),
                             "type:" + tail, wait_for("❯ " + burst + tail, 10)],
                  term_size=(24, 100), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05)
    a = TTYAssert(raw, rows=24, cols=100)
    seen = [s for s in a.frame_screens if any(("❯ " + burst + tail) in s.line_text(r) for r in range(s.rows))]
    assert seen, "the last typed key never reached the generating input box"
    if not IS_WINDOWS:
        # Before #328 each of the burst's keys was its own frame.
        start = raw.find(b"esc to interrupt")
        frames = raw[start:raw.find(burst[-10:].encode(), start) + 10].count(SYNC_BEGIN)
        assert frames < len(burst) // 2, f"{frames} frames to echo a {len(burst)}-key burst"


def test_resize_during_a_burst_leaves_one_box(bin_path):
    from slow_mock_server import SlowMockServer

    turn, n = burst_turn(n_deltas=60, lines_per_delta=2, delay=0.02)
    resizes = []
    with SlowMockServer([turn]) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("row 010 of the burst", 20),
                             "resize:24x60", wait_for("row %03d of the burst" % (n - 1), 30), IDLE],
                  term_size=(24, 80), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05,
                  resizes=resizes)
    problem = _rows_in_order(raw, n)
    assert problem is None, problem
    a = TTYAssert(raw, resizes=resizes)
    a.assert_single_box()


def test_interrupt_during_a_burst_returns_the_prompt(bin_path):
    from slow_mock_server import SlowMockServer

    turn, _ = burst_turn(n_deltas=200, lines_per_delta=1, delay=0.03)
    with SlowMockServer([turn]) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("row 020 of the burst", 20),
                             "key:esc", "sleep:3", IDLE],
                  term_size=(24, 80), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05)
    a = TTYAssert(raw)
    text = "\n".join(a.final.line_text(r) for r in range(a.rows))
    assert "row 199 of the burst" not in _plain(raw), "the reply was not interrupted"
    # What streamed before the interrupt is all there, in order.
    last = max(int(m) for m in re.findall(r"row (\d{3}) of the burst", _plain(raw)))
    problem = _rows_in_order(raw, last + 1)
    assert problem is None, problem
    a.assert_single_box()
    assert "esc to interrupt" not in text, "the generating region was left on screen:\n" + text


def test_exit_right_after_a_burst_is_clean(bin_path):
    from slow_mock_server import SlowMockServer

    turn, n = burst_turn(n_deltas=20, lines_per_delta=4, delay=0.005)
    with SlowMockServer([turn]) as srv:
        raw = run(bin_path, [READY, "type:go", "key:enter", wait_for("row %03d of the burst" % (n - 1), 20),
                             IDLE, "type:/exit", "key:enter", "sleep:3"],
                  term_size=(24, 80), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05)
    problem = _rows_in_order(raw, n)
    assert problem is None, problem
    TTYAssert(raw).assert_clean_exit()


def _websearch_query_then_result_at_once(lead=0.8):
    """The WebSearch sub-request with everything after `lead` in one write: the
    query (`Searching: …`, sent when the server_tool_use block ends), the
    result (`Found 1 result`), and the rest of the stream, whose end completes
    the tool and takes the card away.

    The two progress updates come microseconds apart, so the result always
    lands inside a merge window: the one the query's frame opened, or one
    already pending that the query joined. Either way `Found 1 result` is
    waiting when the card goes, and only the frame `clearToolCard` paints
    before removing the card shows it."""
    return (
        b'data: {"type":"message_start","message":{"id":"ws","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        + b'__DELAY__%f\n' % lead
        + b'data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srv_1","name":"web_search","input":{}}}\n\n'
        b'data: {"type":"content_block_stop","index":0}\n\n'
        b'data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srv_1","content":[{"type":"web_search_result","title":"Merge","url":"https://example.com"}]}}\n\n'
        b'data: {"type":"content_block_stop","index":1}\n\n'
        b'data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}\n\n'
        b'data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"merge summary."}}\n\n'
        b'data: {"type":"content_block_stop","index":2}\n\n'
        b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}\n\n'
        b'data: {"type":"message_stop"}\n\n'
    )


def test_websearch_result_line_is_painted_before_its_card_goes(bin_path):
    # 9016b64a: the result arrives at the end of the sub-request and the card
    # leaves right after it. The merge window may drop the superseded query
    # line, never the result line.
    from slow_mock_server import SlowMockServer, slow_text_then_tooluse, simple_text

    turns = [
        slow_text_then_tooluse(n_chunks=2, delay=0.2, tool="WebSearch", tool_input='{"query":"merge window"}'),
        _websearch_query_then_result_at_once(),
        simple_text("search summarized."),
    ]
    with SlowMockServer(turns) as srv:
        raw = run(bin_path, [READY, "type:search", "key:enter", wait_for("search summarized", 30), "sleep:2", IDLE],
                  term_size=(24, 80), base_url=srv.url, startup_drain=0.8, per_key_drain=0.05)
    a = TTYAssert(raw)
    found = [s for s in a.frame_screens
             if any("Found 1 result" in s.line_text(r) for r in range(s.rows))]
    assert found, "the WebSearch result line never reached the screen before the card went"
    a.assert_single_box()
