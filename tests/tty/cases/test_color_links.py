import os
import re
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import IS_WINDOWS, READY, run, wait_for  # noqa: E402
from slow_mock_server import SlowMockServer, text_turn  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402

END = "ANSWER-END"
ANSWER = "\n".join([
    "## Plan",
    "Read [the docs](https://example.com/docs), then `src/main.zig:3` and [notes](/tmp/notes.txt).",
    "```zig",
    "pub fn main() void { const s = \"x\"; _ = 42; } // done",
    "```",
    END,
])
CLEAN = {"FORCE_COLOR": None, "NO_COLOR": None, "COLORTERM": None, "STY": None, "TMUX": None, "TERM_PROGRAM": None,
         "SSH_CONNECTION": None, "SSH_CLIENT": None, "SSH_TTY": None}
SGR = re.compile(rb"\x1b\[([0-9;]*)m")
SSH = {"SSH_CONNECTION": "10.0.0.1 50022 10.0.0.2 22", "SSH_TTY": "/dev/pts/7"}


def _answer(bin_path, env):
    if IS_WINDOWS:
        raise SkipTest("color detection and SSH sessions here read POSIX terminal variables")
    with SlowMockServer([text_turn(ANSWER)]) as srv:
        return run(bin_path, [READY, "type:go", "key:enter", wait_for(END, 15), "sleep:0.5"],
                   env={**CLEAN, **env}, base_url=srv.url, term_size=(30, 110))


def _sgr_params(raw):
    for match in SGR.finditer(raw):
        yield [int(p) for p in match.group(1).split(b";") if p]


def _colored(raw):
    return [p for p in _sgr_params(raw) if any(30 <= n <= 38 or 40 <= n <= 48 or 90 <= n <= 97 or 100 <= n <= 107 for n in p)]


def _extended(raw, kind):
    return [p for p in _sgr_params(raw) if any(p[i] in (38, 48) and p[i + 1] == kind for i in range(len(p) - 1))]


def _url_host(name):
    return "".join(c if c.isascii() and (c.isalnum() or c in "-._~") else "%%%02X" % ord(c) for c in name)


def test_no_color_leaves_the_answer_heading_link_and_code_uncolored(bin_path):
    raw = _answer(bin_path, {"TERM": "xterm-256color", "COLORTERM": "truecolor", "NO_COLOR": "1"})
    assert END.encode() in raw, raw[-1500:]
    assert not _colored(raw), _colored(raw)[:8]
    assert b"\x1b]8;;https://example.com/docs" in raw


def test_inside_screen_the_inherited_truecolor_becomes_256_colors(bin_path):
    raw = _answer(bin_path, {"TERM": "screen.xterm-256color", "COLORTERM": "truecolor", "STY": "4242.pts-0.host"})
    assert END.encode() in raw, raw[-1500:]
    assert not _extended(raw, 2), _extended(raw, 2)[:8]
    assert _extended(raw, 5), "the code block lost its 256-color highlighting"


def test_a_screen_term_without_256_colors_gets_16_colors(bin_path):
    raw = _answer(bin_path, {"TERM": "screen", "COLORTERM": "truecolor"})
    assert END.encode() in raw, raw[-1500:]
    assert not _extended(raw, 2) and not _extended(raw, 5), (_extended(raw, 2) + _extended(raw, 5))[:8]
    assert _colored(raw), "16-color output is expected"


def test_tmux_with_a_screen_term_keeps_truecolor(bin_path):
    raw = _answer(bin_path, {"TERM": "screen-256color", "COLORTERM": "truecolor", "TMUX": "/tmp/tmux-501/default,1,0"})
    assert END.encode() in raw, raw[-1500:]
    assert _extended(raw, 2), "tmux forwards truecolor, the code block should keep it"


def test_a_file_link_over_ssh_names_this_machine(bin_path):
    raw = _answer(bin_path, {"TERM": "xterm-256color", **SSH})
    assert END.encode() in raw, raw[-1500:]
    expected = ("\x1b]8;;file://%s/tmp/notes.txt\x1b\\" % _url_host(socket.gethostname())).encode()
    assert expected in raw, re.findall(rb"\x1b\]8;;[^\x1b]*", raw)
    assert b"\x1b]8;;file:///" not in raw
    assert b"\x1b]8;;https://example.com/docs\x1b\\" in raw


def test_a_local_file_link_has_no_host(bin_path):
    raw = _answer(bin_path, {"TERM": "xterm-256color"})
    assert END.encode() in raw, raw[-1500:]
    assert b"\x1b]8;;file:///tmp/notes.txt\x1b\\" in raw, re.findall(rb"\x1b\]8;;[^\x1b]*", raw)
