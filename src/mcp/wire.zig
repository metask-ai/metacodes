//! JSON-RPC mechanics for the MCP era adapters: the one request encoder, the
//! one response-envelope parser, and frame classification.

const std = @import("std");
const canonical = @import("canonical.zig");
const json = @import("json_admission.zig");

pub const JSON_RPC_VERSION = "2.0";
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const UNSUPPORTED_PROTOCOL_VERSION: i64 = -32022;

/// How much of the specification a peer must honour for its frames to be
/// accepted. It is the only thing that separates the two entry-point profiles
/// in this file, and every use of it is tested in both positions.
pub const Conformance = enum {
    /// The AgentCore public contract: `jsonrpc` and a matching numeric `id`
    /// are required, `result` must be an object, `error` needs `code` and
    /// `message`, the three strict eras only.
    strict,
    /// The product CLI against servers found in the wild: a frame missing
    /// `jsonrpc`, or an error with a null or absent `id` (how many HTTP servers
    /// report a request they could not parse), still counts as an answer.
    interop,
};

/// What this client declares. `elicitation` is declared only by an entry point
/// that has somewhere to route the request; a server may then ask for input.
pub const ClientCapabilities = struct {
    elicitation: bool = false,

    pub fn jsonStringify(self: ClientCapabilities, writer: anytype) !void {
        try writer.beginObject();
        if (self.elicitation) {
            try writer.objectField("elicitation");
            try writer.beginObject();
            try writer.endObject();
        }
        try writer.endObject();
    }
};

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
    return parseResponseEnvelopeWith(allocator, encoded, expected_id, phase, limits, .strict);
}

pub fn parseResponseEnvelopeWith(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    phase: canonical.Phase,
    limits: canonical.Limits,
    conformance: Conformance,
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
    const strict = conformance == .strict;
    if (strict) {
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
    } else if (root.object.get("id")) |id_value| {
        // A numeric id naming another request is still somebody else's answer.
        if (numberAsU64(id_value)) |response_id| if (response_id != expected_id)
            return .{ .diagnostic = canonical.Diagnostic.init(.response_id_mismatch, phase) };
    }

    const result = root.object.get("result");
    const remote_error = root.object.get("error");
    if ((result == null) == (remote_error == null))
        return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
    if (remote_error) |value| {
        if (!strict and value != .object)
            return .{ .value = .{ .remote_error = .{ .code = 0, .data = null } } };
        if (value != .object)
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
        const code_value = value.object.get("code");
        const message_value = value.object.get("message");
        if (strict) {
            if (code_value == null or message_value == null)
                return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
            if (numberAsI64(code_value.?) == null or message_value.? != .string)
                return .{ .diagnostic = canonical.Diagnostic.init(.invalid_envelope, phase) };
            canonical.validateText(message_value.?.string, limits.max_text_bytes) catch
                return .{ .diagnostic = canonical.Diagnostic.init(.resource_limit, phase) };
        }
        return .{ .value = .{ .remote_error = .{
            .code = if (code_value) |code| numberAsI64(code) orelse 0 else 0,
            .data = value.object.get("data"),
        } } };
    }
    if (strict and result.? != .object)
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
    return parseEnvelopeWith(allocator, encoded, expected_id, phase, limits, .strict);
}

pub fn parseEnvelopeWith(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    expected_id: u64,
    phase: canonical.Phase,
    limits: canonical.Limits,
    conformance: Conformance,
) error{OutOfMemory}!canonical.Outcome(std.json.Value) {
    const envelope = try parseResponseEnvelopeWith(allocator, encoded, expected_id, phase, limits, conformance);
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

/// One request as it travels. Every revision uses the same JSON-RPC frame; a
/// 2026-07-28 request additionally carries the protocol version, client info
/// and client capabilities in `params._meta`. `params_json` is one JSON object
/// whose numbers keep their lexemes and whose field order survives.
pub fn encodeRequest(
    allocator: std.mem.Allocator,
    id: u64,
    era: canonical.Era,
    client: ClientInfo,
    capabilities: ClientCapabilities,
    method: []const u8,
    params_json: []const u8,
    limits: canonical.Limits,
) canonical.Error![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    // `params` wraps the caller's values in one more level and some bytes of
    // method fields, which the caller's own limits do not charge for.
    var params_limits = limits;
    params_limits.max_json_depth +|= 2;
    params_limits.max_json_nodes +|= 8;
    params_limits.max_schema_bytes +|= limits.max_text_bytes;
    params_limits.max_frame_bytes = @max(params_limits.max_frame_bytes, params_limits.max_schema_bytes);
    const params = try parseArguments(scratch.allocator(), params_json, params_limits);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var writer: std.json.Stringify = .{ .writer = &out.writer };
    encodeFrame(&writer, id, method, era, client, capabilities, params) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn encodeFrame(
    writer: *std.json.Stringify,
    id: u64,
    method: []const u8,
    era: canonical.Era,
    client: ClientInfo,
    capabilities: ClientCapabilities,
    params: std.json.Value,
) !void {
    try writer.beginObject();
    try writer.objectField("jsonrpc");
    try writer.write(JSON_RPC_VERSION);
    try writer.objectField("id");
    try writer.write(id);
    try writer.objectField("method");
    try writer.write(method);
    try writer.objectField("params");
    try writer.beginObject();
    if (era.isModern()) {
        try writer.objectField("_meta");
        try writer.beginObject();
        try writer.objectField("io.modelcontextprotocol/protocolVersion");
        try writer.write(canonical.MODERN_VERSION);
        try writer.objectField("io.modelcontextprotocol/clientInfo");
        try writer.write(.{ .name = client.name, .version = client.version });
        try writer.objectField("io.modelcontextprotocol/clientCapabilities");
        try writer.write(capabilities);
        try writer.endObject();
    }
    var fields = params.object.iterator();
    while (fields.next()) |field| {
        try writer.objectField(field.key_ptr.*);
        try writer.write(field.value_ptr.*);
    }
    try writer.endObject();
    try writer.endObject();
}

/// What one received frame is. `error` / `result` stay unparsed here: the
/// caller parses the frame it was waiting for under its own conformance.
pub const FrameKind = union(enum) {
    /// Not a JSON object.
    malformed,
    /// A server notification.
    notification: []const u8,
    /// A server→client request, to be answered.
    server_request: struct { id: u64, method: []const u8 },
    response: Response,

    pub const Response = struct {
        /// Null when absent, null or not a number.
        id: ?u64,
        is_error: bool,
        /// `result.resultType` is `input_required`.
        input_required: bool,
    };
};

/// JSON-RPC classifies by top-level member, never by a substring of the frame
/// (a `requestedSchema` property named "result" must not look like a response).
pub fn classifyFrame(arena: std.mem.Allocator, frame: []const u8) error{OutOfMemory}!FrameKind {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, frame, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
        .max_value_len = @max(frame.len, 1),
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .malformed;
    };
    if (value != .object) return .malformed;
    const id: ?u64 = if (value.object.get("id")) |id_value| numberAsU64(id_value) else null;
    if (value.object.get("method")) |method| {
        if (method == .string) {
            if (value.object.get("id") == null) return .{ .notification = method.string };
            if (id) |request_id| return .{ .server_request = .{ .id = request_id, .method = method.string } };
            // A request whose id cannot be echoed cannot be answered.
            return .{ .notification = method.string };
        }
    }
    const result_type: ?std.json.Value = if (value.object.get("result")) |result|
        (if (result == .object) result.object.get("resultType") else null)
    else
        null;
    return .{ .response = .{
        .id = id,
        .is_error = value.object.get("error") != null,
        .input_required = if (result_type) |kind|
            kind == .string and std.mem.eql(u8, kind.string, "input_required")
        else
            false,
    } };
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
    // "the client MUST treat the absent field as `complete`"
    // (2026-07-28 schema.ts, `Result.resultType`).
    const result_type = result.object.get("resultType") orelse return null;
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

pub fn validateInputRequired(result: std.json.Value, limits: canonical.Limits) canonical.Error!void {
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
            // An InputRequest is `{method, params}`: it is embedded in a result,
            // not a JSON-RPC message, so it has no `jsonrpc` or `id`
            // (2026-07-28 examples/InputRequiredResult).
            const method = request.object.get("method") orelse return error.InvalidValue;
            if (method != .string) return error.InvalidValue;
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

test "encodeRequest keeps number lexemes and field order, and adds _meta only to Modern" {
    const allocator = std.testing.allocator;
    const client = ClientInfo{ .name = "c", .version = "1" };
    const params = "{\"name\":\"t\",\"arguments\":{\"z\":0.123456789012345678901234567890,\"a\":1}}";
    const classic = try encodeRequest(allocator, 3, .classic_2025_11_25, client, .{}, "tools/call", params, .{});
    defer allocator.free(classic);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{\"z\":0.123456789012345678901234567890,\"a\":1}}}",
        classic,
    );
    const modern = try encodeRequest(allocator, 4, .modern_2026_07_28, client, .{ .elicitation = true }, "tools/list", "{}", .{});
    defer allocator.free(modern);
    try std.testing.expect(std.mem.indexOf(u8, modern, "\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, modern, "\"io.modelcontextprotocol/clientCapabilities\":{\"elicitation\":{}}") != null);
    try std.testing.expectError(error.InvalidValue, encodeRequest(allocator, 5, .classic_2025_11_25, client, .{}, "tools/list", "[]", .{}));
}

test "interop envelope accepts an error without id or jsonrpc; strict refuses both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const null_id = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"Bad Request\"}}";
    const tolerated = try parseEnvelopeWith(a, null_id, 7, .discovery, .{}, .interop);
    try std.testing.expectEqual(canonical.DiagnosticCode.remote_error, tolerated.diagnostic.code);
    const refused = try parseEnvelopeWith(a, null_id, 7, .discovery, .{}, .strict);
    try std.testing.expectEqual(canonical.DiagnosticCode.response_id_mismatch, refused.diagnostic.code);
    const bare = "{\"id\":7,\"result\":{\"ok\":true}}";
    try std.testing.expect((try parseEnvelopeWith(a, bare, 7, .tools_list, .{}, .interop)) == .value);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.invalid_envelope,
        (try parseEnvelopeWith(a, bare, 7, .tools_list, .{}, .strict)).diagnostic.code,
    );
    // Another request's numeric id stays somebody else's answer under both.
    const other = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}";
    try std.testing.expectEqual(
        canonical.DiagnosticCode.response_id_mismatch,
        (try parseEnvelopeWith(a, other, 7, .tools_list, .{}, .interop)).diagnostic.code,
    );
}

test "classifyFrame reads top-level members, not nested properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const elicit = "{\"id\":9,\"method\":\"elicitation/create\",\"params\":{\"requestedSchema\":{\"properties\":{\"result\":{\"type\":\"string\"}}}}}";
    const request = try classifyFrame(a, elicit);
    try std.testing.expectEqual(@as(u64, 9), request.server_request.id);
    try std.testing.expect((try classifyFrame(a, "{\"method\":\"notifications/x\"}")) == .notification);
    try std.testing.expectEqual(@as(?u64, 4), (try classifyFrame(a, "{\"id\":4,\"result\":{\"method\":\"x\"}}")).response.id);
    try std.testing.expectEqual(@as(?u64, null), (try classifyFrame(a, "{\"id\":\"s\",\"error\":{}}")).response.id);
    try std.testing.expect((try classifyFrame(a, "not json")) == .malformed);
    try std.testing.expect((try classifyFrame(a, "[1]")) == .malformed);
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
    // An absent resultType is "complete" in every era.
    try std.testing.expect(validateCompleteResult(missing.value, .modern_2026_07_28, .tools_call, .{}) == null);
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
