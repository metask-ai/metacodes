"""终端兼容性:Kitty 协议按 TERM_PROGRAM 分流 + Apple Terminal backslash 换行。

背景:cc-zig 曾无条件发 Kitty 协议(\x1b[>1u),Apple Terminal 不支持 → honor 后发回
乱码/键失常。改成按终端 gate(对齐真 cc terminal.ts:167):认得出的直接发,deny-list
(Apple Terminal 等)不发,认不出的启动时探测(test_keyboard_probe.py)。这些 case 验
cc-zig **发什么字节**(pty 能测);真终端如何响应需用户真机抓。

每个 case 先等空输入框画出(READY)再发键、再收尾断言,不靠固定的启动 sleep:首个输入框出现
之前敲的键整段作为一次粘贴进第一个输入框(input.collectStartupInput,测在 test_startup_splash /
test_keyboard_probe),换行是文本、Enter 不提交、Ctrl+R/Esc 被丢掉,测的就不是输入框里的按键了。
macos-26 runner 上首个输入框实测晚到过 2.2 s(启动后 0.8 + 0.8 s 就开始打字)。
"""
import os
import sys

from tty_driver import READY, case_tmpdir, run
from asserts import TTYAssert
from screen import Screen

try:
    from e2e_helpers import SkipTest
except Exception:  # noqa: BLE001
    class SkipTest(Exception):
        pass


def _skip_if_conpty():
    """Windows/ConPTY 重合成输出流:应用发出的私有模式(?2004h、kitty >1u/=4;2m)被
    conhost 消费不透传,此层观测不到"发了什么字节"——这些断言是 POSIX-pty 专属。
    (Windows 上 paste/键协议功能本身由 console 模式 + VT input 提供,另有用例覆盖。)"""
    if sys.platform == "win32":
        raise SkipTest("ConPTY 不透传应用私有模式序列,字节级断言仅 POSIX-pty 可测")


def test_apple_terminal_no_kitty(bin_path):
    _skip_if_conpty()
    # Apple Terminal:不发 Kitty 协议(\x1b[>1u / >4;2m),但 bracketed paste 仍发。
    raw = run(bin_path, [READY], env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" not in raw, "Apple Terminal 不应发 Kitty enable \\x1b[>1u"
    assert b"\x1b[>4;2m" not in raw, "Apple Terminal 不应发 modifyOtherKeys level 2"
    assert b"\x1b[?2004h" in raw, "bracketed paste 应始终发(兼容性好)"


def test_warp_sends_kitty(bin_path):
    _skip_if_conpty()
    # Warp(白名单):发 Kitty enable —— 实测其默认未开,需 cc-zig 主动发才能 Shift+Enter 换行。
    raw = run(bin_path, [READY], env={"TERM_PROGRAM": "WarpTerminal", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" in raw, "Warp 应发 Kitty enable \\x1b[>1u"


def test_iterm_sends_kitty(bin_path):
    _skip_if_conpty()
    raw = run(bin_path, [READY], env={"TERM_PROGRAM": "iTerm.app", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" in raw, "iTerm 应发 Kitty enable"


def test_sigstop_sigcont_reapplies_terminal_modes(bin_path):
    _skip_if_conpty()
    # A stopped foreground process can come back with shell-modified termios
    # and private-mode flags.  The SIGCONT path must re-emit the full intended
    # state, including Kitty/modifyOtherKeys and bracketed paste.
    raw = run(
        bin_path,
        [READY, "signal:stopcont", "sleep:0.8"],
        env={"TERM_PROGRAM": "WarpTerminal", "TERM": "xterm-256color"},
    )
    assert raw.count(b"\x1b[>1u") >= 2, "SIGCONT should re-enable Kitty keyboard"
    assert raw.count(b"\x1b[>4;2m") >= 2, "SIGCONT should re-enable modifyOtherKeys"
    assert raw.count(b"\x1b[?2004h") >= 2, "SIGCONT should re-enable bracketed paste"


def test_no_keyboard_enhancement_env_sends_no_protocol_sequence_through_stop_and_exit(bin_path):
    _skip_if_conpty()
    raw = run(
        bin_path,
        [READY, "signal:stopcont", "sleep:0.8", "key:ctrl_c", "key:ctrl_c", "strictsleep:1.0"],
        env={"TERM_PROGRAM": "WarpTerminal", "TERM": "xterm-kitty", "METACODES_NO_KEYBOARD_ENHANCEMENT": "1"},
    )
    for sequence in (b"\x1b[<u", b"\x1b[>1u", b"\x1b[>4;2m", b"\x1b[>4m", b"\x1b[?u"):
        assert sequence not in raw, f"METACODES_NO_KEYBOARD_ENHANCEMENT still sent {sequence!r}"
    assert raw.count(b"\x1b[?2004h") >= 2, "SIGCONT should still re-enable bracketed paste"
    assert b"\x1b[?2004l" in raw, "leaving should still turn bracketed paste off"


def test_sigcont_restores_raw_input_after_shell_cooked_the_tty(bin_path):
    _skip_if_conpty()
    # While stopped, the tty goes back to canonical mode (no echo). Without the
    # SIGCONT reconciliation the typed bytes wait in the line discipline for a
    # newline and the input box stays empty.
    raw = run(
        bin_path,
        [READY, "signal:stopcont:cooked", "sleep:0.5", "type:ab", "sleep:0.6"],
    )
    a = TTYAssert(raw)
    a.assert_input_echo("ab")
    a.assert_box_at_bottom()


def test_apple_terminal_backslash_newline_no_exit(bin_path):
    # Apple Terminal 无 Kitty 协议,Shift+Enter 发裸 \r 无法区分 → 换行靠 backslash+return:
    # 行尾 \ + 回车 → 删 \ 插 \n,留在输入框(不提交、不退出)。用 raw:\x0d 发裸回车。
    raw = run(
        bin_path,
        [READY, "type:abc\\", "raw:\\x0d", "sleep:0.3"],
        env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"},
    )
    assert b"Goodbye" not in raw, "backslash 续行不应退出程序"
    a = TTYAssert(raw)
    a.assert_box_height(2)  # 换行后输入框两行(abc + 空续行)
    a.assert_input_echo("abc")  # 第一行恰是 abc:\ 已删(只"含 abc"的话 abc\ 也算过)


def test_esc_cr_inserts_a_newline(bin_path):
    # /terminal-setup (#386) makes Apple Terminal's Shift+Return and VS Code's shift+enter send
    # ESC CR (Meta+Return): a newline that stays in the input box, where a bare CR submits.
    raw = run(
        bin_path,
        [READY, "type:abc", "raw:\\x1b\\x0d", "type:def", "sleep:0.4"],
        env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"},
    )
    assert b"Goodbye" not in raw, "ESC CR must not submit or exit"
    a = TTYAssert(raw)
    a.assert_box_height(2)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "abc")
    a.assert_line_contains(top + 2, "def")


# A person's Esc, then Enter, inside the ESC wait (200 ms) but in two writes: two keys.
# Only an ESC CR that arrives in one write (a terminal's Meta+Return) is a newline.
SEPARATE_ESC_ENTER = ["raw:\\x1b", "strictsleep:0.06", "raw:\\x0d"]
APPLE = {"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"}


def _screen_text(raw):
    sc = Screen(24, 80)
    sc.feed(raw)
    return "\n".join(sc.line_text(r) for r in range(sc.rows))


def test_esc_then_enter_pressed_apart_still_submits(bin_path):
    raw = run(bin_path, [READY, "type:abc"] + SEPARATE_ESC_ENTER + ["sleep:0.8"],
              env=APPLE, per_key_drain=0.02)
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_input_echo("")  # submitted: the box is empty again
    assert "abc" in _screen_text(raw), "the submitted prompt should be echoed above the box"


def test_vim_insert_esc_then_enter_apart_goes_normal_then_submits(bin_path):
    events = [READY, "type:/vim", "key:enter", "wait:Editor mode: vim:5", "type:abc"]
    raw = run(bin_path, events + SEPARATE_ESC_ENTER + ["sleep:0.8"], env=APPLE, per_key_drain=0.02)
    a = TTYAssert(raw)
    a.assert_input_echo("")  # Esc → NORMAL, Enter → submit, as before ESC CR was a key


def test_vim_insert_esc_cr_in_one_write_is_a_newline(bin_path):
    events = [READY, "type:/vim", "key:enter", "wait:Editor mode: vim:5", "type:abc",
              "raw:\\x1b\\x0d", "type:def", "sleep:0.4"]
    raw = run(bin_path, events, env=APPLE, per_key_drain=0.02)
    a = TTYAssert(raw)
    a.assert_box_height(2)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "abc")
    a.assert_line_contains(top + 2, "def")


def _reverse_search_hel(bin_path, keys):
    # A history with "hello" (seeded, so no turn runs), Ctrl+R, "hel", then `keys`.
    state = case_tmpdir("cc-tty-revsearch-")
    with open(os.path.join(state, "history"), "w", encoding="utf-8") as f:
        f.write('"hello"\n')
    events = [READY, "key:ctrl_r", "wait:(reverse-search)`hel:3", "type:hel", "wait:hello:3", "sleep:0.3"]
    raw = run(bin_path, events + keys + ["sleep:0.8"], env=APPLE, per_key_drain=0.02,
              extra_args=["--state-dir", state])
    assert b"(reverse-search)`hel': hello" in raw, "reverse search did not find the seeded history entry"
    return raw


def test_reverse_search_esc_then_enter_apart_cancels(bin_path):
    raw = _reverse_search_hel(bin_path, SEPARATE_ESC_ENTER)
    # Esc cancelled the search: the prompt keeps its empty input. Accepting would
    # have put "hello" in the box.
    TTYAssert(raw).assert_input_echo("")


def test_reverse_search_esc_cr_in_one_write_accepts(bin_path):
    # The terminal's Shift+Enter binding (ESC CR in one write) is Shift+Enter, which
    # reverse search takes as Enter: the match goes into the box.
    raw = _reverse_search_hel(bin_path, ["raw:\\x1b\\x0d"])
    TTYAssert(raw).assert_input_echo("hello")


def test_paste_keeps_esc_cr_as_a_line_break(bin_path):
    raw = run(bin_path, [READY, "raw:\\x1b[200~a\\x1b\\x0db\\x1b[201~", "sleep:0.5"], env=APPLE)
    a = TTYAssert(raw)
    a.assert_box_height(2)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "a")
    a.assert_line_contains(top + 2, "b")


def _multiline_footer(bin_path, term_program):
    # 组多行(backslash 续行)后抓 footer 文案。Apple 用裸回车续行,Kitty 终端用 shift_enter。
    if term_program == "Apple_Terminal":
        events = [READY, "type:a\\", "raw:\\x0d", "type:b", "sleep:0.3"]
    else:
        events = [READY, "type:a", "key:shift_enter", "type:b", "sleep:0.3"]
    raw = run(bin_path, events, env={"TERM_PROGRAM": term_program, "TERM": "xterm-256color", "TMUX": None})
    sc = Screen(24, 80)
    sc.feed(raw)
    return "\n".join(sc.line_text(r) for r in range(sc.rows))


def test_newline_hint_per_terminal(bin_path):
    # 多行编辑时 footer 显当前终端的换行方式(对齐真 cc getNewlineInstructions,按 cc-zig 能力)。
    # Windows 上这正是只发 VT 字节的终端经 ConPTY:字原样到,单独的 CR 被做成记录,
    # 没有一条记录打出过字 → 分不出 Shift+Enter,照旧显 backslash。
    apple = _multiline_footer(bin_path, "Apple_Terminal")
    assert "\\ + " in apple and "for newline" in apple, \
        f"Apple Terminal 应显 backslash 换行提示,实际 footer 区:{apple!r}"
    assert "shift + " not in apple, "Apple Terminal 不应显 shift+⏎(它区分不了,会误导)"

    warp = _multiline_footer(bin_path, "WarpTerminal")
    assert "shift + " in warp and "for newline" in warp, \
        f"Warp(白名单)应显 shift+⏎ 换行提示,实际:{warp!r}"



def _win32_records(*records):
    """win32-input-mode 键记录 `CSI Vk;Sc;Uc;Kd;Cs;Rc _`,写成 raw: 事件。"""
    return "raw:" + "".join(f"\\x1b[{r}_" for r in records)


def test_windows_console_shift_enter_record_is_a_newline(bin_path):
    """Windows 控制台:Shift+Enter 是带 SHIFT_PRESSED 的 Enter 记录 → 换行;不带修饰的 Enter
    记录照旧提交。伪控制台收得下宿主侧写的键记录(Windows Terminal 就这么发),走一遍
    ConPTY → win32-input-mode → 读控制台时还原 → KeyParser,不是 key:shift_enter 的 CSI-u 捷径。
    字也按记录敲(Windows Terminal 就这么送):有记录打出过字,footer 才说 shift+⏎。"""
    if sys.platform != "win32":
        raise SkipTest("win32-input-mode 只在 Windows 控制台上开")
    a_key = _win32_records("65;30;97;1;32;1", "65;30;97;0;32;1")
    b_key = _win32_records("66;48;98;1;32;1", "66;48;98;0;32;1")
    shift_enter = _win32_records("16;42;0;1;16;1", "13;28;13;1;16;1", "13;28;13;0;16;1", "16;42;0;0;0;1")
    raw = run(bin_path, [READY, a_key, a_key, shift_enter, b_key, b_key, "sleep:0.6"])
    a = TTYAssert(raw)
    a.assert_box_height(2)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "aa")
    a.assert_line_contains(top + 2, "bb")
    a.assert_line_contains(a.footer_row(), "shift + ")

    enter = _win32_records("13;28;13;1;0;1", "13;28;13;0;0;1")
    raw = run(bin_path, [READY, "type:aa", enter, "sleep:0.8"])
    a = TTYAssert(raw)
    a.assert_input_echo("")
    sc = Screen(24, 80)
    sc.feed(raw)
    assert sc.find_last_row("❯ aa") is not None, "Enter 记录应提交,❯ aa 进对话区"


def test_colorless_conpty_keeps_unicode_frame(bin_path):
    """PowerShell often has no TERM; color fallback must keep the Unicode TUI glyphs."""
    raw = run(
        bin_path,
        [READY],
        env={"FORCE_COLOR": None, "TERM": None, "COLORTERM": None, "NO_COLOR": None},
    )
    assert "╭".encode("utf-8") in raw, "no-color TTY must keep the banner's rounded top corner"
    assert "╰".encode("utf-8") in raw, "no-color TTY must keep the banner's rounded bottom corner"
    a = TTYAssert(raw)
    if a.box_top_row() is None or a.box_bottom_row() is None:
        a._fail("no-color TTY must draw the input box with full-width ─ rules")
    assert b"+-" not in raw, "ASCII box is reserved for explicit /theme mono"
