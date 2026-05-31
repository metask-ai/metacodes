"""T01-T03 + T07:布局 / 回显 / 中文 / 无跳动。"""
from tty_driver import run
from asserts import TTYAssert


def test_T01_empty_box_layout(bin_path):
    raw = run(bin_path, ["sleep:0.8"])
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()
    fr = a.footer_row()
    a.assert_line_contains(fr, "? for shortcuts")
    a.assert_line_contains(fr, "shift+tab to cycle")
    # 光标在 ❯ 行 col=2
    a.assert_cursor_on_content("")


def test_T02_ascii_echo(bin_path):
    raw = run(bin_path, ["sleep:0.8", "type:hello"])
    a = TTYAssert(raw)
    a.assert_input_echo("hello")
    a.assert_cursor_on_content("hello")
    a.assert_box_at_bottom()


def test_T03_cjk_echo(bin_path):
    raw = run(bin_path, ["sleep:0.8", "type:你好x"])
    a = TTYAssert(raw)
    a.assert_input_echo("你好x")
    a.assert_cursor_on_content("你好x")  # 期望光标列 = 2 + (2+2+1) = 7
    a.assert_box_at_bottom()


def test_T07_no_jitter(bin_path):
    raw = run(bin_path, ["sleep:0.8", "type:abc"])
    a = TTYAssert(raw)
    a.assert_no_jitter()
    a.assert_no_full_clear()
