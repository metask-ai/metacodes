"""Idle prompt key state machine, aligned with Claude Code 2.1.278.

Recorded on the real CLI (ui_compare/cc2.1.278 in the workspace repo) and
matched here:
  - Ctrl+C: the first press shows `Press Ctrl-C again to exit` in the footer
    (and discards a draft); a second press within 800 ms exits. Nothing is
    written to the scrollback, and the hint expires.
  - Ctrl+D: the same double press on an empty prompt; with a draft it deletes
    the character under the cursor.
  - Esc: the first press shows `Esc again to clear` above the box and keeps
    the draft; a second press within 800 ms clears it into history. With the
    `/` menu open, Esc closes the menu and keeps the draft.
  - Enter on a blank prompt does nothing.
"""
from tty_driver import run, READY, wait_for
from asserts import TTYAssert

PLACEHOLDER = 'Try "fix typecheck errors"'


def _content(a):
    row = a.content_row()
    assert row is not None, a.final.render_ascii()
    return a.final.line_text(row)


def _frames_with(a, text):
    return [sc for sc in a.frame_screens if sc.find_row(text) is not None]


def test_ctrl_c_once_shows_footer_hint_then_expires(bin_path):
    raw = run(bin_path, [READY, "key:ctrl_c", wait_for("Press Ctrl-C again to exit", 5), "strictsleep:1.5"])
    a = TTYAssert(raw)
    shown = _frames_with(a, "Press Ctrl-C again to exit")
    if not shown:
        a._fail("Ctrl+C on an empty prompt should show the exit hint")
    # The hint replaces the footer: it sits on the box's last row, below the
    # bottom rule, and never reaches the scrollback (no `^C` either).
    frame = shown[0]
    hint_row = frame.find_row("Press Ctrl-C again to exit")
    if hint_row != a.box_bottom_row(frame) + 1:
        a._fail(f"the exit hint should be the footer row (row {hint_row})")
    assert b"^C" not in raw
    if a.final.find_row("Press Ctrl-C again to exit") is not None:
        a._fail("the Ctrl+C hint should expire after the double-press window")
    a.assert_box_present()


def test_ctrl_c_twice_exits_quietly(bin_path):
    raw = run(bin_path, [READY, "key:ctrl_c", "key:ctrl_c", "strictsleep:1.0", "type:after", "strictsleep:0.5"])
    a = TTYAssert(raw)
    a.assert_clean_exit()
    assert b"Goodbye" not in raw, "a Ctrl+C exit leaves without a goodbye line"
    assert a.final.find_row("after") is None, "keys after the exit must not reach a prompt"


def test_ctrl_c_discards_the_draft(bin_path):
    raw = run(bin_path, [READY, "type:draft text", "key:ctrl_c", wait_for("Press Ctrl-C again to exit", 5)])
    a = TTYAssert(raw)
    assert PLACEHOLDER in _content(a), "Ctrl+C should empty the prompt"
    assert a.final.find_row("draft text") is None, "the discarded draft must not reach the scrollback"


def test_esc_twice_clears_into_history(bin_path):
    raw = run(bin_path, [
        READY, "type:keep me", "key:esc", wait_for("Esc again to clear", 5),
        "key:esc", wait_for(PLACEHOLDER, 5),
        "key:up", wait_for("keep me", 5),
    ])
    a = TTYAssert(raw)
    a.assert_input_echo("keep me")
    assert a.final.find_row("Esc again to clear") is None


def test_single_esc_keeps_the_draft(bin_path):
    raw = run(bin_path, [READY, "type:keep me", "key:esc", "strictsleep:1.5"])
    a = TTYAssert(raw)
    a.assert_input_echo("keep me")
    if a.final.find_row("Esc again to clear") is not None:
        a._fail("the Esc hint should expire after the double-press window")


def test_esc_closes_the_slash_menu_and_keeps_the_draft(bin_path):
    raw = run(bin_path, [READY, "type:/he", wait_for("Show help", 5), "key:esc", "strictsleep:0.6"])
    a = TTYAssert(raw)
    a.assert_input_echo("/he")
    if a.final.find_row("Show help") is not None:
        a._fail("Esc should close the / menu")
    if a.final.find_row("Esc again to clear") is not None:
        a._fail("closing the menu must not arm the clear")


def test_ctrl_d_deletes_forward_and_double_exits(bin_path):
    raw = run(bin_path, [READY, "type:abc", "key:home", "key:ctrl_d", "strictsleep:0.4"])
    TTYAssert(raw).assert_input_echo("bc")

    raw = run(bin_path, [READY, "key:ctrl_d", wait_for("Press Ctrl-D again to exit", 5), "key:ctrl_d", "strictsleep:1.0"])
    a = TTYAssert(raw)
    a.assert_clean_exit()
    assert b"Goodbye" not in raw


def test_blank_enter_writes_nothing(bin_path):
    base = TTYAssert(run(bin_path, [READY, "strictsleep:0.5"]))
    raw = run(bin_path, [READY, "key:enter", "key:enter", "type:   ", "key:enter", "strictsleep:0.5"])
    a = TTYAssert(raw)
    if a.box_top_row() != base.box_top_row():
        a._fail(f"blank Enter moved the prompt (box top {base.box_top_row()} → {a.box_top_row()})")


def _in_one_sync_frame(raw, at, text):
    """Whether the bytes at `at` and the next `text` are inside one synchronized
    update (DEC 2026): opened before `at`, closed after `text`."""
    opened = raw.rfind(b"\x1b[?2026h", 0, at)
    if opened < 0 or raw.rfind(b"\x1b[?2026l", 0, at) > opened:
        return False
    closed = raw.find(b"\x1b[?2026l", at)
    return closed >= 0 and text in raw[at:closed]


def test_ctrl_l_clears_the_screen_and_redraws_the_box_on_top(bin_path):
    # Ctrl+L goes through RenderRegion.resetScreen (doc/TUI_VIEWPORT_OWNERSHIP.md):
    # the box is erased, ED 2 clears the screen (never ED 3, which would wipe
    # the scrollback), and the box comes back on the top row with the draft.
    from tty_driver import IS_WINDOWS, submit

    raw = run(bin_path, submit("/cost", "Total cost:") + [READY, "type:keep me", "key:ctrl_l", "strictsleep:1.0"])
    a = TTYAssert(raw)
    if a.final.find_row("Total cost:") is not None:
        a._fail("Ctrl+L should clear the screen")
    if b"\x1b[3J" in raw:
        a._fail("Ctrl+L must not wipe the scrollback (ED 3)")
    if a.box_top_row() != 0:
        a._fail(f"the box should start on the top row after Ctrl+L, not row {a.box_top_row()}")
    a.assert_box_at_bottom()
    a.assert_single_box()
    assert "keep me" in _content(a), a.final.render_ascii()
    # ConPTY re-renders the screen itself; the bytes are only metacodes' own on a pty.
    if not IS_WINDOWS:
        ed2 = raw.find(b"\x1b[2J")
        if ed2 < 0 or not _in_one_sync_frame(raw, ed2, b"\x1b[2J"):
            a._fail("Ctrl+L should erase the box and clear the screen in one synchronized frame")


def test_home_and_end_as_tmux_screen_and_rxvt_send_them_move_the_cursor(bin_path):
    raw = run(bin_path, [READY, "type:abc", "raw:\\x1b[1~", "type:X", "raw:\\x1b[4~", "type:Y", "strictsleep:0.4"])
    TTYAssert(raw).assert_input_echo("XabcY")

    raw = run(bin_path, [READY, "type:abc", "raw:\\x1b[7~", "type:X", "raw:\\x1b[8~", "type:Y", "strictsleep:0.4"])
    TTYAssert(raw).assert_input_echo("XabcY")
