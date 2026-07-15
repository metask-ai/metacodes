//! SessionService（U2 S3）— session 状态 mutation 的**唯一中立入口**。
//!
//! 设计（doc/U2_SESSIONSERVICE_DESIGN.md）：
//!   - **只收敛 mutation，不收敛渲染**。exec(verb,args)→CommandOutcome{kind,ok,data}；
//!     kind 供 U4 派生 config-change 事件，data 是结构化载荷，**渲染归各 UI**（render(buf)
//!     是共享格式化助手，消除 loop/web 消息重复）。
//!   - **借 *App，不持 backend**（Linus 定）。所有方法只在 driver 线程调（TUI run 循环 /
//!     web cmdbox popFront 后）；App arena 非线程安全，绝不跨线程调。
//!   - **是所有 config 轴 mutation 的唯一写侧**（choke point）。会话轴 mutation
//!     (/resume /retry /goal) 显式排除，归 U5/U8（见 doc §1.5）。
//!   - U4 在 mutation 方法里接 event_sink（本模块不含 emit，只把 kind/data 结构就位）。
//!
//! **message 所有权（Linus 定）**：不用共享 scratch buffer（U4 会跨线程 emit）。
//!   CommandOutcome 只带 kind + data（值语义或借 App 稳定串，同步渲染安全）；render(buf)
//!   写进 **caller 提供的 per-call buf**（非 SessionService 共享），各 UI 自渲染。

const std = @import("std");
const app_mod = @import("app.zig");
const types = @import("types.zig");
const model_command = @import("repl/model_command.zig");
const theme_mod = @import("repl/tui/theme.zig");

pub const CommandOutcome = struct {
    kind: Kind,
    ok: bool,
    data: Data = .none,

    /// 变更类别。config 轴 mutation → U4 据此 emit；unhandled/noop/err 是控制信号。
    pub const Kind = enum {
        model_changed,
        mode_changed,
        dirs_changed,
        theme_changed,
        vim_changed,
        reasoning_changed,
        compacted,
        /// 非本命令面负责（纯展示命令 / 未知动词）→ caller 自渲染/兜底。
        unhandled,
        /// 已处理但无状态变更（如缺参提示）。
        noop,
        /// 处理出错（如 model 切换失败）。ok=false。
        err,
    };

    /// 结构化载荷（值语义或借 App 稳定串——同步渲染期 App 不变，安全）。
    pub const Data = union(enum) {
        none,
        model: []const u8, // 新 model（借 app.activeModel()）
        mode: types.PermissionMode,
        compact: app_mod.App.CompactResult,
        dir: []const u8, // 新增目录
        theme: theme_mod.Variant,
        vim: bool,
        err_name: []const u8, // 错误名（借 @errorName，静态）
        text: []const u8, // 通用静态串（提示/回显）
    };

    /// 渲染人类可读消息到 **caller 的 buf**（per-call，非共享 scratch）。返回 buf 子切片或静态串。
    /// 各 UI（loop.zig / web execCommand）都调此 → 消息不再 loop/web 各写一份。
    pub fn render(self: CommandOutcome, buf: []u8) []const u8 {
        return switch (self.data) {
            .none => switch (self.kind) {
                .compacted => "compacted", // 理论不达（compacted 带 data）
                else => "",
            },
            .model => |m| std.fmt.bufPrint(buf, "model → {s}", .{m}) catch "model changed",
            .mode => |m| std.fmt.bufPrint(buf, "permission mode → {s}", .{@tagName(m)}) catch "mode changed",
            .compact => |c| std.fmt.bufPrint(buf, "compacted {d} messages ({d} → {d} active)", .{ c.dropped, c.before, c.after }) catch "compacted",
            .dir => |d| std.fmt.bufPrint(buf, "added directory: {s}", .{d}) catch "directory added",
            .theme => |v| std.fmt.bufPrint(buf, "theme → {s}", .{theme_mod.variantName(v)}) catch "theme changed",
            .vim => |on| if (on) "editor mode → vim" else "editor mode → emacs",
            .err_name => |e| std.fmt.bufPrint(buf, "error: {s}", .{e}) catch "error",
            .text => |t| t,
        };
    }
};

pub const SessionService = struct {
    app: *app_mod.App,

    pub fn init(app: *app_mod.App) SessionService {
        return .{ .app = app };
    }

    /// 分派一条命令。verb=已去 `/` 的动词，args=其余（已 trim）。alloc 供需要临时分配的命令
    /// （setModel 收集候选做 provider 守卫）;driver 线程的临时分配器。
    /// 只处理 **config 轴 mutation**；纯展示命令 / 未知动词 / 缺参的展示子形式 → .unhandled，
    /// caller 自渲染（如 /model 无参列候选、/theme 无参列变体）。
    pub fn exec(self: *SessionService, alloc: std.mem.Allocator, verb: []const u8, args: []const u8) CommandOutcome {
        const eql = std.mem.eql;
        if (eql(u8, verb, "model")) {
            if (args.len == 0) return .{ .kind = .unhandled, .ok = true }; // 无参=列候选(展示)→caller
            return self.setModel(alloc, args);
        }
        if (eql(u8, verb, "mode")) return self.cyclePermMode();
        if (eql(u8, verb, "compact")) return self.compact();
        if (eql(u8, verb, "add-dir")) {
            if (args.len == 0) return .{ .kind = .noop, .ok = false, .data = .{ .text = "usage: /add-dir <path>" } };
            return self.addDirectory(args);
        }
        if (eql(u8, verb, "theme")) {
            if (args.len == 0) return .{ .kind = .unhandled, .ok = true }; // 无参=列变体(展示)→caller
            return self.setTheme(args);
        }
        if (eql(u8, verb, "vim")) return self.toggleVim();
        return .{ .kind = .unhandled, .ok = true };
    }

    // ── 直接 mutation API（exec 内部调；也供非命令触发点直调，如 Shift+Tab/model-picker 键）──

    pub fn setModel(self: *SessionService, alloc: std.mem.Allocator, model_id: []const u8) CommandOutcome {
        // provider 守卫(对齐 loop.zig 旧 /model；顺带修 web /model 之前漏守卫)：收集当前
        // provider 的候选，拒绝跨 provider 的 model。候选 slice owned,元素借 catalog/BUILTINS。
        const candidates = model_command.collectCandidates(alloc, self.app.config.provider_kind, self.app.api_client.catalog.entries.items) catch {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "model catalog unavailable" } };
        };
        defer alloc.free(candidates);
        if (!model_command.canUseInCurrentProvider(self.app.config.provider_kind, candidates, model_id)) {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "model not available for current provider" } };
        }
        self.app.switchModel(model_id) catch |e| {
            return .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        return .{ .kind = .model_changed, .ok = true, .data = .{ .model = self.app.activeModel() } };
    }

    pub fn cyclePermMode(self: *SessionService) CommandOutcome {
        self.app.cyclePermMode();
        return .{ .kind = .mode_changed, .ok = true, .data = .{ .mode = self.app.permMode() } };
    }

    pub fn setPermMode(self: *SessionService, mode: types.PermissionMode) CommandOutcome {
        self.app.permission_ctx.setMode(mode);
        return .{ .kind = .mode_changed, .ok = true, .data = .{ .mode = self.app.permMode() } };
    }

    pub fn compact(self: *SessionService) CommandOutcome {
        const r = self.app.compactWindow();
        return .{ .kind = .compacted, .ok = true, .data = .{ .compact = r } };
    }

    pub fn addDirectory(self: *SessionService, dir: []const u8) CommandOutcome {
        self.app.addDirectory(dir) catch |e| {
            return .{ .kind = .err, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        return .{ .kind = .dirs_changed, .ok = true, .data = .{ .dir = dir } };
    }

    pub fn setReasoningEffort(self: *SessionService, effort: types.ReasoningEffort) CommandOutcome {
        self.app.setReasoningEffort(effort);
        return .{ .kind = .reasoning_changed, .ok = true, .data = .{ .text = effort.name() } };
    }

    pub fn setTheme(self: *SessionService, variant_name: []const u8) CommandOutcome {
        const variant = theme_mod.parseVariant(variant_name) orelse {
            return .{ .kind = .err, .ok = false, .data = .{ .text = "unknown theme (try: auto, dark, light, mono)" } };
        };
        _ = self.app.setTheme(variant) catch |e| {
            // theme 已切，仅持久化失败 → 仍算 changed，但 ok=false 带错误
            return .{ .kind = .theme_changed, .ok = false, .data = .{ .err_name = @errorName(e) } };
        };
        return .{ .kind = .theme_changed, .ok = true, .data = .{ .theme = variant } };
    }

    pub fn toggleVim(self: *SessionService) CommandOutcome {
        const on = self.app.toggleVim();
        return .{ .kind = .vim_changed, .ok = true, .data = .{ .vim = on } };
    }
};

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

test "SessionService.exec: 未知动词 → unhandled(caller 兜底)" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "doctor", "");
    try testing.expectEqual(CommandOutcome.Kind.unhandled, o.kind);
}

test "SessionService: vim toggle → vim_changed + render" {
    var app: app_mod.App = undefined;
    app.config = types.Config{};
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "vim", "");
    try testing.expectEqual(CommandOutcome.Kind.vim_changed, o.kind);
    try testing.expect(o.ok);
    try testing.expect(o.data.vim); // false→true
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("editor mode → vim", o.render(&buf));
}

test "SessionService: compact → compacted + 结构化 data + render" {
    const a = testing.allocator;
    var app: app_mod.App = undefined;
    app.conversation = @import("core/conversation.zig").Conversation.init(a);
    defer app.conversation.deinit();
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "compact", "");
    try testing.expectEqual(CommandOutcome.Kind.compacted, o.kind);
    try testing.expectEqual(@as(usize, 0), o.data.compact.dropped); // 空对话
    var buf: [80]u8 = undefined;
    try testing.expectEqualStrings("compacted 0 messages (0 → 0 active)", o.render(&buf));
}

test "SessionService: add-dir 无参 → noop + usage 提示" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "add-dir", "");
    try testing.expectEqual(CommandOutcome.Kind.noop, o.kind);
    try testing.expect(!o.ok);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("usage: /add-dir <path>", o.render(&buf));
}

test "SessionService: model 无参 → unhandled(列候选归 caller)" {
    var app: app_mod.App = undefined;
    var svc = SessionService.init(&app);
    const o = svc.exec(testing.allocator, "model", "");
    try testing.expectEqual(CommandOutcome.Kind.unhandled, o.kind);
}
