const std = @import("std");

/// 反转义 JSON 字符串中的 `\n \r \t \" \\`，返回 allocator 拥有的新 buffer。
pub fn unescapeString(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, data.len);
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\\' and i + 1 < data.len) {
            i += 1;
            const c: u8 = switch (data[i]) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => data[i],
            };
            try result.append(allocator, c);
        } else {
            try result.append(allocator, data[i]);
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// 序列化字符串为 JSON，追加到 buf。转义 `" \ \n \r \t`。
pub fn serializeString(s: []const u8, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

/// 从 JSON 对象字符串中查找 `"field":"value"` 形式的字符串值。
/// 不反转义返回值（调用方按需调 unescapeString）。
pub fn extractStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    std.debug.assert(field.len < 200);
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..field.len], field);
    pattern_buf[1 + field.len] = '"';
    pattern_buf[2 + field.len] = ':';
    pattern_buf[3 + field.len] = '"';
    const pattern = pattern_buf[0 .. 4 + field.len];

    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    const start = idx + pattern.len;
    var end = start;
    while (end < data.len) : (end += 1) {
        if (data[end] == '"' and data[end - 1] != '\\') break;
    }
    return data[start..end];
}

test "unescapeString basic" {
    const r = try unescapeString("hello\\nworld", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello\nworld", r);
}

test "unescapeString quote" {
    const r = try unescapeString("say \\\"hi\\\"", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("say \"hi\"", r);
}

test "unescapeString backslash" {
    const r = try unescapeString("a\\\\b", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a\\b", r);
}

test "serializeString escapes newline" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString("a\nb", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\\nb\"", buf.items);
}

test "serializeString escapes quote" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString("say \"hi\"", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", buf.items);
}

test "extractStringField basic" {
    const data = "{\"id\":\"abc\",\"name\":\"foo\"}";
    try std.testing.expectEqualStrings("abc", extractStringField(data, "id").?);
    try std.testing.expectEqualStrings("foo", extractStringField(data, "name").?);
}

test "extractStringField missing" {
    try std.testing.expect(extractStringField("{\"a\":1}", "missing") == null);
}

test "unescapeString preserves plain text" {
    const r = try unescapeString("hello", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello", r);
}

test "unescapeString handles tab" {
    const r = try unescapeString("a\\tb", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a\tb", r);
}

test "unescapeString handles empty" {
    const r = try unescapeString("", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "unescapeString handles unknown escape" {
    // 未知转义按原字符输出（非严格 JSON，但对 API 响应够用）
    const r = try unescapeString("a\\xb", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("axb", r);
}

test "serializeString handles tab" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString("a\tb", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\\tb\"", buf.items);
}

test "serializeString handles backslash" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString("a\\b", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\\\\b\"", buf.items);
}

test "serializeString empty string" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString("", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"\"", buf.items);
}
