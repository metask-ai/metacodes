import base64
import os

from tty_driver import IS_WINDOWS, READY, case_tmpdir, run, wait_for
from asserts import TTYAssert

MOUSE_ON = b"\x1b[?1002h\x1b[?1006h"
CURSOR_QUERY = b"\x1b[6n"
ENV = {"TERM": "xterm-256color", "SSH_CONNECTION": "10.0.0.1 22 10.0.0.2 22"}


def _osc52(text):
    return b"\x1b]52;c;" + base64.b64encode(text.encode()) + b"\x07"


def test_dragging_over_text_copies_it_to_the_clipboard(bin_path):
    if IS_WINDOWS:
        return
    raw = run(bin_path, [
        READY, "type:!echo SELECTME-42", "key:enter", "waitline:⎿  SELECTME-42:30",
        "select:SELECTME-42:20", wait_for("Sent to the terminal's clipboard", 10),
    ], env=ENV)
    assert MOUSE_ON in raw
    assert _osc52("SELECTME-42") in raw, raw[-2000:]


def test_mouse_reporting_is_on_without_any_preview_flag(bin_path):
    if IS_WINDOWS:
        return
    for args in ([], ["--no-preview"]):
        raw = run(bin_path, [READY, "raw:\\x1b[<0;3;2M", "strictsleep:0.3"], extra_args=args, env=ENV)
        assert MOUSE_ON in raw, args
        assert CURSOR_QUERY in raw, args


def _fake_tmux(set_clipboard):
    tools = case_tmpdir("cc-tty-fake-tmux-")
    path = os.path.join(tools, "tmux")
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\necho {set_clipboard}\n")
    os.chmod(path, 0o755)
    return {**ENV, "TMUX": "/tmp/cc-tty-fake-tmux,1,0", "PATH": tools + os.pathsep + os.environ.get("PATH", "")}


def test_inside_a_tmux_that_drops_osc_52_the_copy_notice_says_how_to_let_it_through(bin_path):
    if IS_WINDOWS:
        return
    for set_clipboard, notice in (("external", "tmux did not pass it on: set-clipboard on"),
                                  ("on", "Sent to the terminal's clipboard")):
        raw = run(bin_path, [
            READY, "type:!echo SELECTME-43", "key:enter", "waitline:⎿  SELECTME-43:30",
            "select:SELECTME-43:20", wait_for(notice, 10),
        ], env=_fake_tmux(set_clipboard))
        a = TTYAssert(raw)
        if a.final.find_row(notice) is None:
            a._fail(f"set-clipboard {set_clipboard}: the copy notice is not {notice!r}")
        assert _osc52("SELECTME-43") in raw, set_clipboard
