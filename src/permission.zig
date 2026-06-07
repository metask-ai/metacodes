//! 兼容性 re-export shim。M0.6 已把实现拆到 permission/ 子目录。
//! 保留此文件是为了让 agent_loop.zig / app.zig 的旧 import 继续工作。
//! 后续里程碑会让调用方迁到新路径，再删除本文件。

const std = @import("std");
const types = @import("types.zig");

const mode_mod = @import("permission/mode.zig");
const category_mod = @import("permission/category.zig");
const decision_mod = @import("permission/decision.zig");
const prompt_mod = @import("permission/prompt.zig");
const rule_mod = @import("permission/rule.zig");
const rule_matcher_mod = @import("permission/rule_matcher.zig");
const settings_mod = @import("permission/settings.zig");
const rule_spec_mod = @import("permission/rule_spec.zig");

// --- 旧 API 重导出 ---

pub const PermissionResult = decision_mod.Decision;
pub const ToolCategory = category_mod.ToolCategory;
pub const RiskLevel = category_mod.RiskLevel;
pub const getToolCategory = category_mod.getToolCategory;
pub const getRiskLevel = category_mod.getRiskLevel;
pub const RuleSet = rule_matcher_mod.RuleSet;
pub const Rule = rule_matcher_mod.Rule;
pub const MergedSettings = settings_mod.MergedSettings;
pub const MatchContext = rule_spec_mod.MatchContext;

/// 旧版 PermissionContext。新 decision.Context 更简洁，但此处保留字段兼容 agent_loop。
pub const PermissionContext = struct {
    /// 权限模式。跨线程读写(主线程 agent_loop 读 / plan_mode 工具写 / 生成期 watcher
    /// 线程 Shift+Tab 写)→ 用原子保证可见性。读 modeValue()/写 setMode()。
    mode: std.atomic.Value(types.PermissionMode) = std.atomic.Value(types.PermissionMode).init(.prompt),
    allocator: std.mem.Allocator,
    /// 可选的细粒度规则集；null 时只靠四模式兜底。
    rules: ?*const rule_matcher_mod.RuleSet = null,
    /// 当前激活 skill 的临时白/黑名单。激活 Skill 工具时设;next user message 清。
    active_skill: ?*const @import("skills/active.zig").ActiveSkillState = null,
    /// 5 层 settings 聚合(allow/ask/deny + additionalDirectories)。
    settings: ?*const settings_mod.MergedSettings = null,
    /// path / bash 匹配上下文(cwd / project_root / home)。
    match_ctx: rule_spec_mod.MatchContext = .{},
    /// 沙箱启用 + autoAllowBashIfSandboxed(decision 用)。
    sandbox_enabled: bool = false,
    auto_allow_bash_if_sandboxed: bool = false,
    /// PreToolUse hook 集合(从 settings.hooks.PreToolUse 解析)。
    hooks: ?*const @import("permission/hooks.zig").HookSet = null,
    /// 当前 session plan 文件全路径(plan 模式特许写;App init 时算,挂此处)。空串=无。
    plan_file_path: []const u8 = "",

    /// 读 mode(acquire:看到其它线程的 setMode release 写)。
    pub fn modeValue(self: *const PermissionContext) types.PermissionMode {
        return self.mode.load(.acquire);
    }
    /// 写 mode(release:让读线程 acquire 时看到)。
    pub fn setMode(self: *PermissionContext, m: types.PermissionMode) void {
        self.mode.store(m, .release);
    }
};

pub fn createContext(mode: types.PermissionMode, allocator: std.mem.Allocator) PermissionContext {
    return .{ .mode = std.atomic.Value(types.PermissionMode).init(mode), .allocator = allocator };
}

pub fn checkPermission(ctx: *const PermissionContext, tool_name: []const u8, args: []const u8) PermissionResult {
    const d_ctx = decision_mod.Context{
        .mode = ctx.modeValue(),
        .rules = ctx.rules,
        .active_skill = ctx.active_skill,
        .settings = ctx.settings,
        .match_ctx = ctx.match_ctx,
        .sandbox_enabled = ctx.sandbox_enabled,
        .auto_allow_bash_if_sandboxed = ctx.auto_allow_bash_if_sandboxed,
        .hooks = ctx.hooks,
        .hook_allocator = ctx.allocator,
        .plan_file_path = ctx.plan_file_path,
    };
    return decision_mod.check(&d_ctx, tool_name, args);
}

pub fn promptUser(tool_name: []const u8, args: []const u8, allocator: std.mem.Allocator) !bool {
    _ = allocator;
    return prompt_mod.ask(tool_name, args);
}

test {
    _ = &mode_mod;
    _ = &category_mod;
    _ = &decision_mod;
    _ = &rule_mod;
    _ = &prompt_mod;
}

test "shim checkPermission bypass" {
    const ctx = PermissionContext{ .mode = .init(.bypass), .allocator = std.testing.allocator };
    try std.testing.expect(checkPermission(&ctx, "Bash", "rm -rf /") == .allow);
}

test "shim createContext + check plan" {
    const ctx = createContext(.plan, std.testing.allocator);
    try std.testing.expect(checkPermission(&ctx, "Read", "") == .allow);
    try std.testing.expect(checkPermission(&ctx, "Write", "") == .deny);
}

test "PermissionContext.mode 原子跨线程 write-read(无撕裂,release-acquire 可见)" {
    var ctx = createContext(.default, std.testing.allocator);
    const Writer = struct {
        fn run(c: *PermissionContext) void {
            // 另一线程连写多个 mode(模拟生成期 watcher Shift+Tab / plan_mode 工具)。
            var i: usize = 0;
            while (i < 1000) : (i += 1) {
                c.setMode(.plan);
                c.setMode(.accept_edits);
                c.setMode(.default);
            }
            c.setMode(.plan); // 末态确定为 plan
        }
    };
    var th = try std.Thread.spawn(.{}, Writer.run, .{&ctx});
    // 主线程并发读:每次 load 必是合法 enum(无撕裂);不崩。
    var j: usize = 0;
    while (j < 1000) : (j += 1) {
        const m = ctx.modeValue();
        // 合法枚举值之一(原子读不会读到半更新的垃圾)。
        try std.testing.expect(m == .plan or m == .accept_edits or m == .default);
    }
    th.join();
    try std.testing.expectEqual(types.PermissionMode.plan, ctx.modeValue()); // 末态可见
}
