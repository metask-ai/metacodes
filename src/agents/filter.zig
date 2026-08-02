//! AgentDef → 子 agent 可见的 tool_defs 过滤。
//!
//! 规则(对齐 Claude Code):
//!   1. **永远禁用集** 先移除(UI/session 依赖,无法在子 agent 跑):
//!      Agent / Task / AskUserQuestion / EnterPlanMode / ExitPlanMode / ScheduleWakeup / WaitForMcpServers
//!      (ExitPlanMode 例外:permission_mode==.plan 时保留 — 让 plan-mode subagent 能退出)
//!   2. **disallowed_tools 黑名单**(def 字段)从池里去掉
//!   3. **tools 白名单**(def 字段)若非空,取交集
//!
//! 返回 owned slice(caller free)。原 tool_defs 不动。

const std = @import("std");
const json = @import("../json.zig");
const AgentDef = @import("def.zig").AgentDef;
const PermissionMode = @import("def.zig").PermissionMode;

/// 永远不可用于 subagent 的工具名(对齐 Claude Code 官方表)。
pub const PERMANENTLY_DISABLED = [_][]const u8{
    "Agent",
    "Task",
    "AskUserQuestion",
    "EnterPlanMode",
    "ExitPlanMode",
    "ScheduleWakeup",
    "WaitForMcpServers",
    // KG 写工具**只归主 agent**(设计 v3-final §2.8.4 单写者原则):subagent 干活+返报告,
    // 父 agent 验收后闭合/记忆。避免多线程 KgClient 数据竞争(last_detail/degraded_reason
    // 裸写)+ 避免子 agent 拿到 kg=null 后收到"KG 未配置"假错(H3)。
    "KgRemember",
    "KgRecall",
};

pub fn filterToolDefs(
    allocator: std.mem.Allocator,
    parent_defs: []const json.ToolDefinition,
    def: *const AgentDef,
) ![]json.ToolDefinition {
    var out = std.ArrayList(json.ToolDefinition).empty;
    errdefer out.deinit(allocator);

    for (parent_defs) |d| {
        // 1. 永久禁用集
        if (isPermanentlyDisabled(d.name, def.permission_mode)) continue;
        // 2. disallowed_tools 黑名单
        if (matchesAny(def.disallowed_tools, d.name)) continue;
        // 3. mcpServers 非空时是 server allowlist。来源由注册桥显式标记；
        // 不能把合法含 `__` 的普通动态工具误判成 MCP。
        if (def.mcp_servers.len > 0) if (d.mcp_server) |server| {
            if (!matchesAny(def.mcp_servers, server)) continue;
        };
        // 4. tools 白名单(非空时取交集)
        // memory 开启时 Read/Write/Edit 是该能力的必要通道，和 cc 一样补入白名单；
        // disallowed_tools 仍在上一步优先，可显式禁用。
        if (def.tools.len > 0 and !matchesAny(def.tools, d.name) and
            !(def.memory_scope != .none and isMemoryTool(d.name))) continue;
        try out.append(allocator, d);
    }

    return try out.toOwnedSlice(allocator);
}

pub fn filterMcpSessions(
    allocator: std.mem.Allocator,
    sessions: []const @import("../core/mcp_session.zig").McpSessionEntry,
    allow: []const []const u8,
) ![]@import("../core/mcp_session.zig").McpSessionEntry {
    if (allow.len == 0) return allocator.dupe(@import("../core/mcp_session.zig").McpSessionEntry, sessions);
    var out = std.ArrayList(@import("../core/mcp_session.zig").McpSessionEntry).empty;
    errdefer out.deinit(allocator);
    for (sessions) |s| {
        for (allow) |name| {
            if (std.mem.eql(u8, name, s.name)) {
                try out.append(allocator, s);
                break;
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn isMemoryTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or std.mem.eql(u8, name, "Write") or std.mem.eql(u8, name, "Edit");
}

fn isPermanentlyDisabled(name: []const u8, mode: ?PermissionMode) bool {
    for (PERMANENTLY_DISABLED) |banned| {
        // ExitPlanMode 例外:plan 模式下保留
        if (std.mem.eql(u8, banned, "ExitPlanMode") and mode != null and mode.? == .plan) continue;
        if (std.mem.eql(u8, banned, name)) return true;
    }
    return false;
}

/// 命中规则:精确名匹配 或 形如 "Bash(prefix *)" 时 name=="Bash" 也匹配(只看名)。
fn matchesAny(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| {
        const paren = std.mem.indexOfScalar(u8, p, '(');
        const base = if (paren) |i| p[0..i] else p;
        if (std.mem.eql(u8, base, name)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const parseAgentMd = @import("def.zig").parseAgentMd;

fn makeFakeDef(allocator: std.mem.Allocator, tools_raw: []const u8, disallowed_raw: []const u8, perm: ?PermissionMode) !AgentDef {
    var md_buf: [512]u8 = undefined;
    const md = try std.fmt.bufPrint(
        &md_buf,
        "---\nname: t\ndescription: d\ntools: {s}\ndisallowedTools: {s}\n---\nbody",
        .{ tools_raw, disallowed_raw },
    );
    var d = try parseAgentMd(allocator, md, "/x", .personal);
    d.permission_mode = perm;
    return d;
}

fn fakeDefs(allocator: std.mem.Allocator) ![]json.ToolDefinition {
    const names = [_][]const u8{ "Read", "Write", "Edit", "Bash", "Grep", "Agent", "Task", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode" };
    var out = try allocator.alloc(json.ToolDefinition, names.len);
    for (names, 0..) |n, i| {
        out[i] = .{ .name = n, .description = "", .input_schema = .{ .type = "object", .properties = null, .required = &.{} } };
    }
    return out;
}

test "filterToolDefs: KG 工具从 subagent 移除(单写者 H3)" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "", "", null);
    defer def.deinit(a);
    const parent = [_]json.ToolDefinition{
        .{ .name = "Read", .description = "", .input_schema = .{} },
        .{ .name = "KgRemember", .description = "", .input_schema = .{} },
        .{ .name = "KgRecall", .description = "", .input_schema = .{} },
    };
    const filtered = try filterToolDefs(a, &parent, &def);
    defer a.free(filtered);
    for (filtered) |d| {
        try testing.expect(!std.mem.eql(u8, d.name, "KgRemember"));
        try testing.expect(!std.mem.eql(u8, d.name, "KgRecall"));
    }
    try testing.expectEqual(@as(usize, 1), filtered.len); // 只剩 Read
    try testing.expectEqualStrings("Read", filtered[0].name);
}

test "filterToolDefs: permanently disabled removed" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "", "", null);
    defer def.deinit(a);
    const parent = try fakeDefs(a);
    defer a.free(parent);

    const filtered = try filterToolDefs(a, parent, &def);
    defer a.free(filtered);

    // Agent / Task / AskUserQuestion / EnterPlanMode / ExitPlanMode 不应在结果里
    for (filtered) |d| {
        try testing.expect(!std.mem.eql(u8, d.name, "Agent"));
        try testing.expect(!std.mem.eql(u8, d.name, "Task"));
        try testing.expect(!std.mem.eql(u8, d.name, "AskUserQuestion"));
        try testing.expect(!std.mem.eql(u8, d.name, "EnterPlanMode"));
        try testing.expect(!std.mem.eql(u8, d.name, "ExitPlanMode"));
    }
    // Read/Write/Bash 应保留
    var found_read = false;
    var found_write = false;
    for (filtered) |d| {
        if (std.mem.eql(u8, d.name, "Read")) found_read = true;
        if (std.mem.eql(u8, d.name, "Write")) found_write = true;
    }
    try testing.expect(found_read);
    try testing.expect(found_write);
}

test "filterToolDefs: plan mode keeps ExitPlanMode" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "", "", .plan);
    defer def.deinit(a);
    const parent = try fakeDefs(a);
    defer a.free(parent);

    const filtered = try filterToolDefs(a, parent, &def);
    defer a.free(filtered);

    var found = false;
    for (filtered) |d| {
        if (std.mem.eql(u8, d.name, "ExitPlanMode")) found = true;
    }
    try testing.expect(found);
}

test "filterToolDefs: tools allowlist restricts pool" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "Read, Grep", "", null);
    defer def.deinit(a);
    const parent = try fakeDefs(a);
    defer a.free(parent);

    const filtered = try filterToolDefs(a, parent, &def);
    defer a.free(filtered);

    try testing.expectEqual(@as(usize, 2), filtered.len);
    var found_read = false;
    var found_grep = false;
    for (filtered) |d| {
        if (std.mem.eql(u8, d.name, "Read")) found_read = true;
        if (std.mem.eql(u8, d.name, "Grep")) found_grep = true;
    }
    try testing.expect(found_read);
    try testing.expect(found_grep);
}

test "filterToolDefs: disallowedTools removes from pool" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "", "Write, Edit", null);
    defer def.deinit(a);
    const parent = try fakeDefs(a);
    defer a.free(parent);

    const filtered = try filterToolDefs(a, parent, &def);
    defer a.free(filtered);

    for (filtered) |d| {
        try testing.expect(!std.mem.eql(u8, d.name, "Write"));
        try testing.expect(!std.mem.eql(u8, d.name, "Edit"));
    }
    // Read/Bash 仍在
    var found_bash = false;
    for (filtered) |d| {
        if (std.mem.eql(u8, d.name, "Bash")) found_bash = true;
    }
    try testing.expect(found_bash);
}

test "filterToolDefs: tools and disallowedTools both — disallowed wins" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "Read, Write", "Write", null);
    defer def.deinit(a);
    const parent = try fakeDefs(a);
    defer a.free(parent);

    const filtered = try filterToolDefs(a, parent, &def);
    defer a.free(filtered);
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expectEqualStrings("Read", filtered[0].name);
}

test "filterToolDefs: MCP allowlist uses provenance, not double-underscore names" {
    const a = testing.allocator;
    var def = try parseAgentMd(
        a,
        "---\nname: t\ntools: allowed__probe, blocked__probe, local__helper\nmcpServers: allowed\n---\nbody",
        "/x",
        .personal,
    );
    defer def.deinit(a);
    const parent = [_]json.ToolDefinition{
        .{ .name = "allowed__probe", .description = "", .input_schema = .{}, .mcp_server = "allowed" },
        .{ .name = "blocked__probe", .description = "", .input_schema = .{}, .mcp_server = "blocked" },
        .{ .name = "local__helper", .description = "", .input_schema = .{} },
    };

    const filtered = try filterToolDefs(a, &parent, &def);
    defer a.free(filtered);
    try testing.expectEqual(@as(usize, 2), filtered.len);
    try testing.expectEqualStrings("allowed__probe", filtered[0].name);
    try testing.expectEqualStrings("local__helper", filtered[1].name);
}
