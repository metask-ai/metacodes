"""T08/T10/T11:shift+tab 切模式 / 提交本地命令 / 退出清理。"""
from tty_driver import run, submit, READY, wait_for
from asserts import AssertError, TTYAssert

# /help opens Claude Code's Help pane (tabs General / Commands / Custom
# commands); Esc closes it and leaves `⎿  Help dialog dismissed` under the echo.
HELP_PANE = "Esc to close"


def test_T08_shift_tab_cycle(bin_path):
    # 起始 bypassPermissions(--permission bypassPermissions)。shift+tab 循环按
    # App.nextPermMode:default/prompt→acceptEdits→default;非循环模式(bypass)→default。
    # 按一次:bypass→default;再按:default→acceptEdits。
    # 对齐 cc(2026-06-05 改):mode 区分在 footer mode part(`⏵⏵ accept edits on` + 着色),
    # 边框色恒为 accent 不随 mode 变(cc getBorderColor 恒 promptBorder,仅 bash 例外)。
    raw = run(bin_path, ["sleep:0.8", "key:shift_tab", "sleep:0.2",
                         "key:shift_tab", "sleep:0.3"])
    a = TTYAssert(raw)
    a.assert_footer_mode("accept edits")    # footer 显示 cc 风格 title "accept edits on"
    a.assert_border_class("accent")          # 边框不随 mode 变(对齐 cc,撤销旧 plan→warn)


def test_T08b_shift_tab_cycle_closes_after_accept_edits(bin_path):
    # 循环只有两档(plan 模式已移除):第三下从 acceptEdits 回到 default。
    raw = run(bin_path, ["sleep:0.8", "key:shift_tab", "sleep:0.2",
                         "key:shift_tab", "sleep:0.2", "key:shift_tab", "sleep:0.3"])
    a = TTYAssert(raw)
    fr = a.footer_row()
    if fr is None:
        a._fail("无 footer 行")
    if "? for shortcuts" not in a.final.line_text(fr):
        a._fail(f"三下 Shift+Tab 后应回到 default,实际 '{a.final.line_text(fr)}'")


SHIFT_TABS = ("shift_tab", "shift_tab_csi_u", "shift_tab_modify_other_keys")


def test_T08c_each_shift_tab_encoding_cycles_once_at_the_prompt(bin_path):
    """#643: Shift+Tab as ESC [ Z, kitty's ESC [ 9 ; 2 u and xterm
    modifyOtherKeys' ESC [ 27 ; 2 ; 9 ~ each move default to accept edits
    (a second cycle would be back at default) and type nothing into the box."""
    for key in SHIFT_TABS:
        raw = run(bin_path, [READY, "type:ab", f"key:{key}", "sleep:0.3"], permission="default")
        a = TTYAssert(raw)
        if a.final.find_last_row("accept edits on") is None:
            a._fail(f"{key}: the mode did not move from default to accept edits")
        try:
            a.assert_input_echo("ab")
        except AssertError as e:
            raise AssertError(f"{key}: {e}") from e


def test_T10_submit_local_command(bin_path):
    # 提交 /help(本地命令,不打模型):帮助面板出现 → Esc 关闭 → 结果进 scrollback → 新框回底部
    raw = run(bin_path, [READY, "type:/help", "key:enter", wait_for(HELP_PANE, 10),
                         "key:esc", wait_for("Help dialog dismissed", 10)])
    a = TTYAssert(raw)
    a.assert_box_present()                 # 新输入框重新出现
    a.assert_box_at_bottom()
    shown = a.screens_with("! for shell mode")
    if not shown:
        a._fail("/help should show the shortcuts on its General tab")
    if a.final.find_row("! for shell mode") is not None:
        a._fail("the Help pane should be erased after Esc")


def test_T11_exit_clean(bin_path):
    raw = run(bin_path, submit("/exit", "Goodbye"))
    a = TTYAssert(raw)
    a.assert_clean_exit()
    a.assert_prose_contains("Goodbye")


def test_T13_commit_echoes_user_input(bin_path):
    # 提交后用户输入应回显到 scrollback(❯ 行),结果挂在 ⎿ 下(对齐 cc)。
    raw = run(bin_path, [READY, "type:/help", "key:enter", wait_for(HELP_PANE, 10),
                         "key:esc", wait_for("Help dialog dismissed", 10)])
    a = TTYAssert(raw)
    echo = a.final.find_row("❯ /help")
    if echo is None:
        a._fail("the /help echo is missing from the scrollback")
    a.assert_line_contains(echo + 1, "⎿  Help dialog dismissed")
