const std = @import("std");
const util_json = @import("../util/json.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");
const util_time = @import("../util/time.zig");
const error_class = @import("error_class.zig");

/// Maximum accepted SSE line size. Tool input deltas can legitimately be much
/// larger than the transport reader buffer, but a peer-controlled line must
/// still have a hard bound so a missing newline cannot grow memory forever.
pub const MAX_SSE_LINE_BYTES: usize = 16 * 1024 * 1024;

/// SSE 行解析：提取 `data: ` 之后的 JSON payload；非 data 行返回 null。
pub const SseParser = struct {
    pub fn parseLine(_: *SseParser, line: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, line, " \r\n");
        if (!std.mem.startsWith(u8, trimmed, "data: ")) return null;
        return trimmed[6..];
    }
};

pub const SseEventType = enum {
    message_start,
    content_block_start,
    content_block_delta,
    content_block_stop,
    message_delta,
    message_stop,
    ping,
    error_event,
    unknown,
};

/// 从 SSE data 行的 JSON 字符串中推断事件类型。
///
/// 真正解析 top-level 的 `"type"` 字段——跳过 nested object/array。
/// 原因：不同实现的 Anthropic proxy 返回的字段顺序不同：
///   - 官方：`{"type":"message_start","message":{...}}` —— type 在前
///   - napi 代理：`{"message":{"type":"message",...},"type":"message_start"}` —— type 在后
///   - content_block_start：`{"type":"content_block_start","content_block":{"type":"tool_use"}}` —— nested 同名
/// 用"找第一个"或"找最后一个"都会在某些情况出错，必须做真 depth-aware 解析。
pub fn parseEventType(data: []const u8) SseEventType {
    const type_value = findTopLevelStringField(data, "type") orelse return .unknown;
    if (std.mem.eql(u8, type_value, "message_start")) return .message_start;
    if (std.mem.eql(u8, type_value, "content_block_start")) return .content_block_start;
    if (std.mem.eql(u8, type_value, "content_block_delta")) return .content_block_delta;
    if (std.mem.eql(u8, type_value, "content_block_stop")) return .content_block_stop;
    if (std.mem.eql(u8, type_value, "message_delta")) return .message_delta;
    if (std.mem.eql(u8, type_value, "message_stop")) return .message_stop;
    if (std.mem.eql(u8, type_value, "ping")) return .ping;
    // Anthropic 错误以 data 帧形式到达:{"type":"error","error":{"type":"overloaded_error",...}}
    // 识别为 error_event,由 EventIterator 上抛明确 error(不再静默归 .unknown 跳过)。
    if (std.mem.eql(u8, type_value, "error")) return .error_event;
    return .unknown;
}

/// Return the closing quote for a JSON string whose content starts at
/// `content_start`. A quote closes the string only when preceded by an even
/// run of backslashes; the escaped-state machine implements that parity
/// without repeatedly scanning backwards.
fn jsonStringEnd(data: []const u8, content_start: usize) ?usize {
    var i = content_start;
    var escaped = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return i;
    }
    return null;
}

/// 在 top-level object 中查找指定字段的 string 值。跳过嵌套 object/array 和字符串内部。
/// data 应以 `{` 开头；本函数只查 depth==1 的 key:value。
fn findTopLevelStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    // 跳空白
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;
    i += 1;

    while (i < data.len) {
        // 跳空白 / 逗号
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == ',')) : (i += 1) {}
        if (i >= data.len or data[i] == '}') return null;

        // key：必须是字符串
        if (data[i] != '"') return null;
        i += 1;
        const key_start = i;
        i = jsonStringEnd(data, i) orelse return null;
        const key = data[key_start..i];
        i += 1; // 跳 closing "

        // 跳 : 和空白
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == ':')) : (i += 1) {}
        if (i >= data.len) return null;

        const is_target = std.mem.eql(u8, key, field);

        // value：四种可能——string / object / array / scalar(number/bool/null)
        switch (data[i]) {
            '"' => {
                i += 1;
                const v_start = i;
                i = jsonStringEnd(data, i) orelse return null;
                if (is_target) return data[v_start..i];
                i += 1;
            },
            '{', '[' => {
                if (is_target) return null; // 非 string value
                // 深度配对跳过
                const open = data[i];
                const close: u8 = if (open == '{') '}' else ']';
                var depth: i32 = 0;
                var in_str = false;
                var esc = false;
                while (i < data.len) : (i += 1) {
                    const c = data[i];
                    if (esc) {
                        esc = false;
                        continue;
                    }
                    if (c == '\\') {
                        esc = true;
                        continue;
                    }
                    if (c == '"') {
                        in_str = !in_str;
                        continue;
                    }
                    if (in_str) continue;
                    if (c == open) depth += 1;
                    if (c == close) {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
            },
            else => {
                // scalar：读到 , 或 } 为止
                const v_start = i;
                while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
                if (is_target) return std.mem.trim(u8, data[v_start..i], " \t");
            },
        }
    }
    return null;
}

/// 工具调用的解析结果（id + name + partial input_json 片段）。
pub const ToolUseResult = struct {
    id: []const u8,
    name: []const u8,
    input_json: []const u8,
};

/// 从 content_block_delta 中提取文本增量（反转义后的 owned bytes，caller free）。
pub fn extractTextDelta(data: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    if (parseEventType(data) != .content_block_delta) return null;
    const delta_obj = findTopLevelObjectField(data, "delta") orelse return null;
    // Some older compatible providers omit delta.type. Preserve that accepted
    // shape when a top-level text field exists, while explicitly rejecting
    // typed thinking/input deltas.
    if (findTopLevelStringField(delta_obj, "type")) |delta_type| {
        if (!std.mem.eql(u8, delta_type, "text_delta")) return null;
    }
    const raw_text = findTopLevelStringField(delta_obj, "text") orelse return null;
    return try util_json.unescapeString(raw_text, allocator);
}

/// 从 content_block_delta 中提取 thinking 增量(Anthropic thinking_delta)。
/// 返回反转义后的 owned bytes(caller free)。非 thinking_delta → null。
pub fn extractThinkingDelta(data: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    if (parseEventType(data) != .content_block_delta) return null;
    const delta_obj = findTopLevelObjectField(data, "delta") orelse return null;
    const delta_type = findTopLevelStringField(delta_obj, "type") orelse return null;
    if (!std.mem.eql(u8, delta_type, "thinking_delta")) return null;
    const raw = findTopLevelStringField(delta_obj, "thinking") orelse return null;
    return try util_json.unescapeString(raw, allocator);
}

/// 从 content_block_delta 中提取 tool_use 的 input_json_delta.partial_json 片段。
/// partial_json 是 JSON 字符串内部的原始转义形态（可能半个 key / 半个 value）；返回
/// 借 data 的 slice（不 allocate，不 unescape）；调用方累加到 buffer 最后再一起反转义/解析。
pub fn extractInputJsonDelta(data: []const u8) ?[]const u8 {
    if (parseEventType(data) != .content_block_delta) return null;
    const delta_obj = findTopLevelObjectField(data, "delta") orelse return null;
    const delta_type = findTopLevelStringField(delta_obj, "type") orelse return null;
    if (!std.mem.eql(u8, delta_type, "input_json_delta")) return null;
    return findTopLevelStringField(delta_obj, "partial_json");
}
///
/// 真解析：先用 `findTopLevelObjectField` 拿 outer 的 `content_block` 对象（不依赖字段顺序），
/// 再在其中查 type/id/name/input。这样 napi 代理之类字段乱序的返回也能 parse。
pub fn extractToolUse(data: []const u8) ?ToolUseResult {
    if (parseEventType(data) != .content_block_start) return null;

    const block = findTopLevelObjectField(data, "content_block") orelse return null;

    // content_block.type 必须是 "tool_use"
    const block_type = findTopLevelStringField(block, "type") orelse return null;
    if (!std.mem.eql(u8, block_type, "tool_use")) return null;

    const id = findTopLevelStringField(block, "id") orelse return null;
    const name = findTopLevelStringField(block, "name") orelse return null;

    // input 是 object（初始通常空 {}，真实参数通过后续 input_json_delta 累加）。
    // 这里返回的是 content_block 内的 `input` object 片段；消费方通过
    // input_json_delta 事件拼出真正的参数 JSON。
    const input_json = findTopLevelObjectFieldRaw(block, "input") orelse "{}";

    return ToolUseResult{ .id = id, .name = name, .input_json = input_json };
}

/// 服务端工具调用（web_search 等）的初始块。Anthropic 的 server tool 由 API 侧执行，
/// 我们只需把"模型发起搜索"这件事让本地知道——比如让 transcript / UI 显示。
/// 区别于 tool_use：server_tool_use 的 input 在 content_block_start 就已完整（无 input_json_delta）。
pub const ServerToolUseInfo = struct { name: []const u8, query: []const u8 };

pub fn extractServerToolUse(data: []const u8) ?ServerToolUseInfo {
    if (parseEventType(data) != .content_block_start) return null;
    const block = findTopLevelObjectField(data, "content_block") orelse return null;
    const block_type = findTopLevelStringField(block, "type") orelse return null;
    if (!std.mem.eql(u8, block_type, "server_tool_use")) return null;
    const name = findTopLevelStringField(block, "name") orelse return null;
    const input = findTopLevelObjectFieldRaw(block, "input") orelse "{}";
    const query = findTopLevelStringField(input, "query") orelse "";
    return .{ .name = name, .query = query };
}

/// 服务端工具结果块（web_search_tool_result）。content 是结果数组。
/// 返回 raw content array 字符串(借用 data)；调用方按需解析 title/url。
pub const ServerToolResultInfo = struct { content_array_raw: []const u8 };

pub fn extractServerToolResult(data: []const u8) ?ServerToolResultInfo {
    if (parseEventType(data) != .content_block_start) return null;
    const block = findTopLevelObjectField(data, "content_block") orelse return null;
    const block_type = findTopLevelStringField(block, "type") orelse return null;
    if (!std.mem.eql(u8, block_type, "web_search_tool_result")) return null;
    // content 可能是 array 或 error object；我们只处理 array 形态
    const arr = findTopLevelArrayFieldRaw(block, "content") orelse return null;
    return .{ .content_array_raw = arr };
}

/// 把 web_search_tool_result 的 content 数组渲染成可读多行文本。
/// 输入是 `[{"type":"web_search_result","title":"...","url":"..."}, ...]`。
/// 返回 owned text 形如 `\n[Web search: 3 results]\n  • Title — https://...\n...`。
/// 不严格 parse JSON——按字段名 scan,容错性优先。
pub fn renderWebSearchResults(allocator: std.mem.Allocator, content_array: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var count: usize = 0;

    // 遍历数组里的每个 object。findTopLevelObjectFieldRaw 不适用（不是 object）；
    // 用简单状态机找每个 top-level {...}。
    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    var obj_start: ?usize = null;
    var i: usize = 0;
    var items_buf: std.ArrayList(u8) = .empty;
    defer items_buf.deinit(allocator);

    while (i < content_array.len) : (i += 1) {
        const c = content_array[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (in_str) continue;
        if (c == '{') {
            if (depth == 0) obj_start = i;
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                const obj = content_array[obj_start.? .. i + 1];
                const title = findTopLevelStringField(obj, "title") orelse "(no title)";
                const url = findTopLevelStringField(obj, "url") orelse "(no url)";
                var line_buf: [2048]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "  - {s} — {s}\n", .{ title, url }) catch "  - (line too long)\n";
                try items_buf.appendSlice(allocator, line);
                count += 1;
                obj_start = null;
            }
        }
    }

    // count==0:后端(代理)只把结果喂给模型、不透传原始数组(content:[])——此时
    // 渲染 "0 results" 是误导(实际有结果,模型据此作答)。直接返回空,不打噪音行。
    if (count == 0) return try allocator.dupe(u8, "");

    try out.writer.print("\n[Web search: {d} result{s}]\n", .{ count, if (count == 1) @as([]const u8, "") else @as([]const u8, "s") });
    try out.writer.writeAll(items_buf.items);
    return try out.toOwnedSlice();
}

/// 同 findTopLevelObjectFieldRaw 但找 array `[...]`。
fn findTopLevelArrayFieldRaw(data: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;
    i += 1;
    while (i < data.len) {
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == ',')) : (i += 1) {}
        if (i >= data.len or data[i] == '}') return null;
        if (data[i] != '"') return null;
        i += 1;
        const k_start = i;
        i = jsonStringEnd(data, i) orelse return null;
        const k = data[k_start..i];
        i += 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == ':' or data[i] == '\n')) : (i += 1) {}
        if (i >= data.len) return null;
        const match = std.mem.eql(u8, k, field);
        if (data[i] == '[' and match) {
            // 找匹配的 ]
            const start = i;
            var depth: i32 = 0;
            var in_str = false;
            var escaped = false;
            while (i < data.len) : (i += 1) {
                const c = data[i];
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (c == '\\') {
                    escaped = true;
                    continue;
                }
                if (c == '"') {
                    in_str = !in_str;
                    continue;
                }
                if (in_str) continue;
                if (c == '[') depth += 1;
                if (c == ']') {
                    depth -= 1;
                    if (depth == 0) return data[start .. i + 1];
                }
            }
            return null;
        }
        // skip value（字符串 / 对象 / 数组 / 字面量）
        i = skipJsonValue(data, i);
    }
    return null;
}

fn skipJsonValue(data: []const u8, start: usize) usize {
    var i = start;
    if (i >= data.len) return i;
    const c = data[i];
    if (c == '"') {
        i += 1;
        const end = jsonStringEnd(data, i) orelse return data.len;
        return end + 1;
    }
    if (c == '{' or c == '[') {
        const open = c;
        const close: u8 = if (open == '{') '}' else ']';
        var depth: i32 = 1;
        i += 1;
        var in_str = false;
        var escaped = false;
        while (i < data.len and depth > 0) : (i += 1) {
            const ch = data[i];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (ch == '\\') {
                escaped = true;
                continue;
            }
            if (ch == '"') {
                in_str = !in_str;
                continue;
            }
            if (in_str) continue;
            if (ch == open) depth += 1;
            if (ch == close) depth -= 1;
        }
        return i;
    }
    // literal / number
    while (i < data.len and data[i] != ',' and data[i] != '}' and data[i] != ']') : (i += 1) {}
    return i;
}

/// 找 top-level 字段的 object value，返回完整 `{...}` 片段（借 data）；非 object 返 null。
fn findTopLevelObjectField(data: []const u8, field: []const u8) ?[]const u8 {
    return findTopLevelObjectFieldRaw(data, field);
}

fn findTopLevelObjectFieldRaw(data: []const u8, field: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n')) : (i += 1) {}
    if (i >= data.len or data[i] != '{') return null;
    i += 1;

    while (i < data.len) {
        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == ',')) : (i += 1) {}
        if (i >= data.len or data[i] == '}') return null;

        if (data[i] != '"') return null;
        i += 1;
        const key_start = i;
        i = jsonStringEnd(data, i) orelse return null;
        const key = data[key_start..i];
        i += 1;

        while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == ':')) : (i += 1) {}
        if (i >= data.len) return null;

        const is_target = std.mem.eql(u8, key, field);

        switch (data[i]) {
            '{', '[' => {
                const open = data[i];
                const close: u8 = if (open == '{') '}' else ']';
                const v_start = i;
                var depth: i32 = 0;
                var in_str = false;
                var esc = false;
                while (i < data.len) : (i += 1) {
                    const c = data[i];
                    if (esc) {
                        esc = false;
                        continue;
                    }
                    if (c == '\\') {
                        esc = true;
                        continue;
                    }
                    if (c == '"') {
                        in_str = !in_str;
                        continue;
                    }
                    if (in_str) continue;
                    if (c == open) depth += 1;
                    if (c == close) {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
                if (is_target) return data[v_start..i];
            },
            '"' => {
                // 不匹配（本函数只返回 object/array 值）——跳过这个 string
                i += 1;
                i = (jsonStringEnd(data, i) orelse return null) + 1;
            },
            else => {
                // scalar — 跳
                while (i < data.len and data[i] != ',' and data[i] != '}') : (i += 1) {}
            },
        }
    }
    return null;
}

test "SseParser.parseLine valid" {
    var p = SseParser{};
    try std.testing.expectEqualStrings("{}", p.parseLine("data: {}").?);
    try std.testing.expectEqualStrings("{\"x\":1}", p.parseLine("data: {\"x\":1}").?);
}

test "SseParser.parseLine non-data returns null" {
    var p = SseParser{};
    try std.testing.expect(p.parseLine("event: foo") == null);
    try std.testing.expect(p.parseLine("not data") == null);
}

test "SseParser.parseLine empty data returns null" {
    var p = SseParser{};
    try std.testing.expect(p.parseLine("data: ") == null);
}

test "parseEventType message_start" {
    try std.testing.expect(parseEventType("{\"type\":\"message_start\"}") == .message_start);
}

test "parseEventType content_block_delta" {
    try std.testing.expect(parseEventType("{\"type\":\"content_block_delta\",\"text\":\"hi\"}") == .content_block_delta);
}

test "parseEventType ping" {
    try std.testing.expect(parseEventType("{\"type\":\"ping\"}") == .ping);
}

test "parseEventType unknown" {
    try std.testing.expect(parseEventType("{\"type\":\"foo\"}") == .unknown);
}

test "extractTextDelta basic" {
    const data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}";
    const r = (try extractTextDelta(data, std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello", r);
}

test "extractTextDelta with escape" {
    const data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"a\\nb\"}}";
    const r = (try extractTextDelta(data, std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a\nb", r);
}

test "JSON string scanner handles backslash parity and escaped quotes" {
    const cases = [_]struct { encoded: []const u8, expected: []const u8 }{
        .{
            .encoded =
            \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"tail\\"}}
            ,
            .expected = "tail\\",
        },
        .{
            .encoded =
            \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"tail\\\\"}}
            ,
            .expected = "tail\\\\",
        },
        .{
            .encoded =
            \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"C:\\temp\\"}}
            ,
            .expected = "C:\\temp\\",
        },
        .{
            .encoded =
            \\{"type":"content_block_delta","delta":{"type":"text_delta","text":"say \"hi\""}}
            ,
            .expected = "say \"hi\"",
        },
    };
    for (cases) |case| {
        const actual = (try extractTextDelta(case.encoded, std.testing.allocator)).?;
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "input_json_delta chunk may end with a backslash" {
    const data =
        \\{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"tail\\"}}
    ;
    try std.testing.expectEqualStrings("tail\\\\", extractInputJsonDelta(data).?);
}

test "extractTextDelta accepts proxy whitespace and reordered fields" {
    const data = "{\"delta\": {\"text\": \"proxy text\", \"type\": \"text_delta\"}, \"index\": 2, \"type\": \"content_block_delta\"}";
    const r = (try extractTextDelta(data, std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("proxy text", r);
}

test "extractTextDelta rejects thinking_delta" {
    const data = "{\"type\": \"content_block_delta\", \"delta\": {\"type\": \"thinking_delta\", \"thinking\": \"secret\"}}";
    try std.testing.expect(try extractTextDelta(data, std.testing.allocator) == null);
}

test "extractTextDelta no delta returns null" {
    try std.testing.expect(try extractTextDelta("{\"type\":\"message_stop\"}", std.testing.allocator) == null);
}

test "extractToolUse basic" {
    const data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"bash\",\"input\":{\"cmd\":\"ls\"}}}";
    const tu = extractToolUse(data).?;
    try std.testing.expectEqualStrings("tool_1", tu.id);
    try std.testing.expectEqualStrings("bash", tu.name);
}

test "extractToolUse non-tool-use returns null" {
    try std.testing.expect(extractToolUse("{\"type\":\"message_start\"}") == null);
}

test "SseParser handles multiple data lines" {
    var p = SseParser{};
    try std.testing.expectEqualStrings("{\"a\":1}", p.parseLine("data: {\"a\":1}\n").?);
    try std.testing.expectEqualStrings("{\"b\":2}", p.parseLine("data: {\"b\":2}").?);
}

test "parseEventType with multi-field JSON (outer type first)" {
    // Anthropic SSE: outer type 在 object 开头
    try std.testing.expect(parseEventType("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"text\":\"hi\"}}") == .content_block_delta);
}

test "parseEventType content_block_start with nested tool_use" {
    // 嵌套 content_block.type=tool_use 不应影响外层事件类型识别
    try std.testing.expect(parseEventType("{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\"}}") == .content_block_start);
}

test "parseEventType message_start with nested message.type (outer at end)" {
    // napi 代理返回：outer type 在末尾，nested message.type 在前
    const data = "{\"message\":{\"content\":[],\"id\":\"x\",\"model\":\"y\",\"role\":\"assistant\",\"type\":\"message\"},\"type\":\"message_start\"}";
    try std.testing.expect(parseEventType(data) == .message_start);
}

test "parseEventType content_block_delta with nested delta.type" {
    // content_block_delta 的 delta 对象里 type=text_delta 不应干扰
    const data = "{\"delta\":{\"text\":\"hi\",\"type\":\"text_delta\"},\"index\":0,\"type\":\"content_block_delta\"}";
    try std.testing.expect(parseEventType(data) == .content_block_delta);
}

test "parseEventType official-style content_block_delta (outer at front)" {
    const data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}";
    try std.testing.expect(parseEventType(data) == .content_block_delta);
}

test "parseEventType on malformed JSON returns unknown" {
    try std.testing.expect(parseEventType("garbage") == .unknown);
    try std.testing.expect(parseEventType("{}") == .unknown);
}

test "extractTextDelta on empty text" {
    const data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"\"}}";
    const r = (try extractTextDelta(data, std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "extractToolUse preserves input JSON structure" {
    const data = "{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\",\"timeout\":100}}}";
    const tu = extractToolUse(data).?;
    try std.testing.expectEqualStrings("t1", tu.id);
    try std.testing.expectEqualStrings("Bash", tu.name);
    try std.testing.expect(std.mem.indexOf(u8, tu.input_json, "\"command\"") != null);
}

// ============================================================================
// EventIterator — 真流式 SSE 事件解析器（M1.3）
//
// 基于 std.Io.Reader.takeDelimiter('\n') 逐行消费，不需要手工 line buffer。
// 每次 next() 检查 abort；遇到 message_stop 或 EOF 返回 null。
//
// 调用方负责 Event.deinit 释放 text_delta 之类的分配结果。
// ============================================================================

pub const Event = union(enum) {
    /// 来自 content_block_delta 的文本增量；owned bytes（caller free）
    text_delta: []u8,
    /// 来自 content_block_delta 的思考增量(Anthropic thinking_delta);owned bytes(caller free)
    thinking_delta: []u8,
    /// 来自 content_block_start 的工具调用初始信息；内部字段借用自 reader buffer
    /// —— 调用方若要跨 next() 保留，必须 dupe
    tool_use_start: ToolUseResult,
    /// web_search_tool_result 块(server tool 两阶段的第二段)。
    /// - ui_text:`⏺ Web Search(...) ⎿ Did 1 search` UI 装饰(主对话直接打印,对齐 cc TUI)。
    /// - content_json:web_search_tool_result 的原始 content 数组(title/url);
    ///   子请求(web_search.zig)据此做结构化解析。注:metask 后端常 `[]`(不透传)。
    /// 两字段都 owned，caller free。
    web_search_result: WebSearchResultEvent,
    /// web_search 的 server_tool_use 阶段:query 解析完成(对齐 cc query_update)。
    /// 子请求(web_search.zig)据此 reportProgress(.query_update) 刷新 TUI 第二行
    /// `Searching: <query>`。owned,caller free。
    web_search_query: []u8,
    /// 用量统计（来自 message_start 或 message_delta 的 usage 字段）；数值不拥有资源
    usage: UsageDelta,
    /// 结束信号
    done: void,

    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .text_delta, .thinking_delta => |b| allocator.free(b),
            .tool_use_start => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input_json);
            },
            .web_search_result => |w| {
                allocator.free(w.ui_text);
                allocator.free(w.content_json);
            },
            .web_search_query => |q| allocator.free(q),
            .usage, .done => {},
        }
    }
};

pub const WebSearchResultEvent = struct {
    ui_text: []u8, // owned
    content_json: []u8, // owned(原始 content 数组字符串,可能为 "[]")
};

pub const UsageDelta = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

/// 从 usage object JSON（`{"input_tokens":N,"output_tokens":M,...}`）提数值。
/// 容错：字段缺失返 0；字段存在但非整数返 0。
fn parseUsageDelta(obj: []const u8) UsageDelta {
    return .{
        .input_tokens = parseIntField(obj, "input_tokens"),
        .output_tokens = parseIntField(obj, "output_tokens"),
        .cache_read_input_tokens = parseIntField(obj, "cache_read_input_tokens"),
        .cache_creation_input_tokens = parseIntField(obj, "cache_creation_input_tokens"),
    };
}

/// 从 object string 里抽 `"field":<digits>` 的整数值。委托给 util_json.extractIntField
/// (单一真相源,见 util/json.zig);此处保留薄包装供本文件 parseUsageDelta 调用。
fn parseIntField(obj: []const u8, field: []const u8) u64 {
    return util_json.extractIntField(obj, field);
}

/// API 报告的 stop_reason(message_delta.delta.stop_reason)。
pub const StopReason = enum {
    unknown,
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    pause_turn,
    refusal,

    pub fn fromStr(s: []const u8) StopReason {
        if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
        if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
        if (std.mem.eql(u8, s, "pause_turn")) return .pause_turn;
        if (std.mem.eql(u8, s, "refusal")) return .refusal;
        return .unknown;
    }
};

// ── 中立流式响应契约(多 Provider 重构)──────────────────────────────────────
// 这些类型从 client.zig 下沉到中立层(api/stream.zig),让 provider.zig 只 import 本文件
// (叶子,无循环依赖)即可定义非 generic 的 Provider 接口。client.zig re-export 它们保持兼容。

/// 流式事件(provider 无关)。各 provider 的解析路径把自家 SSE 翻译成它。
/// 注:与内部 Event 同形,差别仅 text 字段名(StreamResponse.next 做 text_delta→text 映射)。
pub const StreamEvent = union(enum) {
    text: []u8,
    /// 思考过程内容(Anthropic thinking_delta / OpenAI reasoning_content)。
    /// 与 text 分离:不混入最终回答,UI 可折叠显示;多轮 preserved thinking 回传需要它。
    thinking: []u8,
    tool_use_start: ToolUseResult,
    web_search_result: WebSearchResultEvent,
    web_search_query: []u8,
    /// Provider 私有的推理续传项(issue #23):OpenAI Responses 的 `reasoning`
    /// output item,原样 JSON。**不是可展示文本**——消费者只负责按序存进
    /// assistant 消息,供下一次同模型请求逐字节回传。owned,消费者释放。
    reasoning_item: []u8,
    usage: UsageDelta,
    done: void,
};

/// 非流式响应(provider 无关)。
pub const ToolCallResult = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    input: []const u8 = "",
};
pub const ApiResponse = struct {
    content: []const u8 = "",
    stop_reason: ?[]const u8 = null,
    tool_calls: []const ToolCallResult = &.{},
};

/// 中立的流式响应句柄(type-erased vtable)。Provider.sendStream 返回它——接口里**不出现**
/// 任何 provider 具体类型,故 Provider 无需 generic、无循环依赖。各 provider 的具体 StreamResponse
/// (Anthropic 的 EventIterator / 未来 OpenAI 的解析器)各自实现 handle()→StreamHandle。
///
/// **借用契约**:handle 的 ctx 借用底层 StreamResponse;底层必须比 handle 活得久(同步消费)。
pub const StreamHandle = struct {
    ctx: *anyopaque,
    /// 本次请求里以**占位文本**发出(模型看不到图)的图像 tool_result 的 tool_use_id——
    /// 序列化器的实际报告,由具体客户端在序列化的同一时刻填写,agent_loop 的送达水位只认它,
    /// 绝不事后重算能力(运行时方言覆盖、并发 setModel、按 MIME 部分拒绝都只有序列化器知道)。
    /// null = 不知道(测试桩/未接线的包装器)→ 所有配对图片按未送达保守处理;空切片 = 全部
    /// 原生发出。切片由流对象拥有、随其 deinit 释放;元素借用请求消息里的 id 字节,只在
    /// agent_loop 紧接请求之后做送达判断时读取。
    image_placeholder_ids: ?[]const []const u8 = null,
    nextFn: *const fn (ctx: *anyopaque) anyerror!?StreamEvent,
    deinitFn: *const fn (ctx: *anyopaque) void,
    stopReasonFn: *const fn (ctx: *anyopaque) StopReason,
    /// 本次请求的 RequestId(日志串联用)。**契约:每个 provider 实现必须在建连时生成一个有效
    /// RequestId 并经此暴露**——不可返回未初始化值(否则跨 provider 日志串联静默错乱)。
    requestIdFn: *const fn (ctx: *anyopaque) @import("../util/log.zig").RequestId,

    pub inline fn next(self: StreamHandle) anyerror!?StreamEvent {
        return self.nextFn(self.ctx);
    }
    pub inline fn deinit(self: StreamHandle) void {
        self.deinitFn(self.ctx);
    }
    pub inline fn stopReason(self: StreamHandle) StopReason {
        return self.stopReasonFn(self.ctx);
    }
    pub inline fn requestId(self: StreamHandle) @import("../util/log.zig").RequestId {
        return self.requestIdFn(self.ctx);
    }
};

/// Provider-neutral connect-retry boundary. Failure is reported immediately,
/// while the next intent is committed only after the delay and immediately
/// before the next physical request.
pub const RetryReporter = struct {
    state: *anyopaque,
    failedFn: *const fn (state: *anyopaque, attempt: u32, max: u32, delay_ms: u64) bool,
    beforeAttemptFn: *const fn (state: *anyopaque, attempt: u32, max: u32) bool,

    pub fn failed(self: RetryReporter, attempt: u32, max: u32, delay_ms: u64) bool {
        return self.failedFn(self.state, attempt, max, delay_ms);
    }

    pub fn beforeAttempt(self: RetryReporter, attempt: u32, max: u32) bool {
        return self.beforeAttemptFn(self.state, attempt, max);
    }
};

pub const EventIterator = struct {
    reader: *std.Io.Reader,
    abort: ?*const AbortSignal = null,
    done_flag: bool = false,
    /// 本次 SSE 流对应的 request_id（client 层设置）。用来把 stream 事件日志和
    /// 更上游的 HTTP 请求/下游 agent turn 串起来。未设置时日志无 id 上下文。
    req_id: ?log.RequestId = null,
    /// 最后一次 message_delta 报告的 stop_reason(枚举化,避免 owned 字符串)。
    /// agent_loop drain 完后读它判断是否 max_tokens 续写。
    last_stop_reason: StopReason = .unknown,

    /// 跨多个 SSE 事件累加的 tool_use 状态。
    /// `content_block_start`(tool_use) 时填入 id/name，input_buf 清空。
    /// 后续 `content_block_delta`(input_json_delta) 持续 append partial_json 到 input_buf。
    /// `content_block_stop` 时整体 emit 为 `.tool_use_start`（带完整 input_json）并清空。
    pending_tool: ?PendingTool = null,

    /// 单行 SSE 超出 reader buffer(8KB)时的溢出累积缓冲。
    /// 正常短行走 takeDelimiter 快路径,不碰这里;只有大 input_json_delta(写大文件
    /// 时模型把整块 JSON 作为一条 >8KB 的 data 行推送)才走 streamDelimiterEnding 累积到此。
    /// 复用同一 ArrayList,每次清空再用;deinit 时释放。修复 StreamTooLong bug。
    line_overflow: std.ArrayList(u8) = .empty,

    /// web_search per-search 渲染状态(对齐 cc 真实表现:每次搜索两行一组)。
    /// cc 真实输出形如:
    ///   ⏺ Web Search("<query>")
    ///     ⎿  Did 1 search in 20s
    /// 每个 server_tool_use(web_search)→ web_search_tool_result 是一次搜索,独立成组(不累计)。
    /// query 来自 input_json_delta(content_block_start 的 query 是占位符);本代理后端 query
    /// 也是占位符,但用户要求照 cc 格式显示(即便占位)。
    ws_start_ms: ?i64 = null, // 本次搜索开始时间(server_tool_use 时记)
    ws_query: std.ArrayList(u8) = .empty, // 本次搜索 query(input_json_delta 累积,provider 给的常是占位符)
    ws_in_server_tool: bool = false, // 当前在 web_search server_tool_use 块内(delta 路由到 ws_query)
    /// 本轮用户原始输入(borrowed)。对齐 mecode web_search.rs:provider 返回的 query 常被
    /// 改写成占位符("web search"/"searching the web"),**优先显示用户原始输入**,
    /// 仅当无用户输入时回退到 provider query。client 层经 setUserQuery 注入。
    ws_user_query: []const u8 = "",

    const PendingTool = struct {
        id: []u8, // owned by iterator's allocator (从 next() 传入)
        name: []u8,
        input_buf: std.ArrayList(u8),
    };

    /// 构造：仅引用 reader 和 abort，不拥有。
    pub fn init(reader: *std.Io.Reader) EventIterator {
        return .{ .reader = reader };
    }

    pub fn initWithAbort(reader: *std.Io.Reader, abort: *const AbortSignal) EventIterator {
        return .{ .reader = reader, .abort = abort };
    }

    /// 绑定 request_id，让后续所有 event 日志带上同一 id。
    pub fn setRequestId(self: *EventIterator, id: log.RequestId) void {
        self.req_id = id;
    }

    /// 注入本轮用户原始输入(borrowed),供 web_search 显示真实 query(对齐 mecode)。
    pub fn setUserQuery(self: *EventIterator, q: []const u8) void {
        self.ws_user_query = q;
    }

    /// 清理未 emit 的 pending_tool（通常在 error 或提前 drop 时调用）。
    /// 正常流程下 content_block_stop 已经消费掉 pending，无需手动 deinit。
    pub fn deinit(self: *EventIterator, allocator: std.mem.Allocator) void {
        if (self.pending_tool) |*pt| {
            allocator.free(pt.id);
            allocator.free(pt.name);
            pt.input_buf.deinit(allocator);
            self.pending_tool = null;
        }
        self.line_overflow.deinit(allocator);
        self.ws_query.deinit(allocator);
    }

    /// UTF-8 安全截断:超过 max 字节则截到 max 内最后一个完整 codepoint + "…"。
    fn truncateUtf8(s: []const u8, max: usize) []const u8 {
        if (s.len <= max) return s;
        var end = max;
        // 回退到 UTF-8 起始字节(非 0b10xxxxxx 续接字节)。
        while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
        return s[0..end];
    }

    /// 一次 web_search 的两行组(对齐 cc):
    ///   ⏺ Web Search("<query>")
    ///     ⎿  Did 1 search in Xs
    /// 在 web_search_tool_result 时调用(本次搜索结束)。owned text,caller free。
    fn webSearchGroup(self: *EventIterator, allocator: std.mem.Allocator) ![]u8 {
        const dur_ms: i64 = if (self.ws_start_ms) |s| @max(0, util_time.nowMs() - s) else 0;
        const time_str = if (dur_ms >= 1000)
            try std.fmt.allocPrint(allocator, "{d}s", .{@divTrunc(dur_ms + 500, 1000)})
        else
            try std.fmt.allocPrint(allocator, "{d}ms", .{dur_ms});
        defer allocator.free(time_str);
        // query 显示(对齐 mecode web_search.rs):优先用户原始输入(provider 的 query 常是
        // 占位符 "web search"/"searching the web");用户输入为空才回退 provider query。
        const provider_q = util_json.extractStringField(self.ws_query.items, "query") orelse "";
        const raw_q: []const u8 = if (self.ws_user_query.len > 0) self.ws_user_query else provider_q;
        // 截断显示(过长 query 折行难看);按字节 60,UTF-8 边界对齐避免切半个字。
        const q = truncateUtf8(raw_q, 60);
        return try std.fmt.allocPrint(allocator, "\n⏺ Web Search(\"{s}\")\n  ⎿  Did 1 search in {s}\n", .{ q, time_str });
    }

    /// 读一行(到 '\n',不含)。
    /// 快路径:reader.takeDelimiter 直接借 reader buffer 里的 slice(短行,无分配)。
    /// 慢路径:行超出 reader buffer(8KB)→ takeDelimiter 报 StreamTooLong,改用
    ///   streamDelimiterLimit 把整行累积到 line_overflow,并在读取过程中执行硬上限。
    /// 返回借用 slice(指向 reader buffer 或 self.line_overflow);null = EOF。
    /// 修复:大 input_json_delta(写大文件)曾因 8KB 上限直接 StreamTooLong→RequestFailed。
    fn takeLine(self: *EventIterator, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.reader.takeDelimiter('\n')) |line_opt| {
            if (line_opt) |line| {
                if (line.len > MAX_SSE_LINE_BYTES) return error.StreamTooLong;
            }
            return line_opt; // 含 EOF→null 的快路径
        } else |err| switch (err) {
            error.StreamTooLong => {
                // 慢路径:行比 reader buffer 长。limit 取 max+1，允许恰好 max
                // 字节后紧跟分隔符，同时保证无分隔符的恶意流最多只累积 max+1。
                self.line_overflow.clearRetainingCapacity();
                var alloc_w: std.Io.Writer.Allocating = .fromArrayList(allocator, &self.line_overflow);
                const line_len = self.reader.streamDelimiterLimit(
                    &alloc_w.writer,
                    '\n',
                    .limited(MAX_SSE_LINE_BYTES + 1),
                ) catch |e| {
                    self.line_overflow = alloc_w.toArrayList();
                    self.logWarn("streamDelimiterLimit failed: {s}", .{@errorName(e)});
                    return switch (e) {
                        error.StreamTooLong => error.StreamTooLong,
                        error.ReadFailed => error.ReadFailed,
                        // Allocating.writer reports allocation failure through
                        // Writer.Error; restore the ArrayList above, then expose
                        // the actionable allocator error to the caller.
                        error.WriteFailed => error.OutOfMemory,
                    };
                };
                // streamDelimiterEnding 停在分隔符处(buffer 首字节是 '\n')或 EOF(buffer 空)。
                // 若还有分隔符,吞掉它,让下次从下一行开始。
                if (self.reader.bufferedLen() > 0) self.reader.toss(1);
                self.line_overflow = alloc_w.toArrayList(); // 取回所有权
                if (line_len > MAX_SSE_LINE_BYTES) return error.StreamTooLong;
                return self.line_overflow.items;
            },
            else => return err,
        }
    }

    /// 读到下一个有语义的事件。跳过 ping / unknown / 空行 / 非 data 行。
    /// 遇到 message_stop 返回 .done（同时标记 done_flag）。之后所有调用返回 null。
    pub fn next(self: *EventIterator, allocator: std.mem.Allocator) !?Event {
        if (self.done_flag) return null;
        if (self.abort) |a| try a.throwIfAborted();

        var parser = SseParser{};
        while (true) {
            if (self.abort) |a| try a.throwIfAborted();

            const line_opt = self.takeLine(allocator) catch |err| {
                // A read/limit failure can leave the transport positioned in
                // the middle of a line. Make the iterator terminal so callers
                // cannot accidentally parse the suffix as a fresh SSE frame.
                self.done_flag = true;
                self.logWarn("takeLine failed: {s}", .{@errorName(err)});
                return err;
            };
            const line = line_opt orelse {
                self.logDebug("EOF reached (no message_stop before EOF)", .{});
                @import("../core/recorder.zig").finishSse();
                self.done_flag = true;
                return null;
            };

            // record/replay(Stage 7):录原始 SSE 行(保留 data: 帧 + 空行框架)。no-op 当未录制。
            @import("../core/recorder.zig").recordSseLine(line);

            const data = parser.parseLine(line) orelse continue;
            const ev_type = parseEventType(data);
            self.logDebug("event: {s} line_len={d} data={s}", .{ @tagName(ev_type), line.len, data });
            switch (ev_type) {
                .content_block_start => {
                    // 检查是不是 tool_use block
                    if (extractToolUse(data)) |tu| {
                        // 清掉任何残留的 pending
                        if (self.pending_tool) |*old| {
                            allocator.free(old.id);
                            allocator.free(old.name);
                            old.input_buf.deinit(allocator);
                        }
                        self.pending_tool = .{
                            .id = try allocator.dupe(u8, tu.id),
                            .name = try allocator.dupe(u8, tu.name),
                            .input_buf = .empty,
                        };
                        self.logInfo("tool_use_start id={s} name={s}", .{ tu.id, tu.name });
                        // tool_use 的参数通过后续 input_json_delta 累加——不立即 emit
                        continue;
                    }
                    // 服务端工具调用（web_search）：开始一次搜索。记开始时间 + 准备累积 query。
                    // 不在此处 emit——等本次 web_search_tool_result 时出完整两行组(对齐 cc)。
                    if (extractServerToolUse(data)) |stu| {
                        self.logInfo("server_tool_use name={s} query={s}", .{ stu.name, stu.query });
                        self.ws_start_ms = util_time.nowMs();
                        self.ws_in_server_tool = true;
                        self.ws_query.clearRetainingCapacity();
                        continue;
                    }
                    // 服务端工具结果（web_search_tool_result）：本次搜索结束 → emit
                    // web_search_result 事件:ui_text(⏺ Web Search 装饰,主对话照打,TUI 不变)
                    // + content_json(原始结果数组,子请求据此结构化解析;metask 常 `[]`)。
                    if (extractServerToolResult(data)) |str| {
                        self.logInfo("web_search_tool_result content_len={d}", .{str.content_array_raw.len});
                        self.ws_in_server_tool = false;
                        const group = try self.webSearchGroup(allocator);
                        errdefer allocator.free(group);
                        const content = try allocator.dupe(u8, str.content_array_raw);
                        return Event{ .web_search_result = .{ .ui_text = group, .content_json = content } };
                    }
                    // 其它 content_block_start（text block 等）——跳过
                    continue;
                },
                .content_block_delta => {
                    // 区分 text_delta 和 input_json_delta
                    if (extractInputJsonDelta(data)) |partial| {
                        const unescaped = try util_json.unescapeString(partial, allocator);
                        defer allocator.free(unescaped);
                        if (self.ws_in_server_tool) {
                            // web_search 的真实 query 经此累积(content_block_start 是占位符)。
                            try self.ws_query.appendSlice(allocator, unescaped);
                        } else if (self.pending_tool) |*pt| {
                            // partial 是 JSON 字符串里的原始片段（"\"path\":\"" 之类）
                            // 它本身在 SSE data 里被 JSON 转义过，反转义后累加。
                            try pt.input_buf.appendSlice(allocator, unescaped);
                            self.logDebug("input_json_delta partial={s}", .{unescaped});
                        }
                        continue;
                    }
                    if (try extractTextDelta(data, allocator)) |text| {
                        self.logDebug("text_delta bytes={d}", .{text.len});
                        return Event{ .text_delta = text };
                    }
                    if (try extractThinkingDelta(data, allocator)) |think| {
                        self.logDebug("thinking_delta bytes={d}", .{think.len});
                        return Event{ .thinking_delta = think };
                    }
                    continue;
                },
                .content_block_stop => {
                    // 若有 pending tool，这就是 emit 时机
                    if (self.pending_tool) |*pt| {
                        // 收齐的 input_buf 应是合法 JSON object；若累加结果为空，用 "{}" fallback。
                        // 非法 input 不在此修——agent_loop 收 tool_use_start 时统一 repair(覆盖所有
                        // provider,单一 choke point,见 message_repair.repairToolArgs)。此处仅记录。
                        const full_input = if (pt.input_buf.items.len == 0)
                            try allocator.dupe(u8, "{}")
                        else
                            try pt.input_buf.toOwnedSlice(allocator);
                        errdefer allocator.free(full_input);

                        validateJsonObject(full_input) catch {
                            self.logWarn("tool input invalid JSON (emitted anyway, repaired downstream): {s}", .{full_input});
                        };

                        const id = pt.id;
                        const name = pt.name;
                        self.logInfo("tool_use complete id={s} name={s} input_bytes={d}", .{ id, name, full_input.len });
                        self.logDebug("tool_use input_json={s}", .{full_input});
                        pt.input_buf.deinit(allocator);
                        self.pending_tool = null;
                        return Event{ .tool_use_start = .{
                            .id = id,
                            .name = name,
                            .input_json = full_input,
                        } };
                    }
                    // server_tool_use(web_search)块结束:query 已累积齐 → emit web_search_query
                    // (对齐 cc query_update)。优先用户原始 query(ws_user_query)——provider 的
                    // query 常是占位符("web search"/"searching the web",见 webSearchGroup 同款逻辑);
                    // 无用户 query 才回退 provider 累积值。
                    if (self.ws_in_server_tool) {
                        const provider_q = util_json.extractStringField(self.ws_query.items, "query") orelse "";
                        const q: []const u8 = if (self.ws_user_query.len > 0) self.ws_user_query else provider_q;
                        if (q.len > 0) {
                            const owned = try allocator.dupe(u8, q);
                            return Event{ .web_search_query = owned };
                        }
                    }
                    continue;
                },
                .message_stop => {
                    // 若还有未 emit 的 pending（异常情况），清理
                    if (self.pending_tool) |*pt| {
                        allocator.free(pt.id);
                        allocator.free(pt.name);
                        pt.input_buf.deinit(allocator);
                        self.pending_tool = null;
                    }
                    self.done_flag = true;
                    self.logInfo("message_stop", .{});
                    @import("../core/recorder.zig").finishSse();
                    return Event{ .done = {} };
                },
                .message_delta => {
                    // 提取 stop_reason 并 log：用户看到截断时能知道原因
                    // 格式示例：{"type":"message_delta","delta":{"stop_reason":"max_tokens",...},"usage":{"output_tokens":N,...}}
                    if (findTopLevelObjectField(data, "delta")) |delta_obj| {
                        if (findTopLevelStringField(delta_obj, "stop_reason")) |sr| {
                            self.last_stop_reason = StopReason.fromStr(sr);
                            if (std.mem.eql(u8, sr, "max_tokens")) {
                                self.logWarn("response hit max_tokens limit — increase max_tokens in request to get longer replies", .{});
                            } else {
                                self.logInfo("stop_reason: {s}", .{sr});
                            }
                        }
                    }
                    // message_delta 的 usage 是 top-level 的 `usage`，不在 delta 里
                    if (findTopLevelObjectField(data, "usage")) |usage_obj| {
                        return Event{ .usage = parseUsageDelta(usage_obj) };
                    }
                    continue;
                },
                .message_start => {
                    self.logInfo("message_start", .{});
                    // message_start 的 usage 嵌在 message 对象里：{"message":{"usage":{...}}}
                    if (findTopLevelObjectField(data, "message")) |msg_obj| {
                        if (findTopLevelObjectField(msg_obj, "usage")) |usage_obj| {
                            return Event{ .usage = parseUsageDelta(usage_obj) };
                        }
                    }
                    continue;
                },
                .error_event => {
                    // Anthropic 错误帧:{"type":"error","error":{"type":"overloaded_error","message":"..."}}
                    // 不再静默归 .unknown 跳过——打 err 日志并上抛明确 error,让上游区分
                    // "API 主动报错" vs "网络/解析失败"(避免三类错误塌缩成 RequestFailed)。
                    const err_obj = findTopLevelObjectField(data, "error") orelse data;
                    self.logWarn("API error event: {s}", .{err_obj});
                    @import("last_error.zig").recordNamed("API 错误帧", err_obj);
                    self.done_flag = true;
                    if (error_class.isContextWindowExceeded(err_obj)) return error.ContextWindowExceededEvent;
                    return error.ApiErrorEvent;
                },
                // ping / unknown → 跳过
                else => continue,
            }
        }
    }

    // --- 内部日志 helper：带 req_id 时用 *Id 变体，否则普通 ---
    fn logDebug(self: *const EventIterator, comptime fmt: []const u8, args: anytype) void {
        if (self.req_id) |id| log.debugId("stream", id, fmt, args) else log.debug("stream", fmt, args);
    }
    fn logInfo(self: *const EventIterator, comptime fmt: []const u8, args: anytype) void {
        if (self.req_id) |id| log.infoId("stream", id, fmt, args) else log.info("stream", fmt, args);
    }
    fn logWarn(self: *const EventIterator, comptime fmt: []const u8, args: anytype) void {
        if (self.req_id) |id| log.warnId("stream", id, fmt, args) else log.warn("stream", fmt, args);
    }
};

/// 用 std.json.Scanner 校验累加后的 input_json 是否是合法 JSON object。
/// 成功返 void；失败返 error.InvalidJson。用 Scanner 而不是 parseFromSlice 是因为
/// 它只做语法检查不 allocate 中间数据结构。
fn validateJsonObject(data: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(std.heap.page_allocator, data);
    defer scanner.deinit();
    while (true) {
        const tok = scanner.next() catch return error.InvalidJson;
        if (tok == .end_of_document) return;
    }
}

test "EventIterator: text_delta event" {
    const sse = "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    const ev = (try it.next(std.testing.allocator)).?;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hi", ev.text_delta);
}

test "EventIterator: web_search_tool_result → web_search_result 事件(含 content)" {
    const a = std.testing.allocator;
    // content_block_start 携带 web_search_tool_result + 非空 content 数组(title/url)。
    const sse = "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srv_1\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Zig\",\"url\":\"https://ziglang.org\"}]}}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(a);
    const ev = (try it.next(a)).?;
    defer ev.deinit(a);
    // 是 web_search_result 变体,不是 text_delta。
    try std.testing.expect(ev == .web_search_result);
    const w = ev.web_search_result;
    // ui_text:UI 装饰(⏺ Web Search),主对话照打。
    try std.testing.expect(std.mem.indexOf(u8, w.ui_text, "Web Search") != null);
    // content_json:原始结果数组,含 title/url(子请求据此结构化解析)。
    try std.testing.expect(std.mem.indexOf(u8, w.content_json, "ziglang.org") != null);
    // renderWebSearchResults 能从 content_json 渲染出结果行。
    const rendered = try renderWebSearchResults(a, w.content_json);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://ziglang.org") != null);
}

test "EventIterator: 超长 SSE 行(> reader buffer)不再 StreamTooLong" {
    // 修复 Bug 3:大 input_json_delta/大 text 把一整条 data 行推成 >buffer。
    // 用 Limited reader 给一个很小的 buffer(64B),构造一条远超它的行,
    // 验证走 streamDelimiterEnding 累积路径、能完整读出、不报 StreamTooLong。
    const a = std.testing.allocator;
    const big = "x" ** 5000; // 5KB 文本,远超 64B buffer
    const sse = "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"" ++ big ++ "\"}}\n";

    var src = std.Io.Reader.fixed(sse);
    var small_buf: [64]u8 = undefined;
    var limited = std.Io.Reader.limited(&src, .unlimited, &small_buf);

    var it = EventIterator.init(&limited.interface);
    defer it.deinit(a);
    const ev = (try it.next(a)).?;
    defer ev.deinit(a);
    // text_delta 应完整拿到 5000 个 'x'
    try std.testing.expectEqual(@as(usize, 5000), ev.text_delta.len);
    try std.testing.expect(std.mem.indexOfNone(u8, ev.text_delta, "x") == null);
}

test "EventIterator: SSE line hard limit prevents unbounded allocation" {
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, MAX_SSE_LINE_BYTES + 2);
    defer a.free(oversized);
    @memset(oversized, 'x');
    oversized[oversized.len - 1] = '\n';

    // Force the overflow path used by network readers rather than letting the
    // fixed source expose the complete line as one enormous reader buffer.
    var src = std.Io.Reader.fixed(oversized);
    var small_buf: [64]u8 = undefined;
    var limited = std.Io.Reader.limited(&src, .unlimited, &small_buf);

    var it = EventIterator.init(&limited.interface);
    defer it.deinit(a);
    try std.testing.expectError(error.StreamTooLong, it.next(a));
    try std.testing.expect(it.line_overflow.items.len <= MAX_SSE_LINE_BYTES + 1);
    // The failed line was only partially consumed; continuing would treat its
    // suffix as a new frame, so the iterator must remain terminal.
    try std.testing.expect((try it.next(a)) == null);
}

test "EventIterator: tool_use_start emitted on content_block_stop" {
    // 新语义：content_block_start 记 pending，content_block_stop 才 emit tool_use_start
    const sse =
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{}}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);
    const ev = (try it.next(std.testing.allocator)).?;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", ev.tool_use_start.id);
    try std.testing.expectEqualStrings("Bash", ev.tool_use_start.name);
    // 累加后的 input_json 应该是完整的 {"cmd":"ls"}
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", ev.tool_use_start.input_json);
}

test "EventIterator: web_search 优先显示用户原始 query(对齐 mecode,provider 占位符回退)" {
    // provider 在 delta 里给占位符 query;setUserQuery 注入用户原话 → 显示用户原话。
    const sse =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"x\",\"name\":\"web_search\",\"input\":{\"query\":\"web search\"}}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"searching the web\\\"}\"}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"x\",\"content\":[]}}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    it.setUserQuery("今天美国排名前十的新闻");
    defer it.deinit(std.testing.allocator);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    while (try it.next(std.testing.allocator)) |ev| {
        defer ev.deinit(std.testing.allocator);
        if (ev == .text_delta) try all.appendSlice(std.testing.allocator, ev.text_delta);
        if (ev == .web_search_result) try all.appendSlice(std.testing.allocator, ev.web_search_result.ui_text);
        if (ev == .done) break;
    }
    const s = all.items;
    // 显示用户原话,不是 provider 占位符
    try std.testing.expect(std.mem.indexOf(u8, s, "今天美国排名前十的新闻") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "searching the web") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\"web search\"") == null);
}

test "EventIterator: web_search per-search 组(对齐 cc:⏺ Web Search + ⎿ Did 1 search)" {
    // server_tool_use → (input_json_delta query) → web_search_tool_result → text。
    // 对齐 cc:本次搜索结束 emit 一组 ⏺ Web Search("query") / ⎿ Did 1 search in Xms。
    const sse =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_abc\",\"name\":\"web_search\",\"input\":{\"query\":\"web search\"}}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"zig version\\\"}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_abc\",\"content\":[]}}\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":1}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"text\":\"Zig is 0.16.\"}}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    while (try it.next(std.testing.allocator)) |ev| {
        defer ev.deinit(std.testing.allocator);
        if (ev == .text_delta) try all.appendSlice(std.testing.allocator, ev.text_delta);
        if (ev == .web_search_result) try all.appendSlice(std.testing.allocator, ev.web_search_result.ui_text);
        if (ev == .done) break;
    }
    const s = all.items;
    // 工具调用行 + 结果行(对齐 cc 格式)。query 用 delta 里的(本例 "zig version")。
    try std.testing.expect(std.mem.indexOf(u8, s, "⏺ Web Search(\"zig version\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "⎿  Did 1 search in") != null);
    // 不出现噪音
    try std.testing.expect(std.mem.indexOf(u8, s, "0 results") == null);
    // 模型回答透传
    try std.testing.expect(std.mem.indexOf(u8, s, "Zig is 0.16.") != null);
}

test "EventIterator: 两次搜索 → 两组各 Did 1 search(per-search 不累计)" {
    const sse =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"a\",\"name\":\"web_search\",\"input\":{\"query\":\"x\"}}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"a\",\"content\":[]}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"b\",\"name\":\"web_search\",\"input\":{\"query\":\"y\"}}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":3,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"b\",\"content\":[]}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":4,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":4,\"delta\":{\"text\":\"ans\"}}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    while (try it.next(std.testing.allocator)) |ev| {
        defer ev.deinit(std.testing.allocator);
        if (ev == .text_delta) try all.appendSlice(std.testing.allocator, ev.text_delta);
        if (ev == .web_search_result) try all.appendSlice(std.testing.allocator, ev.web_search_result.ui_text);
        if (ev == .done) break;
    }
    // 两组 ⏺ Web Search + 两个 Did 1 search(per-search,不合并成 Did 2)
    const s = all.items;
    var web_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, s, pos, "⏺ Web Search")) |idx| : (pos = idx + 1) web_count += 1;
    try std.testing.expectEqual(@as(usize, 2), web_count);
    try std.testing.expect(std.mem.indexOf(u8, s, "Did 2 search") == null); // 不累计
}

test "EventIterator: skips ping and empty lines" {
    const sse =
        "data: {\"type\":\"ping\"}\n" ++
        "\n" ++
        "event: whatever\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"x\"}}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    const ev = (try it.next(std.testing.allocator)).?;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x", ev.text_delta);
}

test "EventIterator: multiple events in sequence" {
    const sse =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"a\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"b\"}}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    const e1 = (try it.next(std.testing.allocator)).?;
    defer e1.deinit(std.testing.allocator);
    const e2 = (try it.next(std.testing.allocator)).?;
    defer e2.deinit(std.testing.allocator);
    const e3 = (try it.next(std.testing.allocator)).?;
    defer e3.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a", e1.text_delta);
    try std.testing.expectEqualStrings("b", e2.text_delta);
    try std.testing.expect(@as(std.meta.Tag(Event), e3) == .done);
}

test "EventIterator: after done returns null" {
    const sse = "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    const done = (try it.next(std.testing.allocator)).?;
    defer done.deinit(std.testing.allocator);
    try std.testing.expect(@as(std.meta.Tag(Event), done) == .done);
    try std.testing.expect(try it.next(std.testing.allocator) == null);
}

test "EventIterator: EOF without message_stop returns null" {
    const sse = "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"x\"}}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    const e1 = (try it.next(std.testing.allocator)).?;
    defer e1.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x", e1.text_delta);
    try std.testing.expect(try it.next(std.testing.allocator) == null);
}

test "EventIterator: abort before first event" {
    var sig = AbortSignal.init();
    sig.abort(.user_ctrl_c);
    const sse = "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"x\"}}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.initWithAbort(&reader, &sig);
    try std.testing.expectError(error.Aborted, it.next(std.testing.allocator));
}

test "EventIterator: abort between events" {
    var sig = AbortSignal.init();
    const sse =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"a\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"b\"}}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.initWithAbort(&reader, &sig);
    const e1 = (try it.next(std.testing.allocator)).?;
    defer e1.deinit(std.testing.allocator);
    sig.abort(.user_ctrl_c);
    try std.testing.expectError(error.Aborted, it.next(std.testing.allocator));
}

test "EventIterator: empty stream returns null" {
    var reader = std.Io.Reader.fixed("");
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);
    try std.testing.expect(try it.next(std.testing.allocator) == null);
}

// ============================================================================
// M1.10 真实 napi 代理风格 fixture 测试
// ============================================================================

test "napi-style: content_block_start with nested-end type + input_json_delta accumulation" {
    // 对齐 `napi.origintask.cn` 真实返回：
    //   content_block 的字段顺序是 id/input/name/type（type 在末尾）
    //   initial input 是空 {}；参数通过后续 input_json_delta 累加
    const sse =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"id\":\"toolu_abc\",\"input\":{},\"name\":\"Glob\",\"type\":\"tool_use\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/tmp\\\"}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    const e1 = (try it.next(std.testing.allocator)).?;
    defer e1.deinit(std.testing.allocator);
    try std.testing.expect(@as(std.meta.Tag(Event), e1) == .tool_use_start);
    try std.testing.expectEqualStrings("toolu_abc", e1.tool_use_start.id);
    try std.testing.expectEqualStrings("Glob", e1.tool_use_start.name);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", e1.tool_use_start.input_json);

    const e2 = (try it.next(std.testing.allocator)).?;
    defer e2.deinit(std.testing.allocator);
    try std.testing.expect(@as(std.meta.Tag(Event), e2) == .done);
}

test "napi-style: multiple input_json_delta across chunks accumulate" {
    // 真实场景：tool input 参数较长时 LLM 会把 partial_json 拆成多段
    const sse =
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"id\":\"t1\",\"input\":{},\"name\":\"Bash\",\"type\":\"tool_use\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"comm\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"and\\\":\\\"\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"ls -la\\\"}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    const ev = (try it.next(std.testing.allocator)).?;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"command\":\"ls -la\"}", ev.tool_use_start.input_json);
}

test "napi-style: text + tool_use in same stream" {
    // LLM 先说几句话，再调工具
    const sse =
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Let me check.\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"id\":\"t1\",\"input\":{},\"name\":\"Read\",\"type\":\"tool_use\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/x\\\"}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    const e1 = (try it.next(std.testing.allocator)).?;
    defer e1.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Let me check.", e1.text_delta);

    const e2 = (try it.next(std.testing.allocator)).?;
    defer e2.deinit(std.testing.allocator);
    try std.testing.expect(@as(std.meta.Tag(Event), e2) == .tool_use_start);
    try std.testing.expectEqualStrings("Read", e2.tool_use_start.name);
    try std.testing.expectEqualStrings("{\"path\":\"/x\"}", e2.tool_use_start.input_json);

    const e3 = (try it.next(std.testing.allocator)).?;
    defer e3.deinit(std.testing.allocator);
    try std.testing.expect(@as(std.meta.Tag(Event), e3) == .done);
}

test "napi-style: tool_use with empty input keeps {}" {
    // 某些工具不接受参数，input_json_delta 不会出现
    const sse =
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"id\":\"t1\",\"input\":{},\"name\":\"NoArgTool\",\"type\":\"tool_use\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    const ev = (try it.next(std.testing.allocator)).?;
    defer ev.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", ev.tool_use_start.input_json);
}

test "napi-style: two tool_use in one message" {
    // 并行调多个工具
    const sse =
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"id\":\"t1\",\"input\":{},\"name\":\"A\",\"type\":\"tool_use\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":1}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"id\":\"t2\",\"input\":{},\"name\":\"B\",\"type\":\"tool_use\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"y\\\":2}\"}}\n" ++
        "data: {\"type\":\"content_block_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    const e1 = (try it.next(std.testing.allocator)).?;
    defer e1.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", e1.tool_use_start.id);
    try std.testing.expectEqualStrings("{\"x\":1}", e1.tool_use_start.input_json);

    const e2 = (try it.next(std.testing.allocator)).?;
    defer e2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t2", e2.tool_use_start.id);
    try std.testing.expectEqualStrings("{\"y\":2}", e2.tool_use_start.input_json);
}

test "extractInputJsonDelta: non-input-json-delta returns null" {
    // text_delta 不应被当成 input_json_delta
    const data = "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}";
    try std.testing.expect(extractInputJsonDelta(data) == null);
}

test "extractInputJsonDelta: napi order works" {
    const data = "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"abc\"}}";
    try std.testing.expectEqualStrings("abc", extractInputJsonDelta(data).?);
}

test "extractToolUse: napi field order works" {
    const data = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"id\":\"toolu_xyz\",\"input\":{},\"name\":\"Grep\",\"type\":\"tool_use\"}}";
    const tu = extractToolUse(data).?;
    try std.testing.expectEqualStrings("toolu_xyz", tu.id);
    try std.testing.expectEqualStrings("Grep", tu.name);
}

test "validateJsonObject: valid passes" {
    try validateJsonObject("{\"a\":1,\"b\":[2,3]}");
}

test "validateJsonObject: invalid errors" {
    try std.testing.expectError(error.InvalidJson, validateJsonObject("{not json}"));
    try std.testing.expectError(error.InvalidJson, validateJsonObject("{\"a\":}"));
}

test "extractServerToolUse: web_search query" {
    const data = "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_x\",\"name\":\"web_search\",\"input\":{\"query\":\"zig 0.16 release notes\"}}}";
    const r = extractServerToolUse(data).?;
    try std.testing.expectEqualStrings("web_search", r.name);
    try std.testing.expectEqualStrings("zig 0.16 release notes", r.query);
}

test "extractServerToolUse: returns null for tool_use" {
    const data = "{\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"Bash\",\"input\":{}}}";
    try std.testing.expect(extractServerToolUse(data) == null);
}

test "extractServerToolResult: gets content array" {
    const data = "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_x\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Zig 0.16\",\"url\":\"https://ziglang.org/news/0.16.0/\"}]}}";
    const r = extractServerToolResult(data).?;
    try std.testing.expect(std.mem.indexOf(u8, r.content_array_raw, "Zig 0.16") != null);
}

test "renderWebSearchResults: single result" {
    const arr = "[{\"type\":\"web_search_result\",\"title\":\"Zig 0.16\",\"url\":\"https://example.org/0.16\"}]";
    const out = try renderWebSearchResults(std.testing.allocator, arr);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Web search: 1 result]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Zig 0.16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "https://example.org/0.16") != null);
}

test "renderWebSearchResults: empty array → 不打噪音(回归:旧版误显示 0 results)" {
    // 真后端(代理)发 content:[](只喂模型不透传)。此时必须**不**渲染 "0 results"
    // ——那行对用户是误导(实际有结果)。返回空串。
    const out = try renderWebSearchResults(std.testing.allocator, "[]");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
    try std.testing.expect(std.mem.indexOf(u8, out, "0 results") == null);
}

test "EventIterator: 真后端形态(空数组 + 占位 query)不打噪音" {
    // 复刻 napi.metask-ai.com 真实响应:server_tool_use query 占位 "web search",
    // web_search_tool_result content:[]。旧版会吐 [Web search: "web search"] + [Web search: 0 results]
    // 这两行噪音。修复后:搜索标记不含 query 字面、空结果不打 "0 results"。
    const sse =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_x\",\"name\":\"web_search\",\"input\":{\"query\":\"web search\"}}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_x\",\"content\":[]}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"今天的 AI 新闻...\"}}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    // 收集所有 text_delta 拼起来
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(std.testing.allocator);
    while (try it.next(std.testing.allocator)) |ev| {
        defer ev.deinit(std.testing.allocator);
        if (ev == .text_delta) try all.appendSlice(std.testing.allocator, ev.text_delta);
        if (ev == .web_search_result) try all.appendSlice(std.testing.allocator, ev.web_search_result.ui_text);
        if (ev == .done) break;
    }
    const s = all.items;
    // 不含占位 query 字面、不含 "0 results"
    try std.testing.expect(std.mem.indexOf(u8, s, "\"web search\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "0 results") == null);
    // 出 "Did 1 search in"(对齐 cc),且模型回答透传
    try std.testing.expect(std.mem.indexOf(u8, s, "Did 1 search in") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "今天的 AI 新闻") != null);
}

test "renderWebSearchResults: multiple results" {
    const arr =
        "[{\"type\":\"web_search_result\",\"title\":\"A\",\"url\":\"https://a/\"}," ++
        "{\"type\":\"web_search_result\",\"title\":\"B\",\"url\":\"https://b/\"}," ++
        "{\"type\":\"web_search_result\",\"title\":\"C\",\"url\":\"https://c/\"}]";
    const out = try renderWebSearchResults(std.testing.allocator, arr);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "3 results") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "C") != null);
}

test "StopReason.fromStr" {
    try std.testing.expect(StopReason.fromStr("max_tokens") == .max_tokens);
    try std.testing.expect(StopReason.fromStr("end_turn") == .end_turn);
    try std.testing.expect(StopReason.fromStr("tool_use") == .tool_use);
    try std.testing.expect(StopReason.fromStr("pause_turn") == .pause_turn);
    try std.testing.expect(StopReason.fromStr("refusal") == .refusal);
    try std.testing.expect(StopReason.fromStr("garbage") == .unknown);
}

test "EventIterator records last_stop_reason from message_delta" {
    const a = std.testing.allocator;
    const sse =
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(a);
    // drain
    while (try it.next(a)) |ev| {
        ev.deinit(a);
    }
    try std.testing.expect(it.last_stop_reason == .max_tokens);
}

test "extractThinkingDelta: 从 thinking_delta 事件提取 thinking 内容" {
    const a = std.testing.allocator;
    const sse =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"let me think\"}}\n\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(a);
    var got: ?[]u8 = null;
    if (try it.next(a)) |ev| {
        switch (ev) {
            .thinking_delta => |t| got = t,
            else => ev.deinit(a),
        }
    }
    defer if (got) |g| a.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("let me think", got.?);
}

test "extractThinkingDelta: 非 thinking_delta 事件返回 null" {
    const a = std.testing.allocator;
    const sse =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(a);
    if (try it.next(a)) |ev| {
        switch (ev) {
            .thinking_delta => |t| {
                a.free(t);
                return error.UnexpectedThinking;
            },
            else => ev.deinit(a),
        }
    }
}

test "extractThinkingDelta: unescape 转义内容" {
    const a = std.testing.allocator;
    const sse =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"line1\\nline2\"}}\n\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(a);
    var got: ?[]u8 = null;
    if (try it.next(a)) |ev| {
        switch (ev) {
            .thinking_delta => |t| got = t,
            else => ev.deinit(a),
        }
    }
    defer if (got) |g| a.free(g);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("line1\nline2", got.?);
}
