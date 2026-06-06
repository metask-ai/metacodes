"""T32-T34:渲染盲区补充 —— 多行收缩擦除 + slash 菜单多前缀过滤。

T32/T33 离线(键盘驱动);T34 离线(只打 `/h`)。补 test_editing(只测过单行 ctrl_u)
和 test_slash_menu(只测过 /co 前缀)的盲区。
"""
from tty_driver import run
from asserts import TTYAssert


def test_T32_multiline_shrink_to_one(bin_path):
    # 3 行(shift_enter x2)→ ctrl_u 清空 → 收缩回 1 行,框仍钉底、下边框紧邻 footer。
    raw = run(bin_path, [
        "sleep:0.8",
        "type:line1", "key:shift_enter",
        "type:line2", "key:shift_enter",
        "type:line3",
        "key:ctrl_u",
    ])
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_height(1)        # 收缩回单内容行
    a.assert_box_at_bottom()      # 收缩残留已擦除,框仍钉底(不留旧的更高区域)


def test_T33_grow_then_shrink_top_anchored(bin_path):
    # 增长(1→3 行)再收缩(→1 行):本实现是**上边框锚定**(top 恒定,框向下铺/
    # 收缩时下边框回弹)。这与 UI_LAYER_DESIGN "底部锚定" 不矛盾——"底部锚定"指
    # 固定区相对消息流末尾锚定(不碰 scrollback),框内部上锚向下长,与 cc 的 Ink
    # 流式布局一致(已核实非 bug)。断言上边框行号逐帧恒定(不抖)。
    raw = run(bin_path, [
        "sleep:0.8",
        "type:a", "key:shift_enter", "type:b", "key:shift_enter", "type:c",
        "key:ctrl_u",
    ])
    a = TTYAssert(raw)
    tops = []
    for sc in a.frame_screens:
        # 跳过 Ctrl+Y paste 提示帧:Ctrl+U 后框上方多一行 `Ctrl+Y to paste deleted text`
        # (对齐 cc DIFF#9),框合理下移 1 行——这不是 grow/shrink 抖动,排除该帧再检跳动。
        if sc.find_last_row("Ctrl+Y to paste deleted text") is not None:
            continue
        # 三横线边框无 ╭;改锚 ❯ 内容行检测跳动(框漂则 ❯ 行号漂)。
        t = sc.find_last_row("❯")
        if t is not None:
            tops.append(t)
    if not tops:
        a._fail("无输入框帧")
    if len(set(tops)) != 1:
        a._fail(f"输入框跳动!逐帧 ❯ 行号={tops}(上锚定应恒定)")
    # 收缩后回到单行(下边框 = top + 2)。
    a.assert_box_height(1)


def test_T34_slash_filter_h_prefix(bin_path):
    # `/h` 前缀:菜单应含 /help /history,不应含 /commit /cost(覆盖 /co 之外的另一前缀)。
    raw = run(bin_path, ["sleep:0.8", "type:/h"], per_key_drain=0.05)
    a = TTYAssert(raw)
    bot = a.box_bottom_row()
    foot = a.footer_row()
    if bot is None or foot is None:
        a._fail("缺边框/footer")
    menu = "\n".join(a.final.line_text(r) for r in range(bot + 1, foot) if a.final.line_text(r).strip())
    if "/help" not in menu:
        a._fail(f"`/h` 菜单应含 /help:\n{menu}")
    if "/commit" in menu or "/cost" in menu:
        a._fail(f"`/h` 菜单不应含 /commit /cost:\n{menu}")
