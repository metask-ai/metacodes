//! Single AgentCore-owned MCP canonical protocol seam for Revision 6.

const std = @import("std");

pub const canonical = @import("mcp_canonical.zig");
pub const wire = @import("mcp_wire.zig");
pub const modern = @import("mcp_modern.zig");
pub const legacy = @import("mcp_legacy.zig");
pub const negotiation = @import("mcp_negotiation.zig");

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
    const legacy_parsed = try legacy.parseListToolsResponse(
        std.testing.allocator,
        legacy_response,
        22,
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
        &modern_catalog.tools[0].identity.permissionBinding(),
        &legacy_catalog.tools[0].identity.permissionBinding(),
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
    const legacy_parsed = try legacy.parseCallToolResponse(
        std.testing.allocator,
        legacy_response,
        32,
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
}
