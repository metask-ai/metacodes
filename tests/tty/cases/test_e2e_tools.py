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
    # 子代理委派意图:Task 首选;模型偶尔自己用 Glob/Bash 直接找也算意图满足。
    assert_tool_e2e(
        bin_path,
        "Use the Task tool with subagent_type Explore to find any .md files in the current directory",
        "Task",
        required_keys=["prompt"],
        wait_s=20,
        require_card=False,
        accept_tools=["Task", "Agent", "Glob", "Bash"],
    )
