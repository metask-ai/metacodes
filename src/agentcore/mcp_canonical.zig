//! AgentCore-owned canonical MCP protocol model for Revision 7.
//!
//! The model is deliberately independent from the product `src/mcp` stack.
//! Protocol-era adapters own wire differences; Runtime, Session, Permission
//! and checkpoint code consume only the bounded values defined here.

const std = @import("std");

pub const MODERN_VERSION = "2026-07-28";
pub const CLASSIC_2025_11_VERSION = "2025-11-25";
pub const CLASSIC_2025_06_VERSION = "2025-06-18";

pub const Limits = struct {
    max_frame_bytes: usize = 8 * 1024 * 1024,
    max_tools: usize = 1024,
    max_tool_name_bytes: usize = 256,
    max_text_bytes: usize = 64 * 1024,
    max_schema_bytes: usize = 1024 * 1024,
    max_json_depth: u16 = 64,
    max_json_nodes: u32 = 131_072,
    max_cursor_bytes: usize = 16 * 1024,
    max_versions: usize = 16,

    pub fn validate(self: Limits) Error!void {
        if (self.max_frame_bytes == 0 or
            self.max_tools == 0 or
            self.max_tool_name_bytes == 0 or
            self.max_text_bytes == 0 or
            self.max_schema_bytes == 0 or
            self.max_schema_bytes > self.max_frame_bytes or
            self.max_json_depth == 0 or
            self.max_json_nodes == 0 or
            self.max_cursor_bytes == 0 or
            self.max_versions == 0)
            return error.ResourceLimit;
    }
};

pub const Era = enum(u8) {
    modern_2026_07_28 = 0,
    classic_2025_11_25 = 1,
    classic_2025_06_18 = 2,

    pub fn version(self: Era) []const u8 {
        return switch (self) {
            .modern_2026_07_28 => MODERN_VERSION,
            .classic_2025_11_25 => CLASSIC_2025_11_VERSION,
            .classic_2025_06_18 => CLASSIC_2025_06_VERSION,
        };
    }

    pub fn parseExact(version_value: []const u8) ?Era {
        if (std.mem.eql(u8, version_value, MODERN_VERSION))
            return .modern_2026_07_28;
        if (std.mem.eql(u8, version_value, CLASSIC_2025_11_VERSION))
            return .classic_2025_11_25;
        if (std.mem.eql(u8, version_value, CLASSIC_2025_06_VERSION))
            return .classic_2025_06_18;
        return null;
    }
};

pub const Phase = enum(u8) {
    request_encode,
    envelope_decode,
    discovery,
    initialize,
    tools_list,
    tools_call,
    negotiation,
    revalidation,
};

/// Stable semantic diagnostics. Human-readable server text is deliberately
/// not used as control flow and is retained only in bounded raw metadata.
pub const DiagnosticCode = enum(u16) {
    invalid_json,
    invalid_envelope,
    response_id_mismatch,
    remote_error,
    method_not_found,
    unsupported_protocol_version,
    missing_required_field,
    invalid_field,
    resource_limit,
    duplicate_tool,
    missing_result_type,
    unsupported_result_type,
    input_required_unsupported,
    downgrade_refused,
    probe_failed,
    connection_failed,
    era_revalidation_mismatch,
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    phase: Phase,
    rpc_code: ?i64 = null,

    pub fn init(code: DiagnosticCode, phase: Phase) Diagnostic {
        return .{ .code = code, .phase = phase };
    }
};

pub fn Outcome(comptime T: type) type {
    return union(enum) {
        value: T,
        diagnostic: Diagnostic,
    };
}

pub const Error = error{
    OutOfMemory,
    InvalidValue,
    ResourceLimit,
};

pub const CacheScope = enum(u8) {
    public,
    private,
};

pub const CachePolicy = struct {
    /// Null means the legacy adapter has no protocol TTL and Runtime must use
    /// its conservative refresh policy. It does not mean infinite caching.
    ttl_ms: ?f64,
    scope: CacheScope,
};

/// Era adapters reduce wire capability shapes to state that AgentCore
/// actually uses. Raw capability JSON is retained only for diagnostics.
pub const CanonicalCapabilities = struct {
    tool_catalog_available: bool,
};

/// AgentCore does not implement MCP Tasks in Revision 7. Optional task
/// support remains callable as an ordinary request; required task execution
/// is admitted into diagnostics but never into an executable catalog.
pub const ExecutionMode = enum(u8) {
    ordinary,
    task_optional,
    task_required,
};

pub const ToolIdentity = struct {
    server_binding_identity: [32]u8,
    name: []const u8,
    schema_fingerprint: [32]u8,

    /// Permission binds the Host/Runtime-assigned server authority, the exact
    /// MCP name and the semantic input/output schema. Server self-reporting is
    /// intentionally absent.
    pub fn permissionBinding(self: ToolIdentity) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // Stable Revision 6 domain: era is provenance and must not churn the
        // permission identity of an otherwise identical external Tool.
        hasher.update("agentcore-r6-mcp-tool-binding\x00");
        hasher.update(&self.server_binding_identity);
        hashBytes(&hasher, self.name);
        hasher.update(&self.schema_fingerprint);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        if (allZero(&digest)) digest[0] = 1;
        return digest;
    }
};

/// Every optional/extension object is retained as semantic JSON. This keeps
/// protocol information lossless even when the first provider projection
/// cannot consume every JSON Schema 2020-12 keyword.
pub const Tool = struct {
    identity: ToolIdentity,
    title: ?[]const u8,
    description: ?[]const u8,
    input_schema_json: []const u8,
    output_schema_json: ?[]const u8,
    annotations_json: ?[]const u8,
    icons_json: ?[]const u8,
    meta_json: ?[]const u8,
    execution_json: ?[]const u8,
    execution_mode: ExecutionMode = .ordinary,
    raw_json: []const u8,
};

pub const OwnedHandshake = struct {
    arena: std.heap.ArenaAllocator,
    era: Era,
    supported_versions: []const []const u8,
    capabilities_json: []const u8,
    capabilities: CanonicalCapabilities,
    server_info_json: ?[]const u8,
    instructions: ?[]const u8,
    cache: CachePolicy,

    pub fn init(backing: std.mem.Allocator, era: Era) OwnedHandshake {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .era = era,
            .supported_versions = &.{},
            .capabilities_json = "{}",
            .capabilities = .{ .tool_catalog_available = false },
            .server_info_json = null,
            .instructions = null,
            .cache = .{ .ttl_ms = null, .scope = .private },
        };
    }

    pub fn allocator(self: *OwnedHandshake) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *OwnedHandshake) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedCatalog = struct {
    arena: std.heap.ArenaAllocator,
    era: Era,
    tools: []Tool,
    next_cursor: ?[]const u8,
    cache: CachePolicy,
    meta_json: ?[]const u8,

    pub fn init(backing: std.mem.Allocator, era: Era) OwnedCatalog {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .era = era,
            .tools = &.{},
            .next_cursor = null,
            .cache = .{ .ttl_ms = null, .scope = .private },
            .meta_json = null,
        };
    }

    pub fn allocator(self: *OwnedCatalog) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *OwnedCatalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedCallResult = struct {
    arena: std.heap.ArenaAllocator,
    era: Era,
    content_json: []const u8,
    structured_content_json: ?[]const u8,
    is_error: bool,
    meta_json: ?[]const u8,
    raw_result_json: []const u8,

    pub fn init(backing: std.mem.Allocator, era: Era) OwnedCallResult {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .era = era,
            .content_json = "[]",
            .structured_content_json = null,
            .is_error = false,
            .meta_json = null,
            .raw_result_json = "{}",
        };
    }

    pub fn allocator(self: *OwnedCallResult) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *OwnedCallResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn validateFrame(encoded: []const u8, limits: Limits) Error!void {
    try limits.validate();
    if (encoded.len == 0 or encoded.len > limits.max_frame_bytes)
        return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.InvalidValue;
}

pub fn validateText(value: []const u8, max_bytes: usize) Error!void {
    if (value.len > max_bytes) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
    for (value) |byte| {
        if (byte < 0x20 and byte != '\t' and byte != '\r' and byte != '\n')
            return error.InvalidValue;
    }
}

fn validateJsonText(value: []const u8, max_bytes: usize) Error!void {
    if (value.len > max_bytes) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidValue;
}

pub fn validateToolName(value: []const u8, limits: Limits) Error!void {
    if (value.len == 0 or value.len > limits.max_tool_name_bytes)
        return error.InvalidValue;
    try validateText(value, limits.max_tool_name_bytes);
}

pub fn encodeValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    max_bytes: usize,
) Error![]const u8 {
    // Count the escaped representation before allocating it. A small input
    // string can expand substantially when JSON escaping is applied, so an
    // allocate-then-check implementation would let the configured wire limit
    // be exceeded transiently.
    var count_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    std.json.Stringify.value(value, .{}, &discarding.writer) catch
        return error.OutOfMemory;
    const encoded_len_u64 = discarding.fullCount();
    if (encoded_len_u64 > max_bytes or encoded_len_u64 > std.math.maxInt(usize))
        return error.ResourceLimit;
    const encoded_len: usize = @intCast(encoded_len_u64);

    var allocating = std.Io.Writer.Allocating.initCapacity(
        allocator,
        encoded_len,
    ) catch return error.OutOfMemory;
    defer allocating.deinit();
    std.json.Stringify.value(value, .{}, &allocating.writer) catch
        return error.OutOfMemory;
    const encoded = allocating.toOwnedSlice() catch return error.OutOfMemory;
    std.debug.assert(encoded.len == encoded_len);
    return encoded;
}

pub fn validateJsonValue(value: std.json.Value, limits: Limits) Error!void {
    var nodes: u32 = 0;
    try validateJsonValueAt(value, 1, &nodes, limits);
}

fn validateJsonValueAt(
    value: std.json.Value,
    depth: u16,
    nodes: *u32,
    limits: Limits,
) Error!void {
    if (depth > limits.max_json_depth or nodes.* == limits.max_json_nodes)
        return error.ResourceLimit;
    nodes.* += 1;
    switch (value) {
        // Arbitrary JSON content may legally contain escaped C0 characters.
        // Protocol fields apply `validateText` explicitly at their own boundary.
        .string, .number_string => |text_value| try validateJsonText(text_value, limits.max_frame_bytes),
        .array => |array| for (array.items) |child|
            try validateJsonValueAt(child, depth + 1, nodes, limits),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try validateJsonText(entry.key_ptr.*, limits.max_text_bytes);
                try validateJsonValueAt(entry.value_ptr.*, depth + 1, nodes, limits);
            }
        },
        else => {},
    }
}

pub const SchemaMode = enum {
    modern_input,
    modern_output,
    classic_input,
    classic_output,
};

pub fn validateSchema(value: std.json.Value, mode: SchemaMode, limits: Limits) Error!void {
    if (value != .object) return error.InvalidValue;
    try validateJsonValue(value, limits);
    const root_type = value.object.get("type");
    switch (mode) {
        .modern_input, .classic_input, .classic_output => {
            const type_value = root_type orelse return error.InvalidValue;
            if (type_value != .string or !std.mem.eql(u8, type_value.string, "object"))
                return error.InvalidValue;
        },
        .modern_output => {},
    }
    if (value.object.get("properties")) |properties| {
        if (properties != .object) return error.InvalidValue;
    }
    if (value.object.get("required")) |required| {
        if (required != .array) return error.InvalidValue;
        for (required.array.items) |item| {
            if (item != .string) return error.InvalidValue;
        }
    }
}

pub fn schemaFingerprint(
    allocator: std.mem.Allocator,
    input_schema: std.json.Value,
    output_schema: ?std.json.Value,
    limits: Limits,
) Error![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Retained across Revision 7 so restored authority cannot drift merely
    // because the ABI learned another exact protocol era.
    hasher.update("agentcore-r6-mcp-schema\x00");
    var nodes: u32 = 0;
    try hashJsonValue(allocator, &hasher, input_schema, 1, &nodes, limits);
    if (output_schema) |value| {
        hasher.update("output\x00");
        try hashJsonValue(allocator, &hasher, value, 1, &nodes, limits);
    } else {
        hasher.update("no-output\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

pub fn projectTool(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    era: Era,
    server_binding_identity: [32]u8,
    limits: Limits,
) Error!Tool {
    if (value != .object or allZero(&server_binding_identity))
        return error.InvalidValue;
    const name_value = value.object.get("name") orelse return error.InvalidValue;
    if (name_value != .string) return error.InvalidValue;
    try validateToolName(name_value.string, limits);

    const input_schema = value.object.get("inputSchema") orelse
        return error.InvalidValue;
    try validateSchema(
        input_schema,
        if (era == .modern_2026_07_28) .modern_input else .classic_input,
        limits,
    );
    const output_schema = value.object.get("outputSchema");
    if (output_schema) |schema| {
        try validateSchema(
            schema,
            if (era == .modern_2026_07_28) .modern_output else .classic_output,
            limits,
        );
    }

    const title = try optionalText(value.object, "title", limits.max_text_bytes);
    const description = try optionalText(value.object, "description", limits.max_text_bytes);
    const annotations_json = try optionalObjectJson(allocator, value.object, "annotations", limits.max_text_bytes);
    const meta_json = try optionalObjectJson(allocator, value.object, "_meta", limits.max_text_bytes);
    const execution_json = try optionalObjectJson(allocator, value.object, "execution", limits.max_text_bytes);
    const icons_json: ?[]const u8 = if (value.object.get("icons")) |icons| blk: {
        if (icons != .array) return error.InvalidValue;
        break :blk try encodeValue(allocator, icons, limits.max_text_bytes);
    } else null;
    const input_schema_json = try encodeValue(allocator, input_schema, limits.max_schema_bytes);
    const output_schema_json = if (output_schema) |schema|
        try encodeValue(allocator, schema, limits.max_schema_bytes)
    else
        null;
    const raw_json = try encodeValue(allocator, value, limits.max_frame_bytes);
    const schema_fingerprint = try schemaFingerprint(
        allocator,
        input_schema,
        output_schema,
        limits,
    );
    return .{
        .identity = .{
            .server_binding_identity = server_binding_identity,
            .name = name_value.string,
            .schema_fingerprint = schema_fingerprint,
        },
        .title = title,
        .description = description,
        .input_schema_json = input_schema_json,
        .output_schema_json = output_schema_json,
        .annotations_json = annotations_json,
        .icons_json = icons_json,
        .meta_json = meta_json,
        .execution_json = execution_json,
        .raw_json = raw_json,
    };
}

pub fn optionalText(
    object: std.json.ObjectMap,
    key: []const u8,
    max_bytes: usize,
) Error!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.InvalidValue;
    try validateText(value.string, max_bytes);
    return value.string;
}

pub fn optionalObjectJson(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    max_bytes: usize,
) Error!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .object) return error.InvalidValue;
    return try encodeValue(allocator, value, max_bytes);
}

fn hashJsonValue(
    allocator: std.mem.Allocator,
    hasher: *std.crypto.hash.sha2.Sha256,
    value: std.json.Value,
    depth: u16,
    nodes: *u32,
    limits: Limits,
) Error!void {
    if (depth > limits.max_json_depth or nodes.* == limits.max_json_nodes)
        return error.ResourceLimit;
    nodes.* += 1;
    switch (value) {
        .null => hasher.update("n"),
        .bool => |item| hasher.update(if (item) "t" else "f"),
        .integer => |item| {
            hasher.update("i");
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(i64, &bytes, item, .little);
            hasher.update(&bytes);
        },
        .float => |item| {
            hasher.update("d");
            const normalized: f64 = if (item == 0) 0 else item;
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, @bitCast(normalized), .little);
            hasher.update(&bytes);
        },
        .number_string => |item| {
            hasher.update("q");
            hashBytes(hasher, item);
        },
        .string => |item| {
            hasher.update("s");
            hashBytes(hasher, item);
        },
        .array => |array| {
            hasher.update("a");
            hashU64(hasher, @intCast(array.items.len));
            for (array.items) |child|
                try hashJsonValue(allocator, hasher, child, depth + 1, nodes, limits);
        },
        .object => |object| {
            hasher.update("o");
            hashU64(hasher, @intCast(object.count()));
            const keys = allocator.alloc([]const u8, object.count()) catch
                return error.OutOfMemory;
            defer allocator.free(keys);
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1)
                keys[index] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, stringLessThan);
            for (keys) |key| {
                hashBytes(hasher, key);
                try hashJsonValue(
                    allocator,
                    hasher,
                    object.get(key).?,
                    depth + 1,
                    nodes,
                    limits,
                );
            }
        },
    }
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashU64(hasher, @intCast(value.len));
    hasher.update(value);
}

fn hashU64(hasher: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

test "canonical era accepts the three Revision 7 protocol versions" {
    try std.testing.expectEqual(Era.modern_2026_07_28, Era.parseExact(MODERN_VERSION).?);
    try std.testing.expectEqual(Era.classic_2025_11_25, Era.parseExact(CLASSIC_2025_11_VERSION).?);
    try std.testing.expectEqual(Era.classic_2025_06_18, Era.parseExact(CLASSIC_2025_06_VERSION).?);
    try std.testing.expect(Era.parseExact("2024-11-05") == null);
}

test "schema fingerprint ignores object key order but covers output schema" {
    var first = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}", .{});
    defer first.deinit();
    var reordered = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"properties\":{\"x\":{\"type\":\"string\"}},\"type\":\"object\"}", .{});
    defer reordered.deinit();
    var output = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"string\"}", .{});
    defer output.deinit();
    const no_output = try schemaFingerprint(std.testing.allocator, first.value, null, .{});
    const same = try schemaFingerprint(std.testing.allocator, reordered.value, null, .{});
    const with_output = try schemaFingerprint(std.testing.allocator, first.value, output.value, .{});
    try std.testing.expectEqualSlices(u8, &no_output, &same);
    try std.testing.expect(!std.mem.eql(u8, &no_output, &with_output));
}

test "MCP permission identity binds server name and schema" {
    const base = ToolIdentity{
        .server_binding_identity = [_]u8{1} ** 32,
        .name = "weather",
        .schema_fingerprint = [_]u8{2} ** 32,
    };
    const renamed = ToolIdentity{
        .server_binding_identity = base.server_binding_identity,
        .name = "forecast",
        .schema_fingerprint = base.schema_fingerprint,
    };
    const other_server = ToolIdentity{
        .server_binding_identity = [_]u8{3} ** 32,
        .name = base.name,
        .schema_fingerprint = base.schema_fingerprint,
    };
    try std.testing.expect(!allZero(&base.permissionBinding()));
    try std.testing.expect(!std.mem.eql(u8, &base.permissionBinding(), &renamed.permissionBinding()));
    try std.testing.expect(!std.mem.eql(u8, &base.permissionBinding(), &other_server.permissionBinding()));
}

test "canonical encoding rejects escaped output before allocating" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.ResourceLimit,
        encodeValue(failing.allocator(), .{ .string = "\x00\x01\x02" }, 4),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}
