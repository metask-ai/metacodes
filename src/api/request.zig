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
};

pub const ToolChoice = struct {
    type: []const u8 = "auto",
    name: ?[]const u8 = null,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
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
                try util_json.serializeString(tr.content, buf, allocator);
                if (tr.is_error) {
                    try buf.appendSlice(allocator, ",\"is_error\":true");
                }
                try buf.append(allocator, '}');
            },
        }
    }
    try buf.append(allocator, ']');
}

fn serializeTools(tools: []const ToolDefinition, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"name\":");
        try util_json.serializeString(tool.name, buf, allocator);
        try buf.appendSlice(allocator, ",\"description\":");
        try util_json.serializeString(tool.description, buf, allocator);
        try buf.appendSlice(allocator, ",\"input_schema\":");
        try serializeInputSchema(tool.input_schema, buf, allocator);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

fn serializeInputSchema(schema: InputSchema, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"type\":");
    try util_json.serializeString(schema.type, buf, allocator);
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

test "serializeMessagesRequest escapes special chars in text" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "line1\nline2\"quoted\"" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"") != null);
}
