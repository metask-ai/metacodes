//! The MCP protocol namespace, and the JSON-RPC frames the client writes by hand:
//! notifications, replies to server requests, and method params. Responses are
//! read by `wire.zig` under a conformance; requests are encoded by `wire.encodeRequest`.

const std = @import("std");
const json_util = @import("../util/json.zig");

pub const canonical = @import("canonical.zig");
pub const wire = @import("wire.zig");
pub const modern = @import("era_modern.zig");
pub const classic = @import("era_classic.zig");
pub const negotiation = @import("negotiation.zig");
pub const schema = @import("schema.zig");
pub const result_stream = @import("result_stream.zig");
pub const client = @import("client.zig");
pub const host_transport = @import("host_transport.zig");
pub const runtime = @import("runtime.zig");
pub const instance_pool = @import("instance_pool.zig");
pub const catalog = @import("catalog.zig");

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

/// 序列化 notification（无 id）。
pub fn serializeNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"{s}\",\"method\":", .{JSONRPC_VERSION});
    try json_util.writeJsonString(&out.writer, method);
    try out.writer.print(",\"params\":{s}}}", .{params_json});
    return out.toOwnedSlice();
}

/// 序列化对 server→client 请求的成功响应：`{"jsonrpc","id","result":<result_json>}`。
pub fn serializeResult(alloc: std.mem.Allocator, id: RequestId, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"{s}\",\"id\":{d},\"result\":{s}}}", .{ JSONRPC_VERSION, id, result_json });
}

/// 序列化错误响应(如 method_not_found)。message 只用 ASCII 简单文本(不转义)。
pub fn serializeErrorResponse(alloc: std.mem.Allocator, id: RequestId, code: i32, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"{s}\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":", .{ JSONRPC_VERSION, id, code });
    try json_util.writeJsonString(&out.writer, message);
    try out.writer.writeAll("}}}");
    return out.toOwnedSlice();
}

/// tools/list 无参数
pub const EMPTY_PARAMS = "{}";

/// 构造 tools/call 的 params
pub fn callToolParams(allocator: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) ![]u8 {
    // `params` must hold one JSON object, not just parse: `arguments` is an object.
    const trimmed = std.mem.trim(u8, arguments_json, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return error.McpInvalidParams;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"name\":");
    try json_util.writeJsonString(&out.writer, tool_name);
    try out.writer.print(",\"arguments\":{s}}}", .{arguments_json});
    return out.toOwnedSlice();
}

/// 构造 resources/read 的 params（uri 需 JSON 转义）。
pub fn readResourceParams(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"uri\":");
    try json_util.writeJsonString(&out.writer, uri);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "serializeNotification no id" {
    const r = try serializeNotification(testing.allocator, "initialized", "{}");
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\"id\"") == null);
    try testing.expect(std.mem.indexOf(u8, r, "initialized") != null);
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

test "dual era tool catalogs project the same executable identity" {
    const modern_response =
        "{\"jsonrpc\":\"2.0\",\"id\":21,\"result\":{" ++
        "\"resultType\":\"complete\",\"ttlMs\":10,\"cacheScope\":\"private\"," ++
        "\"tools\":[{\"name\":\"weather\",\"description\":\"Forecast\"," ++
        "\"inputSchema\":{\"properties\":{\"city\":{\"type\":\"string\"}},\"type\":\"object\"}," ++
        "\"outputSchema\":{\"properties\":{\"temp\":{\"type\":\"number\"}},\"type\":\"object\"}}]}}";
    const legacy_response =
        "{\"jsonrpc\":\"2.0\",\"id\":22,\"result\":{" ++
        "\"tools\":[{\"name\":\"weather\",\"description\":\"Forecast\"," ++
        "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}," ++
        "\"outputSchema\":{\"type\":\"object\",\"properties\":{\"temp\":{\"type\":\"number\"}}}}]}}";
    const binding = [_]u8{9} ** 32;
    const modern_parsed = try modern.parseListToolsResponse(
        std.testing.allocator,
        modern_response,
        21,
        binding,
        .{},
    );
    var modern_catalog = switch (modern_parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer modern_catalog.deinit();
    const legacy_parsed = try classic.parseListToolsResponse(
        std.testing.allocator,
        legacy_response,
        22,
        classic.ClassicProfile.forEra(.classic_2025_11_25).?,
        binding,
        .{},
    );
    var legacy_catalog = switch (legacy_parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer legacy_catalog.deinit();
    try std.testing.expectEqualStrings(
        modern_catalog.tools[0].identity.name,
        legacy_catalog.tools[0].identity.name,
    );
    try std.testing.expectEqualSlices(
        u8,
        &modern_catalog.tools[0].identity.schema_fingerprint,
        &legacy_catalog.tools[0].identity.schema_fingerprint,
    );
    try std.testing.expectEqualSlices(
        u8,
        &modern_catalog.tools[0].identity.authorityBinding(),
        &legacy_catalog.tools[0].identity.authorityBinding(),
    );
}

test "dual era complete call results expose identical canonical content" {
    const modern_response =
        "{\"jsonrpc\":\"2.0\",\"id\":31,\"result\":{" ++
        "\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]," ++
        "\"structuredContent\":{\"temp\":20},\"isError\":false}}";
    const legacy_response =
        "{\"jsonrpc\":\"2.0\",\"id\":32,\"result\":{" ++
        "\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]," ++
        "\"structuredContent\":{\"temp\":20},\"isError\":false}}";
    const modern_parsed = try modern.parseCallToolResponse(
        std.testing.allocator,
        modern_response,
        31,
        .{},
    );
    var modern_result = switch (modern_parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer modern_result.deinit();
    const legacy_parsed = try classic.parseCallToolResponse(
        std.testing.allocator,
        legacy_response,
        32,
        classic.ClassicProfile.forEra(.classic_2025_11_25).?,
        .{},
    );
    var legacy_result = switch (legacy_parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer legacy_result.deinit();
    try std.testing.expectEqualStrings(modern_result.content_json, legacy_result.content_json);
    try std.testing.expectEqualStrings(
        modern_result.structured_content_json.?,
        legacy_result.structured_content_json.?,
    );
    try std.testing.expectEqual(modern_result.is_error, legacy_result.is_error);
}

test "modern discovery is cacheable and selects modern from the supported window" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":40,\"result\":{" ++
        "\"resultType\":\"complete\",\"ttlMs\":250.5,\"cacheScope\":\"public\"," ++
        "\"supportedVersions\":[\"2025-11-25\",\"2026-07-28\"],\"capabilities\":{\"tools\":{}}," ++
        "\"instructions\":\"Use carefully\",\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"demo\",\"version\":\"1\"}}}}";
    const parsed = try modern.parseDiscoverResponse(std.testing.allocator, response, 40, .{});
    var handshake = switch (parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer handshake.deinit();
    try std.testing.expectEqual(@as(f64, 250.5), handshake.cache.ttl_ms.?);
    try std.testing.expectEqual(canonical.CacheScope.public, handshake.cache.scope);
    try std.testing.expect(handshake.server_info_json != null);
    try std.testing.expectEqual(
        canonical.Era.modern_2026_07_28,
        negotiation.selectFromVersions(.auto, handshake.supported_versions).value,
    );
}

test "malformed input required is not hidden by unsupported MRTR status" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"result\":{" ++
        "\"resultType\":\"input_required\",\"inputRequests\":{\"x\":{" ++
        "\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"unknown/request\",\"params\":{}}}}}";
    const parsed = try modern.parseCallToolResponse(std.testing.allocator, response, 41, .{});
    try std.testing.expectEqual(canonical.DiagnosticCode.invalid_field, parsed.diagnostic.code);
}

test "catalog bounds fail closed before authority is created" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":50,\"result\":{" ++
        "\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\"," ++
        "\"tools\":[{\"name\":\"one\",\"inputSchema\":{\"type\":\"object\"}}," ++
        "{\"name\":\"two\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const parsed = try modern.parseListToolsResponse(
        std.testing.allocator,
        response,
        50,
        [_]u8{1} ** 32,
        .{ .max_tools = 1 },
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.resource_limit, parsed.diagnostic.code);
}

test "duplicate tool names are rejected in both eras" {
    const modern_response =
        "{\"jsonrpc\":\"2.0\",\"id\":51,\"result\":{" ++
        "\"resultType\":\"complete\",\"ttlMs\":0,\"cacheScope\":\"private\"," ++
        "\"tools\":[{\"name\":\"dup\",\"inputSchema\":{\"type\":\"object\"}}," ++
        "{\"name\":\"dup\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const parsed = try modern.parseListToolsResponse(
        std.testing.allocator,
        modern_response,
        51,
        [_]u8{1} ** 32,
        .{},
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.duplicate_tool, parsed.diagnostic.code);

    const classic_response =
        "{\"jsonrpc\":\"2.0\",\"id\":52,\"result\":{" ++
        "\"tools\":[{\"name\":\"dup\",\"inputSchema\":{\"type\":\"object\"}}," ++
        "{\"name\":\"dup\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const classic_parsed = try classic.parseListToolsResponse(
        std.testing.allocator,
        classic_response,
        52,
        classic.ClassicProfile.forEra(.classic_2025_06_18).?,
        [_]u8{2} ** 32,
        .{},
    );
    try std.testing.expectEqual(
        canonical.DiagnosticCode.duplicate_tool,
        classic_parsed.diagnostic.code,
    );
}
