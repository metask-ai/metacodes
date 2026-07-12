//! ANSI 着色。
const std = @import("std");
const types = @import("types.zig");
const ColoredSpan = types.ColoredSpan;
const TokenType = types.TokenType;
const LangRule = types.LangRule;
const engine = @import("engine.zig");

pub const Palette = struct {
    keyword: []const u8,
    string: []const u8,
    comment: []const u8,
    number: []const u8,
    reset: []const u8,
};

pub const b16 = Palette{
    .keyword = "\x1b[35m",
    .string = "\x1b[32m",
    .comment = "\x1b[2m",
    .number = "\x1b[33m",
    .reset = "\x1b[0m",
};

pub const tc_dark = Palette{
    .keyword = "\x1b[38;2;197;134;192m",
    .string = "\x1b[38;2;206;145;120m",
    .comment = "\x1b[38;2;106;153;85m",
    .number = "\x1b[38;2;181;206;168m",
    .reset = "\x1b[0m",
};

pub fn colorize(allocator: std.mem.Allocator, spans: []const ColoredSpan, palette: Palette) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    var in_color = false;
    var prev: TokenType = .none;
    for (spans) |s| {
        if (s.token != .none) {
            if (!in_color or s.token != prev) {
                if (in_color) try buf.appendSlice(allocator, palette.reset);
                try buf.appendSlice(allocator, switch (s.token) {
                    .keyword => palette.keyword,
                    .string => palette.string,
                    .comment => palette.comment,
                    .number => palette.number,
                    .none => unreachable,
                });
                in_color = true;
            }
            try buf.appendSlice(allocator, s.text);
        } else {
            if (in_color) {
                try buf.appendSlice(allocator, palette.reset);
                in_color = false;
            }
            try buf.appendSlice(allocator, s.text);
        }
        prev = s.token;
    }
    if (in_color) try buf.appendSlice(allocator, palette.reset);
    return buf.toOwnedSlice(allocator);
}

pub fn colorizeSource(allocator: std.mem.Allocator, source: []const u8, rule: *const LangRule, palette: Palette) ![]u8 {
    const spans = try engine.tokenize(allocator, source, rule);
    defer allocator.free(spans);
    return colorize(allocator, spans, palette);
}