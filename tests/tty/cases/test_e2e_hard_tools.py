"""tty 真模型 e2e:B 组 —— 此前判定"难自动化"的 7 个工具,一律用 tty 真模型方案。

副作用全真跑(用户决策):WebFetch 真联网、CronCreate 真排程(session 内存级)、
PushNotification 真发系统通知、EnterWorktree 真改 git(临时隔离 repo + 清理)。
AskUserQuestion driver 脚本化应答;Monitor 用瞬时命令;MCP 需 mock server(无则跳过)。

断言策略同 A 组:首选工具被调用即过;不确定的接受同类工具(accept_tools)。
真模型(MiniMax)选工具高度不确定,特定工具 schema 由 L2 守卫,这里验"意图达成"。

跳过:TTY_SKIP_MODEL=1。
"""
import os
import sys
import shutil
import tempfile
import subprocess

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import SKIP, assert_tool_e2e  # noqa: E402


def test_e2e_webfetch(bin_path):
    if SKIP:
        return
    # 真联网抓 example.com(稳定测试域名)。
    assert_tool_e2e(
        bin_path,
        "Fetch the page at https://example.com and tell me its title",
        "WebFetch",
        required_keys=["url"],
        wait_s=20,
        require_card=False,
        accept_tools=["WebFetch"],
    )


def test_e2e_croncreate(bin_path):
    if SKIP:
        return
    # CronCreate 排的是 session 内存级任务,进程退出即清,无持久副作用。
    assert_tool_e2e(
        bin_path,
        "Use the CronCreate tool to schedule a reminder 5 minutes from now that says 'check build'",
        "CronCreate",
        required_keys=["prompt"],
        wait_s=16,
        require_card=False,
        accept_tools=["CronCreate"],
    )


def test_e2e_pushnotification(bin_path):
    if SKIP:
        return
    # 会真发系统通知(用户已确认可接受)。
    assert_tool_e2e(
        bin_path,
        "Use the PushNotification tool to notify me that the task is complete",
        "PushNotification",
        required_keys=["message"],
        wait_s=16,
        require_card=False,
        accept_tools=["PushNotification"],
    )


def test_e2e_monitor(bin_path):
    if SKIP:
        return
    # Monitor 用瞬时命令(立即结束),避免长驻。接受 Monitor 或 Bash(后台)。
    assert_tool_e2e(
        bin_path,
        "Use the Monitor tool to watch the command 'echo monitor_done' for output",
        "Monitor",
        required_keys=["command"],
        wait_s=16,
        require_card=False,
        accept_tools=["Monitor", "Bash"],
    )


def test_e2e_askuserquestion(bin_path):
    if SKIP:
        return
    # AskUserQuestion 阻塞读 stdin(tty 下打印数字选项,读一行数字)。
    # driver 提问后喂 "1\n" 应答,验证工具被调用 + 应答后流程继续。
    assert_tool_e2e(
        bin_path,
        "Ask me a multiple choice question about which color I prefer, with options red green blue",
        "AskUserQuestion",
        required_keys=["questions"],
        wait_s=10,
        require_card=False,
        accept_tools=["AskUserQuestion"],
        extra_keys=["type:1", "key:enter", "sleep:4"],
    )


def test_e2e_enterworktree(bin_path):
    if SKIP:
        return
    # EnterWorktree 真改 git(用户决策)。在临时隔离 git repo 里跑,测后整目录删除。
    repo = tempfile.mkdtemp(prefix="cc-e2e-wt-")
    try:
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t",
                        "commit", "--allow-empty", "-qm", "init"], cwd=repo, check=True)
        assert_tool_e2e(
            bin_path,
            "Create a new git worktree named e2etest using the EnterWorktree tool",
            "EnterWorktree",
            required_keys=["name"],
            wait_s=18,
            require_card=False,
            accept_tools=["EnterWorktree"],
            cwd=repo,
        )
    finally:
        shutil.rmtree(repo, ignore_errors=True)


# mock_mcp_server 二进制路径(build 产物);缺失则 MCP 用例跳过。
_ZIG_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_MOCK_MCP = os.path.join(_ZIG_ROOT, "zig-out", "bin", "mock_mcp_server")


def test_e2e_mcp_list_resources(bin_path):
    if SKIP:
        return
    if not os.access(_MOCK_MCP, os.X_OK):
        return  # 无 mock_mcp_server(未 build)→ 跳过
    import json
    # 独立 HOME + config.json 声明 mock MCP server;模型应调 ListMcpResourcesTool。
    home = tempfile.mkdtemp(prefix="cc-e2e-mcp-home-")
    cfg_dir = os.path.join(home, ".cc-zig")
    os.makedirs(cfg_dir, exist_ok=True)
    with open(os.path.join(cfg_dir, "config.json"), "w") as f:
        json.dump({"mcp_servers": [{"name": "mock", "command": [_MOCK_MCP]}]}, f)
    try:
        assert_tool_e2e(
            bin_path,
            "List the resources exposed by the connected MCP servers",
            "ListMcpResourcesTool",
            required_keys=None,
            wait_s=16,
            require_card=False,
            accept_tools=["ListMcpResourcesTool", "ReadMcpResourceTool"],
            env={"HOME": home},
            cleanup_home=False,  # 我们自管这个带 config 的 HOME
        )
    finally:
        shutil.rmtree(home, ignore_errors=True)
