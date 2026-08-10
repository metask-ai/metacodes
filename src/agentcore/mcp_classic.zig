//! MCP Classic adapter for 2025-11-25 and 2025-06-18 in Revision 7.
//!
//! This is external protocol interoperability only. It does not expose or
//! restore any older AgentCore ABI revision.

const std = @import("std");
const canonical = @import("mcp_canonical.zig");
const wire = @import("mcp_wire.zig");

const EmptyCapabilities = struct {};
const ImplementationDto = struct {
    name: []const u8,
    version: []const u8,
};
const InitializeParamsDto = struct {
    protocolVersion: []const u8,
    capabilities: EmptyCapabilities = .{},
    clientInfo: ImplementationDto,
};
const CursorParamsDto = struct {
    cursor: []const u8,
};
const CallParamsDto = struct {
    name: []const u8,
    arguments: std.json.Value,
};

pub const ClassicProfile = struct {
    era: canonical.Era,
    protocol_version: []const u8,
    supports_task_metadata: bool,

    pub fn forEra(era: canonical.Era) ?ClassicProfile {
        return switch (era) {
            .modern_2026_07_28 => null,
            .classic_2025_11_25 => .{
                .era = era,
                .protocol_version = canonical.CLASSIC_2025_11_VERSION,
                .supports_task_metadata = true,
            },
            .classic_2025_06_18 => .{
                .era = era,
                .protocol_version = canonical.CLASSIC_2025_06_VERSION,
                .supports_task_metadata = false,
            },
        };
    }
};

pub fn encodeInitializeRequest(
    allocator: std.mem.Allocator,
    id: u64,
    profile: ClassicProfile,
    client: wire.ClientInfo,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    try client.validate(limits);
    return stringify(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .id = id,
        .method = "initialize",
        .params = InitializeParamsDto{
            .protocolVersion = profile.protocol_version,
            .clientInfo = .{ .name = client.name, .version = client.version },
        },
    });
}

pub fn encodeInitializedNotification(allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .method = "notifications/initialized",
        .params = .{},
    }, .{}) catch return error.OutOfMemory;
}

pub fn encodeListToolsRequest(
    allocator: std.mem.Allocator,
    id: u64,
    cursor: ?[]const u8,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    if (cursor) |value| {
        try canonical.validateText(value, limits.max_cursor_bytes);
        return stringify(allocator, .{
            .jsonrpc = wire.JSON_RPC_VERSION,
            .id = id,
            .method = "tools/list",
            .params = CursorParamsDto{ .cursor = value },
        });
    }
    return stringify(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .id = id,
        .method = "tools/list",
        .params = .{},
    });
}

pub fn encodeCallToolRequest(
    allocator: std.mem.Allocator,
    id: u64,
    name: []const u8,
    arguments_json: []const u8,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    try canonical.validateToolName(name, limits);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arguments = try wire.parseArguments(scratch.allocator(), arguments_json, limits);
    return stringify(allocator, .{
        .jsonrpc = wire.JSON_RPC_VERSION,
        .id = id,
        .method = "tools/call",
        .params = CallParamsDto{ .name = name, .arguments = arguments },
    });
}

pub fn parseInitializeResponse(
    backing: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    requested_profile: ClassicProfile,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(canonical.OwnedHandshake) {
    var owned = canonical.OwnedHandshake.init(backing, requested_profile.era);
    const allocator = owned.allocator();
    const envelope = try wire.parseEnvelope(allocator, encoded, expected_id, .initialize, limits);
    const result = switch (envelope) {
        .diagnostic => |diagnostic| {
            owned.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .value => |value| value,
    };
    if (wire.validateCompleteResult(result, requested_profile.era, .initialize, limits)) |diagnostic| {
        owned.deinit();
        return .{ .diagnostic = diagnostic };
    }
    const version = result.object.get("protocolVersion") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .initialize) };
    };
    const capabilities = result.object.get("capabilities") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .initialize) };
    };
    const server_info = result.object.get("serverInfo") orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.missing_required_field, .initialize) };
    };
    if (version != .string or capabilities != .object or server_info != .object or
        !validImplementation(server_info, limits))
    {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .initialize) };
    }
    const selected_era = canonical.Era.parseExact(version.string) orelse {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .initialize) };
    };
    if (selected_era == .modern_2026_07_28) {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.unsupported_protocol_version, .initialize) };
    }
    owned.era = selected_era;
    const versions = allocator.alloc([]const u8, 1) catch {
        owned.deinit();
        return error.OutOfMemory;
    };
    versions[0] = version.string;
    owned.supported_versions = versions;
    owned.capabilities_json = canonical.encodeValue(allocator, capabilities, limits.max_text_bytes) catch |err| {
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = mapCanonical(err, .initialize) };
    };
    if (capabilities.object.get("tools")) |tools| {
        if (tools != .object) {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .initialize) };
        }
        owned.capabilities.tool_catalog_available = true;
    }
    owned.server_info_json = canonical.encodeValue(allocator, server_info, limits.max_text_bytes) catch |err| {
        owned.deinit();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = mapCanonical(err, .initialize) };
    };
    owned.instructions = canonical.optionalText(result.object, "instructions", limits.max_text_bytes) catch {
        owned.deinit();
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .initialize) };
    };
    owned.cache = .{ .ttl_ms = null, .scope = .private };
    return .{ .value = owned };
}

pub fn parseListToolsResponse(
    backing: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    profile: ClassicProfile,
    server_binding_identity: [32]u8,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(canonical.OwnedCatalog) {
    var owned = canonical.OwnedCatalog.init(backing, profile.era);
    const allocator = owned.allocator();
    const envelope = try wire.parseEnvelope(allocator, encoded, expected_id, .tools_list, limits);
    const result = switch (envelope) {
        .diagnostic => |diagnostic| {
            owned.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .value => |value| value,
    };
    if (wire.validateCompleteResult(result, profile.era, .tools_list, limits)) |diagnostic| {
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
            profile.era,
            server_binding_identity,
            limits,
        ) catch |err| {
            owned.deinit();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = mapCanonical(err, .tools_list) };
        };
        tools[index].execution_mode = parseExecutionMode(tool_value, profile) catch {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_list) };
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
    owned.cache = .{ .ttl_ms = null, .scope = .private };
    return .{ .value = owned };
}

pub fn parseCallToolResponse(
    backing: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    profile: ClassicProfile,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(canonical.OwnedCallResult) {
    var owned = canonical.OwnedCallResult.init(backing, profile.era);
    const allocator = owned.allocator();
    const envelope = try wire.parseEnvelope(allocator, encoded, expected_id, .tools_call, limits);
    const result = switch (envelope) {
        .diagnostic => |diagnostic| {
            owned.deinit();
            return .{ .diagnostic = diagnostic };
        },
        .value => |value| value,
    };
    if (wire.validateCompleteResult(result, profile.era, .tools_call, limits)) |diagnostic| {
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
        if (structured != .object) {
            owned.deinit();
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) };
        }
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

fn validImplementation(value: std.json.Value, limits: canonical.Limits) bool {
    const name = value.object.get("name") orelse return false;
    const version = value.object.get("version") orelse return false;
    if (name != .string or version != .string or name.string.len == 0 or version.string.len == 0)
        return false;
    canonical.validateText(name.string, limits.max_text_bytes) catch return false;
    canonical.validateText(version.string, limits.max_text_bytes) catch return false;
    return true;
}

fn parseExecutionMode(
    tool: std.json.Value,
    profile: ClassicProfile,
) canonical.Error!canonical.ExecutionMode {
    if (!profile.supports_task_metadata) return .ordinary;
    const execution = tool.object.get("execution") orelse return .ordinary;
    if (execution != .object) return error.InvalidValue;
    const support = execution.object.get("taskSupport") orelse return .ordinary;
    if (support != .string) return error.InvalidValue;
    if (std.mem.eql(u8, support.string, "forbidden")) return .ordinary;
    if (std.mem.eql(u8, support.string, "optional")) return .task_optional;
    if (std.mem.eql(u8, support.string, "required")) return .task_required;
    return error.InvalidValue;
}

fn stringify(allocator: std.mem.Allocator, value: anytype) canonical.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch
        return error.OutOfMemory;
}

fn mapCanonical(err: canonical.Error, phase: canonical.Phase) canonical.Diagnostic {
    return canonical.Diagnostic.init(
        if (err == error.ResourceLimit) .resource_limit else .invalid_field,
        phase,
    );
}

test "Classic lifecycle encodes the selected exact initialize then initialized" {
    const allocator = std.testing.allocator;
    const request = try encodeInitializeRequest(
        allocator,
        1,
        ClassicProfile.forEra(.classic_2025_11_25).?,
        .{ .name = "agentcore", .version = "6" },
        .{},
    );
    defer allocator.free(request);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        canonical.CLASSIC_2025_11_VERSION,
        parsed.value.object.get("params").?.object.get("protocolVersion").?.string,
    );
    try std.testing.expect(parsed.value.object.get("params").?.object.get("_meta") == null);
    const notification = try encodeInitializedNotification(allocator);
    defer allocator.free(notification);
    try std.testing.expect(std.mem.indexOf(u8, notification, "notifications/initialized") != null);
    try std.testing.expect(std.mem.indexOf(u8, notification, "\"id\"") == null);
}

test "Classic initialize parser reports the selected known era without enforcing the request" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{" ++
        "\"protocolVersion\":\"2025-06-18\",\"capabilities\":{}," ++
        "\"serverInfo\":{\"name\":\"old\",\"version\":\"1\"}}}";
    const parsed = try parseInitializeResponse(
        std.testing.allocator,
        response,
        1,
        ClassicProfile.forEra(.classic_2025_11_25).?,
        .{},
    );
    var handshake = switch (parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer handshake.deinit();
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, handshake.era);
}

test "Classic initialize rejects unknown and Modern selections" {
    inline for (.{ "2024-11-05", canonical.MODERN_VERSION }) |version| {
        const response = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{}},\"serverInfo\":{{\"name\":\"peer\",\"version\":\"1\"}}}}}}",
            .{version},
        );
        defer std.testing.allocator.free(response);
        const parsed = try parseInitializeResponse(
            std.testing.allocator,
            response,
            1,
            ClassicProfile.forEra(.classic_2025_11_25).?,
            .{},
        );
        try std.testing.expectEqual(
            canonical.DiagnosticCode.unsupported_protocol_version,
            parsed.diagnostic.code,
        );
    }
}

test "Classic 2025-11 tools list classifies optional task execution" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{" ++
        "\"tools\":[{\"name\":\"weather\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}," ++
        "\"outputSchema\":{\"type\":\"object\",\"properties\":{\"temp\":{\"type\":\"number\"}}}," ++
        "\"execution\":{\"taskSupport\":\"optional\"}}]}}";
    const parsed = try parseListToolsResponse(
        std.testing.allocator,
        response,
        3,
        ClassicProfile.forEra(.classic_2025_11_25).?,
        [_]u8{8} ** 32,
        .{},
    );
    var catalog = switch (parsed) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.tools.len);
    try std.testing.expect(catalog.cache.ttl_ms == null);
    try std.testing.expect(catalog.tools[0].execution_json != null);
    try std.testing.expectEqual(canonical.ExecutionMode.task_optional, catalog.tools[0].execution_mode);
}

test "Classic execution metadata is era-local and required tasks stay classified" {
    const response =
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{" ++
        "\"tools\":[{\"name\":\"tasked\",\"inputSchema\":{\"type\":\"object\"}," ++
        "\"execution\":{\"taskSupport\":\"required\"}}]}}";
    const parsed_11 = try parseListToolsResponse(
        std.testing.allocator,
        response,
        7,
        ClassicProfile.forEra(.classic_2025_11_25).?,
        [_]u8{7} ** 32,
        .{},
    );
    var catalog_11 = switch (parsed_11) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer catalog_11.deinit();
    try std.testing.expectEqual(.task_required, catalog_11.tools[0].execution_mode);

    const parsed_06 = try parseListToolsResponse(
        std.testing.allocator,
        response,
        7,
        ClassicProfile.forEra(.classic_2025_06_18).?,
        [_]u8{7} ** 32,
        .{},
    );
    var catalog_06 = switch (parsed_06) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    defer catalog_06.deinit();
    try std.testing.expectEqual(.ordinary, catalog_06.tools[0].execution_mode);
}

test "legacy structured content remains object-only" {
    const valid = try parseCallToolResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"content\":[],\"structuredContent\":{\"ok\":true}}}",
        4,
        ClassicProfile.forEra(.classic_2025_06_18).?,
        .{},
    );
    var result = switch (valid) {
        .value => |value| value,
        .diagnostic => return error.TestUnexpectedResult,
    };
    result.deinit();
    const invalid = try parseCallToolResponse(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"content\":[],\"structuredContent\":\"scalar\"}}",
        5,
        ClassicProfile.forEra(.classic_2025_06_18).?,
        .{},
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.invalid_field, invalid.diagnostic.code);
}
