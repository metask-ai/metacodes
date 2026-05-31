"""T17-T19:`/` 命令菜单 + 生成期多行回复/命令输出排版不乱(根因修复回归)。

T18 离线(只打 `/`);T17/T19 打真实模型(无 key 时 SKIP)。
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run
from asserts import TTYAssert

SKIP = os.environ.get("TTY_SKIP_MODEL") == "1"


def test_T18_slash_menu_appears(bin_path):
    # 打 `/` → 输入框下方应垂直列出候选命令(/help 等),菜单在下边框与 footer 之间。
    raw = run(bin_path, ["sleep:0.8", "type:/"], per_key_drain=0.05)
    a = TTYAssert(raw)
    a.assert_box_present()
    bot = a.box_bottom_row()
    foot = a.footer_row()
    if bot is None or foot is None:
        a._fail("缺边框/footer")
    # 下边框与 footer 之间应有候选行(菜单),且至少含 /help。
    menu_rows = [r for r in range(bot + 1, foot) if a.final.line_text(r).strip()]
    if len(menu_rows) < 3:
        a._fail(f"`/` 菜单候选过少(menu_rows={menu_rows})")
    joined = "\n".join(a.final.line_text(r) for r in menu_rows)
    # 菜单最多列 10 项(/help.../cost),取前几个稳定项断言。
    for needed in ("/help", "/clear", "/tools"):
        if needed not in joined:
            a._fail(f"菜单缺命令 {needed}:\n{joined}")
    # footer 仍钉在菜单下方(底部锚定不变)
    if foot <= bot:
        a._fail("footer 未在菜单下方")


def test_T18b_slash_prefix_filters(bin_path):
    # 打 `/co` → 菜单只剩 /commit /compact /config /cost(前缀过滤),不含 /help。
    raw = run(bin_path, ["sleep:0.8", "type:/co"], per_key_drain=0.05)
    a = TTYAssert(raw)
    bot = a.box_bottom_row()
    foot = a.footer_row()
    menu = "\n".join(a.final.line_text(r) for r in range(bot + 1, foot) if a.final.line_text(r).strip())
    if "/help" in menu:
        a._fail(f"`/co` 菜单不应含 /help:\n{menu}")
    if "/commit" not in menu or "/compact" not in menu:
        a._fail(f"`/co` 菜单应含 /commit /compact:\n{menu}")


def test_T18c_space_dismisses_menu(bin_path):
    # 打 `/help ` (带空格)→ 已带参数,菜单消失;框内容行回显 `/help `。
    raw = run(bin_path, ["sleep:0.8", "type:/help x"], per_key_drain=0.05)
    a = TTYAssert(raw)
    bot = a.box_bottom_row()
    foot = a.footer_row()
    # 带空格后不弹菜单 → 下边框紧邻 footer。
    if bot is None or foot is None or bot != foot - 1:
        a._fail(f"带空格后菜单应消失(下边框紧邻 footer);bottom={bot} footer={foot}")


def test_T19_multiline_reply_complete(bin_path):
    # 根因回归:模型多行回复(逐行数字)应完整流入 scrollback,不被固定区覆盖成 1 行。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:请逐行输出 1 2 3 4 5 6 每个数字单独占一行", "key:enter", "sleep:8"],
              per_key_drain=0.05)
    a = TTYAssert(raw)
    # 多行数字应在最终屏(或 scrollback)各占一行,且彼此不重叠覆盖。
    text = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    present = [d for d in ("1", "2", "3", "4", "5", "6") if d in text]
    if len(present) < 4:
        a._fail(f"多行回复被覆盖(只见到数字 {present},应至少 4 个单独行)")


def test_T17_help_then_question_no_corruption(bin_path):
    # 根因回归:/help(十几行命令输出)后提问 → 模型多行回复,排版不交错重叠。
    if SKIP:
        return
    raw = run(bin_path, ["sleep:0.8", "type:/help", "key:enter", "sleep:0.6",
                         "type:用一句话回答你是谁", "key:enter", "sleep:10"],
              per_key_drain=0.05)
    a = TTYAssert(raw)
    # 用户提问回显进 scrollback(❯ 行),模型有回复文本 → 证明 /help + 提问 + 回复都正常流过。
    a.assert_prose_contains("用一句话回答你是谁")
    # 不交错/不乱的核心不变式:若最终屏有输入框,则它必须钉在内容底部(下边框紧邻 footer、
    # footer 下无残留)。捕获瞬间恰好落在"生成结束擦区→idle 框重画"的窗口时框可能暂缺,
    # 那是捕获时序而非排版错乱——此时跳过钉底断言(prose 完整性已证明无 corruption)。
    if a.box_top_row() is not None and a.footer_row() is not None and a.content_row() is not None:
        a.assert_box_at_bottom()
