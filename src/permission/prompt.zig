//! 用户交互:权限询问(prompt 模式的 yes/always/no/don't-ask)。
//!
//! 已设注入的 UI runner(PermissionContext.ui_request_fn)→ 发 .permission UiRequest 让前端
//! 渲染;无 runner → 退回最简文字 prompt。**不直接依赖任何 TUI 对话框**(库可在无 UI 时复用)。
//!
//! Session 级记忆("Yes always" / "Don't ask again")、persist 路径、UI runner 全部经
//! PermissionContext 携带(每 session 一份),不再用进程全局——多 Session 不串台。

const std = @import("std");
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal;
const category = @import("category.zig");
const PermissionChoice = @import("../core/protocol/permission_choice.zig").PermissionChoice;
const ui_request = @import("../core/protocol/ui_request.zig");
const PermissionContext = @import("../permission.zig").PermissionContext;

/// 阻塞式询问用户。返回 true = 允许。ctx 携带 session 记忆 / UI runner / persist 路径。
/// **ctx 非 const**:本函数有副作用(写 session 记忆 rememberAllow/Deny、写 settings.local.json)。
/// 线程契约:M6 前假设单线程调用(SessionRules 无锁);M6 多 session 多线程化时给 SessionRules 加锁。
pub fn ask(ctx: *PermissionContext, tool_name: []const u8, args: []const u8) !bool {
    // session 记忆优先(per-session,不串台)
    if (ctx.session_rules) |sr| {
        if (sr.isAllowed(tool_name)) return true;
        if (sr.isDenied(tool_name)) return false;
    }

    // 预置应答队列曾加载(Stage 3 e2e)→ 强制走文字路径(askText 从队列弹/耗尽则
    // 安全默认 deny,**绝不**退回读 fd 0——它被 REPL 行流独占,会死等)。
    if (@import("../core/answer_queue.zig").wasLoaded()) {
        return askText(tool_name, args);
    }

    // 已注入 runner → 经 UiRequest 让前端渲染对话框。**不 gate 在 isatty 上**:
    // UiRequester 是 UI 中立抽象,web/GUI 前端无 tty 也能渲染(旧 isatty gate 是 TUI
    // 时代的泄漏——web 模式非 tty 启动会掉进 fd 0 文字 prompt 死等)。
    // 无 runner(库消费者未接 UI / 无 watcher 场景)→ 落到下方文字 prompt。
    if (ctx.ui_requester != null or platform_term.isatty(0)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const choice_opt: ?PermissionChoice = blk: {
            if (ctx.ui_requester) |runner| {
                const req = ui_request.UiRequest{ .permission = .{ .tool = tool_name, .args = args } };
                var resp: ui_request.UiResponse = undefined;
                // permission 门是 executeSlots 前的同步门,不支持挂起(out of scope)——
                // 仅 .answered 读 resp;.pending/.unavailable 落文字 prompt 兜底。
                const outcome = runner.request(ctx.session, arena.allocator(), &req, &resp) catch break :blk null;
                if (outcome != .answered) break :blk null;
                break :blk switch (resp) {
                    .permission => |c| c,
                    else => null,
                };
            }
            break :blk null; // 无 runner → 落文字 prompt(不再裸调 TUI dialog)
        };
        if (choice_opt) |choice| {
            switch (choice) {
                .allow_once => return true,
                .allow_always => {
                    if (ctx.session_rules) |sr| sr.rememberAllow(tool_name);
                    // 持久化:写到 settings.local.json(project)或 ~/.claude/settings.json。
                    // 路径上下文复用 ctx.match_ctx(project_root / home)——App init 在 ask 之前填好。
                    const home = ctx.match_ctx.home;
                    if (home.len > 0) {
                        const writer = @import("settings_writer.zig");
                        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const project: ?[]const u8 = if (ctx.match_ctx.project_root.len > 0) ctx.match_ctx.project_root else null;
                        const written = writer.addAllowRule(arena.allocator(), project, home, tool_name, &path_buf) catch null;
                        if (written) |p| {
                            std.debug.print("\x1b[2m(persisted to {s})\x1b[0m\n", .{p});
                        }
                    } else {
                        // match_ctx 未填(理论上 ask 总在 init 后,home 非空)。仍 allow_always,
                        // 但 session 内有效、不落盘——显式 warn,避免"权限记不住"静默失败抓瞎。
                        @import("../util/log.zig").warn("permission", "allow_always persist skipped: match_ctx.home empty (only session-scoped)", .{});
                    }
                    return true;
                },
                .deny_once => return false,
                .deny_tool_session => {
                    if (ctx.session_rules) |sr| sr.rememberDeny(tool_name);
                    return false;
                },
            }
        }
        // requester 存在但未给出答案(异常/pending/取消)且无 tty 可回落 → 安全 deny。
        // 绝不读 fd 0:web/GUI daemon 的 fd 0 不属于权限系统(读它 = 死等或吞别人的输入)。
        // tty 场景保留 askText 回落(TUI dialog Esc 的存量语义不动)。
        if (!platform_term.isatty(0)) return false;
        // dialog 返回 null(意外非 TTY)→ 落到文字
    }

    // 非 TTY 退回文字 prompt
    return askText(tool_name, args);
}

/// 最简文字 prompt(非 TTY / dialog 不可用时)。
fn askText(tool_name: []const u8, args: []const u8) !bool {
    const aq = @import("../core/answer_queue.zig");
    // 预置应答队列(Stage 3 e2e):非 tty 下 fd 0 被 REPL 行流独占,从队列按序弹应答。
    // y/Y/a(always) → 允许;其余(n 等)→ 拒绝。
    if (aq.pop()) |ans| {
        const yes = ans.len > 0 and (ans[0] == 'y' or ans[0] == 'Y' or ans[0] == 'a' or ans[0] == 'A');
        std.debug.print("\x1b[2m[Permission] {s}: 预置应答 '{s}' → {s}\x1b[0m\n", .{ tool_name, ans, if (yes) "允许" else "拒绝" });
        return yes;
    }
    // 队列曾加载但已耗尽 → 安全默认 deny(不退回 fd 0 死等)。
    if (aq.wasLoaded()) {
        std.debug.print("\x1b[2m[Permission] {s}: 应答队列耗尽 → 默认拒绝\x1b[0m\n", .{tool_name});
        return false;
    }

    const risk = category.getRiskLevel(tool_name);
    const risk_str: []const u8 = switch (risk) {
        .low => "LOW",
        .medium => "MEDIUM",
        .high => "HIGH",
    };
    std.debug.print("\x1b[33m[Permission] {s} tool requires {s} risk action\x1b[0m\n", .{ tool_name, risk_str });
    std.debug.print("  Args: {s}\n", .{args});
    std.debug.print("Allow? [y/N]: ", .{});

    var buf: [10]u8 = undefined;
    const n = pfs.readZ(0, &buf) catch return false;
    if (n > 0 and (buf[0] == 'y' or buf[0] == 'Y')) return true;
    return false;
}

// session 记忆的单测在 session_rules.zig;ask 的真链路(answer_queue → ask → askText)
// 在 tests/component/answer_queue_test.zig 覆盖。本模块不再放占位测试。
