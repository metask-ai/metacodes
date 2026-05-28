const std = @import("std");
const types = @import("../types.zig");
const util_json = @import("../util/json.zig");

/// Anthropic Messages API 请求体。
pub const MessagesRequest = struct {
    model: []const u8,
    /// 默认 16384（2^14）。Sonnet 4 支持到 64K，但多数回答用不到这么多。
    /// 上次默认 4096 太小：一次详细的项目解释就会触发 max_tokens stop_reason 截断。
    max_tokens: u32 = 16384,
    messages: []const types.ApiMessage,
    system: ?[]const u8 = null,
    stream: bool = false,
    tools: ?[]const ToolDefinition = null,
    tool_choice: ?ToolChoice = null,
    /// Prompt caching：顶层 cache_control 自动缓存"最后一个可缓存 block"——
    /// 在常见用法下（稳定的 system + tools + 变化的 conversation）会把 tools + system
    /// 一起写 cache。后续请求只要 prefix（tools + system）字节相同就 read cache，
    /// 约省 70-90% 输入 token 费用 + 显著降低延迟。
    ///
    /// 默认开启：对绝大多数 coding agent 用例都是净收益。
    /// 禁用场景：system 或 tools 每次请求都变（模型不会碰到——本客户端 tools 注册表静态、
    /// system 在 session 生命周期不变）。
    ///
    /// 关键前提：prefix 不能含时间戳/UUID 等易变内容。本客户端的 system prompt 和
    /// tool schema 都是常量，天然满足。
    cache_control: ?CacheControl = .{ .type = "ephemeral" },
};

pub const CacheControl = struct {
    type: []const u8 = "ephemeral",
    /// 可选 TTL："5m"（默认）或 "1h"。1h 写入成本 2x（vs 5m 的 1.25x），
    /// 但跨长间隔仍可读——适合低频请求。默认 null = 5m。
    ttl: ?[]const u8 = null,
};

pub const ToolChoice = struct {
    type: []const u8 = "auto",
    name: ?[]const u8 = null,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
    /// Anthropic server tools（web_search_20250305 / code_execution_20250825 等）需要
    /// 在 JSON 里输出 "type" 字段，而不带 description/input_schema。非 null 时切换到
    /// server-tool 序列化路径。
    server_type: ?[]const u8 = null,
};

pub const InputSchema = struct {
    type: []const u8 = "object",
    properties: ?std.json.ObjectMap = null,
    required: ?[]const []const u8 = null,
};

/// 序列化请求为 JSON 字节串。调用方 free。
pub fn serializeMessagesRequest(req: MessagesRequest, allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"model\":");
    try util_json.serializeString(req.model, &result, allocator);

    try result.appendSlice(allocator, ",\"max_tokens\":");
    const mt = try std.fmt.allocPrint(allocator, "{d}", .{req.max_tokens});
    defer allocator.free(mt);
    try result.appendSlice(allocator, mt);

    try result.appendSlice(allocator, ",\"messages\":");
    try serializeMessages(req.messages, &result, allocator);

    if (req.system) |s| {
        try result.appendSlice(allocator, ",\"system\":");
        try util_json.serializeString(s, &result, allocator);
    }

    try result.appendSlice(allocator, ",\"stream\":");
    try result.appendSlice(allocator, if (req.stream) "true" else "false");

    if (req.tools) |tools| {
        try result.appendSlice(allocator, ",\"tools\":");
        try serializeTools(tools, &result, allocator);
    }

    if (req.cache_control) |cc| {
        try result.appendSlice(allocator, ",\"cache_control\":{\"type\":");
        try util_json.serializeString(cc.type, &result, allocator);
        if (cc.ttl) |ttl| {
            try result.appendSlice(allocator, ",\"ttl\":");
            try util_json.serializeString(ttl, &result, allocator);
        }
        try result.append(allocator, '}');
    }

    try result.append(allocator, '}');
    return try result.toOwnedSlice(allocator);
}

fn serializeMessages(messages: []const types.ApiMessage, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"role\":");
        try util_json.serializeString(switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
        }, buf, allocator);
        try buf.appendSlice(allocator, ",\"content\":");
        try serializeContent(msg.content, buf, allocator);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

fn serializeContent(content: []const types.ApiContent, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '[');
    for (content, 0..) |block, i| {
        if (i > 0) try buf.append(allocator, ',');
        switch (block) {
            .text => |t| {
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"text\",\"text\":");
                try util_json.serializeString(t, buf, allocator);
                try buf.append(allocator, '}');
            },
            .tool_use => |tu| {
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"tool_use\",\"id\":");
                try util_json.serializeString(tu.id, buf, allocator);
                try buf.appendSlice(allocator, ",\"name\":");
                try util_json.serializeString(tu.name, buf, allocator);
                try buf.appendSlice(allocator, ",\"input\":");
                try buf.appendSlice(allocator, tu.input);
                try buf.append(allocator, '}');
            },
            .tool_result => |tr| {
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"tool_result\",\"tool_use_id\":");
                try util_json.serializeString(tr.tool_use_id, buf, allocator);
                try buf.appendSlice(allocator, ",\"content\":");
                // 图像结果：Read 工具返回 {"type":"image","media_type":..,"data":..}
                // → 发成 content block 数组 [{"type":"image","source":{"type":"base64",...}}]
                if (extractImageResult(tr.content)) |img| {
                    try buf.appendSlice(allocator, "[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
                    try util_json.serializeString(img.media_type, buf, allocator);
                    try buf.appendSlice(allocator, ",\"data\":");
                    try util_json.serializeString(img.data, buf, allocator);
                    try buf.appendSlice(allocator, "}}]");
                } else {
                    try util_json.serializeString(tr.content, buf, allocator);
                }
                if (tr.is_error) {
                    try buf.appendSlice(allocator, ",\"is_error\":true");
                }
                try buf.append(allocator, '}');
            },
        }
    }
    try buf.append(allocator, ']');
}

const ImageResult = struct { media_type: []const u8, data: []const u8 };

/// 检测 tool_result content 是否为 Read 工具的图像形态。
/// 仅当以 `{"type":"image"` 开头且含 media_type + data 字段时返回；否则 null（当文本处理）。
/// 返回的 slice 借用 content 内部字节（未 unescape）——base64/media_type 无需转义，直接透传。
fn extractImageResult(content: []const u8) ?ImageResult {
    const trimmed = std.mem.trimStart(u8, content, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "{\"type\":\"image\"")) return null;
    const mt = util_json.extractStringField(trimmed, "media_type") orelse return null;
    const data = util_json.extractStringField(trimmed, "data") orelse return null;
    return .{ .media_type = mt, .data = data };
}

fn serializeTools(tools: []const ToolDefinition, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        if (tool.server_type) |st| {
            // Server tool 形态：{"type":"web_search_20250305","name":"web_search"}
            try buf.appendSlice(allocator, "\"type\":");
            try util_json.serializeString(st, buf, allocator);
            try buf.appendSlice(allocator, ",\"name\":");
            try util_json.serializeString(tool.name, buf, allocator);
        } else {
            try buf.appendSlice(allocator, "\"name\":");
            try util_json.serializeString(tool.name, buf, allocator);
            try buf.appendSlice(allocator, ",\"description\":");
            try util_json.serializeString(tool.description, buf, allocator);
            try buf.appendSlice(allocator, ",\"input_schema\":");
            try serializeInputSchema(tool.input_schema, buf, allocator);
        }
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

fn serializeInputSchema(schema: InputSchema, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"type\":");
    try util_json.serializeString(schema.type, buf, allocator);
    // OpenAI-compat JSON Schema 校验器要求 object schema **总是**带 "properties"。
    // Anthropic native API 对 null properties 是宽容的，但 napi.origintask.cn 这类兼容
    // 层会返 400 "object schema missing properties"。无参数工具序列化为 "properties":{}
    // 才能两边都接受。
    if (schema.properties) |props| {
        try buf.appendSlice(allocator, ",\"properties\":{");
        var first = true;
        var it = props.iterator();
        while (it.next()) |entry| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try util_json.serializeString(entry.key_ptr.*, buf, allocator);
            try buf.append(allocator, ':');
            try serializeJsonValue(entry.value_ptr.*, buf, allocator);
        }
        try buf.append(allocator, '}');
    } else {
        try buf.appendSlice(allocator, ",\"properties\":{}");
    }
    if (schema.required) |req| {
        try buf.appendSlice(allocator, ",\"required\":[");
        for (req, 0..) |r, i| {
            if (i > 0) try buf.append(allocator, ',');
            try util_json.serializeString(r, buf, allocator);
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

fn serializeJsonValue(value: std.json.Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| try util_json.serializeString(s, buf, allocator),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try serializeJsonValue(item, buf, allocator);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try util_json.serializeString(entry.key_ptr.*, buf, allocator);
                try buf.append(allocator, ':');
                try serializeJsonValue(entry.value_ptr.*, buf, allocator);
            }
            try buf.append(allocator, '}');
        },
    }
}

test "serializeMessagesRequest minimal" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "claude-x", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "serializeMessagesRequest with system prompt" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "claude-x", .messages = &.{msg}, .system = "You are X." };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"You are X.\"") != null);
}

test "serializeMessagesRequest with stream=true" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg}, .stream = true };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "serializeMessagesRequest with tool_use content" {
    const msg = types.ApiMessage{
        .role = .assistant,
        .content = &.{.{ .tool_use = .{
            .id = "t1",
            .name = "Read",
            .input = "{\"path\":\"/x\"}",
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"Read\"") != null);
}

test "serializeMessagesRequest with tool_result content" {
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "ok",
            .is_error = false,
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\"") == null); // false 不输出
}

test "serializeMessagesRequest with tool_result is_error=true" {
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "err",
            .is_error = true,
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
}

test "serializeMessagesRequest with image tool_result emits content block array" {
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"iVBORw==\"}",
            .is_error = false,
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":{\"type\":\"base64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"data\":\"iVBORw==\"") != null);
}

test "extractImageResult ignores plain text" {
    try std.testing.expect(extractImageResult("just text") == null);
    try std.testing.expect(extractImageResult("{\"stdout\":\"x\"}") == null);
    const img = extractImageResult("{\"type\":\"image\",\"media_type\":\"image/gif\",\"data\":\"AAAA\"}").?;
    try std.testing.expectEqualStrings("image/gif", img.media_type);
    try std.testing.expectEqualStrings("AAAA", img.data);
}

test "serializeMessagesRequest escapes special chars in text" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "line1\nline2\"quoted\"" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"") != null);
}

test "serializeMessagesRequest includes cache_control by default" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}

test "serializeMessagesRequest cache_control with ttl" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{
        .model = "m",
        .messages = &.{msg},
        .cache_control = .{ .type = "ephemeral", .ttl = "1h" },
    };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ttl\":\"1h\"") != null);
}

test "serializeMessagesRequest no cache_control when disabled" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg}, .cache_control = null };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
}

test "serializeInputSchema emits empty properties for zero-arg tool" {
    // Regression: OpenAI-compat layers (napi.origintask.cn 等) 对缺失 "properties" 的 object
    // schema 返 HTTP 400 "object schema missing properties"。本测试锁定行为：
    // 即便 properties=null（无命名参数），序列化输出也要带 "properties":{}。
    const schema = InputSchema{ .type = "object", .properties = null, .required = &.{} };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(schema, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\":{}") != null);
}

test "serializeInputSchema with required fields still emits properties" {
    // 另一个常见 case：required=["taskId"] 但我们的 InputSchema 没定义
    // properties map。OpenAI 兼容层对这种"声明 required 字段但没在 properties 里"本来
    // 就会抱怨——那是另一个 bug；这里至少保证 properties 字段存在，不漏出 schema-missing
    // properties 的 400。
    const schema = InputSchema{ .type = "object", .properties = null, .required = &.{"taskId"} };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(schema, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"required\":[\"taskId\"]") != null);
}
