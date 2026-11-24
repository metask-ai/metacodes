import base64
import json
import os

from tty_driver import IS_WINDOWS, READY, case_tmpdir, run, wait_for

MOUSE_ON = b"\x1b[?1002h\x1b[?1006h"
ENV = {"TERM": "xterm-256color", "SSH_CONNECTION": "10.0.0.1 22 10.0.0.2 22"}


def _osc52(text):
    return b"\x1b]52;c;" + base64.b64encode(text.encode()) + b"\x07"


def test_dragging_over_text_copies_it_to_the_clipboard(bin_path):
    if IS_WINDOWS:
        return
    raw = run(bin_path, [
        READY, "type:!echo SELECTME-42", "key:enter", "waitline:⎿  SELECTME-42:30",
        "select:SELECTME-42:20", wait_for("Copied to clipboard", 10),
    ], extra_args=["--preview=copy_on_select"], env=ENV)
    assert MOUSE_ON in raw
    assert _osc52("SELECTME-42") in raw, raw[-2000:]


def test_only_its_own_switch_turns_mouse_reporting_on(bin_path):
    if IS_WINDOWS:
        return
    for args, on in (
        ([], False),
        (["--preview=teamwork"], False),
        (["--preview", "--no-preview=copy_on_select"], False),
        (["--preview=copy_on_select"], True),
    ):
        raw = run(bin_path, [READY, "strictsleep:0.3"], extra_args=args, env=ENV)
        assert (MOUSE_ON in raw) == on, args


def test_saved_preview_config_turns_it_on(bin_path):
    if IS_WINDOWS:
        return
    home = case_tmpdir("copy-on-select-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state)
    with open(os.path.join(state, "config.json"), "w") as f:
        json.dump({"preview": {"copy_on_select": True}}, f)
    raw = run(bin_path, [READY, "strictsleep:0.3"], env={**ENV, "HOME": home})
    assert MOUSE_ON in raw
