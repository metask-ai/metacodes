//! LSP JSON-RPC 2.0 信封构造 + 分类(对齐 hermes protocol.py 的 envelope/classify;帧在 transport.zig)。
//!
//! 消息三类:request(有 id + method)/ response(有 id + result|error)/ notification(有 method 无 id)。
//! 构造侧:makeRequest/makeNotification(params 是**已序列化的 JSON 片段**,调用方拼好)。method 名是
//! LSP 固定 ASCII 字面量(如 "textDocument/didChange"),无需 JSON 转义,直接加引号。
//! 解析侧:classify(std.json.Value)→ 判类别 + 抽 id/method,client reader 据此路由。
const std = @import("std");

/// LSP/JSON-RPC 错误码(client 需识别的)。
pub const ERROR_CONTENT_MODIFIED: i64 = -32801; // 文档在处理中被改 → 重试
pub const ERROR_REQUEST_CANCELLED: i64 = -32800;
pub const ERROR_METHOD_NOT_FOUND: i64 = -32601;

pub const Kind = enum { request, response, notification, invalid };

pub const Classified = struct {
    kind: Kind,
    id: ?i64 = null, // request/response 的 id(我们自己只发整数 id)
    method: ?[]const u8 = null, // request/notification 的 method(借 Value 内存)
    has_error: bool = false, // response 是否带 error
};

/// 构造 request:`{"jsonrpc":"2.0","id":<id>,"method":"<method>","params":<params_json>}`。
/// params_json 是已序列化 JSON(对象/数组);传 null → 省略 params。owned。
pub fn makeRequest(alloc: std.mem.Allocator, id: i64, method: []const u8, params_json: ?[]const u8) ![]u8 {
    if (params_json) |p| {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, p });
    }
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\"}}", .{ id, method });
}

/// 构造 notification:`{"jsonrpc":"2.0","method":"<method>","params":<params_json>}`。owned。
pub fn makeNotification(alloc: std.mem.Allocator, method: []const u8, params_json: ?[]const u8) ![]u8 {
    if (params_json) |p| {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, p });
    }
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\"}}", .{method});
}

/// 构造 method-not-found 错误响应(server→client 请求我们不支持时回它;passive 模式几乎不用)。owned。
pub fn makeMethodNotFound(alloc: std.mem.Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"method not found\"}}}}", .{id});
}

/// 分类一条已解析的 JSON-RPC 消息。结构决定类别(容忍 jsonrpc 字段缺失,有 server 不严格)。
pub fn classify(root: std.json.Value) Classified {
    if (root != .object) return .{ .kind = .invalid };
    const obj = root.object;
    const id_v = obj.get("id");
    const has_id = id_v != null and id_v.? != .null;
    const method_v = obj.get("method");
    const has_method = method_v != null and method_v.? == .string;
    const has_result = obj.get("result") != null;
    const err_v = obj.get("error");
    const has_err = err_v != null and err_v.? != .null;

    const id: ?i64 = if (id_v) |v| (if (v == .integer) v.integer else null) else null;
    const method: ?[]const u8 = if (has_method) method_v.?.string else null;

    if (has_method and has_id) return .{ .kind = .request, .id = id, .method = method };
    if (has_method and !has_id) return .{ .kind = .notification, .method = method };
    if (has_id and (has_result or has_err)) return .{ .kind = .response, .id = id, .has_error = has_err };
    return .{ .kind = .invalid };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "makeRequest / makeNotification 结构正确" {
    const a = testing.allocator;
    const r = try makeRequest(a, 7, "initialize", "{\"rootUri\":\"file:///x\"}");
    defer a.free(r);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{\"rootUri\":\"file:///x\"}}", r);

    const r2 = try makeRequest(a, 1, "shutdown", null);
    defer a.free(r2);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"shutdown\"}", r2);

    const n = try makeNotification(a, "initialized", "{}");
    defer a.free(n);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}", n);
}

test "classify: request / response / notification / invalid" {
    const a = testing.allocator;
    const cases = [_]struct { json: []const u8, kind: Kind }{
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"foo\"}", .kind = .request },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", .kind = .response },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601}}", .kind = .response },
        .{ .json = "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{}}", .kind = .notification },
        .{ .json = "{\"foo\":1}", .kind = .invalid },
    };
    for (cases) |c| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, c.json, .{});
        defer parsed.deinit();
        try testing.expectEqual(c.kind, classify(parsed.value).kind);
    }
}

test "classify: 抽 id/method/has_error" {
    const a = testing.allocator;
    {
        var p = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":42,\"result\":{}}", .{});
        defer p.deinit();
        const c = classify(p.value);
        try testing.expectEqual(Kind.response, c.kind);
        try testing.expectEqual(@as(?i64, 42), c.id);
        try testing.expect(!c.has_error);
    }
    {
        var p = try std.json.parseFromSlice(std.json.Value, a, "{\"id\":5,\"error\":{\"code\":-32801}}", .{});
        defer p.deinit();
        const c = classify(p.value);
        try testing.expect(c.has_error);
    }
    {
        var p = try std.json.parseFromSlice(std.json.Value, a, "{\"method\":\"x/y\",\"params\":{}}", .{});
        defer p.deinit();
        const c = classify(p.value);
        try testing.expectEqual(Kind.notification, c.kind);
        try testing.expectEqualStrings("x/y", c.method.?);
    }
}
