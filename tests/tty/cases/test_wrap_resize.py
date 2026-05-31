"""T06/T12:窄终端长行软折 / resize 自适应。"""
from tty_driver import run
from asserts import TTYAssert


def test_T06_softwrap_narrow(bin_path):
    # cols=24 → inner_w=23 → avail=20。打 30 个 a 应软折成多内容行,不溢出边框。
    raw = run(bin_path, ["sleep:0.8", "type:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], term_size=(24, 24))
    a = TTYAssert(raw, rows=24, cols=24)
    top = a.box_top_row()
    bot = a.box_bottom_row()
    if top is None or bot is None:
        a._fail("窄终端下无完整边框")
    content_rows = bot - top - 1
    if content_rows < 2:
        a._fail(f"长行未软折(content_rows={content_rows},应 >=2)")
    # 每个内容行可见宽度不超过 cols(不冲破右边框/不被硬折)
    for r in range(top + 1, bot):
        w = a.final.line_text(r)
        # 行内容(含 prefix)显示宽不应超过 cols
        from screen import str_width
        if str_width(w) > 24:
            a._fail(f"内容行 {r} 宽 {str_width(w)} 超过 cols=24:'{w}'")


def test_T12_resize_widens(bin_path):
    # 起 24x40,打 hi,resize 到 24x100,**不按键**只等待 → SIGWINCH 应让框自动重画变宽。
    raw = run(bin_path, ["sleep:0.8", "type:hi", "resize:24x100", "sleep:0.6"],
              term_size=(24, 40))
    a = TTYAssert(raw, rows=24, cols=100)
    top = a.box_top_row()
    if top is None:
        a._fail("resize 后无上边框")
    border = a.final.line_text(top)
    from screen import str_width
    # 新边框宽度应接近 cols-1=99(而非旧的 39)
    if str_width(border) < 60:
        a._fail(f"resize 后边框未变宽(宽={str_width(border)},应接近 99)实际 '{border}'")
    a.assert_input_echo("hi")
    a.assert_box_at_bottom()
