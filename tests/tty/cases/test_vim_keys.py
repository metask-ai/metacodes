import json
import os

from tty_driver import READY, case_tmpdir, run, wait_for
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, simple_text

VIM = [READY, "type:/vim", "key:enter", wait_for("Editor mode: vim"), READY]
NORMAL = ["key:esc", "strictsleep:0.4"]
PICKER = "apply to"
HELP = "shift + tab to cycle modes"
EXIT_C = "Press Ctrl-C again to exit"
CTRL_C = {"legacy": "raw:\\x03", "kitty": "raw:\\x1b[99;5u", "modifyOtherKeys": "raw:\\x1b[27;5;99~"}


def _screen(raw):
    a = TTYAssert(raw)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def _frames_with(a, text):
    return [sc for sc in a.frame_screens if sc.find_row(text) is not None]


def _footer(a, screen=None):
    sc = screen or a.final
    row = a.footer_row(sc)
    return sc.line_text(row) if row is not None else ""


def _submitted(bin_path, events):
    with SlowMockServer([simple_text("VIM_OK")]) as srv:
        raw = run(bin_path, VIM + events + [wait_for("VIM_OK", 15), "sleep:0.3"], base_url=srv.url,
                  per_key_drain=0.05)
        requests = list(srv.requests)
    texts = []
    for body in requests:
        for message in json.loads(body)["messages"]:
            content = message.get("content")
            if message.get("role") != "user" or not isinstance(content, (str, list)):
                continue
            parts = [content] if isinstance(content, str) else [
                p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text"]
            texts += [t for t in parts if not t.startswith("<system-reminder>")]
    return TTYAssert(raw), texts


def test_vim_shift_tab_cycles_the_permission_mode_in_insert_and_normal_mode(bin_path):
    raw = run(bin_path, VIM + ["key:shift_tab", wait_for("accept edits on", 5)] + NORMAL
              + ["key:shift_tab", "sleep:0.6"], permission="default", per_key_drain=0.1)
    a, text = _screen(raw)
    assert any("accept edits on" in _footer(a, sc) for sc in a.frame_screens), \
        "Shift+Tab in INSERT mode did not cycle to accept edits:\n" + text
    assert "? for shortcuts" in _footer(a), "Shift+Tab in NORMAL mode did not cycle back to default:\n" + text


def test_vim_ctrl_o_opens_the_model_picker_in_insert_and_normal_mode(bin_path):
    raw = run(bin_path, VIM + ["key:ctrl_o", wait_for(PICKER, 5)], per_key_drain=0.1)
    a, text = _screen(raw)
    assert PICKER in text, "Ctrl+O in INSERT mode did not open the picker:\n" + text

    raw = run(bin_path, VIM + ["type:draft"] + NORMAL + ["key:ctrl_o", wait_for(PICKER, 5),
                                                        "key:esc", wait_for("kept ", 5), "sleep:0.3"],
              per_key_drain=0.1)
    a, text = _screen(raw)
    assert _frames_with(a, PICKER), "Ctrl+O in NORMAL mode did not open the picker:\n" + text
    assert "kept " in text and PICKER not in text, "Esc did not close the picker opened from NORMAL mode:\n" + text
    a.assert_input_echo("draft")


def test_vim_ctrl_r_opens_reverse_search_in_insert_and_normal_mode(bin_path):
    for setup, mode in (([], "INSERT"), (["type:draft"] + NORMAL, "NORMAL")):
        raw = run(bin_path, VIM + setup + ["key:ctrl_r", wait_for("(reverse-search)", 5), "sleep:0.3"],
                  per_key_drain=0.1)
        a, text = _screen(raw)
        assert "(reverse-search)" in text, f"Ctrl+R in {mode} mode did not open reverse search:\n" + text


def test_vim_question_mark_opens_help_and_esc_closes_it_before_leaving_insert_mode(bin_path):
    raw = run(bin_path, VIM + ["type:?", wait_for(HELP, 5), "key:esc", "strictsleep:0.6", "type:a", "sleep:0.4"],
              per_key_drain=0.1)
    a, text = _screen(raw)
    assert _frames_with(a, HELP), "? on an empty prompt did not open the shortcut help:\n" + text
    assert HELP not in text, "Esc did not close the help:\n" + text
    a.assert_input_echo("a")


def test_vim_up_recalls_history_and_enter_runs_the_highlighted_slash_command(bin_path):
    state = case_tmpdir("cc-tty-vim-history-")
    with open(os.path.join(state, "history"), "w", encoding="utf-8") as f:
        f.write('"hello history"\n')
    raw = run(bin_path, VIM + ["key:up", wait_for("❯ hello history", 5), "sleep:0.3"],
              extra_args=["--state-dir", state], per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("hello history")

    raw = run(bin_path, VIM + ["type:/hel", "sleep:0.3", "key:enter", wait_for("Esc to close", 5)],
              per_key_drain=0.1)
    a, text = _screen(raw)
    assert "Esc to close" in text, "Enter on the / menu did not run /help:\n" + text


def test_vim_normal_left_moves_the_cursor_instead_of_deleting(bin_path):
    raw = run(bin_path, VIM + ["type:hello world"] + NORMAL + ["key:left", "sleep:0.3", "type:i", "type:X",
                                                              "sleep:0.4"], per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("hello worXld")


def test_vim_normal_paste_inserts_the_text_instead_of_running_it(bin_path):
    raw = run(bin_path, VIM + ["type:abc"] + NORMAL + ["raw:\\x1b[200~dd\\x1b[201~", "sleep:0.5"],
              per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("abddc")


def test_vim_normal_esc_b_in_one_write_is_esc_then_b(bin_path):
    raw = run(bin_path, VIM + ["type:foo bar"] + NORMAL + ["raw:\\x1bb", "sleep:0.3", "type:i", "type:X", "sleep:0.4"],
              per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("foo Xbar")

    raw = run(bin_path, VIM + ["type:foo bar"] + NORMAL + ["type:d", "raw:\\x1bb", "sleep:0.4"], per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("foo bar")


def test_vim_a_command_right_after_esc_runs_instead_of_being_typed(bin_path):
    raw = run(bin_path, VIM + ["type:hello", "raw:\\x1bx", "sleep:0.6"], per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("hell")


def test_vim_normal_line_editor_keys_leave_the_draft_alone(bin_path):
    raw = run(bin_path, VIM + ["type:hello world"] + NORMAL + ["key:ctrl_u", "key:ctrl_w", "key:ctrl_k", "sleep:0.4"],
              per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("hello world")


def test_vim_normal_arrows_move_the_cursor_across_lines(bin_path):
    a, sent = _submitted(bin_path, ["type:abc", "key:shift_enter", "type:def"] + NORMAL
                         + ["key:up", "key:left", "key:left", "key:right", "key:down", "type:i", "type:X",
                            "key:enter"])
    if sent != ["abc\ndXef"]:
        a._fail(f"Up, Left, Left, Right, Down in NORMAL mode did not move as k, h, h, l, j: sent {sent!r}")


def test_vim_normal_d_keeps_the_lines_below_the_cursor(bin_path):
    a, sent = _submitted(bin_path, ["type:first line", "key:shift_enter", "type:second line"] + NORMAL
                         + ["type:k", "type:0", "type:w", "type:D", "key:enter"])
    if sent != ["first \nsecond line"]:
        a._fail(f"D on the first line of two did not stop at the end of that line: sent {sent!r}")


def test_vim_normal_ctrl_c_arms_the_double_press_exit_in_every_encoding(bin_path):
    for encoding, press in CTRL_C.items():
        raw = run(bin_path, VIM + ["type:hello world"] + NORMAL + [press, wait_for(EXIT_C, 5), "sleep:0.2"],
                  per_key_drain=0.1)
        a, text = _screen(raw)
        assert _frames_with(a, EXIT_C), f"{encoding} Ctrl+C in NORMAL mode did not arm the exit:\n" + text
        assert a.final.find_row("hello world") is None, f"{encoding} Ctrl+C in NORMAL mode kept the draft:\n" + text


def test_vim_insert_ctrl_c_arms_the_double_press_exit(bin_path):
    raw = run(bin_path, VIM + ["type:hello world", "key:ctrl_c", wait_for(EXIT_C, 5), "sleep:0.2"],
              per_key_drain=0.1)
    a, text = _screen(raw)
    assert _frames_with(a, EXIT_C), "Ctrl+C in INSERT mode did not arm the exit:\n" + text


def test_vim_normal_ctrl_c_twice_exits(bin_path):
    raw = run(bin_path, VIM + ["type:hello"] + NORMAL + ["key:ctrl_c", "key:ctrl_c", "strictsleep:1.0",
                                                        "type:after", "strictsleep:0.5"], per_key_drain=0.1)
    a = TTYAssert(raw)
    a.assert_clean_exit()
    assert a.final.find_row("after") is None, "keys after the exit must not reach a prompt"


def test_vim_normal_ctrl_x_ctrl_o_opens_the_transcript(bin_path):
    raw = run(bin_path, VIM + ["type:draft"] + NORMAL + ["key:ctrl_x", "key:ctrl_o",
                                                        wait_for("Showing detailed transcript", 5)],
              per_key_drain=0.1)
    assert b"Showing detailed transcript" in raw, "Ctrl+X Ctrl+O in NORMAL mode did not open the transcript"


def test_vim_normal_shortcut_cancels_a_pending_operator(bin_path):
    raw = run(bin_path, VIM + ["type:foo bar"] + NORMAL + ["type:0", "type:d", "key:ctrl_t", "type:w", "sleep:0.4"],
              per_key_drain=0.1)
    TTYAssert(raw).assert_input_echo("foo bar")


def test_vim_keys_vim_takes_end_a_pending_ctrl_x(bin_path):
    runs = ((["type:hello world", "key:ctrl_x"], NORMAL),
            (["type:hello world"] + NORMAL, ["key:ctrl_x", "type:h"]))
    for setup, keys in runs:
        raw = run(bin_path, VIM + setup + keys + ["key:ctrl_k", "sleep:0.5"], per_key_drain=0.1)
        a, text = _screen(raw)
        assert b"background task(s)" not in raw, f"Ctrl+K after Ctrl+X, {keys} killed the background tasks:\n" + text
        a.assert_input_echo("hello world")
