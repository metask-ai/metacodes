//! 分页器(TUI_COMPONENTS.md §5.4):less 风格全屏浏览长输出。
//!
//! 触发场景:
//! - 工具输出超过终端高度(由调用方决定何时启用)
//! - /transcript 长会话浏览
//! - git log --oneline | head -200
//!
//! 键绑定:
//! - Space / PgDn / Ctrl+F:翻一页
//! - b / PgUp / Ctrl+B:回翻一页
//! - j / Down / Enter:下一行
//! - k / Up:上一行
//! - g:跳到首行
//! - G:跳到末行
//! - q / Esc:退出
//!
//! 不实现的(P2 留待):/ 搜索 / 行号开关 / mouse scroll。
//!
//! 实现策略:
//! 1. 进 alt screen + 隐光标
//! 2. 内容按 \n 切成行数组(浅拷贝 borrow)
//! 3. 渲染 window:从 top_line 起,显示 rows-1 行(留 1 行 status)
//! 4. status 行(底部):"-- N/M (P%)  q to quit, ?--"
//! 5. 读键循环,更新 top_line + 重画
//! 6. 退出:恢复

const std = @import("std");
const pfs = @import("platform").fs;
const ansi = @import("../ansi.zig");
const theme_mod = @import("../theme.zig");
const term = @import("../term.zig");
const overlay_mod = @import("../overlay.zig");
const Theme = theme_mod.Theme;

pub const PageOptions = struct {
    /// 终端尺寸(0,0 = 自动 getSize fd 1)
    rows: u16 = 0,
    cols: u16 = 0,
    /// 输入 / 输出 fd
    in_fd: c_int = 0,
    out_fd: c_int = 1,
};

/// 渲染一帧:返回 alt screen 上要打的完整字符串(光标到 home + 内容 + status)。
/// 用于 snapshot 测试 + 真 IO 路径。caller free。
pub fn renderFrame(
    alloc: std.mem.Allocator,
    th: Theme,
    lines: []const []const u8,
    top: usize,
    rows: u16,
    cols: u16,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 光标 home + 清屏
    try out.appendSlice(alloc, ansi.cursor.home);
    try out.appendSlice(alloc, ansi.clear.to_end_of_screen);

    const content_rows = if (rows > 1) rows - 1 else 1;
    var i: usize = 0;
    while (i < content_rows) : (i += 1) {
        const line_idx = top + i;
        if (line_idx >= lines.len) break;
        // 截断到 cols(避免折行影响 status 行位置)
        const ln = lines[line_idx];
        const w = term.displayWidth(ln);
        if (cols > 0 and w > cols) {
            // 简化:按字节截 cols(CJK 边界这里不严格,够 less 风格)
            var byte_end: usize = 0;
            var col_used: usize = 0;
            while (byte_end < ln.len and col_used < cols) {
                const cn = nextCharBytes(ln, byte_end);
                col_used += term.displayWidth(ln[byte_end .. byte_end + cn]);
                if (col_used > cols) break;
                byte_end += cn;
            }
            try out.appendSlice(alloc, ln[0..byte_end]);
        } else {
            try out.appendSlice(alloc, ln);
        }
        try out.append(alloc, '\n');
    }

    // 填空行(让 status 总在底部)
    while (i < content_rows) : (i += 1) try out.append(alloc, '\n');

    // status 行:反色 + 信息
    const total = lines.len;
    const bottom = @min(top + content_rows, total);
    const pct: u32 = if (total > 0) @intCast((bottom * 100) / total) else 100;
    try out.appendSlice(alloc, ansi.sgr.reverse);
    try out.print(alloc, " {d}-{d}/{d} ({d}%)  q to quit ", .{ top + 1, bottom, total, pct });
    _ = th; // status 不用 theme(reverse 已足够区分)
    try out.appendSlice(alloc, ansi.sgr.reset);

    return try out.toOwnedSlice(alloc);
}

/// 全屏分页器主循环(真 IO)。
/// 进 alt screen → 内容切行 → 渲染 → 读键 → 更新 → ... → 退出。
/// 非 TTY → 直接打印全部内容(不分页)+ return。
pub fn page(alloc: std.mem.Allocator, th: Theme, content: []const u8, opts: PageOptions) !void {
    const in_fd = opts.in_fd;
    const out_fd = opts.out_fd;

    if (!term.isatty(in_fd) or !term.isatty(out_fd)) {
        // 非 TTY:直接打印
        writeAll(out_fd, content);
        return;
    }

    var size = term.TermSize{ .rows = 24, .cols = 80 };
    if (opts.rows > 0 and opts.cols > 0) {
        size = .{ .rows = opts.rows, .cols = opts.cols };
    } else if (term.getSize(out_fd)) |s| {
        size = s;
    }

    // 切行(借用 content)
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var pos: usize = 0;
    while (pos < content.len) {
        const eol = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
        try lines.append(alloc, content[pos..eol]);
        pos = eol + 1;
    }

    // 进 alt screen
    var ov = overlay_mod.Overlay{ .fd = out_fd };
    ov.enter();
    defer ov.exit();

    // 切 raw mode
    const input = @import("../../input.zig");
    const orig = input.enterRawMode(in_fd) orelse return;
    defer input.restoreMode(in_fd, orig);

    var top: usize = 0;
    const content_rows = if (size.rows > 1) size.rows - 1 else 1;
    const max_top = if (lines.items.len > content_rows) lines.items.len - content_rows else 0;

    while (true) {
        // 渲染
        const frame = try renderFrame(alloc, th, lines.items, top, size.rows, size.cols);
        defer alloc.free(frame);
        writeAll(out_fd, frame);

        // 读键
        var buf: [8]u8 = undefined;
        const n = pfs.read(in_fd, &buf);
        if (n <= 0) break;
        const b = buf[0];

        switch (b) {
            'q', 'Q', 0x03 => break, // q / Ctrl+C
            'g' => top = 0,
            'G' => top = max_top,
            ' ', 0x06 => { // Space / Ctrl+F
                top = @min(top + content_rows, max_top);
            },
            'b', 'B', 0x02 => { // b / Ctrl+B
                top = if (top > content_rows) top - content_rows else 0;
            },
            'j', '\r', '\n' => {
                top = @min(top + 1, max_top);
            },
            'k' => {
                top = if (top > 0) top - 1 else 0;
            },
            0x1b => {
                // ESC [ A/B(↑↓)或单 ESC(退出)
                if (n >= 3 and buf[1] == '[') {
                    switch (buf[2]) {
                        'A' => top = if (top > 0) top - 1 else 0, // up
                        'B' => top = @min(top + 1, max_top), // down
                        '5' => { // PgUp
                            top = if (top > content_rows) top - content_rows else 0;
                        },
                        '6' => { // PgDn
                            top = @min(top + content_rows, max_top);
                        },
                        else => {},
                    }
                } else {
                    break; // 单 ESC = 退出
                }
            },
            else => {},
        }
    }
}

fn nextCharBytes(s: []const u8, i: usize) usize {
    if (i >= s.len) return 0;
    const b = s[i];
    if (b < 0x80) return 1;
    if (b & 0b1110_0000 == 0b1100_0000) return @min(2, s.len - i);
    if (b & 0b1111_0000 == 0b1110_0000) return @min(3, s.len - i);
    if (b & 0b1111_1000 == 0b1111_0000) return @min(4, s.len - i);
    return 1;
}

fn writeAll(fd: c_int, bytes: []const u8) void {
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

test "renderFrame: 显示 window + status" {
    const lines = [_][]const u8{ "line1", "line2", "line3", "line4", "line5" };
    const th = theme_mod.dark;
    const s = try renderFrame(testing.allocator, th, &lines, 0, 4, 80);
    defer testing.allocator.free(s);
    // 4 rows = 3 content rows + 1 status
    try capture.expectContains(s, "line1");
    try capture.expectContains(s, "line3");
    try testing.expect(std.mem.indexOf(u8, s, "line4") == null); // 在 window 外
    try capture.expectContains(s, "1-3/5"); // status:1-3 of 5
}

test "renderFrame: top 偏移" {
    const lines = [_][]const u8{ "a", "b", "c", "d", "e" };
    const s = try renderFrame(testing.allocator, theme_mod.dark, &lines, 2, 4, 80);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "c");
    try capture.expectContains(s, "e");
    try testing.expect(std.mem.indexOf(u8, s, "a") == null);
    try capture.expectContains(s, "3-5/5"); // 显示从第 3 行起
}

test "renderFrame: 百分比正确" {
    const lines = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };
    const s = try renderFrame(testing.allocator, theme_mod.dark, &lines, 0, 6, 80);
    defer testing.allocator.free(s);
    // 5 content rows / 10 total = 50%
    try capture.expectContains(s, "(50%)");
}

test "renderFrame: 内容少于窗口高度" {
    const lines = [_][]const u8{ "only" };
    const s = try renderFrame(testing.allocator, theme_mod.dark, &lines, 0, 10, 80);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "1-1/1");
    try capture.expectContains(s, "(100%)");
}

test "renderFrame: 行被 cols 截断" {
    const lines = [_][]const u8{"a very long line that exceeds the column width"};
    const s = try renderFrame(testing.allocator, theme_mod.dark, &lines, 0, 4, 10);
    defer testing.allocator.free(s);
    // 应只保留前 10 列字符
    try capture.expectContains(s, "a very lon");
    try testing.expect(std.mem.indexOf(u8, s, "exceeds") == null);
}

test "VISUAL demo: pager(TUI_DEMO=1)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const th = theme_mod.dark;
    const lines = [_][]const u8{
        "Line 1 — hello", "Line 2",  "Line 3",  "Line 4",
        "Line 5 — world", "Line 6",  "Line 7",  "Line 8",
        "Line 9",         "Line 10",
    };
    const s = try renderFrame(testing.allocator, th, &lines, 0, 6, 40);
    defer testing.allocator.free(s);
    std.debug.print("\n{s}\n", .{s});
}

test "VISUAL demo: pager 真 IO(TUI_DEMO=pager)" {
    if (std.c.getenv("TUI_DEMO_PAGER") == null) return error.SkipZigTest;
    const th = theme_mod.dark;
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try content_buf.print(testing.allocator, "Line {d}: hello world\n", .{i});
    }
    try page(testing.allocator, th, content_buf.items, .{});
}
