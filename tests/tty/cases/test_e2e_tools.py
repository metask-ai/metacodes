"""tty 真模型 e2e:工具被模型自主调用验证(A 组:安全直接工具)。

真模型(base_url=None → napi.metask-ai.com)读 schema 自主决定调工具。这是 cassette
做不到的——cassette 的工具参数是手写死的,模型不参与决策,抓不到 schema/漏参 bug。

断言双通道:屏幕工具卡片 `⚙ <Tool>` + transcript tool_use(name+必填参数)。重试 3 次。

跳过:TTY_SKIP_MODEL=1(CI/离线)。
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import SKIP, assert_tool_e2e, read_tool_uses, tool_called  # noqa: E402


def test_e2e_write(bin_path):
    if SKIP:
        return
    # 自然提示词。写文件意图:Write 首选;模型偶尔用 Bash(echo>)也算意图满足。
    assert_tool_e2e(
        bin_path,
        "Create the file /tmp/cc_e2e_w.txt with the content hello_e2e",
        "Write",
        required_keys=["file_path", "content"],
        wait_s=14,
        require_card=False,
        accept_tools=["Write", "Bash"],
    )


def test_e2e_read(bin_path):
    if SKIP:
        return
    # 先放一个文件,让模型有东西可读。
    with open("/tmp/cc_e2e_read_src.txt", "w") as f:
        f.write("READ_ME_E2E_MARKER\n")
    assert_tool_e2e(
        bin_path,
        "Show me the contents of the file /tmp/cc_e2e_read_src.txt",
        "Read",
        required_keys=["file_path"],
        wait_s=14,
        require_card=False,
        accept_tools=["Read", "Bash"],
    )


def test_e2e_bash(bin_path):
    if SKIP:
        return
    # Bash 是无可替代工具(运行命令),保持首选断言 + schema。
    assert_tool_e2e(
        bin_path,
        "Run the shell command: echo cc_e2e_bash_marker",
        "Bash",
        required_keys=["command"],
        wait_s=14,
        require_card=False,
        accept_tools=["Bash"],
    )


def test_e2e_edit(bin_path):
    if SKIP:
        return
    with open("/tmp/cc_e2e_edit.txt", "w") as f:
        f.write("alpha_before beta\n")
    # 自然提示词。Edit 是两步(Read→Edit must-read-first),给足等待。
    # 改文件意图:Edit 首选;模型用 Bash(sed)或 Write 重写也算意图满足。
    assert_tool_e2e(
        bin_path,
        "In the file /tmp/cc_e2e_edit.txt, change 'alpha_before' to 'alpha_after'",
        "Edit",
        required_keys=["file_path", "old_string", "new_string"],
        wait_s=22,
        require_card=False,
        accept_tools=["Edit", "Bash", "Write"],
    )


def test_e2e_grep(bin_path):
    if SKIP:
        return
    with open("/tmp/cc_e2e_grep.txt", "w") as f:
        f.write("noise\nGREP_E2E_NEEDLE\nmore\n")
    # 自然提示词。MiniMax 在满工具集下选搜索工具高度不确定(实测同 prompt 多次在
    # Grep/Bash/TaskCreate 间漂移)——接受 Grep 或 Bash 完成搜索都算"意图满足"。
    # Grep 工具自身的 schema 正确性由 L2 tool_schema_coverage_test 守卫,不靠真模型采样。
    assert_tool_e2e(
        bin_path,
        "Search for the text GREP_E2E_NEEDLE in the file /tmp/cc_e2e_grep.txt",
        "Grep",
        required_keys=["pattern"],
        wait_s=14,
        require_card=False,
        accept_tools=["Grep", "Bash"],
    )


def test_e2e_glob(bin_path):
    if SKIP:
        return
    # 同 Grep:接受 Glob 或 Bash(ls/find)完成查找。
    assert_tool_e2e(
        bin_path,
        "Find all files matching *.txt in the /tmp directory",
        "Glob",
        required_keys=["pattern"],
        wait_s=14,
        require_card=False,
        accept_tools=["Glob", "Bash"],
    )


def test_e2e_taskcreate(bin_path):
    if SKIP:
        return
    # 当事工具(本次 bug 主角):验证模型能拿到 subject+description schema 并传齐
    # (旧 bug:properties 空 → 模型漏 description → MissingRequiredField)。
    # 保持严格断言 TaskCreate + 两个 required 字段——这正是真模型 e2e 唯一能"无中生有"
    # 验证 schema 修复的点。实测模型稳定主动调 TaskCreate,不 flaky。
    assert_tool_e2e(
        bin_path,
        "Use the TaskCreate tool to create a task with subject 'e2e smoke' and description 'verify schema'",
        "TaskCreate",
        required_keys=["subject", "description"],
        wait_s=14,
        require_card=False,
    )


def test_e2e_task_subagent(bin_path):
    if SKIP:
        return
    # 强断言 subagent **出口**(不只是主 agent 发起了 Task)。这是之前漏掉熔断 bug 的根因:
    # 旧断言只验"主 agent 调了 Task",subagent 内部第一轮熔断也照样绿;且 accept_tools 的
    # Bash/Glob 兜底把"Task 子系统坏了"直接吞掉。现在:让主 agent 起后台 subagent + 轮询到
    # 完成,从 transcript 的 TaskOutput 结果断言 subagent 真干完活——
    #   stop_reason != tool_loop(没被熔断)、turns >= 2(真干活非卡在第一轮)、
    #   final_text 有实质内容(非空开场白)、不含 ANSI(\x1b)。
    # 不给 Bash/Glob 兜底:这个用例就是要钉 subagent 子系统本身。
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from e2e_helpers import RETRIES, fresh_home, find_subagent_done  # noqa: E402
    from tty_driver import run as _run  # noqa: E402
    import shutil as _shutil

    prompt = ("Launch a background subagent with the Task tool (run_in_background true, "
              "subagent_type Explore) to count the .zig files under src/core. Then poll with "
              "TaskOutput until it finishes and report the count.")
    last_done = None
    homes = []
    for _ in range(RETRIES):
        home = fresh_home()
        homes.append(home)
        _run(bin_path,
             ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:32"],
             base_url=None, env={"HOME": home}, per_key_drain=0.04, startup_drain=1.2)
        done = find_subagent_done(home)
        if done is not None:
            last_done = done
            sr = done.get("stop_reason")
            ft = done.get("final_text", "") or ""
            turns = done.get("turns", 0)
            ok = (sr != "tool_loop"
                  and turns >= 2
                  and len(ft.strip()) >= 20
                  and "\x1b" not in ft
                  and "\\u001b" not in ft)
            if ok:
                for h in homes:
                    _shutil.rmtree(h, ignore_errors=True)
                return
    # 全部 attempt 失败 → 判负,带诊断
    diag = ("subagent 出口断言未通过(%d attempts)。最后一次 done=%r\n"
            "  期望: stop_reason!=tool_loop, turns>=2, final_text 实质且无 ANSI\n"
            "  HOME(保留): %s") % (RETRIES, last_done, homes[-1] if homes else "?")
    for h in homes[:-1]:
        _shutil.rmtree(h, ignore_errors=True)
    raise AssertionError(diag)


def test_e2e_agent_tree_onscreen(bin_path):
    """真模型 + 后台 subagent → 主 agent 轮询期间,屏幕底部应闪现 agent 进度树
    (⏺ Running N subagent… + 树枝 + subagent desc)。

    这是 B2 的端到端真模型验证:不只看 transcript 出口(那是 test_e2e_task_subagent),
    而是确认 agent_jobs → drawPanel → agent_tree 这条 TUI 链在真运行里画到了屏上。
    扫所有帧:任一帧出现树标题即通过(轮询窗口短,树只在 running 期可见)。
    真模型不确定 → 重试 RETRIES 次。term 开大(rows=40)给面板留空间。
    """
    if SKIP:
        return
    import sys as _sys
    _sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from e2e_helpers import RETRIES, fresh_home  # noqa: E402
    from tty_driver import run as _run  # noqa: E402
    from asserts import TTYAssert  # noqa: E402
    import shutil as _shutil

    prompt = ("Launch a background subagent with the Task tool (run_in_background true, "
              "subagent_type Explore) to count the .zig files under src/core. Then poll with "
              "TaskOutput until it finishes and report the count.")
    homes = []
    last_diag = "?"
    for _ in range(RETRIES):
        home = fresh_home()
        homes.append(home)
        raw = _run(bin_path,
                   ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:32"],
                   base_url=None, env={"HOME": home}, term_size=(40, 100),
                   per_key_drain=0.04, startup_drain=1.2)
        a = TTYAssert(raw, rows=40, cols=100)
        hit = False
        for sc in a.frame_screens:
            full = "\n".join(sc.line_text(r) for r in range(sc.rows))
            # 树标题(running 或 finished 形态均可)+ subagent 概念出现即算画到。
            if ("subagent" in full) and ("Running" in full or "finished" in full):
                hit = True
                break
        if hit:
            for h in homes:
                _shutil.rmtree(h, ignore_errors=True)
            return
        last_diag = a.frame_screens[-1].render_ascii() if a.frame_screens else "(无帧)"

    for h in homes[:-1]:
        _shutil.rmtree(h, ignore_errors=True)
    raise AssertionError(
        "agent 进度树未在任何帧出现(%d attempts)。最后帧:\n%s\n  HOME(保留): %s"
        % (RETRIES, last_diag, homes[-1] if homes else "?"))
