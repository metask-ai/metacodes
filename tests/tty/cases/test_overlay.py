"""阶段1:? help(非模态 footer 区展开)+ Ctrl+O transcript overlay(模态)。

全离线(死端口,不打模型)。验证(2026-06-05 改:? 对齐 cc 非模态):
  - 空框按 ? → footer 区原地展开快捷键(不需回车),? 不进输入框,**输入框仍在**(非模态)。
  - help 下打其它字符 → 关闭 help,该字符进输入框(非模态)。
  - Ctrl+O → 全屏 transcript(模态,alt-screen ESC[?1049h;退出由终端自动恢复主缓冲)。
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
    # Ctrl+O → 全屏 transcript viewer(alt-screen)。多 agent 长跑时 inline 重画会显两份/footer
    # 堆叠/几何漂移,根治法=进 alt-screen 独立缓冲全屏画,退出由终端自动恢复主缓冲(banner+对话+框)。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.4"], per_key_drain=0.1)
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen(ESC[?1049h)"
    assert b"Showing detailed transcript" in raw, "应渲染 cc 风格 transcript footer"


def test_ctrl_o_via_kitty_csi_u(bin_path):
    # 实测 bug:Kitty 键盘协议白名单终端把 Ctrl+O 编成 CSI-u(ESC[111;5u,111='o'/5=Ctrl)
    # 而非裸 0x0f。旧 CSI-u 解析表无 'o' → 返 .unknown → Ctrl+O 静默失效("完全无反应")。
    # 用 raw 注入 CSI-u 序列(模拟这类终端的真实字节),断言 viewer 照常打开。
    raw = run(bin_path, ["sleep:0.8", "raw:\\x1b[111;5u", "sleep:0.4"], per_key_drain=0.1)
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen"
    assert b"Showing detailed transcript" in raw, "CSI-u 形式的 Ctrl+O 也应打开 transcript viewer(回归 bug)"


def test_ctrl_o_csi_u_toggles_closed(bin_path):
    # 实测 bug:agent 运行期 Ctrl+O 进 transcript 后再按 Ctrl+O 无法 toggle 关闭。根因:
    # transcript_viewer 自己的裸字节 read 循环只认 0x0f,不认 Kitty CSI-u ESC[111;5u →
    # 白名单终端第二次 Ctrl+O(CSI-u 形式)被忽略,viewer 不退出。修:viewer 解析 CSI-u codepoint。
    # 第一次 0x0f 开,第二次 CSI-u 关 → 最终屏无 transcript footer(成功 toggle)。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "raw:\\x1b[111;5u", "sleep:0.4"], per_key_drain=0.15)
    assert b"Showing detailed transcript" in raw, "第一次 Ctrl+O 应打开 transcript"
    a = TTYAssert(raw)
    final = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    assert "Showing detailed transcript" not in final, \
        "第二次 Ctrl+O(CSI-u 形式)未 toggle 关闭 transcript(回归 bug):\n" + final
    a.assert_box_present()  # 关闭后输入框恢复


def _screen_full(raw, rows=20, cols=90):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_ctrl_o_markdown_render_equivalent(bin_path):
    # bug#1+#2 根治:对话含 markdown,Ctrl+O viewer 渲染等效主区(markdown 渲染、无 ▶/◀ 角色头),
    # 退出后主区不变源码、无残留。/md-test 注入 1 user + 1 assistant(含 **粗体**/`代码`/列表)。
    base = ["sleep:0.8", "type:/md-test", "key:enter", "sleep:0.4"]
    # viewer 内:markdown 渲染(无源码 `**`)+ cc 风格前缀(❯/⏺,无 ▶ user/◀ assistant)。
    inside = _screen_full(run(bin_path, base + ["key:ctrl_o", "sleep:0.5"], term_size=(20, 90)), rows=20)
    assert "⏺ 我是 MetaCode" in inside, f"viewer 未用 ⏺ 前缀渲染 assistant:\n{inside}"
    assert "❯ 你是谁" in inside, f"viewer 未用 ❯ 前缀渲染 user:\n{inside}"
    assert "**MetaCode**" not in inside, f"viewer 显示 markdown 源码 `**`(bug#1):\n{inside}"
    assert "▶ user" not in inside and "◀ assistant" not in inside, f"viewer 残留 ▶/◀ 角色头(bug#2):\n{inside}"
    assert "• 阅读代码" in inside, f"viewer 未渲染列表(- → •):\n{inside}"
    # 退出后:主区无源码 `**`、无 ▶/◀ 残留(进出渲染等效)。
    after = _screen_full(run(bin_path, base + ["key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5"], term_size=(20, 90)), rows=20)
    assert "**MetaCode**" not in after, f"退出后主区变 markdown 源码(bug#1):\n{after}"
    assert "▶ user" not in after and "◀ assistant" not in after, f"退出后 ▶/◀ 残留(bug#2):\n{after}"


def test_ctrl_o_toggle_close(bin_path):
    # Ctrl+O 开 inline → 再 Ctrl+O 关(viewer 认 0x0f 退出)→ 恢复输入框。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "key:ctrl_o", "sleep:0.4"], per_key_drain=0.1)
    a = TTYAssert(raw)
    a.assert_box_present()
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen"
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


def test_ctrl_o_box_top_idempotent(bin_path):
    # 回归(2026-06-06 真 bug,2026-06-13 改 alt-screen 根治):历史多时两次 Ctrl+O(开+关)后框
    # 位置必须与按之前一致(box_top 不跳)。早期嵌入式 overlay bug:进入 transcript 从区顶向下画
    # ~19 行,滚动把 scrollback 永久滚走 → 退出后框跳屏顶;后续 inline 修法又按下葫芦起瓢(退出 \n
    # 重发对话尾把框推走、贴底漂移)。**alt-screen 根治**:进 ESC[?1049h 切独立缓冲(主屏 grid+
    # 光标整屏保存)、全屏画 transcript;退出 ESC[?1049l 由终端**逐字节恢复主缓冲** → box_top 必然
    # 与按前一致(终端保证),无任何 inline 几何数学。
    def box_only(events):
        a = TTYAssert(run(bin_path, ["sleep:0.8"] + events, term_size=(24, 80),
                          per_key_drain=0.04, startup_drain=0.8), rows=24, cols=80)
        return a.box_top_row()

    msgs = []
    for i in range(6):
        msgs += ["type:msg %d zig" % i, "key:enter", "sleep:1.0"]

    box0 = box_only(msgs)
    box2 = box_only(msgs + ["key:ctrl_o", "sleep:0.6", "key:ctrl_o", "sleep:0.6"])

    # 核心幂等:alt-screen 退出自动恢复主缓冲 → 框回原位(无跳屏顶、无滚走历史、无贴底漂移)。
    assert box0 is not None and box2 is not None, \
        f"box_top 定位失败(box0={box0}, box2={box2})"
    assert box0 == box2, f"两次 Ctrl+O 后框漂移(box_top {box0}→{box2}):alt-screen 恢复失准"


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


def test_ctrl_o_agent_panel_box_top_idempotent(bin_path):
    # 回归(2026-06-10 真 bug,用户实测):有 agent panel 时 Ctrl+O 开+关后 box_top **数值**必须幂等。
    # 旧 bug:viewer 退出绝对定位贴屏底(box_top=rows-5),但基线固定区跟随内容(不贴底)→ 两种锚定
    # 不一致 → 整体下移~panel高度,banner 滚出。修(方案A):viewer DECSC 锚区顶、不覆盖 banner,退出
    # 回区顶相对重画 → 跟随内容、幂等。覆盖多终端高度(漂移量=rows-20,高终端漂得多,必须都幂等)。
    # (旧 test_ctrl_o_idempotent_with_agent_panel 只验框存在/树保留/边框计数,漏了 box_top 数值漂移。)
    def box_top(rows):
        raw = run(bin_path, ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.4"],
                  term_size=(rows, 90), per_key_drain=0.05, startup_drain=0.8)
        return TTYAssert(raw, rows=rows, cols=90).box_top_row()

    def box_top_after_toggle(rows):
        raw = run(bin_path, ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.4",
                             "key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5"],
                  term_size=(rows, 90), per_key_drain=0.05, startup_drain=0.8)
        return TTYAssert(raw, rows=rows, cols=90).box_top_row(), raw

    for rows in (20, 24, 30, 40):
        b0 = box_top(rows)
        b2, raw = box_top_after_toggle(rows)
        assert b0 is not None and b2 is not None, f"rows={rows} box_top 定位失败"
        assert b0 == b2, f"rows={rows}: agent panel Ctrl+O 开关后 box_top 漂移 {b0}→{b2}(应幂等,跟随内容不贴底)"
        # banner + agent 树退出后保留(viewer 不覆盖 banner)。
        import re as _re
        txt = _re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", raw).decode("utf-8", "replace")
        assert "Running 2 Explore agents" in txt, f"rows={rows}: Ctrl+O 后 agent 进度树丢失"


def test_ctrl_o_tall_history_alt_screen(bin_path):
    # 长历史 + 小终端:Ctrl+O 进全屏 transcript(alt-screen),退出由终端自动恢复主缓冲(输入框回来)。
    # 这正是"多 agent 长跑显两份"的代表场景——alt-screen 独立缓冲根治:进退都不碰主屏 scrollback。
    msgs = []
    for i in range(5):
        msgs += ["type:line %d" % i, "key:enter", "sleep:0.9"]
    raw = run(bin_path, ["sleep:0.8"] + msgs + ["key:ctrl_o", "sleep:0.5", "key:ctrl_o", "sleep:0.5"],
              term_size=(12, 80), per_key_drain=0.05, startup_drain=0.8)
    a = TTYAssert(raw, rows=12, cols=80)
    text = _screen_text(a)
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen"
    assert "Showing detailed transcript" not in text, "退出后残留 transcript footer:\n" + text
    a.assert_box_present()


def test_gen_region_agent_churn_no_spinner_residue(bin_path):
    # 回归(2026-06-10):生成期固定区在 agent 进度树**行数动态变化**(subagent 陆续 spawn)时,
    # erase/draw 几何不能漏擦 → spinner 行不得遗留进 scrollback。/agent-churn-test 离线驱动:
    # enterGenerating → 循环 tickSpinner + 增 agent(树长高) + emit,leaveGenerating。
    # (单线程几何不变式守护;真模型多线程时序的 spinner 遗留是另一类并发 bug,见 KG,offline tty 复现不了。)
    import re
    raw = run(bin_path, ["sleep:0.8", "type:/agent-churn-test", "key:enter", "sleep:1.2"],
              term_size=(30, 100), per_key_drain=0.05, startup_drain=0.8)
    a = TTYAssert(raw, rows=30, cols=100)
    lines = [a.final.line_text(r) for r in range(30)]
    spin = [l for l in lines if re.search(r"[✸✻✦✶✺✷✽·] \w+…", l)]
    # 最终屏最多 1 个 spinner(完成态/收尾),不得有多行遗留快照。
    assert len(spin) <= 1, f"生成期 agent 树变化致 spinner 遗留 scrollback({len(spin)} 行):\n" + "\n".join(lines)


def test_ctrlb_backgrounds_main_session_deterministic(bin_path):
    """Ctrl+B 生成期把主对话转后台续跑(确定性,慢 mock,不打真模型)。

    机制:慢 mock turn1 慢吐 ~7.5s text 后以 tool_use 收尾 → 必有 turn2。在 turn1 执行期间注入
    Ctrl+B(0x02)→ 信号置位 → turn2 **开头**被拦截,run 返回 .backgrounded → loop 深拷贝转后台。
    断言:① 前台打出 "已转后台续跑";② agent tree 出现转后台的 main agent;③ turn2 的哨兵
    "SHOULD_NOT_REACH" 不出现(turn2 起点确实被拦,没继续跑)。
    """
    import re
    # 准备工具要读的文件(turn1 末尾的 Read 在转后台前可能已被调度,文件存在避免噪声)。
    with open("/tmp/bgtest_file.txt", "w") as f:
        f.write("hi\n")
    from slow_mock_server import SlowMockServer, slow_text_then_tooluse, simple_text
    turns = [
        slow_text_then_tooluse(n_chunks=15, delay=0.5),  # turn1:宽窗口 + tool_use 收尾
        simple_text("SHOULD_NOT_REACH"),                  # turn2:不该到达(被转后台拦截)
    ]
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            ["type:do it", "key:enter", "sleep:2.5", "raw:\\x02", "sleep:6.5", "type:next", "sleep:0.5"],
            base_url=srv.url, startup_drain=0.8, per_key_drain=0.15,
        )
    txt = re.compile(rb"\x1b\[[0-9;?>]*[A-Za-z]").sub(b"", raw).decode("utf-8", "replace")
    assert "已转后台续跑" in txt, "Ctrl+B 未触发转后台(无 '已转后台续跑' 提示):\n" + txt[-1500:]
    assert "SHOULD_NOT_REACH" not in txt, "turn2 被执行了(转后台未在 turn 边界拦截):\n" + txt[-1500:]
    # agent tree 出现转后台的 main agent(loop 打 "Running 1 main agent" 或树里含 main)。
    assert ("main agent" in txt) or ("main" in txt), "agent tree 未显示转后台的 main agent:\n" + txt[-1500:]


def test_ctrl_o_multiagent_no_scroll_garbage(bin_path):
    # 用户实测 bug:多 agent 运行期(生成期固定区高)按 Ctrl+O → 多余空行 + scrollback 重复
    # (根因:viewer 从很低的区顶相对下移画 view_rows=rows-3 行,撑出屏底滚屏)。修:view_rows 夹到
    # anchor 下方可用行数,不滚屏。本测试:/agent-test-multi 造 3 agent(高区)→ 慢 mock 进生成期 →
    # Ctrl+O。断言:footer 恰好 1 次(无重复)、transcript 正常打开。
    import re
    from slow_mock_server import SlowMockServer, slow_text_then_tooluse
    # 慢 text turn(宽窗口)以 tool_use 收尾;agent tree 由 /agent-test-multi 预置。
    turns = [slow_text_then_tooluse(n_chunks=14, delay=0.5)]
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.4",
             "type:go", "key:enter", "sleep:2.5", "key:ctrl_o", "sleep:1.2"],
            base_url=srv.url, startup_drain=0.8, per_key_drain=0.15, term_size=(24, 80),
        )
    a = TTYAssert(raw, rows=24, cols=80)
    final = "\n".join(a.final.line_text(r) for r in range(24))
    foot = final.count("Showing detailed transcript")
    assert foot == 1, f"transcript footer 出现 {foot} 次(应 1 次;>1=滚屏重复 bug):\n{final}"
    assert "Showing detailed transcript" in final, "Ctrl+O 未打开 transcript viewer"
    # 全屏 transcript 进 alt-screen(独立缓冲 → 根治多 agent"显两份":主屏对话被 alt 缓冲整屏遮住)。
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen"


def test_ctrl_o_autorepeat_debounced_no_altscreen_churn(bin_path):
    # 用户实测 bug(Warp):问题正在回答中(生成期)"不断 Ctrl+O" →
    #   症状1:footer 出现重复的多行文字;症状2:停止下来之后再 Ctrl+O,终端界面丧失幂等性。
    #
    # 真因:Warp 是 Kitty 协议白名单终端(input.zig kbd_enable_seq),Ctrl+O 编成 CSI-u `ESC[111;5u`;
    #   "不断" = 按住 → 键盘 auto-repeat 把一连串 CSI-u 批量塞进同一个 read 缓冲。每个都 toggle 一次
    #   transcript viewer 的 alt-screen(`ESC[?1049h`/`l`)→ 真终端跟不上高频 alt-screen 切换 → footer
    #   多行堆叠 + 退出后框不幂等。(离线 Screen 模型如实模拟 alt-screen 存/复原 → 渲染层面复现不出
    #   真机抖动;但"churn 次数无上限"这一**机制**是离线确定可测的代理指标:批量 burst 经 watcher/viewer
    #   逐字节 toggle 出 N 对 1049h/l。)
    #
    # 修法(render_region.noteCtrloAndShouldSuppressReopen,生成期+输入期同源):open 前去抖,抑制紧随的 reopen
    #   → 按住一次只产生一对 open/close(退化为单次 toggle 干净路径)。
    # 本测试钉死机制:批量 auto-repeat burst 产生的 alt-screen 开关数 **有界**(去抖前每 burst≈burst长度/2
    #   对,去抖后每 burst 恰 1 对),且末态干净幂等。用真 Warp 字节(批量 CSI-u),非裸 0x0f。
    from slow_mock_server import SlowMockServer, slow_text_then_end

    BURST = "raw:" + ("\\x1b[111;5u" * 20)  # 按住 Ctrl+O 的 auto-repeat(批量 CSI-u,单次注入=同一 read 缓冲)
    H, L = b"\x1b[?1049h", b"\x1b[?1049l"

    def trial(events, rows=24, cols=80):
        with SlowMockServer([slow_text_then_end(n_chunks=14, delay=0.4)]) as srv:
            raw = run(bin_path, ["sleep:0.8", "type:go", "key:enter"] + events,
                      base_url=srv.url, startup_drain=0.8, per_key_drain=0.06,
                      term_size=(rows, cols))
        return TTYAssert(raw, rows=rows, cols=cols), raw

    # 基线:同样的生成→停止,不按 Ctrl+O,等生成完整结束。框顶 = 幂等参照。
    base_a, _ = trial(["sleep:8.0"])
    box0 = base_a.box_top_row()

    # 复现:进生成 ~1.3s 按住 Ctrl+O(burst)→ 等生成结束 → 停止后再按住 Ctrl+O(burst)。
    a, raw = trial(["sleep:1.3", BURST, "sleep:7.5", BURST, "sleep:0.8"])
    full = "\n".join(a.final.line_text(r) for r in range(a.rows))

    # sanity:Ctrl+O 确实开过 alt-screen viewer(否则没走到目标路径)。
    h, l = raw.count(H), raw.count(L)
    assert h >= 1, "Ctrl+O 未进 alt-screen(没复现到目标路径):\n" + full

    # 机制核心:每个 burst(两个,生成期 + 停止后)经去抖只产生 1 对 open/close → 总 alt-screen 开关有界。
    # 去抖前同输入是每 burst ≈10 对(h/l≈20/20)→ 此 bound 清晰区分修前/修后,且 close 由 viewer
    # 内部消费故 h==l(末态 viewer 关闭,无悬挂)。
    assert h <= 4 and l <= 4, \
        f"按住 Ctrl+O 产生过多 alt-screen 开关(h/l={h}/{l},去抖失效 → 真终端 footer 堆叠/不幂等)"
    assert h == l, f"alt-screen 开/关不配对(h/l={h}/{l}),末态有悬挂 viewer"

    # 末态干净:无生成期 footer / transcript footer 残留(多行堆叠 bug)。
    assert "Showing detailed transcript" not in full, "停止后残留 transcript footer:\n" + full
    assert full.count("esc to interrupt") == 0, "停止后残留生成期 footer 'esc to interrupt':\n" + full

    # 幂等:框完整钉底、box_top 与基线一致(无漂移)、框边框恰 2 条(无残留堆叠)。
    a.assert_box_present()
    a.assert_box_at_bottom()
    assert box0 is not None and a.box_top_row() is not None, \
        f"box_top 定位失败(base={box0}, after={a.box_top_row()})"
    assert box0 == a.box_top_row(), \
        f"按住 Ctrl+O 后框漂移(box_top {box0}→{a.box_top_row()}):丧失幂等性\n" + full
    border_lines = [r for r in range(a.rows) if a.final.line_text(r).strip().startswith("─" * 20)]
    assert len(border_lines) == 2, \
        f"框边框行数异常(应 2,实 {len(border_lines)}),疑 footer/框残留堆叠:\n" + full


def test_gen_ctrl_o_exit_region_redraw_self_cleans(bin_path):
    # 用户实测(Warp):反复 Ctrl+O 后 footer/spinner 留**重影**,下一轮输出才复原。
    # 真因(DSR 诊断 + script 真机字节坐实):cc-zig 输出**字节级干净**(离线 + script 1718 帧无重复),
    #   是 Warp 的 alt-screen 退出 `?1049l` 主缓冲恢复**不精确**(游标列不还原、行偶尔偏 1)→ 旧固定区
    #   残留。**关键观察:"下一轮输出复原"** = 一次正常的区重画就清掉了它。
    # 根因修(单一机制):drawGenRegion 开头 `\r`/`\n` 把光标落到区顶(已提交文本下方)后,`ESC[0J`
    #   清到屏末——**每次区重画都把区下方主动清净**,不再"假设 ?1049l 恢复干净"。删掉了 DSR 证明对
    #   Warp 无效的 DECSC/DECRC 死路(那是 cargo-cult)。
    # **诚实边界**:离线 Screen 模型如实还原游标 → 复现不出真机残影,本测试只能守**机制**(退出重画发
    #   ESC[0J + 末态固定区干净);真机视觉是否消失需 Warp 实测确认。不再断言任何 DECSC/DECRC(死代码)。
    from slow_mock_server import SlowMockServer, slow_text_then_end

    H, L, J = b"\x1b[?1049h", b"\x1b[?1049l", b"\x1b[0J"
    with SlowMockServer([slow_text_then_end(n_chunks=18, delay=0.5)]) as srv:
        # 生成期开+关 transcript(Warp CSI-u 形式,间隔 >120ms 避免被去抖折叠 → 真 toggle)。
        raw = run(bin_path,
                  ["sleep:0.8", "type:go", "key:enter", "sleep:1.5",
                   "raw:\\x1b[111;5u", "sleep:0.6", "raw:\\x1b[111;5u", "sleep:4.0"],
                  base_url=srv.url, startup_drain=0.8, per_key_drain=0.06, term_size=(24, 80))

    a = TTYAssert(raw, rows=24, cols=80)
    full = "\n".join(a.final.line_text(r) for r in range(a.rows))
    # sanity:生成期确实开/关过 alt-screen。
    assert raw.count(H) >= 1 and raw.count(L) >= 1, "生成期 Ctrl+O 未开/关 alt-screen:\n" + full
    # 机制:alt-screen 退出(?1049l)后的区重画必含 ESC[0J(区下方自清)。
    li = raw.rfind(L)
    assert J in raw[li:], "alt-screen 退出后的区重画未发 ESC[0J(区自清机制丢失):\n" + full
    # **绝不**再断言 DECSC/DECRC ——DSR 证明 Warp 对它不还原列,是死代码,已删。
    assert b"\x1b8" not in raw, "退出路径仍在发 DECRC(ESC 8)死代码(DSR 已证 Warp 无效,应删净)"
    # 末态干净:footer `esc to interrupt` 不重影(恰 ≤1 行),输入框存在。
    foot = sum(1 for r in range(a.rows) if "esc to interrupt" in a.final.line_text(r))
    assert foot <= 1, f"footer `esc to interrupt` 重影({foot} 行):\n" + full


def test_ctrl_o_during_websearch_card_no_card_pileup(bin_path):
    # 用户实测(Warp):输入"调研一下今天的ai新闻"→ 生成期出现 `⏺ Web Search` 进度卡 + `Iterating…`
    # spinner,此时不断按下 Ctrl+O → 卡与 spinner **重复堆叠进 scrollback**(`⏺ Web Search` 一行接一行)。
    #
    # 真因:同 test_ctrl_o_autorepeat_debounced —— Warp(Kitty 白名单)Ctrl+O=CSI-u,按住 auto-repeat
    #   高频 toggle transcript viewer 的 alt-screen;此场景底部固定区里**多了一张 WebSearch 进度卡**,
    #   每次 alt-screen 进出真终端把"卡+spinner"那几行漏进 scrollback → 肉眼看到卡堆叠。
    #   (离线 Screen 模型如实模拟 alt-screen 存/复原 + 固定区原地重画 → committed scrollback 里卡数恒 0,
    #   复现不出真机堆叠;但"卡有进度卡时 alt-screen churn 是否有界"这一机制离线确定可测。)
    # 修法:render_region.noteCtrloAndShouldSuppressReopen 去抖,按住一次只一对 open/close。
    #
    # 本测试钉死:复刻用户输入 + 3-turn mock(主 turn 发 WebSearch tool_use → 慢子请求让 `⏺ Web Search`
    #   卡常驻 → 续写),期间按住 Ctrl+O。断言 ① alt-screen 开关有界(去抖生效,修前每 burst≈卡长度/2 对);
    #   ② committed scrollback 里 `⏺ Web Search` 卡**不堆叠**(≤1,卡是瞬态的,正常永不 commit);③ 末态干净。
    from slow_mock_server import (SlowMockServer, slow_text_then_tooluse,
                                  slow_websearch_subrequest, simple_text)
    from asserts import split_frames
    import re

    H, L = b"\x1b[?1049h", b"\x1b[?1049l"
    BURST = "raw:" + ("\\x1b[111;5u" * 20)  # 按住 Ctrl+O 的 auto-repeat(批量 CSI-u)

    # 3 turns:① 主 turn 慢吐文本后发 WebSearch tool_use;② WebSearch 隔离子请求(慢,卡常驻 ~7s);
    #          ③ 拿到结果后的续写(end_turn 收尾)。
    turns = [
        slow_text_then_tooluse(n_chunks=4, delay=0.4, tool="WebSearch",
                               tool_input='{"query":"今天的ai新闻"}'),
        slow_websearch_subrequest(delay=0.5, n_delay=14),
        simple_text("今天的 AI 新闻摘要。"),
    ]
    with SlowMockServer(turns) as srv:
        # 复刻用户:输入提示词 → 回车 → 进生成 + WebSearch 卡出现后,按住 Ctrl+O(burst)。
        ev = ["sleep:0.8", "type:调研一下今天的ai新闻", "key:enter", "sleep:2.6",
              BURST, "sleep:0.6", BURST, "sleep:5.5"]
        raw = run(bin_path, ev, base_url=srv.url, startup_drain=0.8,
                  per_key_drain=0.05, term_size=(24, 80))

    a = TTYAssert(raw, rows=24, cols=80)
    full = "\n".join(a.final.line_text(r) for r in range(a.rows))
    prose = b"".join(c for k, c in split_frames(raw) if k == "prose")
    prose_txt = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", prose).decode("utf-8", "replace")

    # sanity:确实走到了"有 WebSearch 卡 + Ctrl+O 进 alt-screen"的目标路径。
    h, l = raw.count(H), raw.count(L)
    assert h >= 1, "Ctrl+O 未进 alt-screen(没复现到目标路径):\n" + full

    # ① alt-screen 开关有界(去抖):每个 burst 折叠成一对 → 总数小;修前同输入 ≈20+ 对。
    assert h <= 4 and l <= 4, \
        f"按住 Ctrl+O 产生过多 alt-screen 开关(h/l={h}/{l},去抖失效 → 真终端卡/spinner 堆叠)"
    assert h == l, f"alt-screen 开/关不配对(h/l={h}/{l}),末态有悬挂 viewer"

    # ② 进度卡不堆叠:`⏺ Web Search` 卡是瞬态固定区元素,完成走 clearToolCard,正常永不进 scrollback。
    #    用户症状是它一行接一行 commit → 此处钉死 committed 里至多 1 次(留 1 容差给边界提交)。
    card_committed = prose_txt.count("⏺ Web Search")
    assert card_committed <= 1, \
        f"`⏺ Web Search` 进度卡堆叠进 scrollback {card_committed} 次(用户实测 bug):\n" + prose_txt[-1500:]

    # ③ 末态干净:输入框完整、无生成期 footer 残留。
    a.assert_box_present()
    assert "esc to interrupt" not in full, "末态残留生成期 footer 'esc to interrupt':\n" + full
