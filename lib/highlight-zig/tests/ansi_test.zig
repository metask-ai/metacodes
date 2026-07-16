const std = @import("std");
const hl = @import("hl");
const ColoredSpan = hl.ColoredSpan;
const TokenType = hl.TokenType;
const Palette = hl.Palette;
const colorize = hl.colorize;
const colorizeSource = hl.colorizeSource;

const testing = std.testing;

test "单个 keyword span 着色" {
    const spans = [_]ColoredSpan{
        .{ .text = "fn", .token = .keyword },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.b16);
    defer testing.allocator.free(out);

    // 应包含 magenta 色码 + "fn" + reset
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[35m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fn") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "none span 不着色" {
    const spans = [_]ColoredSpan{
        .{ .text = "plain text", .token = .none },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.b16);
    defer testing.allocator.free(out);

    // 不应有任何 ANSI 转义
    try testing.expect(std.mem.indexOf(u8, out, "\x1b") == null);
    try testing.expectEqualStrings("plain text", out);
}

test "连续同色 span 合并" {
    const spans = [_]ColoredSpan{
        .{ .text = "fn", .token = .keyword },
        .{ .text = " ", .token = .keyword },
        .{ .text = "main", .token = .keyword },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.b16);
    defer testing.allocator.free(out);

    // 只应有一个色码开头和一个 reset 结尾
    const color_count = std.mem.count(u8, out, "\x1b[35m");
    const reset_count = std.mem.count(u8, out, "\x1b[0m");
    try testing.expectEqual(@as(usize, 1), color_count);
    try testing.expectEqual(@as(usize, 1), reset_count);
}

test "不同色 span 切换" {
    const spans = [_]ColoredSpan{
        .{ .text = "fn", .token = .keyword },
        .{ .text = " ", .token = .none },
        .{ .text = "\"hi\"", .token = .string },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.b16);
    defer testing.allocator.free(out);

    // keyword(magenta) + none(无色) + string(green) + reset
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[35m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[32m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "空 span 数组" {
    const out = try colorize(testing.allocator, &.{}, hl.ansi.b16);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "colorizeSource 完整流程" {
    const rule = hl.lookupByName("zig").?;
    const out = try colorizeSource(testing.allocator, "pub fn main() void {}", rule, hl.ansi.b16);
    defer testing.allocator.free(out);

    // 应包含 magenta（pub/fn/main 是 keyword）和 reset
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[35m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "truecolor palette 着色" {
    const spans = [_]ColoredSpan{
        .{ .text = "fn", .token = .keyword },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.tc_dark);
    defer testing.allocator.free(out);

    // truecolor 色码格式 \x1b[38;2;R;G;Bm
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
}

test "comment 用 dim（b16）" {
    const spans = [_]ColoredSpan{
        .{ .text = "// comment", .token = .comment },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.b16);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
}

test "number 用 yellow（b16）" {
    const spans = [_]ColoredSpan{
        .{ .text = "42", .token = .number },
    };
    const out = try colorize(testing.allocator, &spans, hl.ansi.b16);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\x1b[33m") != null);
}