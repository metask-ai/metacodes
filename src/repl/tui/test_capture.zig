//! L1 测试基础设施:CaptureWriter + ANSI strip + snapshot 断言。
//!
//! 用途(tests/README.md L1 单元层):组件渲染时,把输出累到 buffer,然后:
//! - assertContains:断言含某段字节
//! - assertNoAnsi:断言输出无 ANSI(monochrome 主题测试)
//! - stripAnsi:剥 ANSI 后比对纯文本(主题无关测试)
//!
//! 不依赖 std.io.Writer:我们的组件大多返 `[]u8`(allocator-owned),
//! 调用方直接用 expectEqualStrings 即可。CaptureWriter 是给那些"写多段到
//! 同一 buffer"的组件用(如未来的 dialog/permission 增量渲染)。

const std = @import("std");

pub const CaptureWriter = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CaptureWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CaptureWriter) void {
        self.buf.deinit(self.allocator);
    }

    pub fn write(self: *CaptureWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    /// 别名:兼容 anytype writer 接口(ui.render 用 writeAll,std.Io.Writer 同名)。
    pub fn writeAll(self: *CaptureWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *CaptureWriter, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.buf.appendSlice(self.allocator, s);
    }

    pub fn output(self: *const CaptureWriter) []const u8 {
        return self.buf.items;
    }

    pub fn clear(self: *CaptureWriter) void {
        self.buf.clearRetainingCapacity();
    }
};

// ============================================================================
// ANSI 剥离
// ============================================================================

/// 删除字符串中的 ANSI 转义序列(CSI / OSC / DEC private),返回纯文本。
/// caller free。覆盖:
///   ESC [ ... letter  (CSI:颜色 / 光标 / 清屏)
///   ESC 7 / ESC 8     (DECSC/DECRC)
///   ESC ] ... BEL/ST  (OSC:超链接、标题)
pub fn stripAnsi(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b != 0x1b) { // 不是 ESC
            try out.append(alloc, b);
            i += 1;
            continue;
        }
        // ESC ... 处理
        if (i + 1 >= s.len) {
            i += 1;
            continue;
        }
        const next = s[i + 1];
        if (next == '[') {
            // CSI:吃 i,i+1,然后吃参数字符(数字 / ; / ?)直到字母
            i += 2;
            while (i < s.len) {
                const c = s[i];
                i += 1;
                if ((c >= 0x40 and c <= 0x7E)) break; // 终止符:@ A-Z [ \ ] ^ _ ` a-z { | } ~
            }
            continue;
        }
        if (next == ']') {
            // OSC:吃到 BEL(0x07)或 ST(ESC \)
            i += 2;
            while (i < s.len) {
                if (s[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        // ESC 7 / ESC 8 / ESC c 等单字符序列
        i += 2;
    }
    return try out.toOwnedSlice(alloc);
}

// ============================================================================
// 断言 helpers
// ============================================================================

const testing = std.testing;

pub fn expectContains(actual: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, actual, needle) == null) {
        std.debug.print("expectContains failed:\n  actual:   {s}\n  expected to contain: {s}\n", .{ actual, needle });
        return error.TestExpectedContain;
    }
}

pub fn expectNoAnsi(actual: []const u8) !void {
    if (std.mem.indexOfScalar(u8, actual, 0x1b) != null) {
        std.debug.print("expectNoAnsi failed: output contains ESC (0x1b)\n  actual: {s}\n", .{actual});
        return error.TestExpectedNoAnsi;
    }
}

/// 剥 ANSI 后比对(主题无关的内容断言)。
pub fn expectStrippedEquals(alloc: std.mem.Allocator, actual: []const u8, expected_text: []const u8) !void {
    const stripped = try stripAnsi(alloc, actual);
    defer alloc.free(stripped);
    try testing.expectEqualStrings(expected_text, stripped);
}

// ============================================================================
// Tests
// ============================================================================

test "CaptureWriter: write + print + output" {
    var cw = CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    try cw.write("hello ");
    try cw.print("{s} {d}", .{ "world", 42 });
    try testing.expectEqualStrings("hello world 42", cw.output());
    cw.clear();
    try testing.expectEqualStrings("", cw.output());
}

test "stripAnsi: 移除 SGR" {
    const out = try stripAnsi(testing.allocator, "\x1b[31mhello\x1b[0m");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "stripAnsi: 移除多个 CSI" {
    const out = try stripAnsi(testing.allocator, "\x1b[2m\x1b[36maccent\x1b[0m text \x1b[1mB\x1b[0m");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("accent text B", out);
}

test "stripAnsi: 移除光标/清屏" {
    const out = try stripAnsi(testing.allocator, "\x1b[H\x1b[2Jhello\x1b[1;1H");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "stripAnsi: 移除 ESC 7 / ESC 8(DECSC/DECRC)" {
    const out = try stripAnsi(testing.allocator, "\x1b7state\x1b8");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("state", out);
}

test "stripAnsi: 移除 OSC(以 BEL 结束)" {
    // OSC 8 超链接:\x1b]8;;https://x\x07text\x1b]8;;\x07
    const out = try stripAnsi(testing.allocator, "\x1b]8;;https://x\x07text\x1b]8;;\x07");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("text", out);
}

test "expectContains: 正例 / 反例" {
    try expectContains("hello world", "world");
    // 反例:不调,只测正例
}

test "expectNoAnsi: 干净文本通过" {
    try expectNoAnsi("hello world");
}

test "expectStrippedEquals: ANSI 干扰下断言纯文本" {
    try expectStrippedEquals(testing.allocator, "\x1b[2m[\x1b[0msonnet\x1b[2m]\x1b[0m", "[sonnet]");
}
