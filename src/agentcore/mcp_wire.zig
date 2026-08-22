//! Shared strict JSON-RPC mechanics for Revision 7 MCP era adapters.

const std = @import("std");
const canonical = @import("mcp_canonical.zig");
const json = @import("mcp_json.zig");

pub const JSON_RPC_VERSION = "2.0";
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const UNSUPPORTED_PROTOCOL_VERSION: i64 = -32022;

pub const RemoteError = struct {
    code: i64,
    data: ?std.json.Value,
};

pub const ResponseEnvelope = union(enum) {
    result: std.json.Value,
    remote_error: RemoteError,
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,

    pub fn validate(self: ClientInfo, limits: canonical.Limits) canonical.Error!void {
        if (self.name.len == 0 or self.version.len == 0)
            return error.InvalidValue;
        try canonical.validateText(self.name, limits.max_text_bytes);
        try canonical.validateText(self.version, limits.max_text_bytes);
    }
};

pub fn parseResponseEnvelope(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    phase: canonical.Phase,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(ResponseEnvelope) {
    canonical.validateFrame(encoded, limits) catch |err|
        return .{ .diagnostic = canonical.Diagnostic.init(
            if (err == error.ResourceLimit) .resource_limit else .invalid_json,
            phase,
        ) };
    switch (json.admit(allocator, encoded, structuralLimits(encoded.len, limits))) {
        .valid => {},
        .invalid_json => return .{ .diagnostic = canonical.Diagnostic.init(.invalid_json, phase) },
        .resource_limit => return .{ .diagnostic = canonical.Diagnostic.init(.resource_limit, phase) },
        .out_of_memory => return error.OutOfMemory,
    }
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.max_frame_bytes,
        // Call results are returned as semantic JSON. Preserve every numeric
        // lexeme instead of silently round-tripping provider data through f64.
        .parse_numbers = false,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_json, phase) };
    };
    canonical.validateJsonValue(root, limits) catch |err| return .{
        .diagnostic = canonical.Diagnostic.init(
            if (err == error.ResourceLimit) .resource_limit else .invalid_field,
            phase,
        ),
    };
    if (root != .object)
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
    const jsonrpc = root.object.get("jsonrpc") orelse
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, JSON_RPC_VERSION))
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
    const id_value = root.object.get("id") orelse
        return .{ .diagnostic = canonical.Diagnostic.init(.response_id_mismatch, phase) };
    const response_id = numberAsU64(id_value) orelse
        return .{ .diagnostic = canonical.Diagnostic.init(.response_id_mismatch, phase) };
    if (response_id != expected_id)
        return .{ .diagnostic = canonical.Diagnostic.init(.response_id_mismatch, phase) };

    const result = root.object.get("result");
    const remote_error = root.object.get("error");
    if ((result == null) == (remote_error == null))
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
    if (remote_error) |value| {
        if (value != .object)
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
        const code_value = value.object.get("code") orelse
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
        const message_value = value.object.get("message") orelse
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
        const code = numberAsI64(code_value) orelse
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
        if (message_value != .string)
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
        canonical.validateText(message_value.string, limits.max_text_bytes) catch
            return .{ .diagnostic = canonical.Diagnostic.init(.resource_limit, phase) };
        return .{ .value = .{ .remote_error = .{
            .code = code,
            .data = value.object.get("data"),
        } } };
    }
    if (result.? != .object)
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
    return .{ .value = .{ .result = result.? } };
}

pub fn parseEnvelope(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    phase: canonical.Phase,
    limits: canonical.Limits,
) error{OutOfMemory}!canonical.Outcome(std.json.Value) {
    const envelope = try parseResponseEnvelope(allocator, encoded, expected_id, phase, limits);
    return switch (envelope) {
        .diagnostic => |diagnostic| .{ .diagnostic = diagnostic },
        .value => |value| switch (value) {
            .result => |result| .{ .value = result },
            .remote_error => |remote_error| .{ .diagnostic = .{
                .code = if (remote_error.code == METHOD_NOT_FOUND)
                    .method_not_found
                else if (remote_error.code == UNSUPPORTED_PROTOCOL_VERSION)
                    .unsupported_protocol_version
                else
                    .remote_error,
                .phase = phase,
                .rpc_code = remote_error.code,
            } },
        },
    };
}

/// Validate the era-specific Result contract. A structurally valid
/// `input_required` is intentionally returned as a typed unsupported outcome;
/// malformed MRTR data remains an invalid field instead of being hidden by the
/// unsupported-feature diagnostic.
pub fn validateCompleteResult(
    result: std.json.Value,
    era: canonical.Era,
    phase: canonical.Phase,
    limits: canonical.Limits,
) ?canonical.Diagnostic {
    if (result != .object)
        return canonical.Diagnostic.init(.invalid_field, phase);
    // Classic eras do not assign semantics to the Modern resultType field.
    // A vendor extension with that name must not be interpreted as a Modern
    // input-required or unsupported-result response.
    if (era != .modern_2026_07_28) return null;
    const result_type = result.object.get("resultType") orelse {
        return canonical.Diagnostic.init(.missing_result_type, phase);
    };
    if (result_type != .string)
        return canonical.Diagnostic.init(.invalid_field, phase);
    if (std.mem.eql(u8, result_type.string, "complete")) return null;
    if (std.mem.eql(u8, result_type.string, "input_required")) {
        validateInputRequired(result, limits) catch
            return canonical.Diagnostic.init(.invalid_field, phase);
        return canonical.Diagnostic.init(.input_required_unsupported, phase);
    }
    return canonical.Diagnostic.init(.unsupported_result_type, phase);
}

fn validateInputRequired(result: std.json.Value, limits: canonical.Limits) canonical.Error!void {
    const requests = result.object.get("inputRequests");
    const state = result.object.get("requestState");
    if (requests == null and state == null) return error.InvalidValue;
    if (state) |value| {
        if (value != .string) return error.InvalidValue;
        try canonical.validateText(value.string, limits.max_text_bytes);
    }
    if (requests) |value| {
        if (value != .object) return error.InvalidValue;
        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.*.len == 0) return error.InvalidValue;
            try canonical.validateText(entry.key_ptr.*, limits.max_text_bytes);
            const request = entry.value_ptr.*;
            if (request != .object) return error.InvalidValue;
            const jsonrpc = request.object.get("jsonrpc") orelse return error.InvalidValue;
            const id = request.object.get("id") orelse return error.InvalidValue;
            const method = request.object.get("method") orelse return error.InvalidValue;
            if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, JSON_RPC_VERSION) or
                (id != .string and numberAsI64(id) == null) or method != .string)
                return error.InvalidValue;
            if (!std.mem.eql(u8, method.string, "sampling/createMessage") and
                !std.mem.eql(u8, method.string, "roots/list") and
                !std.mem.eql(u8, method.string, "elicitation/create"))
                return error.InvalidValue;
            if (request.object.get("params")) |params| {
                if (params != .object) return error.InvalidValue;
            }
        }
    }
}

pub fn parseArguments(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    limits: canonical.Limits,
) canonical.Error!std.json.Value {
    if (encoded.len == 0 or encoded.len > limits.max_schema_bytes)
        return error.ResourceLimit;
    switch (json.admit(allocator, encoded, structuralLimits(encoded.len, limits))) {
        .valid => {},
        .invalid_json => return error.InvalidValue,
        .resource_limit => return error.ResourceLimit,
        .out_of_memory => return error.OutOfMemory,
    }
    const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, encoded, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = limits.max_schema_bytes,
        // Permission digests and the eventual tools/call payload must observe
        // the same numeric value. Preserve the original JSON number lexeme
        // instead of round-tripping through f64.
        .parse_numbers = false,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
    if (value != .object) return error.InvalidValue;
    try canonical.validateJsonValue(value, limits);
    return value;
}

fn structuralLimits(encoded_len: usize, limits: canonical.Limits) json.Limits {
    return .{
        .max_depth = limits.max_json_depth,
        .max_nodes = limits.max_json_nodes,
        .max_container_entries = limits.max_json_nodes,
        // Frame size already bounds total scanner work. This keeps the guard
        // structural without inventing a second public wire limit.
        .max_work_units = encoded_len +| 1,
    };
}

pub fn numberAsNonNegativeFloat(value: std.json.Value) ?f64 {
    const number: f64 = switch (value) {
        .integer => |integer| if (integer >= 0) @floatFromInt(integer) else return null,
        .float => |float_value| float_value,
        .number_string => |encoded| std.fmt.parseFloat(f64, encoded) catch return null,
        else => return null,
    };
    if (number < 0 or !std.math.isFinite(number)) return null;
    return number;
}

fn numberAsI64(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string => |encoded| std.fmt.parseInt(i64, encoded, 10) catch null,
        else => null,
    };
}

fn numberAsU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |integer| if (integer < 0) null else @intCast(integer),
        .number_string => |encoded| std.fmt.parseInt(u64, encoded, 10) catch null,
        else => null,
    };
}

test "strict envelope classifies method not found without accepting wrong ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseEnvelope(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601,\"message\":\"unknown\"}}",
        7,
        .discovery,
        .{},
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.method_not_found, result.diagnostic.code);
    const wrong = try parseEnvelope(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}",
        7,
        .discovery,
        .{},
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.response_id_mismatch, wrong.diagnostic.code);
}

test "response envelope permits escaped C0 bytes in arbitrary result content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseEnvelope(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"\\u001b[31mred\"}]}}",
        7,
        .tools_call,
        .{},
    );
    try std.testing.expect(parsed == .value);
}

test "response envelope preserves high precision result number lexemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseResponseEnvelope(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"precise\":0.123456789012345678901234567890,\"huge\":900719925474099312345}}",
        7,
        .tools_call,
        .{},
    );
    try std.testing.expect(parsed == .value);
    const encoded = try canonical.encodeValue(arena.allocator(), parsed.value.result, 1024);
    try std.testing.expect(std.mem.indexOf(
        u8,
        encoded,
        "0.123456789012345678901234567890",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "900719925474099312345") != null);
}

test "response envelope matches the full unsigned request id domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseResponseEnvelope(
        arena.allocator(),
        "{\"jsonrpc\":\"2.0\",\"id\":18446744073709551615,\"result\":{}}",
        std.math.maxInt(u64),
        .tools_call,
        .{},
    );
    try std.testing.expect(parsed == .value);
}

test "response structure budget is enforced before dynamic tree allocation" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        // The scanner and its O(depth) bookkeeping each allocate once. Any
        // attempt to materialize the dynamic tree would be the third request.
        .{ .fail_index = 2 },
    );
    const parsed = try parseEnvelope(
        failing.allocator(),
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}",
        7,
        .discovery,
        .{ .max_json_nodes = 2 },
    );
    try std.testing.expectEqual(canonical.DiagnosticCode.resource_limit, parsed.diagnostic.code);
    try std.testing.expectEqual(@as(usize, 2), failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
}

test "modern complete result requires resultType after validating input required" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"resultType\":\"input_required\",\"requestState\":\"opaque\"}",
        .{},
    );
    defer parsed.deinit();
    const diagnostic = validateCompleteResult(
        parsed.value,
        .modern_2026_07_28,
        .tools_call,
        .{},
    ).?;
    try std.testing.expectEqual(canonical.DiagnosticCode.input_required_unsupported, diagnostic.code);
    var missing = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer missing.deinit();
    try std.testing.expectEqual(
        canonical.DiagnosticCode.missing_result_type,
        validateCompleteResult(missing.value, .modern_2026_07_28, .tools_call, .{}).?.code,
    );
    try std.testing.expect(validateCompleteResult(missing.value, .classic_2025_11_25, .tools_call, .{}) == null);
    try std.testing.expect(validateCompleteResult(missing.value, .classic_2025_06_18, .tools_call, .{}) == null);

    var vendor = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"resultType\":\"vendor-specific\"}",
        .{},
    );
    defer vendor.deinit();
    try std.testing.expect(validateCompleteResult(
        vendor.value,
        .classic_2025_11_25,
        .tools_call,
        .{},
    ) == null);
}
