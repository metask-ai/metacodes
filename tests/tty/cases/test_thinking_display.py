import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from screen import Screen  # noqa: E402
from slow_mock_server import SlowMockServer, _json_str  # noqa: E402
from tty_driver import IDLE, READY, run, wait_for  # noqa: E402

ROWS, COLS = 30, 100
SUMMARY = "✻ Thought for "
THOUGHTS = ["weighing the parser first", "then the tail that is cut", "and a third idea", "settling on the fix"]
START = b'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
END_TURN = (b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}\n\n'
            b'data: {"type":"message_stop"}\n\n')
READ_CALL = (b'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"Read","input":{}}}\n\n'
             + ('data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":%s}}\n\n'
                % _json_str('{"file_path":"/definitely/not/there.txt"}')).encode()
             + b'data: {"type":"content_block_stop","index":1}\n\n'
             + b'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}\n\n'
             + b'data: {"type":"message_stop"}\n\n')
BROKEN = b'data: {"type":"error","error":{"type":"overloaded_error","message":"boom"}}\n\n'


def _thinking(thoughts, delay, index=0, close=True):
    parts = [('data: {"type":"content_block_start","index":%d,"content_block":{"type":"thinking","thinking":""}}\n\n'
              % index).encode()]
    for thought in thoughts:
        parts.append(b"__DELAY__%f\n" % delay)
        parts.append(('data: {"type":"content_block_delta","index":%d,"delta":{"type":"thinking_delta","thinking":%s}}\n\n'
                      % (index, _json_str(thought + "\n"))).encode())
    if close:
        parts.append(('data: {"type":"content_block_stop","index":%d}\n\n' % index).encode())
    return b"".join(parts)


def _answer(text, index=1):
    return (('data: {"type":"content_block_start","index":%d,"content_block":{"type":"text","text":""}}\n\n' % index).encode()
            + ('data: {"type":"content_block_delta","index":%d,"delta":{"type":"text_delta","text":%s}}\n\n'
               % (index, _json_str(text))).encode()
            + ('data: {"type":"content_block_stop","index":%d}\n\n' % index).encode())


def _shown(raw):
    sc = Screen(ROWS, COLS, autowrap=True)
    sc.feed(raw)
    history = ["".join(c.ch for c in cells if not c.cont).rstrip() for cells, _ in sc.history]
    return history + sc.lines()


def _ask(bin_path, turns, events):
    with SlowMockServer(turns) as srv:
        return run(bin_path, [READY, "type:go", "key:enter", *events],
                   base_url=srv.url, startup_drain=0.8, per_key_drain=0.06, term_size=(ROWS, COLS))


def _summaries(shown):
    return [i for i, line in enumerate(shown) if line.startswith(SUMMARY)]


def _assert_thinking_gone(shown, thoughts):
    for thought in thoughts:
        assert not any(thought in line for line in shown), \
            f"the thinking {thought!r} stayed on the screen:\n" + "\n".join(shown)


def test_thinking_scrolls_in_the_live_area_then_folds_into_one_summary_line(bin_path):
    turn = START + _thinking(THOUGHTS, 0.3) + b"__DELAY__0.3\n" + _answer("The fix is in.") + END_TURN
    raw = _ask(bin_path, [turn], [wait_for("The fix is in.", 15), IDLE])
    assert THOUGHTS[-1].encode() in raw, "the thinking never showed while it streamed"
    shown = _shown(raw)
    summaries = _summaries(shown)
    assert len(summaries) == 1, "expected one summary line:\n" + "\n".join(shown)
    answer = next(i for i, line in enumerate(shown) if line.startswith("⏺ The fix is in."))
    assert summaries[0] < answer, "the summary should come before the answer:\n" + "\n".join(shown)
    _assert_thinking_gone(shown, THOUGHTS)


def test_the_transcript_view_shows_the_whole_thinking(bin_path):
    turn = START + _thinking(THOUGHTS, 0.05) + _answer("The fix is in.") + END_TURN
    raw = _ask(bin_path, [turn], [wait_for("The fix is in.", 15), IDLE,
                                 "key:ctrl_x", "key:ctrl_o", wait_for("Showing detailed transcript", 5)])
    viewer = raw[raw.rfind(b"\x1b[?1049h"):]
    for thought in THOUGHTS:
        assert thought.encode() in viewer, f"the transcript view is missing the thinking line {thought!r}"


def test_thinking_a_tool_call_and_thinking_again_leave_one_summary_each(bin_path):
    first = START + _thinking(["look before touching"], 0.2) + READ_CALL
    second = START + _thinking(["now the second look"], 0.2) + _answer("All done.") + END_TURN
    raw = _ask(bin_path, [first, second], [wait_for("All done.", 15), IDLE])
    shown = _shown(raw)
    summaries = _summaries(shown)
    assert len(summaries) == 2, "expected two summary lines:\n" + "\n".join(shown)
    tool = next(i for i, line in enumerate(shown) if "Read" in line and i > summaries[0])
    answer = next(i for i, line in enumerate(shown) if line.startswith("⏺ All done."))
    assert summaries[0] < tool < summaries[1] < answer, "\n".join(shown)
    _assert_thinking_gone(shown, ["look before touching", "now the second look"])


def test_a_reply_that_only_thinks_keeps_its_summary_line(bin_path):
    turn = START + _thinking(["nothing to say yet"], 0.2) + END_TURN
    raw = _ask(bin_path, [turn], [wait_for(SUMMARY, 15), IDLE])
    shown = _shown(raw)
    assert len(_summaries(shown)) == 1, "\n".join(shown)
    _assert_thinking_gone(shown, ["nothing to say yet"])


def test_a_reply_broken_off_while_thinking_shows_its_summary_the_notice_and_the_retry(bin_path):
    broken = START + _thinking(["halfway through a thought"], 0.2, close=False) + BROKEN
    good = START + _thinking(["a whole thought"], 0.2) + _answer("clean answer") + END_TURN
    raw = _ask(bin_path, [broken, good], [wait_for("clean answer", 20), IDLE])
    shown = _shown(raw)
    summaries = _summaries(shown)
    assert len(summaries) == 2, "expected a summary for each attempt:\n" + "\n".join(shown)
    notice = next(i for i, line in enumerate(shown) if "The reply above broke off" in line)
    answer = next(i for i, line in enumerate(shown) if line.startswith("⏺ clean answer"))
    assert summaries[0] < notice < summaries[1] < answer, "\n".join(shown)
    _assert_thinking_gone(shown, ["halfway through a thought", "a whole thought"])


def test_an_answer_line_without_a_newline_stays_above_the_summary_of_the_thinking_after_it(bin_path):
    turn = (START + _answer("Let me check", index=0) + _thinking(["weighing the parser"], 0.2, index=1)
            + _answer("Then the file.", index=2) + END_TURN)
    raw = _ask(bin_path, [turn], [wait_for("Then the file.", 15), IDLE])
    shown = _shown(raw)
    earlier = next(i for i, line in enumerate(shown) if line.startswith("⏺ Let me check"))
    summaries = _summaries(shown)
    later = next(i for i, line in enumerate(shown) if line.strip() == "Then the file.")
    assert len(summaries) == 1 and earlier < summaries[0] < later, "\n".join(shown)
    _assert_thinking_gone(shown, ["weighing the parser"])
