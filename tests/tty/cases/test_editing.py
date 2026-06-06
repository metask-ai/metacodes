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


def test_T09b_ctrl_u_paste_hint(bin_path):
    # 对齐 cc DIFF#9:Ctrl+U 删行后,框上方右对齐显示 `Ctrl+Y to paste deleted text`;
    # 之后打字提示消失;Ctrl+Y 把删除内容粘回。
    from screen import Screen
    raw = run(bin_path, ["sleep:0.8", "type:hello world", "key:ctrl_u", "sleep:0.3"])
    sc = Screen(24, 80); sc.feed(raw)
    hint_rows = [r for r in range(sc.rows) if "Ctrl+Y to paste deleted text" in sc.line_text(r)]
    assert hint_rows, "Ctrl+U 后未显示 'Ctrl+Y to paste deleted text' 提示"
    # 提示在输入框(❯)上方
    box_row = next((r for r in range(sc.rows) if sc.line_text(r).strip().startswith("❯")), None)
    assert box_row is not None and hint_rows[0] < box_row, "提示应在输入框上方"

    # 打字后提示消失
    raw2 = run(bin_path, ["sleep:0.8", "type:hello", "key:ctrl_u", "sleep:0.1", "type:Z", "sleep:0.3"])
    sc2 = Screen(24, 80); sc2.feed(raw2)
    assert not any("Ctrl+Y to paste" in sc2.line_text(r) for r in range(sc2.rows)), "打字后提示应消失"

    # Ctrl+Y 粘回删除内容
    raw3 = run(bin_path, ["sleep:0.8", "type:hello", "key:ctrl_u", "sleep:0.15", "key:ctrl_y", "sleep:0.3"])
    sc3 = Screen(24, 80); sc3.feed(raw3)
    assert any("hello" in sc3.line_text(r) for r in range(sc3.rows)), "Ctrl+Y 应把删除的 hello 粘回"
