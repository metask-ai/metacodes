"""Real binary, offline mock: what a streamed reply leaves on a real terminal (#319, #318).

The component tests (apps/cli/tests/component/render_region_contract_test.zig,
md_stream_convergence_test.zig) found two bugs by replaying RenderRegion
through a virtual terminal. These cases check the fixes end to end, through
the binary, a pty and the mock SSE server.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from screen import Screen  # noqa: E402
from slow_mock_server import SlowMockServer, _json_str  # noqa: E402
from tty_driver import run  # noqa: E402


def _streamed_turn(chunks, delay):
    """One text block streamed as `chunks`, `delay` seconds apart (spinner ticks redraw between them)."""
    parts = [
        b'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n',
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
    ]
    for chunk in chunks:
        parts.append(b"__DELAY__%f\n" % delay)
        parts.append(('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":%s}}\n\n'
                      % _json_str(chunk)).encode())
    parts += [
        b'data: {"type":"content_block_stop","index":0}\n\n',
        b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}\n\n',
        b'data: {"type":"message_stop"}\n\n',
    ]
    return b"".join(parts)


def _is_region_row(text):
    t = text.strip()
    return "❯" in t or (len(t) >= 8 and set(t) == {"─"})


def test_narrow_terminal_footer_never_pushes_the_box_into_scrollback(bin_path):
    # 40 columns: the bypass-mode footer (` ⏵⏵ bypass permissions on (shift+tab to cycle) · esc to
    # interrupt`, 65 columns) used to wrap on a real (autowrapping) terminal. With the box at the
    # bottom, every redraw then pushed its spinner, border and prompt rows into the scrollback.
    rows, cols = 12, 40
    chunks = ["line %02d of the reply\nline %02d of the reply\n" % (2 * i, 2 * i + 1) for i in range(12)]
    with SlowMockServer([_streamed_turn(chunks, 0.25)]) as srv:
        raw = run(bin_path, ["sleep:0.8", "type:go", "key:enter", "sleep:5.0"],
                  base_url=srv.url, startup_drain=0.8, per_key_drain=0.06, term_size=(rows, cols))
    sc = Screen(rows, cols, autowrap=True)
    sc.feed(raw)
    history = ["".join(c.ch for c in cells if not c.cont).rstrip() for cells, _ in sc.history]
    leaked = [t for t in history if _is_region_row(t) and "❯ go" not in t]
    assert not leaked, "box rows reached the scrollback: %r\n--- scrollback tail ---\n%s" % (
        leaked[:4], "\n".join(history[-15:]))
    shown = history + sc.lines()
    for i in range(24):
        assert sum(1 for t in shown if t.endswith(" line %02d of the reply" % i)) == 1, \
            "reply line %d not shown exactly once:\n%s" % (i, "\n".join(shown[-30:]))


def _sgr_before(raw, token):
    """The last SGR sequence written before the first `token` that follows a ```python fence."""
    marker = raw.find(b"lambda_marker")
    assert marker >= 0, "the code block was not rendered"
    start = raw.find(token.encode(), marker + len(b"lambda_marker"))
    assert start >= 0, "token %r not in the output" % token
    sgrs = list(re.finditer(rb"\x1b\[[0-9;]*m", raw[:start]))
    assert sgrs, "no SGR before %r" % token
    return sgrs[-1].group(0)


def test_streamed_code_block_is_highlighted_for_its_fence_language(bin_path):
    # The fence line and the code line arrive in separate deltas, as a model streams them. The live
    # renderer used to read the language from a slice of its line buffer that had moved on, so
    # Python-only keywords (lambda) were left plain while common ones (return) were coloured.
    chunks = ["Here:\n", "```python\n", "lambda_marker = 1\n", "if f: return lambda y: y\n", "```\n", "Done.\n"]
    with SlowMockServer([_streamed_turn(chunks, 0.2)]) as srv:
        raw = run(bin_path, ["sleep:0.8", "type:code", "key:enter", "sleep:3.0"],
                  base_url=srv.url, startup_drain=0.8, per_key_drain=0.06, term_size=(24, 80))
    assert b"lambda_marker" in raw, "the reply was not rendered"
    assert _sgr_before(raw, "lambda") == _sgr_before(raw, "return"), \
        "lambda is not highlighted like return (fence language lost)"
