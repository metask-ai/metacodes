//! Skill 激活时的 tool_defs 池裁剪(硬隔离)。
//!
//! 对齐 SKILL_DESIGN.md §11 Stage B.8:`disallowed-tools` 真池裁剪 + `allowed-tools`
//! 白名单(若非空)→ 取交集。模型在请求体里**根本看不到**被禁工具,避免反复尝试。
//!
//! 行为:
//! - allowed_tools 非空 → 父池里只保留 allowed 项(白名单)
//! - disallowed_tools → 从池里移除(黑名单,优先于白名单)
//! - 都为空 → 父池原样返回(零开销;返 null,caller 不必 free)
//!
//! 与 decision.zig 的 active_skill 权限检查互补:
//! - 池裁剪:模型看不见 → 模型不会尝试
//! - 权限检查:即便模型试调(如通过 dispatch 接口直接来),仍被拦
//! 双保险,语义一致。

const std = @import("std");
const json = @import("../json.zig");
const ActiveSkillState = @import("active.zig").ActiveSkillState;

/// 根据 active skill 裁剪 tool_defs。
/// active 为 null → 返回 null(caller 用原 parent_defs,零开销)。
/// 返回 owned slice;caller 用完调 freeFiltered。
pub fn filterToolDefs(
    allocator: std.mem.Allocator,
    parent_defs: []const json.ToolDefinition,
    active: ?*const ActiveSkillState,
) !?[]json.ToolDefinition {
    const as = active orelse return null;
    // 都为空 → 不裁
    if (as.allowed_tools.len == 0 and as.disallowed_tools.len == 0) return null;

    var out = std.ArrayList(json.ToolDefinition).empty;
    errdefer out.deinit(allocator);

    for (parent_defs) |d| {
        // disallowed 黑名单(优先,即便在 allowed 里也拒)
        if (matchesAny(as.disallowed_tools, d.name)) continue;
        // allowed 非空 → 必须在 allowed 里
        if (as.allowed_tools.len > 0 and !matchesAny(as.allowed_tools, d.name)) continue;
        try out.append(allocator, d);
    }

    return try out.toOwnedSlice(allocator);
}

/// 释放 filterToolDefs 返回的 slice(各 ToolDefinition 字段 borrow,只 free 顶层 slice)。
pub fn freeFiltered(allocator: std.mem.Allocator, filtered: ?[]json.ToolDefinition) void {
    if (filtered) |f| allocator.free(f);
}

/// pattern 形如 "Read" 或 "Bash(git *)"。这里只看 base name(括号前)是否匹配。
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

fn fakeDefs(allocator: std.mem.Allocator) ![]json.ToolDefinition {
    const names = [_][]const u8{ "Read", "Write", "Edit", "Bash", "Grep" };
    var out = try allocator.alloc(json.ToolDefinition, names.len);
    for (names, 0..) |n, i| {
        out[i] = .{ .name = n, .description = "", .input_schema = .{ .type = "object", .properties = null, .required = &.{} } };
    }
    return out;
}

fn containsByName(defs: []json.ToolDefinition, name: []const u8) bool {
    for (defs) |d| if (std.mem.eql(u8, d.name, name)) return true;
    return false;
}

test "filterToolDefs: active=null → null(零裁剪)" {
    const a = testing.allocator;
    const parent = try fakeDefs(a);
    defer a.free(parent);
    const r = try filterToolDefs(a, parent, null);
    try testing.expect(r == null);
}

test "filterToolDefs: allowed+disallowed 都空 → null" {
    const a = testing.allocator;
    const parent = try fakeDefs(a);
    defer a.free(parent);
    var as = try ActiveSkillState.init(a, "test", &.{}, &.{});
    defer as.deinit();
    const r = try filterToolDefs(a, parent, &as);
    try testing.expect(r == null);
}

test "filterToolDefs: 白名单只保留命中项" {
    const a = testing.allocator;
    const parent = try fakeDefs(a);
    defer a.free(parent);
    var as = try ActiveSkillState.init(a, "test", &.{ "Read", "Grep" }, &.{});
    defer as.deinit();
    const r = try filterToolDefs(a, parent, &as);
    defer freeFiltered(a, r);
    try testing.expect(r != null);
    try testing.expectEqual(@as(usize, 2), r.?.len);
    try testing.expect(containsByName(r.?, "Read"));
    try testing.expect(containsByName(r.?, "Grep"));
    try testing.expect(!containsByName(r.?, "Bash"));
    try testing.expect(!containsByName(r.?, "Write"));
}

test "filterToolDefs: 黑名单移除命中项" {
    const a = testing.allocator;
    const parent = try fakeDefs(a);
    defer a.free(parent);
    var as = try ActiveSkillState.init(a, "test", &.{}, &.{"Bash"});
    defer as.deinit();
    const r = try filterToolDefs(a, parent, &as);
    defer freeFiltered(a, r);
    try testing.expect(r != null);
    try testing.expectEqual(@as(usize, 4), r.?.len); // 5 - 1
    try testing.expect(!containsByName(r.?, "Bash"));
    try testing.expect(containsByName(r.?, "Read"));
}

test "filterToolDefs: 黑名单优先于白名单" {
    const a = testing.allocator;
    const parent = try fakeDefs(a);
    defer a.free(parent);
    // 允许 Read/Bash,但同时禁 Bash → 最终只剩 Read
    var as = try ActiveSkillState.init(a, "test", &.{ "Read", "Bash" }, &.{"Bash"});
    defer as.deinit();
    const r = try filterToolDefs(a, parent, &as);
    defer freeFiltered(a, r);
    try testing.expect(r != null);
    try testing.expectEqual(@as(usize, 1), r.?.len);
    try testing.expect(containsByName(r.?, "Read"));
    try testing.expect(!containsByName(r.?, "Bash"));
}

test "filterToolDefs: Bash(git *) 形式按 base name 匹配" {
    const a = testing.allocator;
    const parent = try fakeDefs(a);
    defer a.free(parent);
    // 模拟 SKILL.md 写 "allowed-tools: Read, Bash(git *)" → 实际只看 base name
    var as = try ActiveSkillState.init(a, "test", &.{ "Read", "Bash(git *)" }, &.{});
    defer as.deinit();
    const r = try filterToolDefs(a, parent, &as);
    defer freeFiltered(a, r);
    try testing.expect(r != null);
    // Bash 命中 base name → 保留(args 级精化交给 permission decision)
    try testing.expect(containsByName(r.?, "Bash"));
    try testing.expect(containsByName(r.?, "Read"));
}
