"""tty 真模型 e2e 共享 helper。

真模型 e2e 的核心:用真端点(base_url=None → client.zig 硬编码 napi.metask-ai.com)
让模型**自主读 schema 决定调哪个工具传什么参**——这是 cassette/mock 结构上做不到的,
唯一能抓 schema/漏参类 bug 的层。

断言双通道:
  ① 屏幕帧:工具卡片 `⚙ <ToolName>`(用户感知层)
  ② transcript JSONL:`{"type":"tool_use","name":"<Tool>","input":"..."}`(权威层)

不确定性:真模型偶发不调工具/调错(漂移,非 bug)。每个用例重试 RETRIES 次,
任一次工具被正确调用即 pass;全失败才判负。强提示词("Use the X tool to …")提高命中。
"""
import os
import re
import sys
import json
import glob
import time
import shutil
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402

# 真模型偶发漂移 → 重试取成功(用户决策:3 次)。
RETRIES = 3

# CI / 离线跳过(无网或不想烧 token 时设 TTY_SKIP_MODEL=1)。
SKIP = os.environ.get("TTY_SKIP_MODEL") == "1"


class SkipTest(Exception):
    """真模型漂移导致被测路径未被触发(如所有重试模型都没调目标工具)→ 跳过,
    既不算 pass 也不算 fail。区别于 AssertionError(被测路径触发了但行为错=真 regression)。
    runner 识别本异常计入 skipped。"""


def fresh_home():
    """每个 attempt 用独立 HOME,transcript 隔离、易定位最新 session。"""
    return tempfile.mkdtemp(prefix="cc-e2e-home-")


def read_tool_uses(home):
    """扫该 HOME 下所有 transcript.jsonl,返回 [{"name":..,"input":..}, ...]。

    transcript 行格式(transcript.zig):message JSON `{"role":..,"blocks":[...]}`,
    blocks 里 `{"type":"tool_use","id":..,"name":..,"input":"<json string>"}`。
    """
    uses = []
    pattern = os.path.join(home, ".cc-zig", "projects", "*", "*", "transcript.jsonl")
    for path in glob.glob(pattern):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or '"tool_use"' not in line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    blocks = msg.get("blocks")
                    if not isinstance(blocks, list):
                        continue
                    for b in blocks:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            uses.append({"name": b.get("name", ""), "input": b.get("input", "")})
        except OSError:
            continue
    return uses


def read_tool_results(home):
    """扫该 HOME 下所有 transcript.jsonl,返回所有 tool_result 的 content 字符串列表。

    transcript 里 user message 的 blocks 含 `{"type":"tool_result","content":"<str>",...}`。
    后台 subagent 的 TaskOutput 结果(含 status/stop_reason/turns/final_text 的 JSON)即在此。
    """
    results = []
    pattern = os.path.join(home, ".cc-zig", "projects", "*", "*", "transcript.jsonl")
    for path in glob.glob(pattern):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or '"tool_result"' not in line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    blocks = msg.get("blocks")
                    if not isinstance(blocks, list):
                        continue
                    for b in blocks:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            c = b.get("content", "")
                            if isinstance(c, str):
                                results.append(c)
        except OSError:
            continue
    return results


def read_tool_results_with_error(home):
    """扫该 HOME 下所有 transcript.jsonl,返回 [(content, is_error)] 列表。
    用于校验工具 execute 是否成功(is_error=true → execute 返回了 error,被序列化回灌)。
    这是补"声明=接线=测试"盲区:旧 assert_tool_e2e 只看工具被调用,不看执行成功与否。
    """
    results = []
    pattern = os.path.join(home, ".cc-zig", "projects", "*", "*", "transcript.jsonl")
    for path in glob.glob(pattern):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or '"tool_result"' not in line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    blocks = msg.get("blocks")
                    if not isinstance(blocks, list):
                        continue
                    for b in blocks:
                        if isinstance(b, dict) and b.get("type") == "tool_result":
                            c = b.get("content", "")
                            err = bool(b.get("is_error", False))
                            if isinstance(c, str):
                                results.append((c, err))
        except OSError:
            continue
    return results


def find_subagent_done(home):
    """从 transcript 的 tool_result 里找后台 subagent 完成记录(TaskOutput status=done)。

    返回解析后的 dict(含 stop_reason/turns/tool_calls/final_text),找不到返回 None。
    """
    for c in read_tool_results(home):
        if '"status":"done"' not in c and '"stop_reason"' not in c:
            continue
        try:
            d = json.loads(c)
        except json.JSONDecodeError:
            continue
        if isinstance(d, dict) and "stop_reason" in d:
            return d
    return None


def tool_called(uses, name, required_keys=None):
    """uses 里是否有 name 工具、且 input 含全部 required_keys。

    input 是 JSON 字符串(可能空 {})。required_keys 用子串匹配 `"key"`(够分辨存在性)。
    """
    for u in uses:
        if u["name"] != name:
            continue
        if not required_keys:
            return True
        inp = u["input"] or ""
        if all(('"%s"' % k) in inp for k in required_keys):
            return True
    return False


def any_tool_called(uses, names):
    """uses 里是否调用了 names 中任一工具(不校验参数)。

    用于"同类工具算过":真模型(MiniMax)在满工具集下选工具高度不确定——已实测
    同一 prompt 多次在 Grep / Bash / TaskCreate 间漂移。对搜索/查找这类**意图明确但
    实现工具可替代**的任务,断言"意图被某个合理工具达成"而非死磕特定工具,消除 flaky。
    特定工具的 schema 正确性由 L2 tool_schema_coverage_test 守卫,不依赖真模型。
    """
    got = {u["name"] for u in uses}
    return any(n in got for n in names)


def screen_has_tool_card(raw, tool_name):
    """屏幕字节流里是否出现工具卡片 `⚙ <tool_name>`(用户感知层)。"""
    text = raw.decode("utf-8", "replace")
    # 工具卡片首行:icon_tool(⚙)+ 空格 + tool_name。容忍 SGR 包裹,用工具名 + 卡片图标共现。
    return ("⚙" in text) and (tool_name in text)


def run_e2e_tool(bin_path, prompt, tool_name, required_keys=None,
                 extra_keys=None, wait_s=12, env=None, cwd=None, post_keys=None):
    """跑一次真模型 attempt:输入 prompt → 等模型调工具 → 收 (raw, home, uses)。

    extra_keys:prompt 提交后追加的按键(如 AskUserQuestion 需 down+enter 应答)。
    post_keys:工具执行后追加按键(如清理)。返回供调用方断言。
    """
    # env 可覆盖 HOME(如 MCP 用例需预置 config.json 的 HOME);用最终生效的 HOME 读 transcript。
    home = fresh_home()
    e = {"HOME": home}
    if env:
        e.update(env)
    home = e["HOME"]
    keys = ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:%g" % wait_s]
    if extra_keys:
        keys += extra_keys
    if post_keys:
        keys += post_keys
    raw = run(bin_path, keys, base_url=None, env=e, cwd=cwd,
              per_key_drain=0.04, startup_drain=1.0)
    uses = read_tool_uses(home)
    return raw, home, uses


def assert_tool_e2e(bin_path, prompt, tool_name, required_keys=None,
                    extra_keys=None, wait_s=12, env=None, cwd=None,
                    require_card=True, cleanup_home=True, retries=None,
                    accept_tools=None, expect_tool_ok=False):
    """完整断言:重试 retries(默认 RETRIES)次,任一次"意图被满足"即通过。

    通过判据(两档):
      ① 首选:tool_name 被调用且 input 含 required_keys(+可选屏幕工具卡片)——
         这同时验证了该工具的 schema 在真模型下可用。
      ② 同类工具算过:若给了 accept_tools(如 ["Grep","Bash"]),模型用其中任一工具
         完成任务也算通过。用于真模型(MiniMax)在满工具集下选工具高度不确定的情形——
         已实测同一 prompt 多次在 Grep/Bash/TaskCreate 间漂移。特定工具的 schema 正确性
         由 L2 tool_schema_coverage_test 守卫,不依赖真模型采样。
    require_card=True 时额外软校验屏幕出现工具卡片(失败不单独判负,并入重试)。

    expect_tool_ok=True 时(补"声明=接线=测试"盲区):额外**硬校验**——transcript 里至少有
    一条 is_error != true 的 tool_result,且**没有** is_error=true 的(工具 execute 失败即转红)。
    旧判据只看工具被调用,工具 execute 返回 error 仍判绿——AskUserQuestion 的 InvalidArgs
    就这样漏网。开启此参数的用例确保工具真正执行成功。
    返回最后一次 (raw, home, uses) 供调用方追加断言。
    """
    n = retries if retries is not None else RETRIES
    last = None
    homes = []
    for attempt in range(1, n + 1):
        raw, home, uses = run_e2e_tool(bin_path, prompt, tool_name, required_keys,
                                       extra_keys=extra_keys, wait_s=wait_s, env=env, cwd=cwd)
        homes.append(home)
        last = (raw, home, uses)
        # ① 首选工具 + schema + 卡片
        preferred = tool_called(uses, tool_name, required_keys) and (
            (not require_card) or screen_has_tool_card(raw, tool_name))
        # ② 同类工具算过(意图满足)
        alt = bool(accept_tools) and any_tool_called(uses, accept_tools)
        # ③ 工具执行成功校验(expect_tool_ok):无 is_error=true 的 tool_result,且至少一条成功。
        tool_ok = True
        if expect_tool_ok:
            tr = read_tool_results_with_error(home)
            had_error = any(err for (_c, err) in tr)
            had_ok = any((not err) for (_c, err) in tr)
            tool_ok = had_ok and not had_error
        if (preferred or alt) and tool_ok:
            if cleanup_home:
                for h in homes:
                    shutil.rmtree(h, ignore_errors=True)
            return last
        time.sleep(0.5)  # 轻微退避
    # 全部 attempt 失败 → 判负,带最后一次诊断
    raw, home, uses = last
    names = sorted({u["name"] for u in uses})
    accepted = (" / 或同类工具 %s" % accept_tools) if accept_tools else ""
    ok_note = ""
    if expect_tool_ok:
        tr = read_tool_results_with_error(home)
        errs = [c[:120] for (c, err) in tr if err]
        ok_note = "\n  expect_tool_ok=True: tool_result 里有 is_error=true: %s" % (errs or "(无,但也无成功结果)")
    diag = ("工具 %s%s 未被调用或执行失败(required_keys=%s)。%d 次 attempt 全失败。\n"
            "  transcript 实际调用的工具: %s%s\n"
            "  HOME(保留供调试): %s") % (tool_name, accepted, required_keys, n, names, ok_note, home)
    if cleanup_home:
        for h in homes[:-1]:
            shutil.rmtree(h, ignore_errors=True)
    raise AssertionError(diag)
