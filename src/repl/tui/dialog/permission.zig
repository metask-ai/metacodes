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
//! - prompt():render + raw mode 读键循环(真 TTY 才用;非 TTY 由调用方退回文字)

const std = @import("std");
const ansi = @import("../ansi.zig");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
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

/// 交互式询问(真 TTY)。渲染对话框 + raw mode 读键,返回选择。
/// 非 TTY → 返回 null(调用方退回文字 prompt)。
///
/// input.zig 的 enterRawMode/restoreMode 复用。fd 默认 stdin(0),输出 fd 默认 stdout(1)。
pub fn prompt(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, args: []const u8) ?PermissionChoice {
    const input = @import("../../input.zig");
    const in_fd: std.c.fd_t = 0;

    if (!term.isatty(in_fd)) return null;

    const orig = input.enterRawMode(in_fd) orelse return null;
    defer input.restoreMode(in_fd, orig);

    return promptLoop(alloc, th, in_fd, 1, tool_name, args);
}

/// 渲染 + 读键循环(不管 raw mode / 终端接管——调用方负责)。
/// 用于:① prompt() 自己进 raw mode 后调;② TuiBackend 终端接管(停 watcher+持锁)后调。
/// out_fd 输出(prompt 用 stdout=1;TuiBackend 接管用 stderr=2 与 region 同流)。
/// 重画用 render 实际行数(不再硬编码 8——参数长会折行变多行,硬编码会错位)。
pub fn promptLoop(alloc: std.mem.Allocator, th: Theme, in_fd: std.c.fd_t, out_fd: std.c.fd_t, tool_name: []const u8, args: []const u8) ?PermissionChoice {
    var selected: usize = 0;
    var prev_rows: usize = 0;
    while (true) {
        if (prev_rows > 0) {
            var up_buf: [16]u8 = undefined;
            writeAll(out_fd, ansi.cursor.up(@intCast(prev_rows), &up_buf));
            writeAll(out_fd, "\r");
        }
        const frame = render(alloc, th, tool_name, args, selected) catch return .deny_once;
        defer alloc.free(frame);
        writeAll(out_fd, frame);
        prev_rows = countRows(frame);

        var buf: [8]u8 = undefined;
        const n = std.c.read(in_fd, &buf, buf.len);
        if (n <= 0) return .deny_once;
        const b = buf[0];

        switch (b) {
            'y', 'Y' => return .allow_once,
            'a', 'A' => return .allow_always,
            'n', 'N' => return .deny_once,
            'd', 'D' => return .deny_tool_session,
            0x03 => return .deny_once, // Ctrl+C → 拒绝
            '\r', '\n' => return options[selected].choice, // Enter 确认高亮
            else => {},
        }
        // 方向键:ESC [ A/B
        if (b == 0x1b and n >= 3 and buf[1] == '[') {
            switch (buf[2]) {
                'A' => selected = if (selected == 0) options.len - 1 else selected - 1, // up
                'B' => selected = (selected + 1) % options.len, // down
                else => {},
            }
        }
    }
}

/// frame 占的终端行数(= '\n' 数),供 cursor.up 精确回顶。
fn countRows(frame: []const u8) usize {
    var rows: usize = 0;
    for (frame) |c| {
        if (c == '\n') rows += 1;
    }
    return rows;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const w = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (w <= 0) return;
        total += @as(usize, @intCast(w));
    }
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