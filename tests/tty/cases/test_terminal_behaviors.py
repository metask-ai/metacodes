import os

from tty_driver import IS_WINDOWS, READY, case_tmpdir, run, wait_for
from slow_mock_server import SlowMockServer, simple_text

ENV = {"TERM": "xterm-256color", "METACODES_HOME": None, "METACODES_NO_MOUSE": None}
MOUSE_ON = b"\x1b[?1002h\x1b[?1006h"
PASTE_ON = b"\x1b[?2004h"
PASTE_OFF = b"\x1b[?2004l"
PLACEHOLDER = b'Try "fix typecheck errors"'


def _home_with_config(config):
    home = case_tmpdir("cc-tty-terminal-home-")
    os.makedirs(os.path.join(home, ".metacodes"), exist_ok=True)
    with open(os.path.join(home, ".metacodes", "config.json"), "w") as f:
        f.write(config)
    return home


def _mouse_on():
    return {**ENV, "HOME": _home_with_config('{"mouse": true}')}


def test_mouse_reporting_stays_off_unless_the_mouse_setting_turns_it_on(bin_path):
    if IS_WINDOWS:
        return
    assert MOUSE_ON in run(bin_path, [READY, "strictsleep:0.3"], env=_mouse_on())
    for env in (ENV, {**ENV, "HOME": _home_with_config('{"mouse": false}')},
                {**_mouse_on(), "METACODES_NO_MOUSE": "1"}):
        raw = run(bin_path, [READY, "raw:\\x1b[<0;3;2M", "strictsleep:0.3"], env=env)
        assert MOUSE_ON not in raw, env
        assert b"\x1b[6n" not in raw, env
        assert PASTE_ON in raw, env


def test_by_default_no_mouse_reporting_sequence_is_sent_from_start_to_exit(bin_path):
    if IS_WINDOWS:
        return
    raw = run(bin_path, [READY, "raw:\\x1a", "signal:CONT", "sleep:0.8", "key:ctrl_c", "key:ctrl_c",
                         "strictsleep:1.0"], env=ENV)
    shown = raw.find(PLACEHOLDER)
    handed_back = raw.find(PASTE_OFF, shown)
    taken_again = raw.find(PASTE_ON, handed_back)
    assert 0 <= shown < handed_back < taken_again, "Ctrl+Z and fg did not hand the terminal back and take it again"
    assert raw.rfind(PASTE_OFF) > taken_again, "leaving did not hand the terminal back"
    for mode in (b"\x1b[?1000", b"\x1b[?1002", b"\x1b[?1003", b"\x1b[?1005", b"\x1b[?1006", b"\x1b[?1015"):
        assert mode not in raw, mode


def test_ctrl_z_hands_the_terminal_back_before_it_stops_and_takes_it_again_after(bin_path):
    if IS_WINDOWS:
        return
    raw = run(bin_path, [READY, "raw:\\x1a", "signal:CONT", "sleep:0.8"], env=_mouse_on())
    shown = raw.find(PLACEHOLDER)
    handed_back = raw.find(PASTE_OFF, shown)
    assert 0 <= shown < handed_back, "Ctrl+Z did not turn the terminal modes off"
    taken_again = raw.find(PASTE_ON, handed_back)
    assert taken_again > handed_back, "the modes did not come back after the stop"
    assert handed_back < raw.find(b"\x1b[?1002l", handed_back) < taken_again, "Ctrl+Z left mouse reporting on"
    assert MOUSE_ON in raw[taken_again:], "mouse reporting did not come back after the stop"
    assert raw.find(PLACEHOLDER, handed_back) > handed_back, "the prompt was not drawn again"


def test_the_window_title_is_pushed_at_start_and_restored_at_exit(bin_path):
    if IS_WINDOWS:
        return
    raw = run(bin_path, [READY, "key:ctrl_c", "key:ctrl_c", "strictsleep:1.0"], env=ENV)
    push = raw.find(b"\x1b[22;0t")
    first_title = raw.find(b"\x1b]0;")
    assert 0 <= push < first_title, "the title was not saved before metacodes set its own"
    restore = raw.rfind(b"\x1b]0;\x07\x1b[23;0t")
    assert restore > first_title, "leaving did not clear its title and restore the saved one"
    assert raw.rfind(b"\x1b]0;") == restore, "a title was set after the saved one came back"


def test_a_dumb_terminal_gets_the_line_mode_without_cursor_moves_titles_or_modes(bin_path):
    if IS_WINDOWS:
        return
    with SlowMockServer([simple_text("DUMB_TERMINAL_REPLY")]) as srv:
        raw = run(bin_path, ["waitbytes:> :20", "type:hello", "key:enter", wait_for("DUMB_TERMINAL_REPLY"),
                             "strictsleep:0.5"], base_url=srv.url,
                  env={**_mouse_on(), "TERM": "dumb", "FORCE_COLOR": None})
    assert b"DUMB_TERMINAL_REPLY" in raw
    assert PLACEHOLDER not in raw
    for sequence in (b"\x1b[?2026h", PASTE_ON, b"\x1b[?1002", b"\x1b[?1006", b"\x1b[?25l", b"\x1b]0;", b"\x1b[22;0t",
                     b"\x1b[J", b"\x1b[32m"):
        assert sequence not in raw, sequence
