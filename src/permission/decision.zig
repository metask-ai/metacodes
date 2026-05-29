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
const settings_mod = @import("settings.zig");
const rule_spec = @import("rule_spec.zig");
const log = @import("../util/log.zig");

pub const Decision = enum { allow, deny, ask };

pub const Context = struct {
    mode: Mode,
    /// 旧 schema rule_set(保留兼容,新代码用 settings)。
    rules: ?*const rule_matcher.RuleSet = null,
    /// 当前激活 skill 的临时白/黑名单(若有)。优先级:active_skill > settings > rules > mode。
    active_skill: ?*const @import("../skills/active.zig").ActiveSkillState = null,
    /// 5 层 settings 聚合(管理 + cli + project local/shared + user)。
    settings: ?*const settings_mod.MergedSettings = null,
    /// rule_spec 匹配上下文(cwd / project_root / home),用于 path / bash compound 等。
    match_ctx: rule_spec.MatchContext = .{},
};

/// 根据模式 + 工具名决定:允许 / 拒绝 / 询问。
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

    // 1. settings(deny → allow → ask;deny 永远优先)
    if (ctx.settings) |s| {
        const d = settings_mod.evaluate(s, &ctx.match_ctx, tool_name, args);
        switch (d) {
            .deny => {
                log.debug("permission", "settings deny tool={s}", .{tool_name});
                return .deny;
            },
            .allow => {
                // 但 protected paths 始终需要 ask(即便 allow 规则命中也不豁免)
                if (isProtectedTarget(tool_name, args)) {
                    log.debug("permission", "settings allow OVERRIDDEN by protected path tool={s}", .{tool_name});
                    return .ask;
                }
                log.debug("permission", "settings allow tool={s}", .{tool_name});
                return .allow;
            },
            .ask => {
                log.debug("permission", "settings ask tool={s}", .{tool_name});
                return .ask;
            },
            .undecided => {}, // 落到下层
        }
    }

    // 2. Protected paths:Edit/Write/NotebookEdit 到 .git/.env/.ssh/* 永远 ask
    if (isProtectedTarget(tool_name, args)) {
        log.debug("permission", "protected path tool={s} -> ask", .{tool_name});
        return .ask;
    }

    // 3. 旧细粒度规则(向后兼容)
    if (ctx.rules) |rs| {
        if (rs.match(tool_name, args)) |d| {
            log.debug("permission", "legacy rule tool={s} -> {s}", .{ tool_name, @tagName(d) });
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
        if (m == .dont_ask) break :blk .deny;
        if (m == .accept_edits) {
            if (cat == .read) break :blk .allow;
            if (std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "NotebookEdit")) break :blk .allow;
            break :blk .ask;
        }
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

/// 工具是否在写一个 protected path?仅 Edit/Write/NotebookEdit 关心。
fn isProtectedTarget(tool_name: []const u8, args: []const u8) bool {
    if (!(std.mem.eql(u8, tool_name, "Write") or
        std.mem.eql(u8, tool_name, "Edit") or
        std.mem.eql(u8, tool_name, "NotebookEdit"))) return false;
    const path = rule_spec.extractPath(args);
    if (path.len == 0) return false;
    return settings_mod.isProtectedPath(path);
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

test "settings deny takes precedence over mode bypass" {
    const alloc = std.testing.allocator;
    // Build a one-layer settings with Bash(git push) deny
    const src = "{\"permissions\":{\"deny\":[\"Bash(git push)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    const ctx = Context{ .mode = .bypass_permissions, .settings = &ms };
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"git push\"}") == .deny);
    // 其它 Bash 在 bypass 下仍然 allow
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"ls\"}") == .allow);
}

test "settings allow grants Bash in default mode" {
    const alloc = std.testing.allocator;
    const src = "{\"permissions\":{\"allow\":[\"Bash(git *)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    const ctx = Context{ .mode = .default, .settings = &ms };
    // git status:settings allow → allow(不询问)
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"git status\"}") == .allow);
    // ls:未命中 settings → 落到 mode → ask
    try std.testing.expect(check(&ctx, "Bash", "{\"command\":\"ls\"}") == .ask);
}

test "protected path forces ask even with allow rule" {
    const alloc = std.testing.allocator;
    // 用户允许 Write 整个 cwd,但 .env 仍要 ask
    const src = "{\"permissions\":{\"allow\":[\"Write(./**)\"]}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    defer parsed.deinit();
    const L = try settings_mod.parseLayer(alloc, .user, parsed.value);
    const layers = try alloc.alloc(settings_mod.Layer, 1);
    layers[0] = L;
    var ms = settings_mod.MergedSettings{ .layers = layers, .allocator = alloc };
    defer ms.deinit();

    var match_ctx = rule_spec.MatchContext{ .cwd = "/proj" };
    const ctx = Context{ .mode = .default, .settings = &ms, .match_ctx = match_ctx };
    _ = &match_ctx;

    // 普通文件:allow
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/src/foo.zig\"}") == .allow);
    // .env: protected path 覆盖 → ask
    try std.testing.expect(check(&ctx, "Write", "{\"file_path\":\"/proj/.env\"}") == .ask);
    // .git/config: protected → ask
    try std.testing.expect(check(&ctx, "Edit", "{\"file_path\":\"/proj/.git/config\"}") == .ask);
}
