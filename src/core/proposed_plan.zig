//! `<proposed_plan>` XML 标签解析(对齐 metacode-rs utils/stream-parser/src/proposed_plan.rs)。
//!
//! Plan 模式下,模型在**正常助手文本**里用 `<proposed_plan>...</proposed_plan>` 块呈现计划
//! (而非把计划塞进工具参数)。这让弱后端只需输出文本就能稳定产出计划。本模块从完整助手
//! 文本里提取/剥离这些块。
//!
//! 对齐 mecode 的关键规则:**标签必须整行独占**(该行 trim 后正好等于 `<proposed_plan>` 或
//! `</proposed_plan>` 才算标签;`text <proposed_plan>` 这种带其它内容的行视为普通文本)。
//!
//! MVP:全文一次性解析(cc-zig 在末轮才需提取,plan 在最终消息里)。mecode 的流式分片状态机
//! (跨 chunk 检测半截标签)是为实时 PlanDelta UI——cc-zig 暂不做,标签隐藏交显示层。

const std = @import("std");

pub const OPEN_TAG = "<proposed_plan>";
pub const CLOSE_TAG = "</proposed_plan>";

/// 一行 trim(首尾空白)后是否正好等于 needle。
fn lineIsTag(line: []const u8, needle: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), needle);
}

/// 从完整助手文本提取**最后一个** `<proposed_plan>` 块的内容(owned,caller free)。
/// 无块 → null;多块 → 取最后一个(对齐 mecode extract_proposed_plan_text:每个 open 清空累加)。
/// 未闭合 → 提取 open 之后到文本末尾(对齐 mecode finish 自动闭合)。
pub fn extractProposedPlan(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    var saw_block = false;
    var in_block = false;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!in_block) {
            if (lineIsTag(line, OPEN_TAG)) {
                in_block = true;
                saw_block = true;
                buf.clearRetainingCapacity(); // 多块:新块清掉旧累加
            }
            // open 标签行之前/之间的普通文本忽略(只要块内容)
        } else {
            if (lineIsTag(line, CLOSE_TAG)) {
                in_block = false;
            } else {
                try buf.appendSlice(allocator, line);
                try buf.append(allocator, '\n');
            }
        }
    }
    if (!saw_block) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}

/// 移除所有 `<proposed_plan>` 块,返回剩余可见文本(owned,caller free)。
/// 显示层用:raw 标签 + 块内容不进 scrollback(块内容已由审批框单独展示)。
/// 对齐 mecode strip_proposed_plan_blocks。
pub fn stripProposedPlanBlocks(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var in_block = false;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // 保留原文行间 '\n';用 indexOf 手动切分以精确还原换行(splitScalar 丢末尾空段信息)。
    var pos: usize = 0;
    var first = true;
    while (pos <= text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..eol];
        const has_nl = eol < text.len;

        if (!in_block and lineIsTag(line, OPEN_TAG)) {
            in_block = true;
        } else if (in_block and lineIsTag(line, CLOSE_TAG)) {
            in_block = false;
        } else if (!in_block) {
            if (!first) try out.append(allocator, '\n');
            try out.appendSlice(allocator, line);
            first = false;
        }
        if (!has_nl) break;
        pos = eol + 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// 文本是否含完整的(或至少 open 的)`<proposed_plan>` 块。轻量探测,不分配。
pub fn hasProposedPlan(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (lineIsTag(line, OPEN_TAG)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "extractProposedPlan: 单块" {
    const a = testing.allocator;
    const text = "before\n<proposed_plan>\n- step 1\n- step 2\n</proposed_plan>\nafter";
    const r = (try extractProposedPlan(a, text)).?;
    defer a.free(r);
    try testing.expectEqualStrings("- step 1\n- step 2\n", r);
}

test "extractProposedPlan: 无块返 null" {
    const a = testing.allocator;
    try testing.expect((try extractProposedPlan(a, "just normal text\nno plan here")) == null);
}

test "extractProposedPlan: 多块取最后" {
    const a = testing.allocator;
    const text = "<proposed_plan>\nold plan\n</proposed_plan>\nrevised:\n<proposed_plan>\nnew plan\n</proposed_plan>";
    const r = (try extractProposedPlan(a, text)).?;
    defer a.free(r);
    try testing.expectEqualStrings("new plan\n", r);
}

test "extractProposedPlan: 未闭合提取到末尾(对齐 mecode finish 自动闭合)" {
    const a = testing.allocator;
    const text = "<proposed_plan>\n- step 1\n- step 2";
    const r = (try extractProposedPlan(a, text)).?;
    defer a.free(r);
    try testing.expectEqualStrings("- step 1\n- step 2\n", r);
}

test "extractProposedPlan: 整行匹配——带其它内容的行不算标签" {
    const a = testing.allocator;
    // `text <proposed_plan>` 不是标签行 → 不开块 → 无块。
    const text = "see the text <proposed_plan> inline\nmore text";
    try testing.expect((try extractProposedPlan(a, text)) == null);
}

test "extractProposedPlan: 标签行带前导空白仍识别(trim)" {
    const a = testing.allocator;
    const text = "  <proposed_plan>\nindented plan\n  </proposed_plan>\n";
    const r = (try extractProposedPlan(a, text)).?;
    defer a.free(r);
    try testing.expectEqualStrings("indented plan\n", r);
}

test "stripProposedPlanBlocks: 移除块保留可见文本" {
    const a = testing.allocator;
    const text = "before\n<proposed_plan>\n- step\n</proposed_plan>\nafter";
    const r = try stripProposedPlanBlocks(a, text);
    defer a.free(r);
    try testing.expectEqualStrings("before\nafter", r);
}

test "stripProposedPlanBlocks: 无块原样返回" {
    const a = testing.allocator;
    const text = "line1\nline2\nline3";
    const r = try stripProposedPlanBlocks(a, text);
    defer a.free(r);
    try testing.expectEqualStrings("line1\nline2\nline3", r);
}

test "stripProposedPlanBlocks: 整块在末尾不留多余换行" {
    const a = testing.allocator;
    const text = "intro\n<proposed_plan>\nplan\n</proposed_plan>";
    const r = try stripProposedPlanBlocks(a, text);
    defer a.free(r);
    try testing.expectEqualStrings("intro", r);
}

test "hasProposedPlan" {
    try testing.expect(hasProposedPlan("x\n<proposed_plan>\ny"));
    try testing.expect(!hasProposedPlan("no tag here"));
    try testing.expect(!hasProposedPlan("inline <proposed_plan> not a line"));
}
