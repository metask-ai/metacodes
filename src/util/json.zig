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

/// JSON 字符串内容转义核心——仓库唯一实现,别再手搓副本(2026-07-12 已合并 5 份散落
/// 拷贝,其中 3 份+本函数原版共 4 份漏转义控制字符——请求体非法 JSON → API 400 的病根)。
/// 保证输出满足 RFC 8259:`" \` 和 0x00-0x1F 全转义(\n \r \t 用短形式,其余 \u00XX);
/// 非法 UTF-8 序列替换为 U+FFFD——JSON 文档必须是合法 UTF-8,垃圾字节不许污染整个请求体。
/// sink 只需提供 writeAll([]const u8)(*std.Io.Writer 天然满足)。
fn encodeStringInner(s: []const u8, sink: anytype) !void {
    var i: usize = 0;
    var plain_start: usize = 0; // 连续可透传字节段的起点,批量 flush 而非逐字节写
    while (i < s.len) {
        const c = s[i];
        if (c >= 0x20 and c < 0x80 and c != '"' and c != '\\') {
            i += 1;
            continue;
        }
        if (c >= 0x80) {
            const seq_len: ?usize = if (std.unicode.utf8ByteSequenceLength(c)) |l| l else |_| null;
            if (seq_len) |l| {
                if (i + l <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + l])) {
                    i += l; // 合法多字节序列,并入透传段
                    continue;
                }
            }
            // 非法 UTF-8(孤立 continuation/截断/overlong/surrogate):逐字节替换 U+FFFD
            try sink.writeAll(s[plain_start..i]);
            try sink.writeAll("\u{FFFD}");
            i += 1;
            plain_start = i;
            continue;
        }
        try sink.writeAll(s[plain_start..i]);
        switch (c) {
            '"' => try sink.writeAll("\\\""),
            '\\' => try sink.writeAll("\\\\"),
            '\n' => try sink.writeAll("\\n"),
            '\r' => try sink.writeAll("\\r"),
            '\t' => try sink.writeAll("\\t"),
            else => {
                var tmp: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try sink.writeAll(esc);
            },
        }
        i += 1;
        plain_start = i;
    }
    try sink.writeAll(s[plain_start..]);
}

const ListSink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fn writeAll(self: ListSink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

/// 序列化字符串为 JSON(含引号),追加到 buf。转义语义见 encodeStringInner。
pub fn serializeString(s: []const u8, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '"');
    try encodeStringInner(s, ListSink{ .list = buf, .allocator = allocator });
    try buf.append(allocator, '"');
}

/// serializeString 去引号版:只写转义后的字符串内容(调用方自己拼引号/片段)。
pub fn serializeStringContents(s: []const u8, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try encodeStringInner(s, ListSink{ .list = buf, .allocator = allocator });
}

/// serializeString 的 writer 版(含引号)。转义语义见 encodeStringInner。
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try encodeStringInner(s, w);
    try w.writeByte('"');
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

/// 提取 `"field":<digits>` 的非负整数值(裸数字,值不带引号)。缺失/非整数返回 0。
/// 用 indexOf 找首个 `"field":`,故对嵌套子对象里的唯一字段名同样有效(如 OpenAI 的
/// prompt_tokens_details.cached_tokens)。不处理浮点/负数/科学记数——计数类字段都是非负整数。
pub fn extractIntField(data: []const u8, field: []const u8) u64 {
    var pat_buf: [256]u8 = undefined;
    std.debug.assert(field.len < 250);
    pat_buf[0] = '"';
    @memcpy(pat_buf[1..][0..field.len], field);
    pat_buf[1 + field.len] = '"';
    pat_buf[2 + field.len] = ':';
    const pat = pat_buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return 0;
    var i = idx + pat.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {}
    if (i == start) return 0;
    return std.fmt.parseInt(u64, data[start..i], 10) catch 0;
}

test "extractIntField basic + nested + missing" {
    try std.testing.expectEqual(@as(u64, 42), extractIntField("{\"a\":42,\"b\":7}", "a"));
    // 嵌套子对象里的字段
    try std.testing.expectEqual(@as(u64, 99), extractIntField("{\"x\":{\"y\":99}}", "y"));
    // 冒号后空格
    try std.testing.expectEqual(@as(u64, 5), extractIntField("{\"k\": 5}", "k"));
    // 缺失 → 0
    try std.testing.expectEqual(@as(u64, 0), extractIntField("{\"a\":1}", "z"));
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

test "serializeString escapes control chars as \\u00XX" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString("a\x00b\x1bc\x07d", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\\u0000b\\u001bc\\u0007d\"", buf.items);
}

test "serializeString control chars round-trip via unescapeString" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const original = "x\x00\x01\x1f\ny";
    try serializeString(original, &buf, std.testing.allocator);
    const back = try unescapeString(buf.items[1 .. buf.items.len - 1], std.testing.allocator);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(original, back);
}

test "serializeString leaves ascii, utf8 and bare DEL untouched" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    // 0x7f(DEL)不是 printable,但 RFC 8259 只强制转义 <0x20——DEL 裸放是故意的。
    try serializeString("普通文本 ok ~\x7f", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"普通文本 ok ~\x7f\"", buf.items);
}

test "serializeString replaces invalid utf8 with U+FFFD" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    // 孤立 continuation + 截断的 3 字节序列开头 + 合法字节
    try serializeString("a\x80b\xe4\xbdok", &buf, std.testing.allocator);
    try std.testing.expectEqualStrings("\"a\u{FFFD}b\u{FFFD}\u{FFFD}ok\"", buf.items);
}

test "writeJsonString matches serializeString output" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    const input = "mix\x00\"quote\"\\slash 中文\x80tail";
    try serializeString(input, &buf, std.testing.allocator);

    var wbuf: [256]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wbuf);
    try writeJsonString(&fw, input);
    try std.testing.expectEqualStrings(buf.items, fw.buffered());
}

/// differential 裁判:输出必须被 std.json 接受;输出必须是合法 UTF-8;
/// 合法 UTF-8 输入必须逐字节 round-trip;两个公开入口(list/writer)输出必须逐字节一致。
fn diffCheckAgainstStdJson(input: []const u8) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try serializeString(input, &buf, std.testing.allocator);
    const parsed = std.json.parseFromSlice([]const u8, std.testing.allocator, buf.items, .{}) catch |e| {
        std.debug.print("std.json rejected our output: input={x} output={s}\n", .{ input, buf.items });
        return e;
    };
    defer parsed.deinit();
    try std.testing.expect(std.unicode.utf8ValidateSlice(parsed.value));
    if (std.unicode.utf8ValidateSlice(input)) {
        try std.testing.expectEqualSlices(u8, input, parsed.value);
    }
    // writer 入口与 list 入口必须同像素(最坏膨胀 6x + 2 引号,fuzz 输入 ≤ 64 字节)。
    var wbuf: [512]u8 = undefined;
    var fw = std.Io.Writer.fixed(&wbuf);
    try writeJsonString(&fw, input);
    try std.testing.expectEqualStrings(buf.items, fw.buffered());
}

test "serializeString differential vs std.json: all single bytes" {
    var byte: usize = 0;
    while (byte < 256) : (byte += 1) {
        const b = [_]u8{@intCast(byte)};
        try diffCheckAgainstStdJson(&b);
    }
}

test "serializeString differential vs std.json: random byte strings" {
    var prng = std.Random.DefaultPrng.init(0x5eed_cafe);
    const rand = prng.random();
    var iter: usize = 0;
    while (iter < 1000) : (iter += 1) {
        var data: [64]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 0, data.len);
        rand.bytes(data[0..len]);
        try diffCheckAgainstStdJson(data[0..len]);
    }
}

test "serializeString differential vs std.json: adversarial cases" {
    const cases = [_][]const u8{
        "", "\x00", "\"", "\\", "\\u0000", "a\x1f\x7fb",
        "\xed\xa0\x80", // CESU-8 surrogate 编码(非法)
        "\xc0\x80", // overlong NUL(非法)
        "\xf4\x90\x80\x80", // 超出 U+10FFFF(非法)
        "\xf0\x9f\x92\xa9", // 合法 4 字节 emoji
        "结尾截断\xe4\xbd",
    };
    for (cases) |c| try diffCheckAgainstStdJson(c);
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
