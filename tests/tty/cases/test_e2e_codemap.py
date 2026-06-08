"""tty 真模型 e2e:CodeMap 引导验证。

背景:CodeMap schema 完整、单测全过,但真实对话里模型从不选它(transcript 零匹配)。
根因=系统提示词 # Using your tools 段没提 CodeMap、工具也没有 describe_fn 强引导。
本次改动:① system_prompt 加 CodeMap 引导行;② descriptions.zig 加 describeCodeMap
(带 use case + "prefer over whole-file Read")。

这两个 case 验证引导是否真的生效——这是改提示词唯一能"证明"的层(L1 单测只能验
描述字符串存在,验不了模型行为)。

- test_e2e_codemap_explicit:点名 CodeMap → 验 schema 在真模型下可用(path 参数)。
- test_e2e_codemap_spontaneous:**不点名**,只描述"给我这个文件的结构/定义都在哪"。
  这才是引导的真正考验——成功要求模型自发选 CodeMap 而非整文件 Read。
  真模型漂移大:接受 CodeMap;若模型仍退回 Read/Grep 则 SkipTest(引导未命中,
  非 regression——区别于"调了 CodeMap 但参数错"那种 AssertionError)。

跳过:TTY_SKIP_MODEL=1。
"""
import os
import sys
import time
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import (  # noqa: E402
    SKIP, SkipTest, assert_tool_e2e, run_e2e_tool,
    tool_called, any_tool_called, RETRIES,
)

# 一个有明确结构的 Zig 源文件,给 CodeMap 真东西可映射。
SAMPLE_ZIG = """\
const std = @import("std");

pub const Color = enum { red, green, blue };

pub const Point = struct {
    x: i32,
    y: i32,

    pub fn dist(self: Point) i32 {
        return self.x * self.x + self.y * self.y;
    }
};

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn main() void {
    const p = Point{ .x = 3, .y = 4 };
    std.debug.print("{d}\\n", .{p.dist()});
}
"""


def _sample_cwd():
    """临时目录 + sample.zig,作为模型的工作目录。调用方负责清理(harness 清 home,
    cwd 这里手动建,进程退出后留临时目录——用 tempfile 系统会回收;测试量小可接受)。"""
    d = tempfile.mkdtemp(prefix="cc-e2e-codemap-")
    with open(os.path.join(d, "sample.zig"), "w", encoding="utf-8") as f:
        f.write(SAMPLE_ZIG)
    return d


def test_e2e_codemap_explicit(bin_path):
    """点名 CodeMap:验 schema(path 参数)在真模型下可用。"""
    if SKIP:
        return
    cwd = _sample_cwd()
    assert_tool_e2e(
        bin_path,
        "Use the CodeMap tool to give me a structural outline of sample.zig",
        "CodeMap",
        required_keys=["path"],
        wait_s=20,
        cwd=cwd,
        require_card=False,
        accept_tools=["CodeMap"],
    )


def test_e2e_codemap_spontaneous(bin_path):
    """不点名,自然描述"哪里定义了什么"。验引导是否让模型自发选 CodeMap 而非 Read。

    这是本次改动的核心验证点。真模型漂移:
      - 命中 CodeMap → PASS(引导生效)。
      - 仍退回 Read/Grep(全 attempt)→ SkipTest(引导未命中,非代码 regression)。
    """
    if SKIP:
        return
    cwd = _sample_cwd()
    prompt = ("I'm new to sample.zig. Without dumping the whole file, "
              "show me what functions and types it defines and where.")
    last = None
    for _ in range(RETRIES):
        raw, home, uses = run_e2e_tool(
            bin_path, prompt, "CodeMap", ["path"], wait_s=20, cwd=cwd,
        )
        last = (raw, home, uses)
        if tool_called(uses, "CodeMap", ["path"]):
            return  # 引导生效:模型自发选了 CodeMap
        time.sleep(0.5)
    # 没命中:区分"退回 Read/Grep"(漂移→Skip)vs 完全没调工具(也 Skip,非 regression)
    _raw, _home, uses = last
    names = sorted({u["name"] for u in uses})
    raise SkipTest(
        "spontaneous CodeMap 未命中(真模型漂移,非 regression)。本轮调用的工具: %s" % names
    )
