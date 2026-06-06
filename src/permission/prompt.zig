//! 用户交互:权限询问(prompt 模式的 yes/always/no/don't-ask)。
//!
//! TTY 下走 TUI 对话框(tui/dialog/permission.zig);非 TTY 退回最简文字 prompt。
//!
//! "Yes always" / "Don't ask again" 的 session 级记忆:本模块用一个进程级 SessionRules
//! 暂存(同 tool_name 不再问)。完整 settings.local.json 持久化由 App 层做(它知道文件路径)。

const std = @import("std");
const category = @import("category.zig");
const dialog = @import("../repl/tui/dialog/permission.zig");
const theme_mod = @import("../repl/tui/theme.zig");
const term = @import("../repl/tui/term.zig");

/// Session 级权限记忆:always-allow / session-deny 的工具名集合。
/// 进程级(单 session),不持久化。键是 tool_name(值语义拷贝,固定上限避免无限增长)。
const MAX_REMEMBERED = 64;
var g_always_allow: [MAX_REMEMBERED][]const u8 = undefined;
var g_always_allow_count: usize = 0;
var g_session_deny: [MAX_REMEMBERED][]const u8 = undefined;
var g_session_deny_count: usize = 0;
var g_buf: [MAX_REMEMBERED * 2][64]u8 = undefined; // 工具名拷贝存储
var g_buf_used: usize = 0;

fn remember(list: *[MAX_REMEMBERED][]const u8, count: *usize, name: []const u8) void {
    if (count.* >= MAX_REMEMBERED) return;
    if (g_buf_used >= g_buf.len or name.len > 64) return;
    const slot = &g_buf[g_buf_used];
    g_buf_used += 1;
    @memcpy(slot[0..name.len], name);
    list[count.*] = slot[0..name.len];
    count.* += 1;
}

/// 全局上下文:App 启动时 set,allow_always 选项写 settings.local.json 用。
/// project_dir 为 null 时退回 ~/.claude/settings.json。
var g_project_dir: ?[]const u8 = null;
var g_home: ?[]const u8 = null;

pub fn setPersistContext(project_dir: ?[]const u8, home: []const u8) void {
    g_project_dir = project_dir;
    g_home = home;
}

/// 可选的对话框 runner 注入:有 TuiBackend 时,loop.zig 把它设成 backend 的"终端接管"
/// 包装(停 watcher + 持渲染锁后渲染对话框,根治与键盘 watcher 抢 fd0)。null = 没设
/// → ask() 回退裸 dialog.prompt(直接 read fd0,仅在无 watcher 的场景安全)。
/// 签名同 dialog.prompt:返回选择 or null(非 tty/失败)。
const PermissionChoice = dialog.PermissionChoice;
var g_dialog_runner: ?*const fn (state: *anyopaque, tool_name: []const u8, args: []const u8) ?PermissionChoice = null;
var g_dialog_runner_state: ?*anyopaque = null;

pub fn setDialogRunner(
    state: *anyopaque,
    runner: *const fn (state: *anyopaque, tool_name: []const u8, args: []const u8) ?PermissionChoice,
) void {
    g_dialog_runner_state = state;
    g_dialog_runner = runner;
}

/// 清除 runner(生成期结束后,避免悬垂指向已失效的 TuiBackend 栈实例)。
pub fn clearDialogRunner() void {
    g_dialog_runner = null;
    g_dialog_runner_state = null;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// 阻塞式询问用户。返回 true = 允许。
/// 先查 session 记忆;否则:有预置应答队列(非 tty e2e)→ 走文字路径从队列弹;
/// 否则 TTY 走对话框,非 TTY 走文字。
pub fn ask(tool_name: []const u8, args: []const u8) !bool {
    // session 记忆优先
    if (contains(g_always_allow[0..g_always_allow_count], tool_name)) return true;
    if (contains(g_session_deny[0..g_session_deny_count], tool_name)) return false;

    // 预置应答队列曾加载(Stage 3 e2e)→ 强制走文字路径(askText 从队列弹/耗尽则
    // 安全默认 deny,**绝不**退回读 fd 0——它被 REPL 行流独占,会死等)。
    if (@import("../core/answer_queue.zig").wasLoaded()) {
        return askText(tool_name, args);
    }

    // TTY → 对话框
    if (term.isatty(0)) {
        const cap = term.detectFromEnv(1);
        const th = theme_mod.select(.auto, cap);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        // 有注入的 runner(TuiBackend 终端接管)→ 走它(停 watcher+持锁,不抢 fd0);
        // 否则裸 dialog.prompt(无 watcher 场景)。两者返回同一 PermissionChoice。
        const choice_opt: ?PermissionChoice = if (g_dialog_runner) |runner|
            runner(g_dialog_runner_state.?, tool_name, args)
        else
            dialog.prompt(arena.allocator(), th, tool_name, args);
        if (choice_opt) |choice| {
            switch (choice) {
                .allow_once => return true,
                .allow_always => {
                    remember(&g_always_allow, &g_always_allow_count, tool_name);
                    // 持久化:写到 settings.local.json(project)或 ~/.claude/settings.json
                    if (g_home) |home| {
                        const writer = @import("settings_writer.zig");
                        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                        const written = writer.addAllowRule(arena.allocator(), g_project_dir, home, tool_name, &path_buf) catch null;
                        if (written) |p| {
                            std.debug.print("\x1b[2m(persisted to {s})\x1b[0m\n", .{p});
                        }
                    }
                    return true;
                },
                .deny_once => return false,
                .deny_tool_session => {
                    remember(&g_session_deny, &g_session_deny_count, tool_name);
                    return false;
                },
            }
        }
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
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n > 0 and (buf[0] == 'y' or buf[0] == 'Y')) return true;
    return false;
}

test "ask 不崩(非 tty 路径覆盖在集成测试)" {
    // session 记忆 helper 单测
    g_always_allow_count = 0;
    g_buf_used = 0;
    remember(&g_always_allow, &g_always_allow_count, "Bash");
    try std.testing.expect(contains(g_always_allow[0..g_always_allow_count], "Bash"));
    try std.testing.expect(!contains(g_always_allow[0..g_always_allow_count], "Write"));
}
