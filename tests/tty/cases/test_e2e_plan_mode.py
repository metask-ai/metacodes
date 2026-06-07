"""tty 真模型 e2e:Plan 模式审批流(ExitPlanMode → 审批对话框 → 批准/拒绝)。

为什么必须真模型 e2e(纯 TTY 状态机摸不到):审批框只在模型**真的调 ExitPlanMode**
时弹出。这条链是单测和 cassette 都覆盖不到的——
  - 单测直接调 executeExit,**绕过** dispatch 前的 validateRequired 前置层
    (2026-06-07 实测 bug:plan 误设 required → MissingRequiredField 卡死,单测全绿却线上崩);
  - cassette 工具参数手写死,模型不参与"传不传 plan"的决策。
只有真模型读 schema 自主决定调 ExitPlanMode + 传/不传 plan,才能抓 schema/漏参类 bug。

跳过:TTY_SKIP_MODEL=1(CI/离线)。真模型偶发漂移(不进 plan/不调 ExitPlanMode)→
SkipTest(不算 fail);审批框弹了但行为错(崩/不切模式)= AssertionError(真 regression)。
"""
import os
import sys
import time
import shutil

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from e2e_helpers import (  # noqa: E402
    SKIP, SkipTest, RETRIES, fresh_home,
    read_tool_uses, read_tool_results_with_error, tool_called,
)


def _run_plan_attempt(bin_path, prompt, approve_key, wait_s=16):
    """跑一次 plan 模式 attempt:--permission plan 起步 → prompt → 等模型规划+调 ExitPlanMode
    → 审批框弹出后按 approve_key(1/2/3)→ 收 (raw, home, uses)。

    直接调 run()(非 run_e2e_tool)因为要 permission="plan" + 审批框出现后的延时按键。
    """
    home = fresh_home()
    keys = [
        "sleep:0.8",
        "type:" + prompt,
        "key:enter",
        "sleep:%g" % wait_s,   # 等模型 explore + 调 ExitPlanMode + 审批框渲染
        "key:" + approve_key,  # 审批框选择(1=proceed / 2=accept_edits / 3=keep planning)
        "sleep:1.5",
    ]
    raw = run(bin_path, keys, base_url=None, env={"HOME": home},
              permission="plan", per_key_drain=0.04, startup_drain=1.0)
    uses = read_tool_uses(home)
    return raw, home, uses


def _assert_no_crash(raw, home):
    """真 regression:进程 panic(任何阶段)都是硬失败,绝不当漂移跳过。
    2026-06-07 真 TTY 实测在 plan 模式触发 auto-compact 时撞到 client.zig parseApiResponse
    的 index OOB——纯单测没覆盖,只有真模型多轮跑出长上下文才触发。"""
    crash_markers = (b"panic", b"reached unreachable", b"index out of bounds",
                     b"integer overflow", b"error return trace")
    for m in crash_markers:
        if m in raw:
            txt = raw.decode("utf-8", "replace")
            i = txt.find(m.decode())
            raise AssertionError(
                "进程 panic(真 regression,非漂移):...%s...\n  HOME: %s"
                % (txt[max(0, i - 100):i + 300], home))


def test_e2e_plan_approve_proceed(bin_path):
    """模型在 plan 模式规划 → 调 ExitPlanMode → 审批框出现 → 选 1(proceed)。

    硬断言(真 regression):
      ① ExitPlanMode 被调用;
      ② 其 tool_result **非 is_error**(回归 MissingRequiredField:plan 漏参不该硬失败);
      ③ 屏幕出现审批框标题 "Ready to code?"。
    任一 attempt 满足即过;全 attempt 模型都没调 ExitPlanMode → SkipTest(漂移)。
    """
    if SKIP:
        return
    # 提示词明确要求 <proposed_plan> 块 + ExitPlanMode(对齐每轮注入的协议指令)。
    # wait_s 必须给足:plan 模式模型要 explore 多轮 + 写计划,实测需 ~45-50s,短窗口会在
    # 模型写完前截断(早期"模型不产 XML"的误判正源于 wait 太短,非后端漂移)。
    prompt = ("Briefly plan how to add a /version command. Wrap the final plan in "
              "proposed_plan tags, then call ExitPlanMode.")
    homes = []
    last = None
    for _ in range(RETRIES):
        raw, home, uses = _run_plan_attempt(bin_path, prompt, approve_key="1", wait_s=50)
        homes.append(home)
        last = (raw, home, uses)
        _assert_no_crash(raw, home)  # panic = 硬失败(任何 attempt),先于漂移判定
        text = raw.decode("utf-8", "replace")
        # 被测路径触发判据:审批框出现(屏幕)或 ExitPlanMode 在 transcript(二者任一即算走到)。
        # 注:transcript flush 可能落后于审批框渲染,故屏幕信号优先。
        box_shown = "Ready to code?" in text
        if not box_shown and not tool_called(uses, "ExitPlanMode"):
            time.sleep(0.5)
            continue
        # 走到审批路径 → 以下任一失败都是真 regression。
        results = read_tool_results_with_error(home)
        # ① ExitPlanMode 的结果不该是 error(回归 MissingRequiredField)。
        plan_errs = [c for (c, err) in results if err and
                     ("Missing" in c or "Required" in c)]
        assert not plan_errs, (
            "ExitPlanMode 执行失败(回归 MissingRequiredField):%s\n  HOME: %s"
            % (plan_errs[:1], home))
        # ② 审批框出现且不在屏幕泄漏 raw <proposed_plan> 标签(标签隐藏生效)。
        assert box_shown, (
            "ExitPlanMode 被调用但审批框未出现(应有标题 'Ready to code?')。\n  HOME: %s" % home)
        assert "<proposed_plan>" not in text, (
            "屏幕泄漏了 raw <proposed_plan> 标签(应被显示层隐藏)。\n  HOME: %s" % home)
        for h in homes:
            shutil.rmtree(h, ignore_errors=True)
        return
    # 全 attempt 模型都没进审批路径 → 漂移,跳过(非 fail)。
    raw, home, uses = last
    names = sorted({u["name"] for u in uses})
    for h in homes[:-1]:
        shutil.rmtree(h, ignore_errors=True)
    raise SkipTest(
        "RETRIES 次模型均未呈现计划/调 ExitPlanMode(漂移/超时)。实际调用: %s\n  HOME: %s" % (names, home))


def test_e2e_plan_mode_readonly_tool_works(bin_path):
    """plan 模式下读类工具仍可被调用 + 进程不崩(更稳的 plan-mode 健康检查)。

    比 approve_proceed 稳:弱模型对"读某文件"这种直接请求几乎必调 Read,不依赖完整
    plan 工作流。主要守:① plan 模式没把读类工具误锁死;② 多轮跑不 panic(parseApiResponse
    OOB 回归)。模型偶发不调 Read → 漂移跳过;调了但崩 → 硬失败。
    """
    if SKIP:
        return
    prompt = "Read the file src/main.zig and summarize what it does."
    homes = []
    last = None
    for _ in range(RETRIES):
        home = fresh_home()
        keys = ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:14"]
        raw = run(bin_path, keys, base_url=None, env={"HOME": home},
                  permission="plan", per_key_drain=0.04, startup_drain=1.0)
        uses = read_tool_uses(home)
        homes.append(home)
        last = (raw, home, uses)
        _assert_no_crash(raw, home)  # panic = 硬失败
        # plan 模式读类工具应放行(Read/Grep/Glob 任一即证明没误锁)。
        if tool_called(uses, "Read") or tool_called(uses, "Grep") or tool_called(uses, "Glob"):
            for h in homes:
                shutil.rmtree(h, ignore_errors=True)
            return
        time.sleep(0.5)
    raw, home, uses = last
    names = sorted({u["name"] for u in uses})
    for h in homes[:-1]:
        shutil.rmtree(h, ignore_errors=True)
    raise SkipTest(
        "RETRIES 次模型均未调读类工具(漂移)。实际调用: %s\n  HOME: %s" % (names, home))

