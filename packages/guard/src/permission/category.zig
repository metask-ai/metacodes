//! 工具类别与风险等级。
//!
//! 本期是粗粒度分类（按工具名硬编码）。沙箱版本会改为 per-tool 元数据声明 + 运行时能力测量。

const std = @import("std");

pub const ToolCategory = enum { read, write, execute };
pub const RiskLevel = enum { low, medium, high };

/// Borrowed, immutable upper bound for one execution context. The owner must
/// keep `ctx` alive until every synchronous tool execution has quiesced.
///
/// This interface deliberately does not grant permission. `true` only means
/// that the ordinary Session permission pipeline may continue; `false` is a
/// fail-closed denial before dispatch.
pub const ToolExecutionPolicy = struct {
    ctx: *const anyopaque,
    allowsToolFn: *const fn (ctx: *const anyopaque, name: []const u8) bool,
    allowsInvocationFn: *const fn (
        ctx: *const anyopaque,
        name: []const u8,
        arguments_json: []const u8,
    ) bool,

    pub fn allowsTool(self: ToolExecutionPolicy, name: []const u8) bool {
        return self.allowsToolFn(self.ctx, name);
    }

    pub fn allowsInvocation(
        self: ToolExecutionPolicy,
        name: []const u8,
        arguments_json: []const u8,
    ) bool {
        return self.allowsInvocationFn(self.ctx, name, arguments_json);
    }
};

pub fn getToolCategory(tool_name: []const u8) ToolCategory {
    if (std.mem.eql(u8, tool_name, "Read") or
        std.mem.eql(u8, tool_name, "Grep") or
        std.mem.eql(u8, tool_name, "Glob"))
    {
        return .read;
    }
    if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit") or
        std.mem.eql(u8, tool_name, "ApplyPatch") or std.mem.eql(u8, tool_name, "NotebookEdit"))
    {
        return .write;
    }
    // KgRemember 是持久写(跨会话 store);按 read 分类会被 auto 等模式静默放行(M5)。
    // KgRecall/KgContext 是只读检索/遍历 → read。
    if (std.mem.eql(u8, tool_name, "KgRemember")) return .write;
    if (std.mem.eql(u8, tool_name, "Bash")) return .execute;
    return .read;
}

pub fn getRiskLevel(tool_name: []const u8) RiskLevel {
    return switch (getToolCategory(tool_name)) {
        .read => .low,
        .write => .medium,
        .execute => .high,
    };
}

test "getToolCategory read tools" {
    try std.testing.expect(getToolCategory("Read") == .read);
    try std.testing.expect(getToolCategory("Grep") == .read);
    try std.testing.expect(getToolCategory("Glob") == .read);
}

test "getToolCategory write tools" {
    try std.testing.expect(getToolCategory("Write") == .write);
    try std.testing.expect(getToolCategory("Edit") == .write);
}

test "getToolCategory execute tools" {
    try std.testing.expect(getToolCategory("Bash") == .execute);
}

test "getToolCategory: KgRemember=write,KgRecall/KgContext=read" {
    // M5:KgRemember 是持久跨会话写,plan 模式(只读探索)decision 走 cat==.read→allow 的
    // 分支时它必须落到非 read,否则 plan 下静默写盘。
    try std.testing.expect(getToolCategory("KgRemember") == .write);
    try std.testing.expect(getToolCategory("KgRecall") == .read);
    try std.testing.expect(getToolCategory("KgContext") == .read);
}

test "getToolCategory unknown defaults to read" {
    try std.testing.expect(getToolCategory("Foobar") == .read);
}

test "getRiskLevel maps category to risk" {
    try std.testing.expect(getRiskLevel("Read") == .low);
    try std.testing.expect(getRiskLevel("Write") == .medium);
    try std.testing.expect(getRiskLevel("Bash") == .high);
}
