"""T25-T27:TaskTab —— 输入框上方显示当前 in_progress 任务(本次新功能)。

离线驱动:用测试专用本地命令 /task-test[:label] 造一个 in_progress 任务
(loop.zig),无需打模型即可让 TaskTab 渲染。验证 ◐ <label> 行出现在输入框上方,
框仍钉底、布局不乱。
"""
from tty_driver import run
from asserts import TTYAssert


def test_T25_tasktab_appears_above_box(bin_path):
    # 造任务 → 输入框上方应出现 `◐ building widget` 行。
    raw = run(bin_path, ["sleep:0.8", "type:/task-test:building widget", "key:enter", "sleep:0.4"])
    a = TTYAssert(raw)
    a.assert_box_present()
    top = a.box_top_row()
    if top is None or top == 0:
        a._fail(f"box_top_row 异常(top={top}),无法验证上方 TaskTab")
    # TaskTab 在上边框正上方一行。
    tab_line = a.final.line_text(top - 1)
    if "◐" not in tab_line and "building widget" not in tab_line:
        a._fail(f"TaskTab 行(row {top-1})未含 ◐/label:'{tab_line}'")


def test_T26_tasktab_keeps_box_at_bottom(bin_path):
    # 有 TaskTab 时框仍钉底(下边框紧邻 footer,新增的上方行不破坏底部锚定)。
    raw = run(bin_path, ["sleep:0.8", "type:/task-test:x", "key:enter", "sleep:0.4"])
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()


def test_T27_no_tasktab_when_no_task(bin_path):
    # 无 in_progress 任务时不画 TaskTab(区不含 ◐),回归确认默认行为不变。
    raw = run(bin_path, ["sleep:0.8"])
    a = TTYAssert(raw)
    a.assert_box_present()
    full = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    if "◐" in full:
        a._fail("无任务时不应出现 TaskTab(◐)")
