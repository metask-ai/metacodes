"""T08/T10/T11:shift+tab 切模式 / 提交本地命令 / 退出清理。"""
from tty_driver import run
from asserts import TTYAssert


def test_T08_shift_tab_cycle(bin_path):
    # 起始 bypassPermissions(--permission bypassPermissions)。shift+tab 循环按
    # loop.zig:default/prompt→acceptEdits→plan→default;非循环模式(bypass)→default。
    # 按一次:bypass→default;再按:default→acceptEdits;再按:→plan(应边框变 warn 色)
    raw = run(bin_path, ["sleep:0.8", "key:shift_tab", "sleep:0.2",
                         "key:shift_tab", "sleep:0.2", "key:shift_tab", "sleep:0.3"])
    a = TTYAssert(raw)
    a.assert_footer_mode("plan")
    a.assert_border_class("warn")  # plan 模式边框 = theme.warn(黄)


def test_T10_submit_local_command(bin_path):
    # 提交 /help(本地命令,不打模型):框清掉 → /help 文本进 scrollback → 新框回底部
    raw = run(bin_path, ["sleep:0.8", "type:/help", "key:enter", "sleep:0.5"])
    a = TTYAssert(raw)
    a.assert_prose_contains("Commands:")   # /help 输出
    a.assert_box_present()                 # 新输入框重新出现
    a.assert_box_at_bottom()


def test_T11_exit_clean(bin_path):
    raw = run(bin_path, ["sleep:0.8", "type:/exit", "key:enter", "sleep:0.4"])
    a = TTYAssert(raw)
    a.assert_clean_exit()
    a.assert_prose_contains("Goodbye")


def test_T13_commit_echoes_user_input(bin_path):
    # 提交后用户输入应回显到 scrollback(❯ 行),否则打的东西凭空消失。
    # 用 /help(本地命令不打模型);它的回显行应含 "❯" + "/help"。
    raw = run(bin_path, ["sleep:0.8", "type:/help", "key:enter", "sleep:0.5"])
    a = TTYAssert(raw)
    # scrollback 里应能找到提交的 /help(回显)+ Commands(输出)
    a.assert_prose_contains("/help")
    a.assert_prose_contains("Commands:")
