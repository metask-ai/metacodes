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
    /// memdir 绝对路径(通道 B 自动记忆;App init 时算,挂此处)。空串=禁用。
    /// 写此子树内文件任何模式豁免(对齐 cc isAutoMemPath),deny/protected 仍优先。
    memdir_abs: []const u8 = "",
    /// Session 级权限记忆(always-allow / session-deny)。指针:*const ctx 仍可经它 remember。
    /// null = 无记忆(单测/库消费者不接)→ 每次都问。每 session 一个实例(多 Session 不串台)。
    session_rules: ?*@import("permission/session_rules.zig").SessionRules = null,
    /// UI 请求 runner(权限框经它让前端渲染)。重构前是 prompt.zig 的 g_ui_runner 全局
    /// (多 Session 会串台 + 指向已失效 TuiBackend 的 UAF)。现挂 per-session ctx。
    /// null = 无 runner → ask 退回文字 prompt。见 UiRequester。
    ui_requester: ?@import("core/protocol/ui_request.zig").UiRequester = null,
    /// **非交互强制拒**(swarm teammate 用):true 时 ask() 命中 `.ask` 且无 ui_requester →
    /// 直接 deny,**绝不读 fd 0**。teammate 线程与 lead REPL 共享进程 fd 0,isatty(0) 为真会
    /// 让 ask() 落到 askText 读 stdin,和 lead 行读争抢/卡死(PM SW4 3c)。fail-closed:
    /// teammate 拿不到权限就报工具错,由模型经 SendMessage 请 lead 代办(SW7 权限代理)。
    no_interactive_prompt: bool = false,
    /// 本 ctx 归属的会话(权限对话框路由到对应 session 视图)。默认 .single(N=1)。
    /// **M6 待办**:这与 ToolContext.session 是同一概念的两份拷贝(权限路径走 PermissionContext,
    /// 工具路径走 ToolContext)。M6 拆 SessionContext 后,两者都从 SessionContext.id 取,这俩
    /// 字段消失。在此之前 M6 必须**同时**填这俩,否则权限框/工具框路由到不同 session(不一致)。
    session: @import("core/session_id.zig").SessionId = @import("core/session_id.zig").SessionId.single,

    /// **配置变更事件出口(U4)**:permission_mode 是 setMode 单写侧(model/dirs/reasoning
    /// 各在 App 方法 emit)。App 只给 `app.permission_ctx` 设 sink;setMode 有 sink 才 emit,
    /// 故 mode 变更(含 plan_mode 工具直写 ctx.setMode——最该出事件的转移)自动广播。
    /// **scoped 值拷贝(subagent/agent_loop/agent)必须 null sink**——用 scopedDerive() 单 seam
    /// 保证(不手工 null N 点,清单会漏)。null = 不 emit(无 UI / 单测 / scoped 拷贝)。
    event_sink: ?@import("core/protocol/ui_event.zig").ConfigEventSink = null,

    /// 读 mode(acquire:看到其它线程的 setMode release 写)。
    pub fn modeValue(self: *const PermissionContext) types.PermissionMode {
        return self.mode.load(.acquire);
    }
    /// 写 mode(release:让读线程 acquire 时看到)。**U4 单写侧**:有 event_sink 则 emit
    /// mode_changed(读回 store 后的值,保证事件与状态一致)。
    pub fn setMode(self: *PermissionContext, m: types.PermissionMode) void {
        self.mode.store(m, .release);
        if (self.event_sink) |sink| sink.emit(.{ .mode = m });
    }

    /// **scoped 派生的唯一入口(U4)**:值拷贝本 ctx + **null 掉 event_sink**(scoped ctx 不是
    /// session ctx,其 mode override 绝不 emit 到 session sink),可选覆盖 mode。所有"值拷贝
    /// permission_ctx 做 override"必须走它(subagent/agent_loop prefetch·nohooks/agent)。
    /// grep-guard(S4):src 里除本函数外无裸 `permission_ctx.*` / `perm.*` 值拷贝——null 逻辑
    /// 塌成一处不可能漏(手工枚举 N 点已被证伪漏 4 个)。
    pub fn scopedDerive(self: *const PermissionContext, mode_override: ?types.PermissionMode) PermissionContext {
        var derived = self.*;
        derived.event_sink = null; // scoped 拷贝绝不 emit 到 session sink
        if (mode_override) |m| derived.mode = std.atomic.Value(types.PermissionMode).init(m);
        return derived;
    }
};

pub fn createContext(mode: types.PermissionMode, allocator: std.mem.Allocator) PermissionContext {
    return .{ .mode = std.atomic.Value(types.PermissionMode).init(mode), .allocator = allocator };
}

pub fn checkPermission(ctx: *const PermissionContext, tool_name: []const u8, args: []const u8) PermissionResult {
    // B1 防御:规则匹配器(matchesPathDual)用 match_ctx.alloc 做路径 canonicalize
    // (unescape + 折叠 ..)。生产里 App.loadSettings 已填 .alloc,但那与 settings!=null 是
    // 隐式耦合;此处兜底——PermissionContext.allocator 非可选,恒填,消除"某路径设了 settings
    // 却漏填 match_ctx.alloc → 规则匹配退回原始字节被 .. 绕过"的窗口。
    var mctx = ctx.match_ctx;
    if (mctx.alloc == null) mctx.alloc = ctx.allocator;
    const d_ctx = decision_mod.Context{
        .mode = ctx.modeValue(),
        .rules = ctx.rules,
        .active_skill = ctx.active_skill,
        .settings = ctx.settings,
        .match_ctx = mctx,
        .sandbox_enabled = ctx.sandbox_enabled,
        .auto_allow_bash_if_sandboxed = ctx.auto_allow_bash_if_sandboxed,
        .hooks = ctx.hooks,
        .hook_allocator = ctx.allocator,
        .plan_file_path = ctx.plan_file_path,
        .memdir_abs = ctx.memdir_abs,
        .memdir_allocator = ctx.allocator,
        .path_check_allocator = ctx.allocator,
    };
    return decision_mod.check(&d_ctx, tool_name, args);
}

/// 询问用户(有副作用:写 session 记忆 / 落盘)。ctx 非 const,见 prompt.ask 线程契约。
pub fn promptUser(ctx: *PermissionContext, tool_name: []const u8, args: []const u8) !bool {
    return prompt_mod.ask(ctx, tool_name, args);
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

test "U4 A2: setMode 有 sink 则 emit mode_changed;无 sink 不 emit" {
    const ui_event = @import("core/protocol/ui_event.zig");
    const Recorder = struct {
        got: ?ui_event.ConfigChange = null,
        fn emit(ctx: *anyopaque, ev: ui_event.ConfigChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.got = ev;
        }
    };
    var rec = Recorder{};
    var ctx = PermissionContext{ .allocator = std.testing.allocator };
    // 无 sink:setMode 不 emit
    ctx.setMode(.plan);
    try std.testing.expect(rec.got == null);
    // 挂 sink:setMode emit mode_changed，值=store 后的 mode
    ctx.event_sink = .{ .ctx = @ptrCast(&rec), .emitFn = &Recorder.emit };
    ctx.setMode(.accept_edits);
    try std.testing.expect(rec.got != null);
    try std.testing.expectEqual(types.PermissionMode.accept_edits, rec.got.?.mode);
    // 关键:工具路径(plan_mode 直写 ctx.setMode)同样 emit（这就是 task#14/plan 转移的事件源）
    ctx.setMode(.plan);
    try std.testing.expectEqual(types.PermissionMode.plan, rec.got.?.mode);
}

test "U4 A2: scopedDerive null 掉 sink(scoped 拷贝的 override 绝不 emit 到 session sink)" {
    const ui_event = @import("core/protocol/ui_event.zig");
    const Recorder = struct {
        count: usize = 0,
        fn emit(ctx: *anyopaque, _: ui_event.ConfigChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };
    var rec = Recorder{};
    var session_ctx = PermissionContext{ .allocator = std.testing.allocator };
    session_ctx.event_sink = .{ .ctx = @ptrCast(&rec), .emitFn = &Recorder.emit };

    // scopedDerive:值拷贝 + null sink + 可选 override。
    var derived = session_ctx.scopedDerive(.bypass_permissions);
    try std.testing.expect(derived.event_sink == null); // sink 被 null
    try std.testing.expectEqual(types.PermissionMode.bypass_permissions, derived.modeValue()); // override 生效
    // derived.setMode 不 emit 到 session sink（scoped override 不污染 session 事件）
    derived.setMode(.plan);
    try std.testing.expectEqual(@as(usize, 0), rec.count);
    // **task#15 核心:mode 隔离**——derived(后台 subagent/teammate)改 mode 绝不回灌 lead。
    // scopedDerive 值拷贝 → derived.mode 是独立 atomic,session_ctx.mode 不受影响(仍默认 .prompt)。
    try std.testing.expectEqual(types.PermissionMode.prompt, session_ctx.modeValue());
    // 对照:session_ctx.setMode 才 emit
    session_ctx.setMode(.plan);
    try std.testing.expectEqual(@as(usize, 1), rec.count);
    // scopedDerive(null):无 override，保留原 mode，仍 null sink
    var derived2 = session_ctx.scopedDerive(null);
    try std.testing.expect(derived2.event_sink == null);
    try std.testing.expectEqual(session_ctx.modeValue(), derived2.modeValue());
}
