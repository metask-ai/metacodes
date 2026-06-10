"""Agent switcher(区域2)—— footer 下方 agent 列表 + 导航 + 选择 + 查看。

对齐 cc v2.1.169 实拍金标准(napicc 录制):
  footer 空闲 `· ← for agents`;`←` 进 list → `⏺ main` + `◯ Explore <desc> Ns`;
  `↓` 出 `❯` 光标,选中 agent 时头行 hint 变 `Enter to view · x to stop · ...`;
  `Enter` 提交 viewing:输入框上方分隔线 label 变被查看 agent 的 desc + 列表 marker 翻 ⏺
  (**真 cc 不渲染 agent transcript 面板**——只有 label + marker);viewing 态 ↑↓ 只移 ❯
  高亮、Enter 才切被查看对象;`esc` 退回 list(再 esc 关)。

离线驱动:/agent-test-multi 造 3 个假 agent(无线程/无网络)。
"""
from tty_driver import run
from screen import Screen


def _full(raw, rows=34, cols=100):
    sc = Screen(rows, cols)
    sc.feed(raw)
    return "\n".join(sc.line_text(r) for r in range(rows))


def test_S1_footer_shows_for_agents_when_agents_exist(bin_path):
    # 造 agent 后空闲态 footer 出现 `← for agents`。
    raw = run(bin_path, ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.4"],
              term_size=(34, 100))
    full = _full(raw)
    assert "← for agents" in full, f"footer 未出现 '← for agents':\n{full}"


def test_S2_left_opens_switcher_list(bin_path):
    # `←`(输入框空)→ 打开 switcher:出现 `⏺ main` 头 + agent 条目。
    raw = run(bin_path, ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
                         "key:left", "sleep:0.3"], term_size=(34, 100))
    full = _full(raw)
    assert "⏺ main" in full, f"switcher 未出现 main 头行:\n{full}"
    assert "↑/↓ to select" in full, f"switcher 头行缺 hint '↑/↓ to select':\n{full}"
    assert "Explore" in full and "Summarize mod0.py" in full, f"switcher 缺 agent 条目:\n{full}"


def test_S3_down_shows_cursor_and_select_agent_hint(bin_path):
    # `←` 进 → `↓`(选 main)→ `↓`(选 agent0):出现 `❯` 光标 + 头行 hint 变 stop。
    raw = run(bin_path, ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
                         "key:left", "sleep:0.2", "key:down", "sleep:0.15", "key:down", "sleep:0.3"],
              term_size=(34, 100))
    full = _full(raw)
    assert "❯" in full, f"selection 光标 ❯ 未出现:\n{full}"
    # 选中 agent 时头行 hint 变。
    assert "x to stop" in full, f"选中 agent 后头行 hint 未变 'x to stop':\n{full}"


def test_S4_esc_closes_switcher(bin_path):
    # `←` 进 → `esc` 关:switcher 列表消失(不再有 main 头 / hint)。
    raw = run(bin_path, ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
                         "key:left", "sleep:0.2", "key:esc", "sleep:0.3"], term_size=(34, 100))
    full = _full(raw)
    assert "↑/↓ to select" not in full, f"esc 后 switcher 头行仍在:\n{full}"


def test_S5_enter_views_agent_transcript(bin_path):
    # `←` 进 → `↓`(main) → `↓`(agent0) → `Enter` 提交 viewing(对齐真 cc v2.1.169/170 金标准):
    # **主区整体切成被查看 subagent 的完整对话历史**(output_buf:prompt+助手文本+工具行)+ 分隔 label
    # + switcher 列表里被看 agent marker ⏺。golden=tmp/tty_golden/napicc_agent_viewing.txt。
    base = ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
            "key:left", "sleep:0.2", "key:down", "sleep:0.15", "key:down", "sleep:0.15",
            "key:enter", "sleep:0.4"]
    full = _full(run(bin_path, base, term_size=(34, 100)))
    # 分隔线 label = 被查看 agent 的 desc(右对齐 `──── Summarize mod0.py ──`)。
    assert "Summarize mod0.py ──" in full, f"viewing 分隔 label 未出现:\n{full}"
    # 被查看 agent marker = ⏺(switcher 列表里);main 翻 ◯。
    assert "⏺ Explore  Summarize mod0.py" in full, f"被查看 agent marker 未变 ⏺:\n{full}"
    assert "◯ main" in full, f"viewing 时 main marker 未翻 ◯:\n{full}"
    # **核心(V1)**:主区显被查看 subagent 的对话历史(/agent-test-multi 给 agent0 填了假 output_buf)。
    assert "我来分析 mod0.py" in full, f"viewing 主区未显 subagent 助手文本(V1 切对话失败):\n{full}"
    assert "transform" in full, f"viewing 主区未显 subagent 对话内容:\n{full}"


def test_S5b_viewing_pageup_scrolls(bin_path):
    # viewing 态 PageUp 滚动主区对话历史(V2)。16 行小窗口逼出滚动:进入钉底显末尾,
    # PageUp 后显更早的行(对话开头 prompt)。
    base = ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
            "key:left", "sleep:0.2", "key:down", "sleep:0.15", "key:down", "sleep:0.15",
            "key:enter", "sleep:0.4"]
    # 进入(钉底):窗口容不下全部对话 → 末尾的 `transform 第 42 行` 可见,开头 prompt 不可见。
    bottom = _full(run(bin_path, base, term_size=(16, 100)))
    assert "transform 在第 42 行" in bottom, f"viewing 钉底未显末尾对话:\n{bottom}"
    # PageUp → 滚到开头:prompt 行可见。
    up = _full(run(bin_path, base + ["raw:\\x1b[5~", "sleep:0.3"], term_size=(16, 100)))
    assert "我来分析 mod0.py" in up, f"PageUp 未滚到对话开头:\n{up}"


def test_S6_viewing_down_moves_cursor_not_commit(bin_path):
    # viewing 态 ↓ **只移 ❯ 高亮,不切被查看对象**(对齐真 cc:Enter 才提交)。
    # 进 viewing 看 agent0(mod0)后 ↓ 高亮到 agent1,但分隔 label + ⏺ marker 仍是 mod0;
    # 再 Enter 才把被查看对象切到 mod1。
    base = ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
            "key:left", "sleep:0.2", "key:down", "sleep:0.15", "key:down", "sleep:0.15",
            "key:enter", "sleep:0.3", "key:down", "sleep:0.3"]
    full = _full(run(bin_path, base, term_size=(34, 100)))
    # ↓ 只移光标:分隔 label + ⏺ marker 仍指向 mod0(未跟随 sel 切换)。
    assert "Summarize mod0.py ──" in full, f"viewing ↓ 不应改分隔 label(仍 mod0):\n{full}"
    assert "⏺ Explore  Summarize mod0.py" in full, f"viewing ↓ 不应移 ⏺ marker(仍 mod0):\n{full}"
    assert "Summarize mod1.py ──" not in full, f"viewing ↓ 误把 label 切到 mod1(应 Enter 才切):\n{full}"
    # ❯ 高亮已移到 mod1 行(光标独立于被查看对象)。
    assert "❯ ◯ Explore  Summarize mod1.py" in full, f"viewing ↓ 未把 ❯ 高亮移到 mod1:\n{full}"


def test_S6b_viewing_enter_commits_switch(bin_path):
    # viewing 态 ↓ 移到 mod1 后,**再 Enter 提交切换**:分隔 label + ⏺ marker 切到 mod1。
    base = ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
            "key:left", "sleep:0.2", "key:down", "sleep:0.15", "key:down", "sleep:0.15",
            "key:enter", "sleep:0.3", "key:down", "sleep:0.2", "key:enter", "sleep:0.3"]
    full = _full(run(bin_path, base, term_size=(34, 100)))
    assert "Summarize mod1.py ──" in full, f"viewing Enter 未把 label 切到 mod1:\n{full}"
    assert "⏺ Explore  Summarize mod1.py" in full, f"viewing Enter 未把 ⏺ marker 切到 mod1:\n{full}"


def test_S7_viewing_esc_back_to_list(bin_path):
    # viewing 态 esc 退回 list(主区恢复进度树,marker 回 ⏺ main)。
    base = ["sleep:0.8", "type:/agent-test-multi", "key:enter", "sleep:0.3",
            "key:left", "sleep:0.2", "key:down", "sleep:0.15", "key:down", "sleep:0.15",
            "key:enter", "sleep:0.3", "key:esc", "sleep:0.3"]
    full = _full(run(bin_path, base, term_size=(34, 100)))
    # 退出 viewing:主区回进度树(Running N Explore agents),分隔线消失。
    assert "Running 2 Explore agents" in full, f"esc 后主区未回进度树:\n{full}"
    assert "Summarize mod0.py ──" not in full, f"esc 后 viewing 分隔线残留:\n{full}"
    # main marker 回 ⏺(回 main 视图)。
    assert "⏺ main" in full, f"esc 后 main marker 未回 ⏺:\n{full}"
