//! AgentDef → 子 agent 可见的 tool_defs 过滤。
//!
//! 规则(对齐 Claude Code):
//!   1. **永远禁用集** 先移除(UI/session 依赖,无法在子 agent 跑):
//!      Agent / Task / AskUserQuestion / ScheduleWakeup / WaitForMcpServers / KgRemember
//!   2. **disallowed_tools 黑名单**(def 字段)从池里去掉
//!   3. **tools 白名单**(def 字段)若非空,取交集
//!
//! 返回 owned slice(caller free)。原 tool_defs 不动。

const std = @import("std");
const json = @import("metacodes-ai").json;
const AgentDef = @import("def.zig").AgentDef;
const mcp_naming = @import("metacodes-guard").mcp.naming;

/// 永远不可用于 subagent 的工具名(对齐 Claude Code 官方表)。
pub const PERMANENTLY_DISABLED = [_][]const u8{
    "Agent",
    "Task",
    "AskUserQuestion",
    "ScheduleWakeup",
    "WaitForMcpServers",
    // KG 长期记忆保持单写者：subagent 只读并返报告，父 agent 验收后才沉淀新记忆。
    // KgRecall/KgContext 是只读工具；spawnAgentSink 为每个 child 克隆独立 KgClient，
    // 因此它们无需因 allocator/abort/cache 共享风险而被禁用。
    "KgRemember",
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
        if (isPermanentlyDisabled(d.name)) continue;
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
            !(d.mcp_server != null and matchesLegacyMcp(def.tools, d.name)) and
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

/// `tools:` 里 metacodes 旧命名 `<server>__<tool>` 仍选中现在的 `mcp__<server>__<tool>`。
fn matchesLegacyMcp(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| if (mcp_naming.isLegacyAlias(p, name)) return true;
    return false;
}

fn isMemoryTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or std.mem.eql(u8, name, "Write") or std.mem.eql(u8, name, "Edit");
}

fn isPermanentlyDisabled(name: []const u8) bool {
    for (PERMANENTLY_DISABLED) |banned| {
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

fn makeFakeDef(allocator: std.mem.Allocator, tools_raw: []const u8, disallowed_raw: []const u8) !AgentDef {
    var md_buf: [512]u8 = undefined;
    const md = try std.fmt.bufPrint(
        &md_buf,
        "---\nname: t\ndescription: d\ntools: {s}\ndisallowedTools: {s}\n---\nbody",
        .{ tools_raw, disallowed_raw },
    );
    return parseAgentMd(allocator, md, "/x", .personal);
}

fn fakeDefs(allocator: std.mem.Allocator) ![]json.ToolDefinition {
    const names = [_][]const u8{ "Read", "Write", "Edit", "Bash", "Grep", "Agent", "Task", "AskUserQuestion", "ScheduleWakeup" };
    var out = try allocator.alloc(json.ToolDefinition, names.len);
    for (names, 0..) |n, i| {
        out[i] = .{ .name = n, .description = "", .input_schema = .{ .type = "object", .properties = null, .required = &.{} } };
    }
    return out;
}

test "filterToolDefs: subagent keeps read-only KG tools but never KgRemember" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "", "");
    defer def.deinit(a);
    const parent = [_]json.ToolDefinition{
        .{ .name = "Read", .description = "", .input_schema = .{} },
        .{ .name = "KgRemember", .description = "", .input_schema = .{} },
        .{ .name = "KgRecall", .description = "", .input_schema = .{} },
        .{ .name = "KgContext", .description = "", .input_schema = .{} },
    };
    const filtered = try filterToolDefs(a, &parent, &def);
    defer a.free(filtered);
    for (filtered) |d| try testing.expect(!std.mem.eql(u8, d.name, "KgRemember"));
    try testing.expectEqual(@as(usize, 3), filtered.len);
    try testing.expectEqualStrings("Read", filtered[0].name);
    try testing.expectEqualStrings("KgRecall", filtered[1].name);
    try testing.expectEqualStrings("KgContext", filtered[2].name);
}

test "filterToolDefs: permanently disabled removed" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "", "");
    defer def.deinit(a);
    const parent = try fakeDefs(a);
    defer a.free(parent);

    const filtered = try filterToolDefs(a, parent, &def);
    defer a.free(filtered);

    // Agent / Task / AskUserQuestion / ScheduleWakeup 不应在结果里
    for (filtered) |d| {
        try testing.expect(!std.mem.eql(u8, d.name, "Agent"));
        try testing.expect(!std.mem.eql(u8, d.name, "Task"));
        try testing.expect(!std.mem.eql(u8, d.name, "AskUserQuestion"));
        try testing.expect(!std.mem.eql(u8, d.name, "ScheduleWakeup"));
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

test "filterToolDefs: tools allowlist restricts pool" {
    const a = testing.allocator;
    var def = try makeFakeDef(a, "Read, Grep", "");
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
    var def = try makeFakeDef(a, "", "Write, Edit");
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
    var def = try makeFakeDef(a, "Read, Write", "Write");
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

test "filterToolDefs: tools lists name MCP tools as mcp__server__tool or the legacy server__tool" {
    const a = testing.allocator;
    var def = try parseAgentMd(
        a,
        "---\nname: t\ntools: mcp__github__create_issue, slack__send, plain__tool\n---\nbody",
        "/x",
        .personal,
    );
    defer def.deinit(a);
    const parent = [_]json.ToolDefinition{
        .{ .name = "mcp__github__create_issue", .description = "", .input_schema = .{}, .mcp_server = "github" },
        .{ .name = "mcp__github__delete_repo", .description = "", .input_schema = .{}, .mcp_server = "github" },
        .{ .name = "mcp__slack__send", .description = "", .input_schema = .{}, .mcp_server = "slack" },
        // Not MCP provenance: the legacy alias never applies to it.
        .{ .name = "mcp__plain__tool", .description = "", .input_schema = .{} },
    };

    const filtered = try filterToolDefs(a, &parent, &def);
    defer a.free(filtered);
    try testing.expectEqual(@as(usize, 2), filtered.len);
    try testing.expectEqualStrings("mcp__github__create_issue", filtered[0].name);
    try testing.expectEqualStrings("mcp__slack__send", filtered[1].name);
}
