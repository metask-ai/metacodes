const std = @import("std");

/// 反转义 JSON 字符串中的 `\n \r \t \" \\ \b \f \uXXXX`，返回 allocator 拥有的新 buffer。
///
/// `\uXXXX` 处理：
///   - 4 hex 字符 → u16 code unit
///   - 高代理对（D800..DBFF）后跟低代理对（DC00..DFFF）→ 合成 code point 再编 UTF-8
///   - 裸代理（无配对）→ UTF-8 不合法，输出 U+FFFD replacement char
///   - 格式不合法（非 hex 字符）→ 保留原样字面量（fail-open；调用方 Edit 会再 StringNotFound）
pub fn unescapeString(data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, data.len);
    errdefer result.deinit(allocator);
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] != '\\' or i + 1 >= data.len) {
            try result.append(allocator, data[i]);
            i += 1;
            continue;
        }
        i += 1; // 跳 backslash
        switch (data[i]) {
            '"' => {
                try result.append(allocator, '"');
                i += 1;
            },
            '\\' => {
                try result.append(allocator, '\\');
                i += 1;
            },
            '/' => {
                try result.append(allocator, '/');
                i += 1;
            },
            'b' => {
                try result.append(allocator, 8);
                i += 1;
            },
            'f' => {
                try result.append(allocator, 12);
                i += 1;
            },
            'n' => {
                try result.append(allocator, '\n');
                i += 1;
            },
            'r' => {
                try result.append(allocator, '\r');
                i += 1;
            },
            't' => {
                try result.append(allocator, '\t');
                i += 1;
            },
            'u' => {
                // 需要 4 hex
                if (i + 4 >= data.len) {
                    // 不够 4 位：保留字面 "\u..."
                    try result.append(allocator, '\\');
                    try result.append(allocator, 'u');
                    i += 1;
                    continue;
                }
                const hex1 = parseHex4(data[i + 1 .. i + 5]) orelse {
                    // 非 hex：保留字面
                    try result.append(allocator, '\\');
                    try result.append(allocator, 'u');
                    i += 1;
                    continue;
                };
                i += 5; // 跳 u + 4 hex

                // 高代理：尝试配低代理
                var cp: u21 = hex1;
                if (hex1 >= 0xD800 and hex1 <= 0xDBFF) {
                    if (i + 5 < data.len and data[i] == '\\' and data[i + 1] == 'u') {
                        if (parseHex4(data[i + 2 .. i + 6])) |hex2| {
                            if (hex2 >= 0xDC00 and hex2 <= 0xDFFF) {
                                cp = 0x10000 + (@as(u21, hex1 - 0xD800) << 10) + @as(u21, hex2 - 0xDC00);
                                i += 6;
                            } else {
                                cp = 0xFFFD; // 裸高代理
                            }
                        } else {
                            cp = 0xFFFD;
                        }
                    } else {
                        cp = 0xFFFD;
                    }
                } else if (hex1 >= 0xDC00 and hex1 <= 0xDFFF) {
                    // 裸低代理
                    cp = 0xFFFD;
                }

                // 编码 UTF-8
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch blk: {
                    const replacement = [_]u8{ 0xEF, 0xBF, 0xBD }; // U+FFFD
                    try result.appendSlice(allocator, &replacement);
                    break :blk 0;
                };
                if (utf8_len > 0) try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
            },
            else => {
                // 未知 escape：原样保留（JSON spec 不合法，但 fail-open 更有用）
                try result.append(allocator, data[i]);
                i += 1;
            },
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// 解析 4 个 hex 字符为 u16。任何非 hex 字符返 null。
fn parseHex4(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var v: u16 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const c = s[i];
        const digit: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        v = (v << 4) | digit;
    }
    return v;
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

test "unescapeString \\uXXXX basic ASCII" {
    // A → 'A'
    const r = try unescapeString("\\u0041BC", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("ABC", r);
}

test "unescapeString \\uXXXX BMP Chinese" {
    // 你好 → "你好"（UTF-8: E4 BD A0 E5 A5 BD）
    const r = try unescapeString("\\u4f60\\u597d", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("\xe4\xbd\xa0\xe5\xa5\xbd", r);
    try std.testing.expectEqualStrings("你好", r);
}

test "unescapeString \\uXXXX surrogate pair emoji" {
    // 🎉 = U+1F389；UTF-16 surrogate pair D83C DF89
    // UTF-8: F0 9F 8E 89
    const r = try unescapeString("\\uD83C\\uDF89", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("\xf0\x9f\x8e\x89", r);
    try std.testing.expectEqualStrings("🎉", r);
}

test "unescapeString lone high surrogate becomes replacement" {
    // 裸高代理 → U+FFFD (EF BF BD)
    const r = try unescapeString("\\uD800x", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("\xef\xbf\xbdx", r);
}

test "unescapeString \\b \\f supported" {
    const r = try unescapeString("a\\bb\\fc", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 'a', 8, 'b', 12, 'c' }, r);
}

test "unescapeString \\/ supported" {
    // JSON 允许 \/ 转义（冗余但合法）
    const r = try unescapeString("a\\/b", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a/b", r);
}

test "unescapeString invalid hex keeps literal" {
    // \uZZZZ 不是合法 hex → 保留 \u 字面
    const r = try unescapeString("\\uZZZZ", std.testing.allocator);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("\\uZZZZ", r);
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
