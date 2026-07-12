//! MCP (Model Context Protocol) 协议类型 + JSON-RPC 2.0。
//!
//! 简化实现：只覆盖本项目需要的 4 个方法（initialize / tools/list / tools/call / notifications/initialized）。
//! 完整 spec 见 https://spec.modelcontextprotocol.io/。
//!
//! 序列化手写（不用 std.json 的 stringify，以保证字段顺序和精简）；
//! 解析用 std.json.parseFromSlice（MCP server 返回的 JSON 是完整的，不像 SSE partial）。
//!
//! 关键类型：
//! - RequestId：递增 u64（MCP spec 允许 string 或 number；我们统一用 number 简化）
//! - Request：{ jsonrpc: "2.0", id, method, params }
//! - Response：{ jsonrpc: "2.0", id, result | error }
//! - Notification：{ jsonrpc: "2.0", method, params }（无 id）

const std = @import("std");

pub const JSONRPC_VERSION = "2.0";

pub const RequestId = u64;

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    _,
};

pub const RpcError = struct {
    code: i32,
    message: []const u8,
    // data 字段可选，本期不解析
};

/// 序列化：`{"jsonrpc":"2.0","id":<id>,"method":"<method>","params":<params_json>}`
/// params_json 已是合法 JSON（null / object / array）；调用方负责正确构造。
/// owned bytes，caller free。
pub fn serializeRequest(
    allocator: std.mem.Allocator,
    id: RequestId,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"{s}\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
        .{ JSONRPC_VERSION, id, method, params_json },
    );
}

/// 序列化 notification（无 id）。
pub fn serializeNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ JSONRPC_VERSION, method, params_json },
    );
}

/// 序列化对 server→client 请求的成功响应：`{"jsonrpc","id","result":<result_json>}`。
pub fn serializeResult(alloc: std.mem.Allocator, id: RequestId, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"{s}\",\"id\":{d},\"result\":{s}}}", .{ JSONRPC_VERSION, id, result_json });
}

/// 序列化错误响应(如 method_not_found)。message 只用 ASCII 简单文本(不转义)。
pub fn serializeErrorResponse(alloc: std.mem.Allocator, id: RequestId, code: i32, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"{s}\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ JSONRPC_VERSION, id, code, message });
}

/// 取顶层 "method" 字段字符串值(区分 server→client 请求/通知 vs 响应)。null=无 method=响应。
pub fn extractMethod(data: []const u8) ?[]const u8 {
    return extractStringField(data, "method");
}

/// 解析响应：返回 id + result_json slice（借 data）或 error。
/// result_json 是响应中 "result" 对应的完整 JSON（含括号/引号），caller 不得释放。
pub const ParsedResponse = struct {
    id: ?RequestId,
    result_json: ?[]const u8, // 若成功
    err: ?RpcError, // 若失败

    pub fn isSuccess(self: ParsedResponse) bool {
        return self.err == null;
    }
};

/// 最小手写响应解析：找 "id", "result", "error" 字段。
/// 注意：result/error 的 value 是 JSON object（嵌套），用花括号配对找终点。
pub fn parseResponse(data: []const u8) !ParsedResponse {
    const id = parseUintField(data, "id");

    // error 优先：如果有 error 字段，标记失败
    if (findObjectField(data, "error")) |err_obj| {
        const code = parseI32Field(err_obj, "code") orelse 0;
        const message = extractStringField(err_obj, "message") orelse "";
        return .{ .id = id, .result_json = null, .err = .{ .code = code, .message = message } };
    }

    if (findObjectField(data, "result")) |result_obj| {
        return .{ .id = id, .result_json = result_obj, .err = null };
    }

    // 允许 result 是非 object 值（例如 null / string），退化查找
    if (std.mem.indexOf(u8, data, "\"result\":")) |idx| {
        const start = idx + 9;
        return .{ .id = id, .result_json = data[start..], .err = null };
    }

    return error.MalformedResponse;
}

// ----------------------------------------------------------------------
// 辅助：手写 JSON 字段解析（借用 util/json 的能力，但这里要处理嵌套对象）
// ----------------------------------------------------------------------

/// 找 `"field":` 后跟的 object/array JSON 值，用括号配对返回其完整 slice。
/// 返回值包含外层 `{...}`/`[...]`，借 data。
pub fn findObjectField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pattern = buf[0 .. 3 + field.len];

    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var pos = idx + pattern.len;
    while (pos < data.len and data[pos] == ' ') : (pos += 1) {}
    if (pos >= data.len) return null;

    const open = data[pos];
    const close: u8 = switch (open) {
        '{' => '}',
        '[' => ']',
        else => return null,
    };

    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    var i = pos;
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
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return data[pos .. i + 1];
        }
    }
    return null;
}

pub fn parseUintField(data: []const u8, field: []const u8) ?u64 {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pattern = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var start = idx + pattern.len;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    var end = start;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(u64, data[start..end], 10) catch null;
}

fn parseI32Field(data: []const u8, field: []const u8) ?i32 {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pattern = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    var start = idx + pattern.len;
    while (start < data.len and data[start] == ' ') : (start += 1) {}
    var end = start;
    if (end < data.len and data[end] == '-') end += 1;
    while (end < data.len and data[end] >= '0' and data[end] <= '9') : (end += 1) {}
    if (end == start) return null;
    return std.fmt.parseInt(i32, data[start..end], 10) catch null;
}

fn extractStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    buf[3 + field.len] = '"';
    const pattern = buf[0 .. 4 + field.len];
    const idx = std.mem.indexOf(u8, data, pattern) orelse return null;
    const start = idx + pattern.len;
    var end = start;
    while (end < data.len) : (end += 1) {
        if (data[end] == '"' and data[end - 1] != '\\') break;
    }
    return data[start..end];
}

// ============================================================================
// MCP 方法：构造 params
// ============================================================================

/// 构造 initialize 请求的 params（最小：protocolVersion + capabilities + clientInfo）
pub fn initializeParams(allocator: std.mem.Allocator) ![]u8 {
    // 声明 client 支持 elicitation(server 据此才会发 elicitation/create;client.handleServerRequest 应答)。
    // protocolVersion 用 2025-06-18(elicitation 引入的版本)——与所声明的 elicitation capability 一致
    // (旧的 2024-11-05 无 elicitation,两者矛盾;server 会协商降级到它支持的版本)。
    return try std.fmt.allocPrint(allocator,
        \\{{"protocolVersion":"2025-06-18","capabilities":{{"elicitation":{{}}}},"clientInfo":{{"name":"cc-zig","version":"0.1.0"}}}}
    , .{});
}

/// tools/list 无参数
pub const EMPTY_PARAMS = "{}";

/// 构造 tools/call 的 params
pub fn callToolParams(allocator: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"name":"{s}","arguments":{s}}}
    , .{ tool_name, arguments_json });
}

/// 构造 resources/read 的 params（uri 需 JSON 转义）。
pub fn readResourceParams(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"uri\":");
    try std.json.Stringify.encodeJsonString(uri, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "serializeRequest basic" {
    const r = try serializeRequest(testing.allocator, 1, "initialize", "{}");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
        r,
    );
}

test "serializeNotification no id" {
    const r = try serializeNotification(testing.allocator, "initialized", "{}");
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\"id\"") == null);
    try testing.expect(std.mem.indexOf(u8, r, "initialized") != null);
}

test "parseResponse success" {
    const data = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}";
    const resp = try parseResponse(data);
    try testing.expect(resp.isSuccess());
    try testing.expect(resp.id.? == 1);
    try testing.expect(std.mem.indexOf(u8, resp.result_json.?, "tools") != null);
}

test "parseResponse error" {
    const data = "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}";
    const resp = try parseResponse(data);
    try testing.expect(!resp.isSuccess());
    try testing.expect(resp.id.? == 2);
    try testing.expect(resp.err.?.code == -32601);
    try testing.expectEqualStrings("Method not found", resp.err.?.message);
}

test "parseResponse null result" {
    const data = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}";
    const resp = try parseResponse(data);
    try testing.expect(resp.isSuccess());
    try testing.expect(resp.id.? == 3);
}

test "findObjectField nested object" {
    const data = "{\"a\":1,\"b\":{\"nested\":{\"x\":1}},\"c\":2}";
    const b = findObjectField(data, "b").?;
    try testing.expectEqualStrings("{\"nested\":{\"x\":1}}", b);
}

test "findObjectField array value" {
    const data = "{\"items\":[1,2,3]}";
    try testing.expectEqualStrings("[1,2,3]", findObjectField(data, "items").?);
}

test "findObjectField missing" {
    try testing.expect(findObjectField("{\"a\":1}", "missing") == null);
}

test "findObjectField handles escapes in strings" {
    const data = "{\"text\":\"has \\\"quotes\\\"\",\"result\":{\"ok\":true}}";
    const r = findObjectField(data, "result").?;
    try testing.expectEqualStrings("{\"ok\":true}", r);
}

test "initializeParams structure" {
    const p = try initializeParams(testing.allocator);
    defer testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, p, "protocolVersion") != null);
    try testing.expect(std.mem.indexOf(u8, p, "clientInfo") != null);
}

test "callToolParams structure" {
    const p = try callToolParams(testing.allocator, "Read", "{\"path\":\"/x\"}");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("{\"name\":\"Read\",\"arguments\":{\"path\":\"/x\"}}", p);
}

test "readResourceParams escapes uri" {
    const p = try readResourceParams(testing.allocator, "file:///a/b.txt");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("{\"uri\":\"file:///a/b.txt\"}", p);
}
