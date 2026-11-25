"""Golden vectors that pin apps/cli/tests/component/vterm.zig to screen.py (#319).

screen.py is the pty suite's terminal model; apps/cli/tests/component/vterm.zig is its
Zig port for component tests. This module replays a fixed corpus of byte
streams through screen.py — hand-picked semantic cases (several ported from
cases/test_autowrap_align.py, test_sgr_color.py and test_screen_resize.py)
plus a seeded random corpus — and records screen.py's complete state after
each. apps/cli/tests/component/vterm_test.zig replays the same operations through the
Zig port and must reach the same state; cases/test_vterm_parity.py fails when
screen.py's answers drift from the committed fixture.

After changing screen.py on purpose, regenerate and commit the fixture:

    python tests/tty/vterm_parity.py --write

The random corpus avoids two spots where the ports differ on purpose:
screen.py raises IndexError on EL 1 / ED 1 with the cursor parked past the
last column (the Zig port clamps), and its `line_text` strips every Unicode
whitespace character where the Zig port strips U+0020 only.
"""

import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from screen import Screen  # noqa: E402

FIXTURE = os.path.join(HERE, "..", "fixtures", "vterm", "screen_parity.jsonl")
SEED = 319
RANDOM_CASES = 80

_CLASS = {"plain": "p", "dim": "d", "accent": "a", "warn": "w", "danger": "x"}


def _cell(c):
    """One cell as `<ch><kind><class><written>`: kind 1/2 = width, c = continuation."""
    kind = "c" if c.cont else str(c.width)
    return c.ch + kind + _CLASS[c.border_class] + ("w" if c.written else "-")


def snapshot(sc):
    return {
        "lines": sc.lines(),
        "cursor": [sc.row, sc.col],
        "cursor_visible": sc.cursor_visible,
        "pending_wrap": sc._pending_wrap,
        "saved_cursor": [sc._saved_row, sc._saved_col],
        "scrolled": sc.scrolled,
        "sync_depth": sc.sync_depth,
        "max_sync_depth": sc.max_sync_depth,
        "alt": getattr(sc, "_alt_saved", None) is not None,
        "pending_bytes": sc._buf.hex(),
        "classes": [sc.line_attr_class(r) for r in range(sc.rows)],
        "grid": [[_cell(c) for c in row] for row in sc.grid],
        "wrapped": list(sc.wrapped),
        "history": [[_cell(c) for c in cells] for cells, _ in sc.history],
        "history_wrapped": [w for _, w in sc.history],
    }


def replay(case):
    sc = Screen(case["rows"], case["cols"], autowrap=case["autowrap"])
    for op in case["ops"]:
        if op[0] == "feed":
            sc.feed(op[1])
        else:
            sc.resize(op[1], op[2], reflow=op[3])
    return sc


def _case(name, ops, rows=6, cols=12, autowrap=False):
    if isinstance(ops, bytes):
        ops = [("feed", ops)]
    return {"name": name, "rows": rows, "cols": cols, "autowrap": autowrap, "ops": ops}


def hand_cases():
    E = b"\x1b"
    full = b"abcdefghi\r\nabcdefghi\r\nabcdefghi\r\nabcdefghi"
    sgr_seqs = [
        b"\x1b[36m", b"\x1b[34m", b"\x1b[33m", b"\x1b[31m", b"\x1b[2m", b"\x1b[0m",
        b"\x1b[38;5;14m", b"\x1b[38;5;196m", b"\x1b[38;5;226m", b"\x1b[38;5;240m",
        b"\x1b[38;2;0;200;255m", b"\x1b[38;2;255;0;0m", b"\x1b[38;2;255;220;0m", b"\x1b[38;2;128;128;128m",
        b"\x1b[48;5;200m\x1b[36m", b"\x1b[38m\x1b[36m", b"\x1b[38;5m", b"\x1b[m",
        b"\x1b[2m\x1b[22m", b"\x1b[36m\x1b[32m", b"\x1b[1;36m", b"\x1b[96;39m",
    ]
    sgr = b"".join(seq + b"X\x1b[0m\r\n" for seq in sgr_seqs)
    return [
        _case("text_crlf", b"hello\r\nworld"),
        # cases/test_autowrap_align.py, at 8 columns.
        _case("autowrap_primitive_ideal", b"A" * 8 + b"B", rows=3, cols=8),
        _case("autowrap_primitive_strict", b"A" * 8 + b"B", rows=3, cols=8, autowrap=True),
        _case("crlf_after_full_line_ideal", b"A" * 8 + b"\r\nC", rows=3, cols=8),
        _case("crlf_after_full_line_strict", b"A" * 8 + b"\r\nC", rows=3, cols=8, autowrap=True),
        _case("pending_wrap_then_lf", b"A" * 8 + b"\nB", rows=3, cols=8, autowrap=True),
        _case("pending_wrap_cleared_by_cursor_move", b"A" * 8 + b"\x1b[2DZ", rows=3, cols=8, autowrap=True),
        _case("pending_wrap_kept_by_erase", b"A" * 8 + b"\x1b[KZ", rows=3, cols=8, autowrap=True),
        _case("pending_wrap_kept_by_decrc", E + b"7" + b"A" * 8 + E + b"8Z", rows=3, cols=8, autowrap=True),
        _case("sync_pairing", b"\x1b[?2026hhello\x1b[?2026l"),
        _case("sync_nested_and_stray", b"\x1b[?2026h\x1b[?2026hx\x1b[?2026l\x1b[?2026l\x1b[?2026l"),
        # cases/test_sgr_color.py T28-T31, one sequence per row.
        _case("sgr_classes", sgr, rows=len(sgr_seqs) + 1, cols=4),
        _case("cursor_moves", b"\x1b[3B\x1b[5Cx\x1b[Ay\x1b[2Dz\x1b[Gq\x1b[4Gr\x1b[0Gs\x1b[2;3Ht\x1b[Hu"
              b"\x1b[99;99Hv\x1b[fw\x1b[99Ax\x1b[99Dy\x1b[3C\x1b[Bz"),
        _case("erase_line_modes", b"abcdefghi\r\nabcdefghi\r\nabcdefghi\x1b[1;4H\x1b[K\x1b[2;4H\x1b[1K\x1b[3;4H\x1b[2K",
              rows=4, cols=10),
        _case("erase_display_0", full + b"\x1b[2;4H\x1b[J", rows=4, cols=10),
        _case("erase_display_1", full + b"\x1b[2;4H\x1b[1J", rows=4, cols=10),
        _case("erase_display_2", full + b"\x1b[2;4H\x1b[2J", rows=4, cols=10),
        _case("erase_display_3_keeps_scrollback", full + b"\r\nmore\x1b[3J", rows=4, cols=10),
        _case("bottom_scroll_into_history", b"l1\r\nl2\r\nl3\r\nl4\r\nl5", rows=3),
        _case("alt_screen", b"main1\r\nmain2\x1b[?1049halt1\r\nalt2\r\nalt3\r\nalt4\x1b[?1049lZ", rows=3),
        _case("alt_screen_nested_enter", b"m\x1b[?1049ha\x1b[?1049hb\x1b[?1049lc", rows=3),
        _case("alt_leave_without_enter", b"x\x1b[?1049ly", rows=3),
        _case("cursor_visibility", b"\x1b[?25lx\x1b[?25h\x1b[?25l"),
        _case("decsc_decrc", b"ab\x1b7\r\ncd\x1b8ef"),
        _case("osc_skipped", b"\x1b]0;title\x07ab\x1b]8;;https://x\x1b\\link\x1b]8;;\x1b\\cd"),
        _case("wide_clipped_at_edge", "中文字中".encode(), rows=3, cols=7),
        _case("wide_wraps_whole_on_autowrap", "中文字中".encode(), rows=3, cols=7, autowrap=True),
        _case("wide_half_overwritten", "中文\x1b[2Gx".encode(), rows=3, cols=7),
        _case("emoji_and_combining", "a😀b é─⏺❯".encode(), rows=3, cols=12),
        _case("sequences_split_across_feeds", [
            ("feed", b"ab\x1b"), ("feed", b"[2"), ("feed", b"Kc\xe4"), ("feed", b"\xb8"),
            ("feed", b"\xadd\x1b]0;t"), ("feed", b"itle\x07e\x1b[?20"), ("feed", b"26hf"),
        ]),
        _case("incomplete_sequence_left_pending", b"ab\x1b[12"),
        _case("invalid_utf8", b"a\xffb\xc3(c\xe4\xb8d\xed\xa0\x80e\xf4\x90\x80\x80f\x80g\xc0\x80h", cols=20),
        _case("del_tab_and_c0", b"a\x7fb\tc\x01\x08\x07d"),
        _case("unknown_csi_swallowed", b"a\x1b[5Sb\x1b[2;3rc\x1b[?2004hd\x1b[>4;1me\x1b[3Xf\x1b[2Pg\x1b[1@h\x1b[2 qi",
              cols=16),
        _case("csi_odd_params", b"\x1b[1:2Cx\x1b[;5Hy\x1b[3;Hz\x1b[0002;0005Hw"),
        # cases/test_screen_resize.py.
        _case("resize_narrow_then_wide", [("feed", b"0123456789\r\nab"), ("resize", 4, 6, True), ("resize", 4, 12, True)],
              rows=4, cols=12),
        _case("resize_erased_row_is_its_own_line", [
            ("feed", b"0123456789\r\n"), ("resize", 4, 6, True), ("feed", b"\x1b[2A\r\x1b[1B\x1b[2Kxy"),
            ("resize", 4, 12, True),
        ], rows=4, cols=12),
        _case("resize_full_screen_anchored_bottom",
              [("feed", b"top\r\nmiddle\r\n01234567"), ("resize", 3, 4, True), ("resize", 3, 8, True)], rows=3, cols=8),
        _case("resize_clip_keeps_rows",
              [("feed", b"0123456789\r\nab\x1b[8C"), ("resize", 3, 6, False), ("resize", 3, 12, False)], rows=3, cols=12),
        _case("resize_autowrap_continuation", [("feed", b"0123456789"), ("resize", 3, 12, True)], rows=3, cols=6,
              autowrap=True),
        _case("resize_clip_shorter_and_taller",
              [("feed", b"a\r\nb\r\nc\r\nd\r\ne"), ("resize", 3, 12, False), ("resize", 6, 12, False)], rows=5),
        _case("resize_clip_cuts_wide", [("feed", "ab中x".encode()), ("resize", 3, 3, False)], rows=3, cols=8),
        _case("resize_reflow_wide", [("feed", "ab中文\r\n".encode()), ("resize", 3, 3, True), ("resize", 3, 8, True)],
              rows=3, cols=8),
    ]


_WORDS = [b"ab", b"xyz", b"hello", b"0123456789", "中".encode(), "文字".encode(), "😀".encode(), "é".encode(),
          "─".encode(), "⏺".encode(), "❯".encode()]
_CONTROLS = [b"\r", b"\n", b"\r\n", b"\t", b"\x7f", b"\x07", b"\x08"]
_SGR = ["0", "1", "2", "22", "31", "32", "33", "34", "36", "39", "91", "94", "96", "38;5;{n}", "38;2;{r};{g};{b}",
        "48;5;{n}", "1;36", ""]


def _random_token(rng):
    kind = rng.random()
    if kind < 0.35:
        return rng.choice(_WORDS)
    if kind < 0.50:
        return rng.choice(_CONTROLS)
    if kind < 0.65:
        spec = rng.choice(_SGR).format(n=rng.randrange(256), r=rng.randrange(256), g=rng.randrange(256),
                                       b=rng.randrange(256))
        return b"\x1b[" + spec.encode() + b"m"
    if kind < 0.85:
        final = rng.choice("ABCDGHKJ")
        nparams = rng.choice([0, 1, 1, 2])
        params = ";".join(str(rng.choice([0, 1, 2, 3, 5, 12])) for _ in range(nparams))
        return b"\x1b[" + params.encode() + final.encode()
    if kind < 0.93:
        return rng.choice([b"\x1b[?25l", b"\x1b[?25h", b"\x1b[?2026h", b"\x1b[?2026l", b"\x1b[?1049h", b"\x1b[?1049l",
                           b"\x1b[?2004h", b"\x1b[>4;1m"])
    return rng.choice([b"\x1b7", b"\x1b8", b"\x1bc", b"\x1b]0;t\x07", b"\xff", b"\xc3("])


def _random_case(rng, index):
    while True:
        rows = rng.randrange(2, 8)
        cols = rng.randrange(4, 15)
        autowrap = rng.random() < 0.5
        stream = b"".join(_random_token(rng) for _ in range(rng.randrange(10, 60)))
        cuts = sorted(rng.sample(range(1, len(stream)), min(len(stream) - 1, rng.randrange(0, 5))))
        ops = []
        last = 0
        for cut in cuts + [len(stream)]:
            ops.append(("feed", stream[last:cut]))
            last = cut
            if rng.random() < 0.2:
                ops.append(("resize", rng.randrange(2, 8), rng.randrange(4, 15), rng.random() < 0.6))
        case = _case(f"random_{index:02d}", ops, rows=rows, cols=cols, autowrap=autowrap)
        try:
            replay(case)
        except (IndexError, NotImplementedError):
            continue  # EL 1 / ED 1 past the last column, or a resize on the alternate screen
        return case


def build():
    rng = random.Random(SEED)
    cases = hand_cases() + [_random_case(rng, i) for i in range(RANDOM_CASES)]
    out = []
    for case in cases:
        ops = []
        for op in case["ops"]:
            if op[0] == "feed":
                ops.append({"feed": op[1].hex()})
            else:
                ops.append({"resize": {"rows": op[1], "cols": op[2], "reflow": op[3]}})
        record = {k: case[k] for k in ("name", "rows", "cols", "autowrap")}
        record["ops"] = ops
        record["expect"] = snapshot(replay(case))
        out.append(json.dumps(record, ensure_ascii=True, sort_keys=True))
    return "\n".join(out) + "\n"


def main(argv):
    text = build()
    if "--write" in argv:
        os.makedirs(os.path.dirname(FIXTURE), exist_ok=True)
        with open(FIXTURE, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
        print(f"wrote {text.count(chr(10))} vectors to {os.path.normpath(FIXTURE)}")
        return 0
    with open(FIXTURE, encoding="ascii") as f:
        same = f.read() == text
    print("fixture is current" if same else "fixture is stale: run python tests/tty/vterm_parity.py --write")
    return 0 if same else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
