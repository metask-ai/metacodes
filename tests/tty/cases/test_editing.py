"""T04/T05/T09:退格左右 / Shift+Enter 多行 / Ctrl+U 清行。"""
from tty_driver import run
from asserts import TTYAssert


def test_T04_backspace_and_arrows(bin_path):
    # 打 abcd,左移 2(到 'b' 后 'c' 前... 光标在 c 前),退格删 'b' → acd
    raw = run(bin_path, ["sleep:0.8", "type:abcd", "key:left", "key:left", "key:backspace"])
    a = TTYAssert(raw)
    a.assert_input_echo("acd")
    a.assert_cursor_on_content("a")  # 删 b 后光标在 a 后
    a.assert_box_at_bottom()


def test_T05_multiline_shift_enter(bin_path):
    raw = run(bin_path, ["sleep:0.8", "type:line1", "key:shift_enter", "type:line2"])
    a = TTYAssert(raw)
    a.assert_box_height(2)  # 两个内容行
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "line1")
    a.assert_line_contains(top + 2, "line2")
    a.assert_box_at_bottom()


def test_T09_ctrl_u_clears(bin_path):
    raw = run(bin_path, ["sleep:0.8", "type:hello", "key:ctrl_u"])
    a = TTYAssert(raw)
    a.assert_input_echo("")  # 清空
    a.assert_box_height(1)   # 缩回单行
    a.assert_cursor_on_content("")
    a.assert_box_at_bottom()
