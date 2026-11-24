//! 权限对话框(替代 permission/prompt.zig 的 13 行 stdin print)。
//!
//! TUI_COMPONENTS.md §5.1。
//!
//! 功能:
//! - 边框 + 标题 "Permission required"
//! - 工具名 + 关键参数预览(长 JSON 截断)
//! - 4 选项:[y] Yes once / [a] Yes always / [n] No / [d] Don't ask again
//! - 键盘选择(y/a/n/d 直接选 + ↑↓ 移动高亮 + Enter 确认)
//! - 返回 PermissionChoice
//!
//! 分层:
//! - render():纯渲染 → []u8(可 snapshot 测试)
//! - promptLoop():render + 读键循环(调用方负责 raw mode 与终端接管,见 TuiBackend)

const std = @import("std");
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal;
const ansi = @import("../ansi.zig");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const reflow = @import("../reflow.zig");
const input_mod = @import("../../input.zig");
const Theme = theme_mod.Theme;

/// PermissionChoice 已移到中立协议位置(core/protocol/);此处 re-export 保 UI 端引用兼容。
pub const PermissionChoice = @import("../../../core/protocol/permission_choice.zig").PermissionChoice;

pub const Option = struct {
    key: u8, // 'y' / 'a' / 'n' / 'd'
    label: []const u8,
    choice: PermissionChoice,
};

pub const options = [_]Option{
    .{ .key = 'y', .label = "Yes once", .choice = .allow_once },
    .{ .key = 'a', .label = "Yes, always", .choice = .allow_always },
    .{ .key = 'n', .label = "No", .choice = .deny_once },
    .{ .key = 'd', .label = "Don't ask again", .choice = .deny_tool_session },
};

/// 参数预览的最大显示宽度
const MAX_ARG_PREVIEW = 60;

/// 渲染权限对话框为字符串。selected = 当前高亮选项 index(0..3)。
/// caller free。
pub fn render(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, args: []const u8, selected: usize) ![]u8 {
    // 构造内容:工具名 + 参数预览行 + 空行 + 选项行
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);

    // 工具名(加色)
    try content.appendSlice(alloc, th.role_tool);
    try content.appendSlice(alloc, tool_name);
    try content.appendSlice(alloc, th.reset);
    try content.append(alloc, '\n');

    // 参数预览(截断,dim)。truncate 不超长返回 borrow(==args),超长返回 owned。
    const preview = try layout.truncate(alloc, args, MAX_ARG_PREVIEW, "…");
    defer if (preview.ptr != args.ptr) alloc.free(@constCast(preview));
    try content.appendSlice(alloc, th.dim);
    try content.appendSlice(alloc, preview);
    try content.appendSlice(alloc, th.reset);
    try content.append(alloc, '\n');
    try content.append(alloc, '\n');

    // 选项行:高亮 selected
    for (options, 0..) |opt, i| {
        if (i == selected) {
            try content.appendSlice(alloc, th.accent);
            try content.appendSlice(alloc, th.icon_arrow);
            try content.append(alloc, ' ');
        } else {
            // 用空格对齐(arrow 宽度 + 1)
            const arrow_w = term.displayWidth(th.icon_arrow);
            var p: usize = 0;
            while (p < arrow_w + 1) : (p += 1) try content.append(alloc, ' ');
        }
        try content.print(alloc, "[{c}] {s}", .{ opt.key, opt.label });
        if (i == selected) try content.appendSlice(alloc, th.reset);
        if (i + 1 < options.len) try content.append(alloc, '\n');
    }

    return try layout.drawBox(alloc, th, content.items, .{
        .title = "Permission required",
        .width = MAX_ARG_PREVIEW + 4,
        .padding = 1,
    });
}

/// 渲染 + 读键循环(不管 raw mode / 终端接管——调用方负责)。
/// TuiBackend 终端接管(停 watcher+持锁)后调,生成期的 raw mode 由 loop 进好:对话框自己不再进
/// 一层 raw mode(嵌套的 restoreMode 会把外层开着的括号粘贴、win32-input-mode 一起关掉)。
/// out_fd 输出(TuiBackend 接管用 stderr=2 与 region 同流)。
/// 重画用 render 实际行数(不再硬编码 8——参数长会折行变多行,硬编码会错位)。
/// 回顶按终端现在的宽度数上一帧占的行:框比终端宽时画的那一刻就折了行,终端变窄后
/// 又会把每行重排成多行(reflow.zig);回顶后 ED 0 清掉旧帧多出的行。
pub fn promptLoop(alloc: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int, tool_name: []const u8, args: []const u8) ?PermissionChoice {
    var selected: usize = 0;
    var drawn: ?reflow.Anchor = null;
    const reflows = term.reflowFromEnv();
    var parser = input_mod.KeyParser{};
    while (true) {
        const cols: u16 = if (term.getSize(out_fd)) |size| size.cols else 80;
        if (drawn) |anchor| {
            var up_buf: [16]u8 = undefined;
            writeAll(out_fd, ansi.cursor.up(anchor.climb(cols, reflows), &up_buf));
            writeAll(out_fd, "\r");
            writeAll(out_fd, ansi.clear.to_end_of_screen);
        }
        const frame = render(alloc, th, tool_name, args, selected) catch return .deny_once;
        defer alloc.free(frame);
        writeAll(out_fd, frame);
        drawn = reflow.Anchor.atEnd(frame, cols);

        const key = switch (input_mod.readKey(in_fd, &parser)) {
            .key => |key| key,
            .interrupted => continue,
            .closed => return .deny_once,
        };
        switch (key) {
            .char => |c| switch (c) {
                'y', 'Y' => return .allow_once,
                'a', 'A' => return .allow_always,
                'n', 'N' => return .deny_once,
                'd', 'D' => return .deny_tool_session,
                else => {},
            },
            .ctrl_c => return .deny_once,
            .enter => return options[selected].choice,
            .up => selected = if (selected == 0) options.len - 1 else selected - 1,
            .down => selected = (selected + 1) % options.len,
            .paste_begin => if (skipPaste(in_fd, &parser)) |choice| return choice,
            else => {},
        }
    }
}

fn skipPaste(in_fd: c_int, parser: *input_mod.KeyParser) ?PermissionChoice {
    while (true) {
        switch (input_mod.readKey(in_fd, parser)) {
            .key => |key| switch (key) {
                .paste_end => return null,
                .ctrl_c => return .deny_once,
                else => {},
            },
            .interrupted => {},
            .closed => return .deny_once,
        }
    }
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    @import("../screen_mirror.zig").feed(fd, bytes);
    _ = pfs.writeAll(fd, bytes); // resize 打断(EINTR)重试,不丢半帧
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

test "render: monochrome 含标题/工具名/4 选项/无 ANSI" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "Bash", "{\"command\":\"git status\"}", 0);
    defer testing.allocator.free(s);

    try capture.expectContains(s, "Permission required");
    try capture.expectContains(s, "Bash");
    try capture.expectContains(s, "git status");
    try capture.expectContains(s, "[y] Yes once");
    try capture.expectContains(s, "[a] Yes, always");
    try capture.expectContains(s, "[n] No");
    try capture.expectContains(s, "[d] Don't ask again");
    try capture.expectNoAnsi(s); // monochrome 无颜色
}

test "render: dark 含 ANSI + 高亮箭头" {
    const th = theme_mod.dark;
    const s = try render(testing.allocator, th, "Write", "{\"file_path\":\"/x\"}", 0);
    defer testing.allocator.free(s);
    // dark 主题应含 ANSI
    try testing.expect(std.mem.indexOf(u8, s, "\x1b") != null);
    // selected=0 时第一个选项前有箭头 →
    try capture.expectContains(s, "→ [y]");
}

test "render: selected=2 高亮第三项 No" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "Bash", "rm", 2);
    defer testing.allocator.free(s);
    // monochrome 箭头是 "->"
    try capture.expectContains(s, "-> [n] No");
}

test "render: 长参数被截断" {
    const th = theme_mod.monochrome;
    const long = "{\"command\":\"this is a very long command that definitely exceeds sixty columns for sure yes\"}";
    const s = try render(testing.allocator, th, "Bash", long, 0);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "…"); // 省略号
}

test "options 表完整" {
    try testing.expectEqual(@as(usize, 4), options.len);
    try testing.expectEqual(PermissionChoice.allow_once, options[0].choice);
    try testing.expectEqual(PermissionChoice.allow_always, options[1].choice);
    try testing.expectEqual(PermissionChoice.deny_once, options[2].choice);
    try testing.expectEqual(PermissionChoice.deny_tool_session, options[3].choice);
}

test "VISUAL demo (打印到 stderr,看真实渲染)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const s = try render(testing.allocator, theme_mod.dark, "Bash", "{\"command\":\"rm -rf /tmp/build\",\"timeout\":30000}", 0);
    defer testing.allocator.free(s);
    std.debug.print("\n{s}\n", .{s});
}

test "promptLoop 读 Windows 控制台送来的按键记录:y、n、Ctrl+C 各是一个回答" {
    // win32-input-mode 开着时每个键都是一条记录(控制台逐字符排进队列,sendChars)。对话框读的是
    // 还原后的键;读原始字节时一个也认不出,工具调用一直等着(#388 审查)。
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("platform").test_support.PrivateConsole.begin();
    defer console.end();
    defer platform_term.resetConsoleInputForTesting();
    platform_term.decodeKeyRecords();
    const sink = pfs.open("NUL", .{ .ACCMODE = .WRONLY }, 0);
    try testing.expect(sink >= 0);
    defer _ = pfs.close(sink);
    const cases = [_]struct { records: []const u8, choice: PermissionChoice }{
        .{ .records = "\x1b[89;21;121;1;32;1_\x1b[89;21;121;0;32;1_", .choice = .allow_once },
        .{ .records = "\x1b[78;49;110;1;32;1_\x1b[78;49;110;0;32;1_", .choice = .deny_once },
        .{ .records = "\x1b[17;29;0;1;40;1_\x1b[67;46;3;1;40;1_\x1b[67;46;3;0;40;1_\x1b[17;29;0;0;32;1_", .choice = .deny_once },
    };
    for (cases) |c| {
        try console.sendChars(c.records);
        try testing.expectEqual(c.choice, promptLoop(testing.allocator, theme_mod.dark, 0, sink, "Write", "{}").?);
    }
}

test "promptLoop reads whole keys: Ctrl+C sent as CSI u refuses, keys written together each count, a paste never answers" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const sink = pfs.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    try testing.expect(sink >= 0);
    defer _ = pfs.close(sink);
    const Later = struct {
        fn send(fd: c_int, bytes: []const u8) void {
            @import("platform").sync.sleepMs(300);
            _ = pfs.writeAll(fd, bytes);
            _ = std.c.close(fd);
        }
    };
    const cases = [_]struct { now: []const u8, later: []const u8, choice: PermissionChoice }{
        .{ .now = "\x1b[99;5u", .later = "y", .choice = .deny_once },
        .{ .now = "\x1b[27u", .later = "d", .choice = .deny_tool_session },
        .{ .now = "\x1b[B\x1b[B\x1b[B\r", .later = "y", .choice = .deny_tool_session },
        .{ .now = "\x1b[200~yes\x1b[201~", .later = "d", .choice = .deny_tool_session },
        .{ .now = "\x1b[200~a\x03", .later = "\x1b[201~d", .choice = .deny_once },
    };
    for (cases) |c| {
        var fds: [2]std.c.fd_t = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        try testing.expect(pfs.writeAll(fds[1], c.now));
        const thread = try std.Thread.spawn(.{}, Later.send, .{ fds[1], c.later });
        const got = promptLoop(testing.allocator, theme_mod.monochrome, fds[0], sink, "Write", "{}");
        thread.join();
        try testing.expectEqual(c.choice, got.?);
    }
}
