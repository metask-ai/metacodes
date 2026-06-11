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
    // 只匹配到 `"field":`,冒号后允许空白(模型/标准 JSON 序列化器常发 `"k": "v"`)。
    const pattern = pattern_buf[0 .. 3 + field.len];

    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var start = idx + pattern.len;
    // 跳过冒号后的空白(空格 / tab / 换行)。
    while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) : (start += 1) {}
    // 必须是字符串值的开引号。
    if (start >= data.len or data[start] != '"') return null;
    start += 1;
    var end = start;
    while (end < data.len) : (end += 1) {
        if (data[end] == '"' and data[end - 1] != '\\') break;
    }
    return data[start..end];
}

/// 提取顶层字段为**字符串或数字**(返回 raw slice,借 data 内存)。缺失返回 null。
/// `extractStringField` 只认带引号的字符串值;但模型常把"看起来是数字的 id"发成裸数字
/// (实测:TaskCreate 返 id="1" 后,模型调 TaskUpdate 发 `"taskId":1` 而非 `"1"` → 旧版
/// 当作缺字段报 MissingTaskId)。本函数对 id 类字段容错:带引号走字符串(可含转义),裸值
/// 取到下一个 `,`/`}`/空白前的 token(数字/true/false/null 的字面量),供数字 id 用。
/// 注意:字符串分支返回**已去引号但仍含转义**的内层(同 extractStringField),裸值分支返回原样
/// 字面量;调用方按需 unescape。
pub fn extractStringOrNumberField(data: []const u8, field: []const u8) ?[]const u8 {
    var pattern_buf: [256]u8 = undefined;
    std.debug.assert(field.len < 200);
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..field.len], field);
    pattern_buf[1 + field.len] = '"';
    pattern_buf[2 + field.len] = ':';
    const pattern = pattern_buf[0 .. 3 + field.len];

    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var start = idx + pattern.len;
    while (start < data.len and (data[start] == ' ' or data[start] == '\t' or data[start] == '\n' or data[start] == '\r')) : (start += 1) {}
    if (start >= data.len) return null;
    if (data[start] == '"') {
        // 字符串值:沿用 extractStringField 的内层提取(处理转义引号)。
        start += 1;
        var end = start;
        while (end < data.len) : (end += 1) {
            if (data[end] == '"' and data[end - 1] != '\\') break;
        }
        return data[start..end];
    }
    // 裸值(数字 / true / false / null):取到分隔符前的 token。
    var end = start;
    while (end < data.len) : (end += 1) {
        const c = data[end];
        if (c == ',' or c == '}' or c == ']' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
    }
    if (end == start) return null;
    return data[start..end];
}

/// 提取顶层布尔字段 `"field":true|false`(值不带引号)。缺失或非法返回 null。
pub fn extractBoolField(data: []const u8, field: []const u8) ?bool {
    var pattern_buf: [256]u8 = undefined;
    std.debug.assert(field.len < 200);
    pattern_buf[0] = '"';
    @memcpy(pattern_buf[1..][0..field.len], field);
    pattern_buf[1 + field.len] = '"';
    pattern_buf[2 + field.len] = ':';
    const pattern = pattern_buf[0 .. 3 + field.len];

    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var p = idx + pattern.len;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) : (p += 1) {}
    if (std.mem.startsWith(u8, data[p..], "true")) return true;
    if (std.mem.startsWith(u8, data[p..], "false")) return false;
    return null;
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

test "extractStringField tolerates whitespace after colon" {
    // 回归:模型/标准 JSON 序列化器常发 `"key": "value"`(冒号后空格)。
    // 旧实现要求引号紧贴冒号 → Task/Agent/MCP 全部 MissingField。
    const sp = "{\"subject\": \"do x\", \"description\": \"desc\"}";
    try std.testing.expectEqualStrings("do x", extractStringField(sp, "subject").?);
    try std.testing.expectEqualStrings("desc", extractStringField(sp, "description").?);
    // tab / 换行也容忍
    const tab = "{\"k\":\t\"v\"}";
    try std.testing.expectEqualStrings("v", extractStringField(tab, "k").?);
    const nl = "{\n  \"k\":\n  \"v\"\n}";
    try std.testing.expectEqualStrings("v", extractStringField(nl, "k").?);
    // 非字符串值(数字)→ null(本函数只取 string)
    try std.testing.expect(extractStringField("{\"k\": 5}", "k") == null);
}

test "extractStringOrNumberField: string 与裸数字都取" {
    // 字符串值:同 extractStringField。
    try std.testing.expectEqualStrings("abc", extractStringOrNumberField("{\"id\":\"abc\"}", "id").?);
    // 裸数字(真 bug:模型发 "taskId":1)→ 取成 "1"。
    try std.testing.expectEqualStrings("1", extractStringOrNumberField("{\"taskId\":1}", "taskId").?);
    // 数字在中间(后跟 ,)。
    try std.testing.expectEqualStrings("42", extractStringOrNumberField("{\"taskId\":42,\"x\":1}", "taskId").?);
    // 冒号后空白 + 数字。
    try std.testing.expectEqualStrings("7", extractStringOrNumberField("{\"taskId\": 7 }", "taskId").?);
    // 字符串在中间(后跟 ,)。
    try std.testing.expectEqualStrings("整理核心架构", extractStringOrNumberField("{\"taskId\":\"整理核心架构\",\"s\":1}", "taskId").?);
    // 缺字段 → null。
    try std.testing.expect(extractStringOrNumberField("{\"a\":1}", "taskId") == null);
    // 数字 id 是末字段(后跟 })。
    try std.testing.expectEqualStrings("3", extractStringOrNumberField("{\"status\":\"completed\",\"taskId\":3}", "taskId").?);
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
