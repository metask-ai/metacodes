//! 权限决策（M0 骨架实现）。
//!
//! 本期仅支持 4 种模式的粗粒度决策。完整的决策树（deny/ask rules → tool.checkPermissions → hooks）
//! 留给沙箱版本，由 rule.zig / prompt.zig / tool context 一起协作。
//!
//! 注意：本模块的 `Decision` 是不带 reason 字符串的简单枚举——为了避免在 M0 引入 allocator 关注点。
//! 扩展到携带 reason 留给 M2/沙箱阶段。

const std = @import("std");
const Mode = @import("mode.zig").Mode;
const category = @import("category.zig");
const rule_matcher = @import("rule_matcher.zig");
const log = @import("../util/log.zig");

pub const Decision = enum { allow, deny, ask };

pub const Context = struct {
    mode: Mode,
    /// 可选的细粒度规则集。非 null 时先查规则，命中即用；都不命中落回四模式。
    rules: ?*const rule_matcher.RuleSet = null,
    /// 当前激活 skill 的临时白/黑名单(若有)。优先级:active_skill > rules > mode。
    active_skill: ?*const @import("../skills/active.zig").ActiveSkillState = null,
};

/// 根据模式 + 工具名决定：允许 / 拒绝 / 询问。
pub fn check(ctx: *const Context, tool_name: []const u8, args: []const u8) Decision {
    // 0. 最高优先:active skill 白/黑名单
    if (ctx.active_skill) |as| {
        if (as.isDisallowed(tool_name, args)) {
            log.debug("permission", "active skill '{s}' disallowed tool={s}", .{ as.skill_name, tool_name });
            return .deny;
        }
        if (as.isAllowed(tool_name, args)) {
            log.debug("permission", "active skill '{s}' allowed tool={s}", .{ as.skill_name, tool_name });
            return .allow;
        }
    }

    // 先查细粒度规则
    if (ctx.rules) |rs| {
        if (rs.match(tool_name, args)) |d| {
            log.debug("permission", "rule matched tool={s} -> {s}", .{ tool_name, @tagName(d) });
            return d;
        }
    }

    const cat = category.getToolCategory(tool_name);
    const risk = category.getRiskLevel(tool_name);

    const mode_mod = @import("mode.zig");
    const m = mode_mod.canonical(ctx.mode);
    const decision: Decision = blk: {
        if (m == .bypass_permissions) break :blk .allow;
        if (m == .plan) break :blk if (cat == .read) .allow else .deny;
        if (m == .auto) break :blk if (risk == .low) .allow else .ask;
        if (m == .dont_ask) break :blk .deny; // 仅 explicit allow 规则可放行,落到这层就 deny
        if (m == .accept_edits) {
            // 读 + 文件编辑 + fs 命令 ALLOW;其它 ASK
            if (cat == .read) break :blk .allow;
            if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "NotebookEdit")) break :blk .allow;
            // TODO: accept_edits 还应放行 mkdir/touch/mv/cp/rm/rmdir/sed,需要 Bash command 解析(Stage A 后续)
            break :blk .ask;
        }
        // default(等价旧 prompt)
        break :blk if (cat == .read) .allow else .ask;
    };

    log.debug("permission", "decide tool={s} mode={s} category={s} risk={s} -> {s}", .{
        tool_name,
        @tagName(ctx.mode),
        @tagName(cat),
        @tagName(risk),
        @tagName(decision),
    });
    return decision;
}

test "bypass_permissions allows everything including dangerous" {
    const ctx = Context{ .mode = .bypass_permissions };
    try std.testing.expect(check(&ctx, "Bash", "rm -rf /") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .allow);
}

test "legacy bypass alias still works" {
    const ctx = Context{ .mode = .bypass };
    try std.testing.expect(check(&ctx, "Write", "") == .allow);
}

test "plan mode: read allowed, write/exec denied" {
    const ctx = Context{ .mode = .plan };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Grep", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .deny);
    try std.testing.expect(check(&ctx, "Edit", "") == .deny);
    try std.testing.expect(check(&ctx, "Bash", "") == .deny);
}

test "auto mode: low risk allow, others ask" {
    const ctx = Context{ .mode = .auto };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .ask);
    try std.testing.expect(check(&ctx, "Bash", "") == .ask);
}

test "default mode: read allow, write/exec ask" {
    const ctx = Context{ .mode = .default };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .ask);
    try std.testing.expect(check(&ctx, "Bash", "") == .ask);
}

test "prompt alias still maps to default mode" {
    const ctx = Context{ .mode = .prompt };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .ask);
}

test "accept_edits: read + Write/Edit allow, Bash ask" {
    const ctx = Context{ .mode = .accept_edits };
    try std.testing.expect(check(&ctx, "Read", "") == .allow);
    try std.testing.expect(check(&ctx, "Write", "") == .allow);
    try std.testing.expect(check(&ctx, "Edit", "") == .allow);
    try std.testing.expect(check(&ctx, "NotebookEdit", "") == .allow);
    try std.testing.expect(check(&ctx, "Bash", "ls") == .ask);
}

test "dont_ask: nothing matched in rules → deny" {
    const ctx = Context{ .mode = .dont_ask };
    try std.testing.expect(check(&ctx, "Read", "") == .deny);
    try std.testing.expect(check(&ctx, "Write", "") == .deny);
    try std.testing.expect(check(&ctx, "Bash", "ls") == .deny);
}
