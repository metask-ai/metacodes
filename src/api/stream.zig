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
            .done => {},
        }
    }
};

pub const EventIterator = struct {
    reader: *std.Io.Reader,
    abort: ?*const AbortSignal = null,
    done_flag: bool = false,

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
                log.warn("stream", "takeDelimiter failed: {s}", .{@errorName(err)});
                return err;
            };
            const line = line_opt orelse {
                log.debug("stream", "EOF reached (no message_stop before EOF)", .{});
                self.done_flag = true;
                return null;
            };

            const data = parser.parseLine(line) orelse continue;
            const ev_type = parseEventType(data);
            log.debug("stream", "event: {s} (line_len={d})", .{ @tagName(ev_type), line.len });
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
                        // tool_use 的参数通过后续 input_json_delta 累加——不立即 emit
                        continue;
                    }
                    // 非 tool_use 的 content_block_start（比如 text block）——跳过
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
                        }
                        continue;
                    }
                    if (try extractTextDelta(data, allocator)) |text| {
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
                            // 校验失败：仍透传给工具，由工具层报错给 LLM（比我们在此吞掉好）
                        };

                        const id = pt.id;
                        const name = pt.name;
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
                    return Event{ .done = {} };
                },
                .message_delta => {
                    // 提取 stop_reason 并 log：用户看到截断时能知道原因
                    // 格式示例：{"type":"message_delta","delta":{"stop_reason":"max_tokens",...},...}
                    if (findTopLevelObjectField(data, "delta")) |delta_obj| {
                        if (findTopLevelStringField(delta_obj, "stop_reason")) |sr| {
                            if (std.mem.eql(u8, sr, "max_tokens")) {
                                log.warn("stream", "response hit max_tokens limit — increase max_tokens in request to get longer replies", .{});
                            } else {
                                log.debug("stream", "stop_reason: {s}", .{sr});
                            }
                        }
                    }
                    continue;
                },
                // ping / message_start / unknown → 跳过
                else => continue,
            }
        }
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
