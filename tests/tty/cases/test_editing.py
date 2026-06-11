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


def test_T05b_ctrl_enter_does_not_newline(bin_path):
    # 真 cc v2.1.172 实测:ctrl+enter(CSI-u 13;5u)**不换行**(整序列被吞,xxxyyy 同行);
    # 只有 shift+enter 换行。cc-zig 对齐 → ctrl_enter no-op。
    raw = run(bin_path, ["sleep:0.8", "type:xxx", "key:ctrl_enter", "type:yyy"])
    a = TTYAssert(raw)
    a.assert_box_height(1)        # 仍单行(未换行)
    a.assert_input_echo("xxxyyy")  # 同行拼接,无 \n


def test_T05c_bare_newline_does_not_exit(bin_path):
    # 回归(Warp bug):Warp plain 模式下 shift+enter 发裸 \n(非 CSI-u 13;2u)。
    # 旧 bug:裸 \n → 提交空/草稿 → 主循环把空提交当 EOF → 打印 Goodbye! 退出整个程序。
    # 修后:裸 \n 提交后留在 REPL,后续输入仍被接收。用 raw:\x0a 绕过 key:shift_enter 的 CSI-u 捷径。
    raw = run(bin_path, ["sleep:0.8", "type:line1", "raw:\\x0a", "sleep:0.3", "type:line2", "sleep:0.3"])
    assert b"Goodbye" not in raw, "裸 \\n 不应触发 Goodbye!/退出"
    from screen import Screen
    sc = Screen(24, 80); sc.feed(raw)
    # 提交 line1 后 REPL 仍活,line2 进了输入框(或 scrollback)。
    assert any("line2" in sc.line_text(r) for r in range(sc.rows)), "裸 \\n 提交后 REPL 应仍接收 line2"


def test_T05d_empty_submit_does_not_exit(bin_path):
    # 回归(Bug B 直接):空 buffer 时裸 \n(空提交)→ 不退出,留 REPL 接收后续 after。
    raw = run(bin_path, ["sleep:0.8", "raw:\\x0a", "sleep:0.3", "type:after", "sleep:0.3"])
    assert b"Goodbye" not in raw, "空提交不应触发 Goodbye!/退出"
    from screen import Screen
    sc = Screen(24, 80); sc.feed(raw)
    assert any("after" in sc.line_text(r) for r in range(sc.rows)), "空提交后 REPL 应仍接收 after"


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


# ── up/down 可视行竖移(对齐真 cc v2.1.172;标记插入法反推光标落点)─────────────────
# 录制金标准 ui_compare/input/vmove.txt;差距矩阵 INPUT_BEHAVIOR_DIFF_2026-06-11.md。

def test_vmove_up_logical_lines(bin_path):
    # 建 aaa/bb/cccc 三逻辑行,光标在 cccc 尾;up 落 bb 行(goal=4 clamp 到 bb 尾),插 @ → bb@。
    raw = run(bin_path, [
        "sleep:0.8", "type:aaa", "key:shift_enter", "type:bb", "key:shift_enter", "type:cccc",
        "key:up", "type:@", "sleep:0.2",
    ])
    a = TTYAssert(raw)
    a.assert_box_height(3)
    top = a.box_top_row()
    a.assert_line_contains(top + 1, "aaa")
    a.assert_line_contains(top + 2, "bb@")   # up 落 bb 行尾(goal 4 clamp 到 len 2)
    a.assert_line_contains(top + 3, "cccc")  # 末行不变


def test_vmove_up_softwrap_is_visual_line(bin_path):
    # 关键证据:up 按【可视行】非逻辑行。窄窗(cols=40)让长行软折成多可视行。
    # 长 'a' 行(软折)+ shift_enter + short;从 short 行 up 应落到 a 行的软折【续行】,非逻辑行首。
    longa = "a" * 60
    raw = run(bin_path, [
        "sleep:0.8", f"type:{longa}", "key:shift_enter", "type:short",
        "key:up", "type:@", "sleep:0.2",
    ], term_size=(24, 40))
    from screen import Screen
    sc = Screen(24, 40); sc.feed(raw)
    # @ 必须落在某条全 'a' 的软折续行里(行内含 a 且含 @),而不是 short 行、不是逻辑行首。
    rows_with_at = [r for r in range(sc.rows) if "@" in sc.line_text(r)]
    assert rows_with_at, "未找到插入的 @ 标记"
    row_txt = sc.line_text(rows_with_at[0])
    assert "a" in row_txt and "short" not in row_txt, \
        f"up 应落到软折续行(全 a 段),实际落在 '{row_txt.strip()}'"


def test_vmove_down_roundtrip(bin_path):
    # cccc 尾 up 到 bb 行,再 down 回 cccc 行,插 $ → cccc 末(goal 保持/重算)。
    raw = run(bin_path, [
        "sleep:0.8", "type:aaa", "key:shift_enter", "type:bb", "key:shift_enter", "type:cccc",
        "key:up", "key:down", "type:$", "sleep:0.2",
    ])
    a = TTYAssert(raw)
    top = a.box_top_row()
    a.assert_line_contains(top + 3, "$")  # 回到 cccc 行,$ 落该行


def test_vmove_first_row_up_no_history_noop(bin_path):
    # 首可视行 up:无历史时回退 history 是 no-op(光标不动,缓冲不变)。
    # 必须用全新空 HOME 隔离(共享 /tmp/cc-tty-home 会累积历史 → up 拉历史污染断言)。
    import tempfile
    home = tempfile.mkdtemp(prefix="cc-tty-vmove-")
    raw = run(bin_path, [
        "sleep:0.8", "type:onlyline", "key:up", "type:X", "sleep:0.2",
    ], env={"HOME": home})
    a = TTYAssert(raw)
    # 单逻辑行,up 在首行 → moved=false → 历史空 no-op;X 插在原光标处(行尾)→ onlylineX
    a.assert_input_echo("onlylineX")


def test_paste_placeholder_footer(bin_path):
    # 粘贴 ≥4 行 → 缓冲转占位符 `[Pasted text #1 +3 lines]`,footer 显 `paste again to expand`
    # (对齐真 cc v2.1.172)。用 bracketed paste(raw ESC[200~ … ESC[201~)一次性送 4 行。
    from screen import Screen
    import tempfile
    home = tempfile.mkdtemp(prefix="cc-tty-paste-")
    paste = "\\x1b[200~L0\\x0aL1\\x0aL2\\x0aL3\\x1b[201~"
    raw = run(bin_path, ["sleep:0.8", f"raw:{paste}", "sleep:0.4"], env={"HOME": home})
    sc = Screen(24, 80); sc.feed(raw)
    # 占位符出现在输入框
    assert any("[Pasted text #" in sc.line_text(r) for r in range(sc.rows)), \
        "≥4 行粘贴应转占位符 [Pasted text #N ...]"
    assert any("+3 lines" in sc.line_text(r) for r in range(sc.rows)), \
        "4 行粘贴占位符应为 +3 lines(M=行数-1)"
    # footer 显 paste again to expand
    assert any("paste again to expand" in sc.line_text(r) for r in range(sc.rows)), \
        "占位符态 footer 应显 'paste again to expand'"
    # 占位符删除后(ctrl_u 清行)footer 复原(不再显 paste again to expand)。
    raw2 = run(bin_path, ["sleep:0.8", f"raw:{paste}", "sleep:0.2", "key:ctrl_u", "sleep:0.3"], env={"HOME": home})
    sc2 = Screen(24, 80); sc2.feed(raw2)
    assert not any("paste again to expand" in sc2.line_text(r) for r in range(sc2.rows)), \
        "占位符删除后 footer 应复原(不再显 paste again to expand)"

