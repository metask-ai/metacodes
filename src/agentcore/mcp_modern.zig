//! MCP 2026-07-28 adapter for AgentCore Revision 6.

const std = @import("std");
const canonical = @import("mcp_canonical.zig");
const wire = @import("mcp_wire.zig");

const EmptyCapabilities = struct {};
const ImplementationDto = struct {
    name: []const u8,
    version: []const u8,
};
const RequestMetaDto = struct {
    @"io.modelcontextprotocol/protocolVersion": []const u8,
    @"io.modelcontextprotocol/clientInfo": ImplementationDto,
    @"io.modelcontextprotocol/clientCapabilities": EmptyCapabilities = .{},
};
const BaseParamsDto = struct {
    _meta: RequestMetaDto,
};
const CursorParamsDto = struct {
    _meta: RequestMetaDto,
    cursor: []const u8,
};
const CallParamsDto = struct {
    _meta: RequestMetaDto,
    name: []const u8,
    arguments: std.json.Value,
};

pub fn encodeDiscoverRequest(
    allocator: std.mem.Allocator,
    id: u64,
    client: wire.ClientInfo,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    try client.validate(limits);
    return stringify(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .id = id,
        .method = "server/discover",
        .params = BaseParamsDto{ ._meta = requestMeta(client) },
    });
}

pub fn encodeListToolsRequest(
    allocator: std.mem.Allocator,
    id: u64,
    client: wire.ClientInfo,
    cursor: ?[]const u8,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    try client.validate(limits);
    if (cursor) |value| {
        try canonical.validateText(value, limits.max_cursor_bytes);
        return stringify(allocator, .{
            .jsonrpc = wire.JSON_RPC_VERSION,
            .id = id,
            .method = "tools/list",
            .params = CursorParamsDto{
                ._meta = requestMeta(client),
                .cursor = value,
            },
        });
    }
    return stringify(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .id = id,
        .method = "tools/list",
        .params = BaseParamsDto{ ._meta = requestMeta(client) },
    });
}

pub fn encodeCallToolRequest(
    allocator: std.mem.Allocator,
    id: u64,
    client: wire.ClientInfo,
    name: []const u8,
    arguments_json: []const u8,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    try client.validate(limits);
    try canonical.validateToolName(name, limits);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arguments = try wire.parseArguments(scratch.allocator(), arguments_json, limits);
    return stringify(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .id = id,
        .method = "tools/call",
        .params = CallParamsDto{
            ._meta = requestMeta(client),
            .name = name,
            .arguments = arguments,
        },
    });
}

pub fn parseDiscoverResponse(
    backing: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(canonical.OwnedHandshake) {
    var owned = canonical.OwnedHandshake.init(backing, .modern_2026_07_28);
    const allocator = owned.allocator();
    const envelope = try wire.parseEnvelope(allocator, encoded, expected_id, .discovery, limits);
    const result = switch (envelope) {
        .diagnostic => |diagnostic| {
            owned.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .value => |value| value,
    };
    if (wire.validateCompleteResult(result, .modern_2026_07_28, .discovery, limits)) |diagnostic| {
        owned.deinit();
        return .{ .diagnostic = diagnostic };
    }

    const versions_value = result.object.get("supportedVersions") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .discovery) };
    };
    const capabilities = result.object.get("capabilities") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .discovery) };
    };
    if (versions_value != .array or capabilities != .object or
        versions_value.array.items.len == 0 or
        versions_value.array.items.len > limits.max_versions)
    {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
    }
    const versions = allocator.alloc([]const u8, versions_value.array.items.len) catch {
        owned.deinit();
        return error.OutOfMemory;
    };
    for (versions_value.array.items, 0..) |version, index| {
        if (version != .string or version.string.len == 0 or
            version.string.len > limits.max_text_bytes)
        {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
        }
        canonical.validateText(version.string, limits.max_text_bytes) catch {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
        };
        for (versions[0..index]) |existing| {
            if (std.mem.eql(u8, existing, version.string)) {
                owned.deinit();
                return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
            }
        }
        versions[index] = version.string;
    }
    owned.supported_versions = versions;
    owned.capabilities_json = canonical.encodeValue(allocator, capabilities, limits.max_text_bytes) catch |err| {
        const diagnostic = mapCanonical(err, .discovery);
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = diagnostic };
    };
    owned.instructions = canonical.optionalText(result.object, "instructions", limits.max_text_bytes) catch {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
    };
    parseOptionalCache(result, &owned.cache) catch {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
    };
    if (result.object.get("_meta")) |meta| {
        if (meta != .object) {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
        }
        if (meta.object.get("io.modelcontextprotocol/serverInfo")) |server_info| {
            if (server_info != .object) {
                owned.deinit();
                return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .discovery) };
            }
            owned.server_info_json = canonical.encodeValue(allocator, server_info, limits.max_text_bytes) catch |err| {
                owned.deinit();
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return .{ .diagnostic = mapCanonical(err, .discovery) };
            };
        }
    }
    return .{ .value = owned };
}

pub fn parseListToolsResponse(
    backing: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    server_binding_identity: [32]u8,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(canonical.OwnedCatalog) {
    var owned = canonical.OwnedCatalog.init(backing, .modern_2026_07_28);
    const allocator = owned.allocator();
    const envelope = try wire.parseEnvelope(allocator, encoded, expected_id, .tools_list, limits);
    const result = switch (envelope) {
        .diagnostic => |diagnostic| {
            owned.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .value => |value| value,
    };
    if (wire.validateCompleteResult(result, .modern_2026_07_28, .tools_list, limits)) |diagnostic| {
        owned.deinit();
        return .{ .diagnostic = diagnostic };
    }
    const tools_value = result.object.get("tools") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .tools_list) };
    };
    if (tools_value != .array or tools_value.array.items.len > limits.max_tools) {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.resource_limit, .tools_list) };
    }
    const tools = allocator.alloc(canonical.Tool, tools_value.array.items.len) catch {
        owned.deinit();
        return error.OutOfMemory;
    };
    for (tools_value.array.items, 0..) |tool_value, index| {
        tools[index] = canonical.projectTool(
            allocator,
            tool_value,
            .modern_2026_07_28,
            server_binding_identity,
            limits,
        ) catch |err| {
            owned.deinit();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = mapCanonical(err, .tools_list) };
        };
        for (tools[0..index]) |existing| {
            if (std.mem.eql(u8, existing.identity.name, tools[index].identity.name)) {
                owned.deinit();
                return .{ .diagnostic = canonical.Diagnostic.init(.duplicate_tool, .tools_list) };
            }
        }
    }
    owned.tools = tools;
    owned.next_cursor = canonical.optionalText(result.object, "nextCursor", limits.max_cursor_bytes) catch {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_list) };
    };
    owned.meta_json = canonical.optionalObjectJson(allocator, result.object, "_meta", limits.max_text_bytes) catch |err| {
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = mapCanonical(err, .tools_list) };
    };
    parseCache(result, &owned.cache) catch {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_list) };
    };
    return .{ .value = owned };
}

pub fn parseCallToolResponse(
    backing: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(canonical.OwnedCallResult) {
    var owned = canonical.OwnedCallResult.init(backing, .modern_2026_07_28);
    const allocator = owned.allocator();
    const envelope = try wire.parseEnvelope(allocator, encoded, expected_id, .tools_call, limits);
    const result = switch (envelope) {
        .diagnostic => |diagnostic| {
            owned.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .value => |value| value,
    };
    if (wire.validateCompleteResult(result, .modern_2026_07_28, .tools_call, limits)) |diagnostic| {
        owned.deinit();
        return .{ .diagnostic = diagnostic };
    }
    const content = result.object.get("content") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .tools_call) };
    };
    if (content != .array) {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) };
    }
    owned.content_json = canonical.encodeValue(allocator, content, limits.max_frame_bytes) catch |err| {
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = mapCanonical(err, .tools_call) };
    };
    if (result.object.get("structuredContent")) |structured| {
        owned.structured_content_json = canonical.encodeValue(allocator, structured, limits.max_frame_bytes) catch |err| {
            owned.deinit();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = mapCanonical(err, .tools_call) };
        };
    }
    if (result.object.get("isError")) |is_error| {
        if (is_error != .bool) {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) };
        }
        owned.is_error = is_error.bool;
    }
    owned.meta_json = canonical.optionalObjectJson(allocator, result.object, "_meta", limits.max_text_bytes) catch |err| {
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = mapCanonical(err, .tools_call) };
    };
    owned.raw_result_json = canonical.encodeValue(allocator, result, limits.max_frame_bytes) catch |err| {
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = mapCanonical(err, .tools_call) };
    };
    return .{ .value = owned };
}

fn requestMeta(client: wire.ClientInfo) RequestMetaDto {
    return .{
        .@"io.modelcontextprotocol/protocolVersion" = canonical.MODERN_VERSION,
        .@"io.modelcontextprotocol/clientInfo" = .{
            .name = client.name,
            .version = client.version,
        },
    };
}

fn stringify(allocator: std.mem.Allocator, value: anytype) canonical.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch
        return error.OutOfMemory;
}

fn parseCache(result: std.json.Value, out: *canonical.CachePolicy) canonical.Error!void {
    const ttl_value = result.object.get("ttlMs") orelse return error.InvalidValue;
    const scope_value = result.object.get("cacheScope") orelse return error.InvalidValue;
    const ttl = wire.numberAsNonNegativeFloat(ttl_value) orelse return error.InvalidValue;
    if (scope_value != .string) return error.InvalidValue;
    const scope: canonical.CacheScope = if (std.mem.eql(u8, scope_value.string, "public"))
        .public
    else if (std.mem.eql(u8, scope_value.string, "private"))
        .private
    else
        return error.InvalidValue;
    out.* = .{ .ttl_ms = ttl, .scope = scope };
}

fn parseOptionalCache(result: std.json.Value, out: *canonical.CachePolicy) canonical.Error!void {
    const has_ttl = result.object.get("ttlMs") != null;
    const has_scope = result.object.get("cacheScope") != null;
    if (!has_ttl and !has_scope) return;
    if (has_ttl != has_scope) return error.InvalidValue;
    try parseCache(result, out);
}

fn mapCanonical(err: canonical.Error, phase: canonical.Phase) canonical.Diagnostic {
    return canonical.Diagnostic.init(
        if (err == error.ResourceLimit) .resource_limit else .invalid_field,
        phase,
    );
}

test "modern requests carry required per-request metadata" {
    const allocator = std.testing.allocator;
    const client = wire.ClientInfo{ .name = "agentcore", .version = "6" };
    const request = try encodeCallToolRequest(allocator, 4, client, "weather", "{\"city\":\"Paris\"}", .{});
    defer allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    const meta = params.get("_meta").?.object;
    try std.testing.expectEqualStrings(
        canonical.MODERN_VERSION,
        meta.get("io.modelcontextprotocol/protocolVersion").?.string,
    );
    try std.testing.expect(meta.get("io.modelcontextprotocol/clientCapabilities").? == .object);
    try std.testing.expectEqualStrings("Paris", params.get("arguments").?.object.get("city").?.string);
}

test "tools call preserves high precision numeric arguments" {
    const allocator = std.testing.allocator;
    const arguments =
        "{\"precise\":0.123456789012345678901234567890,\"tiny\":1e-30}";
    const request = try encodeCallToolRequest(
        allocator,
        5,
        .{ .name = "agentcore", .version = "6" },
        "calculate",
        arguments,
        .{},
    );
    defer allocator.free(request);
    try std.testing.expect(std.mem.indexOf(
        u8,
        request,
        "0.123456789012345678901234567890",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "1e-30") != null);
}

test "server discover does not require list-result cache metadata" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{" ++
        "\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"]," ++
        "\"capabilities\":{}}}";
    var parsed = try parseDiscoverResponse(
        std.testing.allocator,
        response,
        6,
        .{},
    );
    defer if (parsed == .value) parsed.value.deinit();
    try std.testing.expect(parsed == .value);
    try std.testing.expect(parsed.value.cache.ttl_ms == null);
    try std.testing.expectEqual(canonical.CacheScope.private, parsed.value.cache.scope);
}

test "modern tools list preserves full schemas and derives bound identity" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{" ++
        "\"resultType\":\"complete\",\"ttlMs\":5000,\"cacheScope\":\"private\"," ++
        "\"tools\":[{\"name\":\"weather\",\"description\":\"Forecast\"," ++
        "\"inputSchema\":{\"type\":\"object\",\"$defs\":{\"city\":{\"type\":\"string\"}},\"properties\":{\"city\":{\"$ref\":\"#/$defs/city\"}}}," ++
        "\"outputSchema\":{\"oneOf\":[{\"type\":\"string\"},{\"type\":\"null\"}]}," ++
        "\"annotations\":{\"readOnlyHint\":true},\"_meta\":{\"vendor\":\"x\"}}]}}";
    const parsed = try parseListToolsResponse(
        std.testing.allocator,
        response,
        11,
        [_]u8{7} ** 32,
        .{},
    );
    var catalog = switch (parsed) {
        .value => |value| value,
        .diagnostic => |diagnostic| {
            std.debug.print("unexpected diagnostic {any}\n", .{diagnostic});
            return error.TestUnexpectedResult;
        },
    };
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.tools.len);
    try std.testing.expect(std.mem.indexOf(u8, catalog.tools[0].input_schema_json, "$defs") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog.tools[0].output_schema_json.?, "oneOf") != null);
    try std.testing.expect(!std.mem.allEqual(u8, &catalog.tools[0].identity.permissionBinding(), 0));
}

test "modern call rejects missing result type and returns typed input required" {
    const missing = try parseCallToolResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[]}}",
        1,
        .{},
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.missing_result_type, missing.diagnostic.code);
    const input_required = try parseCallToolResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"input_required\",\"requestState\":\"opaque\"}}",
        2,
        .{},
    );
    try std.testing.expectEqual(
        canonical.DiagnosticCode.input_required_unsupported,
        input_required.diagnostic.code,
    );
}
