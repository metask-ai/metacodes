"""阶段1:? help(非模态 footer 区展开)+ Ctrl+O transcript overlay(模态)。

全离线(死端口,不打模型)。验证(2026-06-05 改:? 对齐 cc 非模态):
  - 空框按 ? → footer 区原地展开快捷键(不需回车),? 不进输入框,**输入框仍在**(非模态)。
  - help 下打其它字符 → 关闭 help,该字符进输入框(非模态)。
  - Ctrl+O → transcript overlay(模态),且不进 alt screen(无 ESC[?1049h)。
  - transcript 滚动/关闭 → 回输入框。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from asserts import TTYAssert  # noqa: E402


def _screen_text(a):
    return "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_help_inline_instant(bin_path):
    # 空框按 ? → footer 区即时展开快捷键(不需回车)。非模态:输入框 ╭ ❯ ╰ 仍在。
    raw = run(bin_path, ["sleep:0.8", "type:?", "sleep:0.3"], per_key_drain=0.1)
    a = TTYAssert(raw)
    text = _screen_text(a)
    assert "Open transcript" in text, text     # 快捷键已展开
    assert "Shift+Tab" in text, text
    # 非模态:输入框边框 + ❯ 行仍在(help 替换的是 footer 行,不是输入框)。
    assert a.box_top_row() is not None, "输入框上边框缺失(help 应非模态):\n" + text
    assert a.content_row() is not None, "❯ 输入行缺失(help 应非模态):\n" + text
    # 不得用 ESC[2J(不进 alt screen / 不清 scrollback)。
    a.assert_no_full_clear()


def test_help_inline_dismiss_and_type(bin_path):
    # ? 开 help,再打字符 x → 关 help 且 x 进输入框(非模态:打字即关并生效)。
    raw = run(bin_path, ["sleep:0.8", "type:?", "sleep:0.3", "type:x", "sleep:0.3"], per_key_drain=0.1)
    a = TTYAssert(raw)
    a.assert_box_present()
    a.assert_box_at_bottom()
    text = _screen_text(a)
    # 关闭后快捷键不应再在屏(已被收缩擦除),且 x 进了输入框。
    assert "Open transcript" not in text, "help 关闭后仍残留:\n" + text
    assert "x" in text, "打字 x 应进输入框(非模态):\n" + text


def test_help_esc_dismiss_no_border_residue(bin_path):
    # 回归(2 个 bug 同锁):
    #  1) ? 开 help 后按 Esc → help 关闭。Esc 是孤立 ESC 字节,KeyParser 卡 esc_seen,
    #     依赖 loop poll 超时 flushEsc 兑现为 .esc 才能到 dispatch——若接线缺失则 Esc 永不生效。
    #     **关键**:Esc 后不能跟任何按键(否则那个字节会在 esc_seen 态把 pending ESC 兑现,
    #     掩盖 flushEsc 接线缺失)。故 esc 是序列最后一个键,只靠 sleep 触发 flushEsc 超时(200ms),
    #     这里给 0.8s。
    #  2) 关 help 后输入框顶边框 ╭ 必须恰为 1 条(help 帧光标终态对齐;否则关 help 残留一条孤立 ╭)。
    raw = run(bin_path,
              ["sleep:0.8",
               "type:?", "sleep:0.4",      # 开 help
               "key:esc", "sleep:0.8"],    # Esc 关 help——序列末键,纯靠 flushEsc 超时兑现
              per_key_drain=0.1)
    a = TTYAssert(raw)
    text = _screen_text(a)
    # help 已关:快捷键说明区不在屏。
    assert "Open transcript" not in text, "Esc 未能关闭 help(flushEsc 接线缺失?):\n" + text
    # 输入框完整且钉底。
    a.assert_box_present()
    a.assert_box_at_bottom()
    # 无边框残留:输入框恰 1 个(早期 bug:关 help 残留孤立顶边框)。
    # 三横线边框(─)与 banner 分隔线通用,不能 count("─");改 count ❯ 内容行 == 1。
    assert text.count("❯") == 1, "输入框残留(关 help 几何错,应恰 1 个 ❯ 输入框):\n" + text
    a.assert_box_at_bottom()  # 顺带验证框钉底、footer 下无残留


def test_help_esc_repeated_no_border_accumulation(bin_path):
    # 边框不累积:反复 ?→Esc 开关 help,顶边框 ╭ 恒为 1 条(早期 bug:每次关 help 残留一条
    # 孤立 ╭,3 轮后屏上 2~3 条)。每个 Esc 都留足 flushEsc 超时,且 Esc 后才接下一个 ?。
    raw = run(bin_path,
              ["sleep:0.8",
               "type:?", "sleep:0.4", "key:esc", "sleep:0.7",
               "type:?", "sleep:0.4", "key:esc", "sleep:0.7",
               "type:?", "sleep:0.4", "key:esc", "sleep:0.7"],
              per_key_drain=0.1)
    a = TTYAssert(raw)
    text = _screen_text(a)
    a.assert_box_present()
    a.assert_box_at_bottom()
    assert "Open transcript" not in text, "末轮 Esc 未关 help:\n" + text
    # 三横线边框不可 count("─")(与 banner 通用);改 count ❯ == 1 验证无框累积。
    assert text.count("❯") == 1, "3 轮开关后输入框累积残留(应恰 1 个 ❯):\n" + text


def test_esc_then_char_not_swallowed(bin_path):
    # 回归:ESC 后紧跟普通字符,该字符不被吞(早期 bug:feed 在 esc_seen 态兑现 ESC 时丢字节)。
    # 场景:先开 help(? ),再一次性发 ESC+'k'(raw 两字节连发,模拟终端把快速两次按键合批送来)。
    #   - ESC → 关 help(非 vim 下 esc 在空框是 dispatch 消费);
    #   - 'k' → 进输入框(不能被吞)。
    # raw:\x1bk 让两字节无 per_key_drain 间隔进内核缓冲,loop 逐字节 read:0x1b→esc_seen,
    # 紧接读到 'k' 在 esc_seen 态兑现 ESC + pending 'k';drain 接线把 'k' 喂到 editor。
    # (若间隔 >200ms 会先 flushEsc,测的就不是吞字符路径——故必须 raw 连发。)
    raw = run(bin_path,
              ["sleep:0.8",
               "type:?", "sleep:0.4",   # 开 help
               "raw:\\x1bk", "sleep:0.5"],  # ESC+k 连发:关 help + k 进框
              per_key_drain=0.1)
    a = TTYAssert(raw)
    text = _screen_text(a)
    assert "Open transcript" not in text, "ESC 未关 help:\n" + text
    a.assert_box_present()
    # 关键:'k' 必须出现在输入框内容行(没被吞)。content_row() 返回行号,取该行文本断言。
    crow = a.content_row()
    assert crow is not None, "❯ 输入行缺失:\n" + text
    content_text = a.final.line_text(crow)
    assert "k" in content_text, "ESC 后的字符 'k' 被吞了(drain 接线缺失?):\n输入行=[" + content_text + "]\n" + text


def test_ctrl_o_enters_inline_transcript(bin_path):
    # Ctrl+O → inline 内联 transcript viewer(对齐 cc 2.1.167,DIFF#6/#7)。
    # **不进 alt-screen**(无 ESC[?1049h):原地重绘视口(绝对光标定位,不 2J/不 \n),
    # 不动 scrollback;footer 变 cc 风格 `Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll`。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.4"], per_key_drain=0.1)
    assert b"\x1b[?1049h" not in raw, "inline transcript 不应进 alt-screen(ESC[?1049h)"
    assert b"Showing detailed transcript" in raw, "应渲染 cc 风格 transcript footer"


def test_ctrl_o_toggle_close(bin_path):
    # Ctrl+O 开 inline → 再 Ctrl+O 关(viewer 认 0x0f 退出)→ 恢复输入框。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "key:ctrl_o", "sleep:0.4"], per_key_drain=0.1)
    a = TTYAssert(raw)
    a.assert_box_present()
    assert b"\x1b[?1049h" not in raw, "inline 不进 alt-screen"
    # 关闭后 transcript footer 不再在最终屏。
    text = _screen_text(a)
    assert "Showing detailed transcript" not in text, "关闭后残留 transcript footer:\n" + text


def test_ctrl_o_double_press_clean(bin_path):
    # 连按两次 Ctrl+O(开+关)→ 净回输入框,无 transcript 残留。
    raw = run(bin_path,
              ["sleep:0.8",
               "key:ctrl_o", "key:ctrl_o", "sleep:0.5"],  # 连按两次:开+关
              per_key_drain=0.08)
    a = TTYAssert(raw)
    a.assert_box_present()           # 回到输入框
    text = _screen_text(a)
    assert "Showing detailed transcript" not in text, "退出后残留 transcript footer:\n" + text


def test_question_in_nonempty_buffer_is_literal(bin_path):
    # 非空 buffer 按 ? → 普通字符进输入框(不开 help)。
    raw = run(bin_path, ["sleep:0.8", "type:foo?", "sleep:0.3"], per_key_drain=0.08)
    a = TTYAssert(raw)
    text = _screen_text(a)
    # foo? 应在输入框里,不展开 help 快捷键。
    assert "Open transcript" not in text, "非空 buffer 的 ? 误触发 help"
    assert "foo?" in text, text


def test_ctrl_o_bottom_anchored_idempotent(bin_path):
    # 回归(2026-06-06 真 bug):框**贴屏底 + 历史多**时,两次 Ctrl+O(开+关)后框位置
    # 必须与按之前一致(box_top 不跳)。早期嵌入式 overlay bug:进入 transcript 从区顶向下画
    # ~19 行,框贴屏底时滚动 ~15 行把 scrollback 永久滚走 → 退出后框跳屏顶(box_top 19→4)。
    # inline 内联(对齐 cc):用绝对光标定位重绘视口、绝不 emit \n 滚动,故 scrollback 不被毁,
    # 框位置幂等。这是 inline 实现必须守住的正确性不变式。
    import re

    def box_only(events):
        a = TTYAssert(run(bin_path, ["sleep:0.8"] + events, term_size=(24, 80),
                          per_key_drain=0.04, startup_drain=0.8), rows=24, cols=80)
        return a.box_top_row()

    msgs = []
    for i in range(6):
        msgs += ["type:msg %d zig" % i, "key:enter", "sleep:1.0"]

    box0 = box_only(msgs)
    box2 = box_only(msgs + ["key:ctrl_o", "sleep:0.6", "key:ctrl_o", "sleep:0.6"])

    # 前置:框确实被推到屏底(否则测不出 bug)。
    assert box0 is not None and box0 >= 14, \
        f"T0 框应被历史推到屏底(box_top={box0}),否则测不出跳屏顶 bug"
    # 核心幂等:两次 Ctrl+O 后框回原位(无跳屏顶、无滚走历史)。
    assert box0 == box2, f"两次 Ctrl+O 后框漂移(box_top {box0}→{box2}):inline 滚动毁了 scrollback"


def test_ctrl_o_idempotent_with_agent_panel(bin_path):
    # 回归(2026-06-09 真 bug):有 agent 进度树/task panel(输入框上方可变行)时,
    # transcript_viewer 旧版硬编码 box_h=5 忽略 panel 行 → 退出锚定错位 → 残留 + TUI 乱。
    # 修:box_h = region.fixedRegionHeight()+1(含 panel)。本测试钉死:有 panel 时连续 Ctrl+O
    # 收敛到干净贴底态(框完整 + agent 树完整无残留 + 无重叠),且再按幂等(box_top 稳定)。
    setup = ["type:/agent-test-multi", "key:enter", "sleep:0.4"]
    # 连按 4 次(2 个开关周期)后应稳定。
    raw = run(bin_path, ["sleep:0.8"] + setup +
              ["key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5",
               "key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5"],
              term_size=(24, 100), per_key_drain=0.04, startup_drain=0.8)
    a = TTYAssert(raw, rows=24, cols=100)
    full = "\n".join(a.final.line_text(r) for r in range(24))
    # 框存在且贴屏底(footer 下无大片残留)。
    a.assert_box_present()
    a.assert_box_at_bottom()
    # agent 进度树完整保留(panel 未被 Ctrl+O 毁)。
    assert "Running 2 Explore agents" in full, "Ctrl+O 后 agent 进度树丢失:\n" + full
    assert "Summarize mod2.py" in full, "Ctrl+O 后 agent 树残缺:\n" + full
    # 无重复框边框(残留会留多条 ─── 行)。
    border_lines = [r for r in range(24) if a.final.line_text(r).strip().startswith("─" * 20)]
    assert len(border_lines) == 2, f"框边框行数异常(应 2,实 {len(border_lines)}),疑残留:\n" + full


def test_ctrl_o_tall_history_inline(bin_path):
    # 长历史 + 小终端:Ctrl+O 进 inline transcript,退出恢复输入框,无 alt-screen。
    msgs = []
    for i in range(5):
        msgs += ["type:line %d" % i, "key:enter", "sleep:0.9"]
    raw = run(bin_path, ["sleep:0.8"] + msgs + ["key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5"],
              term_size=(12, 80), per_key_drain=0.05, startup_drain=0.8)
    a = TTYAssert(raw, rows=12, cols=80)
    text = _screen_text(a)
    assert b"\x1b[?1049h" not in raw, "inline 不应进 alt-screen"
    assert "Showing detailed transcript" not in text, "退出后残留 transcript footer:\n" + text
    a.assert_box_present()
