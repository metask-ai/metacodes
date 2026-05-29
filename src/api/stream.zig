const std = @import("std");
const util_json = @import("../util/json.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const log = @import("../util/log.zig");

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
    return .unknown;
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
        while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
        if (i >= data.len) return null;
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
                while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
                if (i >= data.len) return null;
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
    if (std.mem.indexOf(u8, data, "\"type\":\"content_block_delta\"") == null) return null;
    const delta_start = std.mem.indexOf(u8, data, "\"delta\":{") orelse return null;

    var depth: i32 = 1;
    var i = delta_start + 8;
    while (i < data.len and depth > 0) : (i += 1) {
        if (data[i] == '{') depth += 1;
        if (data[i] == '}') depth -= 1;
    }
    const delta_obj = data[delta_start + 8 .. i];

    const text_start = std.mem.indexOf(u8, delta_obj, "\"text\":\"") orelse return null;
    const value_start = text_start + 8;
    var end = value_start;
    while (end < delta_obj.len and delta_obj[end] != '"') {
        if (delta_obj[end] == '\\') end += 1;
        end += 1;
    }
    return try util_json.unescapeString(delta_obj[value_start..end], allocator);
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
        if (escaped) { escaped = false; continue; }
        if (c == '\\') { escaped = true; continue; }
        if (c == '"') { in_str = !in_str; continue; }
        if (in_str) continue;
        if (c == '{') {
            if (depth == 0) obj_start = i;
            depth += 1;
        } else if (c == '}') {
            depth -= 1;
            if (depth == 0) {
                const obj = content_array[obj_start.?..i + 1];
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
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        if (i >= data.len) return null;
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
                if (escaped) { escaped = false; continue; }
                if (c == '\\') { escaped = true; continue; }
                if (c == '"') { in_str = !in_str; continue; }
                if (in_str) continue;
                if (c == '[') depth += 1;
                if (c == ']') {
                    depth -= 1;
                    if (depth == 0) return data[start..i + 1];
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
        while (i < data.len and data[i] != '"') : (i += 1) {
            if (data[i] == '\\') i += 1;
        }
        return if (i < data.len) i + 1 else i;
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
            if (escaped) { escaped = false; continue; }
            if (ch == '\\') { escaped = true; continue; }
            if (ch == '"') { in_str = !in_str; continue; }
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
        while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
        if (i >= data.len) return null;
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
                while (i < data.len and !(data[i] == '"' and data[i - 1] != '\\')) : (i += 1) {}
                if (i < data.len) i += 1;
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
    const data = "{\"type\":\"content_block_delta\",\"delta\":{\"text\":\"a\\nb\"}}";
    const r = (try extractTextDelta(data, std.testing.allocator)).?;
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a\nb", r);
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
    const data = "{\"type\":\"content_block_delta\",\"delta\":{\"text\":\"\"}}";
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
    /// 来自 content_block_start 的工具调用初始信息；内部字段借用自 reader buffer
    /// —— 调用方若要跨 next() 保留，必须 dupe
    tool_use_start: ToolUseResult,
    /// 用量统计（来自 message_start 或 message_delta 的 usage 字段）；数值不拥有资源
    usage: UsageDelta,
    /// 结束信号
    done: void,

    pub fn deinit(self: Event, allocator: std.mem.Allocator) void {
        switch (self) {
            .text_delta => |b| allocator.free(b),
            .tool_use_start => |tu| {
                allocator.free(tu.id);
                allocator.free(tu.name);
                allocator.free(tu.input_json);
            },
            .usage, .done => {},
        }
    }
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

/// 从 object string 里抽 `"field":<digits>` 的整数值。
/// 不处理浮点、负数、科学记数——usage 字段都是非负整数。
fn parseIntField(obj: []const u8, field: []const u8) u64 {
    var pat_buf: [64]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{field}) catch return 0;
    const idx = std.mem.indexOf(u8, obj, pat) orelse return 0;
    var i = idx + pat.len;
    while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < obj.len and obj[i] >= '0' and obj[i] <= '9') : (i += 1) {}
    if (i == start) return 0;
    return std.fmt.parseInt(u64, obj[start..i], 10) catch 0;
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

    /// 清理未 emit 的 pending_tool（通常在 error 或提前 drop 时调用）。
    /// 正常流程下 content_block_stop 已经消费掉 pending，无需手动 deinit。
    pub fn deinit(self: *EventIterator, allocator: std.mem.Allocator) void {
        if (self.pending_tool) |*pt| {
            allocator.free(pt.id);
            allocator.free(pt.name);
            pt.input_buf.deinit(allocator);
            self.pending_tool = null;
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

            const line_opt = self.reader.takeDelimiter('\n') catch |err| {
                self.logWarn("takeDelimiter failed: {s}", .{@errorName(err)});
                return err;
            };
            const line = line_opt orelse {
                self.logDebug("EOF reached (no message_stop before EOF)", .{});
                self.done_flag = true;
                return null;
            };

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
                    // 服务端工具调用（web_search）：发起搜索的可读标记
                    if (extractServerToolUse(data)) |stu| {
                        self.logInfo("server_tool_use name={s} query={s}", .{ stu.name, stu.query });
                        const text = try std.fmt.allocPrint(allocator, "\n[Web search: \"{s}\"]\n", .{stu.query});
                        return Event{ .text_delta = text };
                    }
                    // 服务端工具结果（web_search_tool_result）：把结果列表渲染成可读文本
                    if (extractServerToolResult(data)) |str| {
                        self.logInfo("web_search_tool_result content_len={d}", .{str.content_array_raw.len});
                        const text = try renderWebSearchResults(allocator, str.content_array_raw);
                        return Event{ .text_delta = text };
                    }
                    // 其它非 tool_use 的 content_block_start（比如 text block）——跳过
                    continue;
                },
                .content_block_delta => {
                    // 区分 text_delta 和 input_json_delta
                    if (extractInputJsonDelta(data)) |partial| {
                        if (self.pending_tool) |*pt| {
                            // partial 是 JSON 字符串里的原始片段（"\"path\":\"" 之类）
                            // 它本身在 SSE data 里被 JSON 转义过，用 util_json.unescapeString 反转义后
                            // 得到真实的 JSON 片段，累加
                            const unescaped = try util_json.unescapeString(partial, allocator);
                            defer allocator.free(unescaped);
                            try pt.input_buf.appendSlice(allocator, unescaped);
                            self.logDebug("input_json_delta partial={s}", .{unescaped});
                        }
                        continue;
                    }
                    if (try extractTextDelta(data, allocator)) |text| {
                        self.logDebug("text_delta bytes={d}", .{text.len});
                        return Event{ .text_delta = text };
                    }
                    continue;
                },
                .content_block_stop => {
                    // 若有 pending tool，这就是 emit 时机
                    if (self.pending_tool) |*pt| {
                        // 收齐的 input_buf 应是合法 JSON object；若累加结果为空，用 "{}" fallback
                        const full_input = if (pt.input_buf.items.len == 0)
                            try allocator.dupe(u8, "{}")
                        else
                            try pt.input_buf.toOwnedSlice(allocator);
                        errdefer allocator.free(full_input);

                        // 用 std.json.Scanner 做完整性校验（不阻塞事件流——即使格式错仍 emit，
                        // 让下游 tool 返错给 LLM 自纠。这里只记录一下是否合法）
                        validateJsonObject(full_input) catch {
                            self.logWarn("tool input invalid JSON (emitted anyway): {s}", .{full_input});
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

test "EventIterator: web_search emits search marker + results as text_delta" {
    // 模拟真实 web_search 流：server_tool_use（带 query）→ result block
    const sse =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srvtoolu_abc\",\"name\":\"web_search\",\"input\":{\"query\":\"zig 0.16\"}}}\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"web_search_tool_result\",\"tool_use_id\":\"srvtoolu_abc\",\"content\":[{\"type\":\"web_search_result\",\"title\":\"Zig 0.16 Release\",\"url\":\"https://ziglang.org/0.16/\"}]}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Based on search, Zig 0.16...\"}}\n" ++
        "data: {\"type\":\"message_stop\"}\n";
    var reader = std.Io.Reader.fixed(sse);
    var it = EventIterator.init(&reader);
    defer it.deinit(std.testing.allocator);

    // 第一个事件：搜索发起的可读标记
    const ev1 = (try it.next(std.testing.allocator)).?;
    defer ev1.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, ev1.text_delta, "Web search") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev1.text_delta, "zig 0.16") != null);

    // 第二个事件：搜索结果渲染
    const ev2 = (try it.next(std.testing.allocator)).?;
    defer ev2.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, ev2.text_delta, "Zig 0.16 Release") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev2.text_delta, "ziglang.org") != null);

    // 第三个事件：模型基于搜索结果给出的回答
    const ev3 = (try it.next(std.testing.allocator)).?;
    defer ev3.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, ev3.text_delta, "Based on search") != null);

    // done
    const ev4 = (try it.next(std.testing.allocator)).?;
    defer ev4.deinit(std.testing.allocator);
    try std.testing.expect(ev4 == .done);
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

test "renderWebSearchResults: empty array" {
    const out = try renderWebSearchResults(std.testing.allocator, "[]");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "0 results") != null);
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
