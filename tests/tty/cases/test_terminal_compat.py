"""终端兼容性:Kitty 协议按 TERM_PROGRAM 白名单分流 + Apple Terminal backslash 换行。

背景:cc-zig 曾无条件发 Kitty 协议(\x1b[>1u),Apple Terminal 不支持 → honor 后发回
乱码/键失常。改成白名单 gate(对齐真 cc terminal.ts:167)。这些 case 验 cc-zig **发什么字节**
(pty 能测);真终端如何响应需用户真机抓。
"""
from tty_driver import run
from asserts import TTYAssert
from screen import Screen


def test_apple_terminal_no_kitty(bin_path):
    # Apple Terminal:不发 Kitty 协议(\x1b[>1u / >4;2m),但 bracketed paste 仍发。
    raw = run(bin_path, ["sleep:0.8"], env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" not in raw, "Apple Terminal 不应发 Kitty enable \\x1b[>1u"
    assert b"\x1b[>4;2m" not in raw, "Apple Terminal 不应发 modifyOtherKeys level 2"
    assert b"\x1b[?2004h" in raw, "bracketed paste 应始终发(兼容性好)"


def test_warp_sends_kitty(bin_path):
    # Warp(白名单):发 Kitty enable —— 实测其默认未开,需 cc-zig 主动发才能 Shift+Enter 换行。
    raw = run(bin_path, ["sleep:0.8"], env={"TERM_PROGRAM": "WarpTerminal", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" in raw, "Warp 应发 Kitty enable \\x1b[>1u"


def test_iterm_sends_kitty(bin_path):
    raw = run(bin_path, ["sleep:0.8"], env={"TERM_PROGRAM": "iTerm.app", "TERM": "xterm-256color"})
    assert b"\x1b[>1u" in raw, "iTerm 应发 Kitty enable"


def test_apple_terminal_backslash_newline_no_exit(bin_path):
    # Apple Terminal 无 Kitty 协议,Shift+Enter 发裸 \r 无法区分 → 换行靠 backslash+return:
    # 行尾 \ + 回车 → 删 \ 插 \n,留在输入框(不提交、不退出)。用 raw:\x0d 发裸回车。
    raw = run(
        bin_path,
        ["sleep:0.8", "type:abc\\", "raw:\\x0d", "sleep:0.3"],
        env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"},
    )
    assert b"Goodbye" not in raw, "backslash 续行不应退出程序"
    a = TTYAssert(raw)
    a.assert_box_height(2)  # 换行后输入框两行(abc + 空续行)
    sc = Screen(24, 80)
    sc.feed(raw)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "abc")  # 第一行是 abc(\ 已删)


def _multiline_footer(bin_path, term_program):
    # 组多行(backslash 续行)后抓 footer 文案。Apple 用裸回车续行,Kitty 终端用 shift_enter。
    if term_program == "Apple_Terminal":
        events = ["sleep:0.8", "type:a\\", "raw:\\x0d", "type:b", "sleep:0.3"]
    else:
        events = ["sleep:0.8", "type:a", "key:shift_enter", "type:b", "sleep:0.3"]
    raw = run(bin_path, events, env={"TERM_PROGRAM": term_program, "TERM": "xterm-256color"})
    sc = Screen(24, 80)
    sc.feed(raw)
    return "\n".join(sc.line_text(r) for r in range(sc.rows))


def test_newline_hint_per_terminal(bin_path):
    # 多行编辑时 footer 显当前终端的换行方式(对齐真 cc getNewlineInstructions,按 cc-zig 能力)。
    apple = _multiline_footer(bin_path, "Apple_Terminal")
    assert "\\ + " in apple and "for newline" in apple, \
        f"Apple Terminal 应显 backslash 换行提示,实际 footer 区:{apple!r}"
    assert "shift + " not in apple, "Apple Terminal 不应显 shift+⏎(它区分不了,会误导)"

    warp = _multiline_footer(bin_path, "WarpTerminal")
    assert "shift + " in warp and "for newline" in warp, \
        f"Warp(白名单)应显 shift+⏎ 换行提示,实际:{warp!r}"

