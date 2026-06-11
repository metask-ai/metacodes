"""tty 真模型 e2e:从一份终端 log 的"找茬"中确认的 4 个 TUI bug 的复现测试。

每个 bug 真相已用代码核实(根因见 doc 计划 / 各测试 docstring)。这些测试先红(在未修
代码上失败=真复现)后绿(修复生效)。真模型(base_url=None → napi.metask-ai.com)读 schema
自主调工具,用强指令 prompt + 确定性命令(exit 3 / sleep 20)压模型漂移,重试 3 次。

断言通道:
  ① transcript JSONL(权威层):工具确实被调用(read_tool_uses + tool_called)。
  ② prose(scrollback 散文本):工具卡走 stdout_writer.print 裸字节落滚动历史,不是 frame。
     图标 ⏺/✓/✗ 与卡名同行 → 定位含 "⏺ <Tool>" 的行,断言其图标。

跳过:TTY_SKIP_MODEL=1(CI/离线)。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import (  # noqa: E402
    SKIP, RETRIES, SkipTest, fresh_home, run_e2e_tool, read_tool_uses,
    tool_called, any_tool_called,
)
from tty_driver import run  # noqa: E402
from asserts import split_frames, TTYAssert  # noqa: E402

# 去 ANSI/CSI(SGR 颜色、光标移动);⏺ ✓ ✗ ▶ 是普通 codepoint,strip 不掉,保留。
_ANSI = re.compile(rb"\x1b\[[0-9;?>]*[A-Za-z]")


def _prose_text(raw: bytes) -> str:
    """split_frames 去 frame 字节,保 scrollback prose,再 strip ANSI 成纯文本。"""
    prose = b"".join(c for k, c in split_frames(raw) if k == "prose")
    return _ANSI.sub(b"", prose).decode("utf-8", "replace")


def _card_header_line(text: str, tool_name: str):
    """返回完成卡头部行 '⏺ <tool> <status> <time>'(图标与卡名、状态同物理行)。

    一次工具调用产生两行 '⏺ <tool>':起始卡(无状态)与完成卡(带 ✓/✗/▶ + 时长)。
    优先返回带状态符的完成卡;若都没有(仍在执行中)退回最后一个匹配行。
    类A 工具(Bash/Read/Grep/Glob)完成卡标题是自然语言(对齐 cc),非 `Tool(args)`——
    故按别名匹配(Bash→"shell command"、Read→"file"…)。
    """
    NL_ALIAS = {
        "Bash": ("Bash", "shell command"),
        "Read": ("Read", " file"),
        "Grep": ("Grep", "pattern", "Search"),
        "Glob": ("Glob", " file"),
    }
    needles = NL_ALIAS.get(tool_name, (tool_name,))
    matches = [ln for ln in text.splitlines() if "⏺" in ln and any(n in ln for n in needles)]
    if not matches:
        return None
    for ln in matches:
        if any(sym in ln for sym in ("✓", "✗", "▶")):
            return ln
    return matches[-1]


def test_e2e_bug3_bash_nonzero_exit_icon(bin_path):
    """#3(已对齐 cc v2.1.168 实拍,2026-06-09 修正测试):Bash 非零退出的 **committed
    scrollback 卡**头部是中性 `⏺ Ran 1 shell command`(**非 ✗**),失败由 body($ cmd)+
    模型后续文本(exit code N)体现。

    旧版测试错误假设"头部应 ✗"——napicc 实拍真 cc 证明:Bash committed 卡标题恒中性 ⏺,
    无 ✓/✗(cc 设计:类A 工具完成卡用自然语言标题 + 中性 bullet,成败不进头部图标)。
    cc-zig renderLiveDone 同此(⏺ + body)。✗ 降级仅在 Ctrl+O transcript 详细视图(headerIcon),
    不在正常 scrollback。故本测试改为验证:Bash 调用了 + committed 卡是中性 ⏺ 标题(不崩、不误显 ✗)。
    """
    if SKIP:
        return
    ever_called = False
    for _ in range(RETRIES):
        raw, home, uses = run_e2e_tool(
            bin_path,
            "Use the Bash tool to run exactly this command and nothing else: exit 3",
            "Bash", required_keys=["command"], wait_s=14,
        )
        if not tool_called(uses, "Bash", ["command"]):
            continue  # 模型没调 Bash → 漂移,重试
        ever_called = True
        text = _prose_text(raw)
        hdr = _card_header_line(text, "Bash")
        # committed 卡标题:中性 `⏺ Ran ... shell command`(对齐 cc 实拍),**不得**误显 ✗/✓ 状态符。
        if hdr is not None and "shell command" in hdr and "✗" not in hdr and "✓" not in hdr:
            return  # 绿:中性 ⏺ 标题,对齐 cc
    if not ever_called:
        raise SkipTest("模型 %d 次重试均未调 Bash(漂移),被测路径未触发" % RETRIES)
    raise AssertionError("Bug#3:Bash committed 卡标题应为中性 `⏺ Ran ... shell command`(对齐 cc 实拍),实际异常")


def test_e2e_bug4_auto_background_neutral_icon(bin_path):
    """#4:Bash 超 15s 自动转后台,committed 卡须显 `▶ moved to background job …`,
    不裸吐 auto_backgrounded JSON,头部不显 ✓。

    根因(原始):formatAutoBackgrounded 返回正常 JSON(无 status/exit_code)→ is_error=false → ✓;
    renderBashResult 的 job_id 分支要求 status!=null 不命中 → 落 renderGenericFold 裸吐 JSON。
    第二根因(2026-06-11 本轮抓到):类A Bash 的 committed scrollback 卡走 **renderLiveDone**(非
    renderResult),而 renderLiveDone 丢 content、只显 ⏺标题 + ⎿输入预览 → auto-bg 转后台**无任何
    痕迹**。修:renderLiveDone 经 bgJobLine 共用渲染 → committed 卡显 ▶ 转后台提示。

    **断言走权威层 + scrollback prose,不查最终视口**:auto-bg 后模型常持续 BashOutput 轮询,把那张
    卡挤出可见视口——查最终屏幕会误判成"未触发"而 skip(旧 bug,实测踩坑)。改为:
      ① 触发判据 = transcript 里出现 auto_backgrounded 结果(权威,与视口无关);
      ② 渲染判据 = scrollback prose(整条字节流的 committed 部分,卡滚走仍在)含 ▶ 转后台提示行,
         且 prose 不裸吐 auto_backgrounded JSON。
    """
    if SKIP:
        return
    from e2e_helpers import read_tool_results  # 权威层:transcript tool_result content
    triggered = False  # auto-background 真触发(transcript 出现 auto_backgrounded 结果)
    for _ in range(RETRIES):
        # wait 给足:模型起步 + sleep 20 + auto-bg(15s)+ 转后台卡 commit。短窗口会截断在卡渲染前。
        raw, home, uses = run_e2e_tool(
            bin_path,
            "Run this shell command for me right now with the Bash tool: sleep 20",
            "Bash", required_keys=["command"], wait_s=36,
        )
        if not tool_called(uses, "Bash", ["command"]):
            continue  # 没调 Bash → 漂移,重试
        # ① 权威层触发判据:该次 run 的 transcript 里出现 auto_backgrounded 结果。
        results = read_tool_results(home)
        if not any('"auto_backgrounded":true' in r for r in results):
            continue  # 命令没到 15s / 没转后台 → 漂移,重试
        triggered = True
        # ② 渲染层判据:scrollback prose(committed 字节,卡滚走仍在)。
        text = _prose_text(raw)
        ok_marker = "▶ moved to background job" in text    # 修复输出的转后台提示行
        ok_nojson = '"auto_backgrounded"' not in text      # committed 卡未裸吐 JSON
        hdr = _card_header_line(text, "Bash")              # Bash 完成卡头部(中性 ⏺,无 ✓)
        ok_icon = hdr is None or "✓" not in hdr
        if ok_marker and ok_nojson and ok_icon:
            return
    if not triggered:
        raise SkipTest("模型 %d 次重试均未触发 auto-background(未调 Bash / 命令未到 15s)" % RETRIES)
    raise AssertionError("Bug#4 regression:auto-background committed 卡缺 ▶ 转后台提示 / 裸吐 JSON / 头部显 ✓")



# #6 用的 prompt:启动后台 Explore subagent,做多个工具调用(数 .zig + 读一个),TaskOutput 轮询。
_BUG6_PROMPT = (
    "Launch a background subagent (run_in_background) using the Task tool with subagent_type "
    "Explore to do these steps: first list the .zig files under src/core, then read one of them. "
    "After launching, keep checking its progress with TaskOutput."
)


def test_e2e_bug6_subagent_tool_count_accumulates(bin_path):
    """#6:subagent 进度树执行中 '· N tools ·' 应随工具调用累加,而非恒 0。

    根因:agent_job_registry trampoline 只实时更新 current_turn,不更新 tool_calls;
    tool_calls 只在 job 跑完后一次性赋值 → snapshotJobs 执行中读到恒 0。
    修复:progress_fn 加 tool_calls 参数,trampoline 持锁实时回写 self.tool_calls。

    断言走 frame(agent 树是底部 in-frame 面板,非 scrollback):某 running 帧
    (含 "Running ... subagent")出现 '· N tool'(N>=1)。
    """
    if SKIP:
        return
    pat = re.compile(r"·\s*([1-9]\d*)\s*tool")
    tree_seen = False  # subagent 树是否真出现过(被测路径触发)
    for _ in range(RETRIES):
        home = fresh_home()
        raw = run(
            bin_path,
            ["sleep:1.0", "type:" + _BUG6_PROMPT, "key:enter", "sleep:32"],
            base_url=None, env={"HOME": home}, term_size=(40, 100),
            per_key_drain=0.04, startup_drain=1.2,
        )
        a = TTYAssert(raw, rows=40, cols=100)
        for sc in a.frame_screens:
            full = "\n".join(sc.line_text(r) for r in range(sc.rows))
            if "Running" in full and "subagent" in full:
                tree_seen = True  # 树渲染出来了 → 被测路径触发
                if pat.search(full):
                    return  # 绿:执行中 tool 计数 >0
    if not tree_seen:
        raise SkipTest("模型 %d 次重试均未启动后台 subagent(树从未出现),被测路径未触发" % RETRIES)
    raise AssertionError("Bug#6 regression:subagent 树出现但执行中始终 '· 0 tools ·'(计数未累加)")


def test_e2e_bug8_task_start_card_visible(bin_path):
    """#8:Task 调用应有可见起始卡(⏺ Task),用户能看到 subagent 启动;结果仍隐藏。

    根因:agent_loop gate `if resultRenderMode(name)==.hidden continue` — Task→hidden
    → 连起始卡(renderStart)都被跳过,用户对 Task 启动毫无感知。
    修复:showStartCard 分离起始卡/结果 — Task/Agent 起始卡可见,结果仍 hidden。
    """
    if SKIP:
        return
    ever_called = False  # Task/Agent 是否真被调用
    for _ in range(RETRIES):
        raw, home, uses = run_e2e_tool(
            bin_path,
            "Use the Task tool to launch a general-purpose subagent that counts "
            "the .zig files under src/core.",
            "Task", required_keys=[], wait_s=22,
        )
        if not any_tool_called(uses, ["Task", "Agent"]):
            continue
        ever_called = True
        text = _prose_text(raw)
        has_start = _card_header_line(text, "Task") is not None
        # 负向不变量:Task 结果 JSON 不应裸吐(只放开起始卡,非结果)
        no_result_json = ('"stop_reason"' not in text) and ('"final_text"' not in text)
        if has_start and no_result_json:
            return
    if not ever_called:
        raise SkipTest("模型 %d 次重试均未调 Task/Agent(漂移),被测路径未触发" % RETRIES)
    raise AssertionError("Bug#8 regression:Task 被调用但起始卡(⏺ Task)不可见,或结果 JSON 被裸吐")
