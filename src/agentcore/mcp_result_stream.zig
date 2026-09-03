//! Bounded, streaming projection of one completed MCP `tools/call` response.
//!
//! The transport writes the complete JSON-RPC frame into a kernel-private
//! `Capture` from byte zero. This module then scans that file with O(depth)
//! parser state, rejects malformed/over-budget envelopes, and publishes only
//! the exact successful `result` value. Remote errors and MCP `isError`
//! results never enter the content-addressed artifact store.
//!
//! The caller hands over its model-derived `result_budget.Budget`. This
//! projector reads only `per_result_bytes`: turn-level allocation belongs to
//! the later conversation projection, which can see sibling tool results.

const std = @import("std");
const artifact_store = @import("../core/tool_result_artifact.zig");
const pfs = @import("platform").fs;
const result_budget = @import("../core/result_budget.zig");
const tool_result = @import("../core/tool_result.zig");
const tool_error = @import("../core/tool_error.zig");

pub const Era = enum { modern_2026_07_28, classic_2025_11_25, classic_2025_06_18 };

pub const Limits = struct {
    max_text_bytes: usize = 64 * 1024,
    max_json_depth: u16 = 64,
    max_json_nodes: u32 = 131_072,
};

pub const DiagnosticCode = enum {
    invalid_json,
    invalid_envelope,
    response_id_mismatch,
    remote_error,
    method_not_found,
    missing_required_field,
    invalid_field,
    resource_limit,
    missing_result_type,
    unsupported_result_type,
    input_required_unsupported,
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    rpc_code: ?i64 = null,

    pub fn init(code: DiagnosticCode) Diagnostic {
        return .{ .code = code };
    }
};

fn ParsedOutcome(comptime T: type) type {
    return union(enum) { value: T, diagnostic: Diagnostic };
}

pub const RESPONSE_OVERHEAD_BYTES: u64 = 1024 * 1024;
pub const MAX_RESPONSE_BYTES: u64 = artifact_store.MAX_ARTIFACT_BYTES +
    RESPONSE_OVERHEAD_BYTES;

pub const Outcome = union(enum) {
    result: tool_result.ToolResultBody,
    diagnostic: Diagnostic,
};

const ValueKind = enum { object, array, string, number, boolean, null };
const Role = enum { root, result, remote_error, other };
const Field = enum {
    none,
    jsonrpc,
    id,
    result,
    remote_error,
    result_type,
    content,
    structured_content,
    is_error,
    meta,
    error_code,
    error_message,
    other,
};

const ResultType = enum { missing, complete, input_required, unsupported };

const Frame = struct {
    kind: enum { object, array },
    role: Role,
    expects_key: bool,
    pending_field: Field = .none,
    keys: std.AutoHashMapUnmanaged([32]u8, void) = .empty,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
    }
};

const ParseState = struct {
    allocator: std.mem.Allocator,
    expected_id: u64,
    era: Era,
    limits: Limits,
    has_output_schema: bool,
    require_content: bool,
    frames: std.ArrayList(Frame) = .empty,
    nodes: u32 = 0,
    root_values: u8 = 0,

    root_jsonrpc_seen: bool = false,
    root_jsonrpc_ok: bool = false,
    root_id_seen: bool = false,
    root_id_ok: bool = false,
    root_result_seen: bool = false,
    root_error_seen: bool = false,

    result_start: ?u64 = null,
    result_end: ?u64 = null,
    result_type: ResultType = .missing,
    content_seen: bool = false,
    structured_content_seen: bool = false,
    is_error: bool = false,

    remote_code_seen: bool = false,
    remote_code: ?i64 = null,
    remote_message_seen: bool = false,

    string_active: bool = false,
    string_is_key: bool = false,
    string_field: Field = .none,
    string_len: u64 = 0,
    string_prefix: [128]u8 = undefined,
    string_prefix_len: usize = 0,
    string_hash: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    string_invalid_text: bool = false,

    number_active: bool = false,
    number_field: Field = .none,
    number_prefix: [96]u8 = undefined,
    number_prefix_len: usize = 0,
    number_truncated: bool = false,

    fn deinit(self: *ParseState) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }

    fn current(self: *ParseState) ?*Frame {
        if (self.frames.items.len == 0) return null;
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn countValue(self: *ParseState) !void {
        if (self.nodes == self.limits.max_json_nodes) return error.ResourceLimit;
        self.nodes += 1;
    }

    fn beginContainer(self: *ParseState, kind: ValueKind, end_offset: u64) !void {
        const role = try self.admitValue(kind);
        if (self.frames.items.len == self.limits.max_json_depth)
            return error.ResourceLimit;
        if (role == .result) self.result_start = end_offset - 1;
        try self.frames.append(self.allocator, .{
            .kind = if (kind == .object) .object else .array,
            .role = role,
            .expects_key = kind == .object,
        });
    }

    fn endContainer(self: *ParseState, kind: ValueKind, end_offset: u64) !void {
        if (self.frames.items.len == 0) return error.InvalidJson;
        var frame = self.frames.pop().?;
        defer frame.deinit(self.allocator);
        const expected: @TypeOf(frame.kind) = if (kind == .object) .object else .array;
        if (frame.kind != expected) return error.InvalidJson;
        if (frame.kind == .object and !frame.expects_key) return error.InvalidJson;
        if (frame.role == .result) self.result_end = end_offset;
    }

    /// Admit one logical value and consume the parent object's pending field.
    /// The returned role is meaningful only for a container being pushed.
    fn admitValue(self: *ParseState, kind: ValueKind) !Role {
        try self.countValue();
        const parent = self.current() orelse {
            if (self.root_values != 0 or kind != .object) return error.InvalidEnvelope;
            self.root_values = 1;
            return .root;
        };
        if (parent.kind == .array) return .other;
        if (parent.expects_key) return error.InvalidJson;
        const field = parent.pending_field;
        parent.pending_field = .none;
        parent.expects_key = true;
        try self.validateFieldValue(parent.role, field, kind);
        return switch (parent.role) {
            .root => switch (field) {
                .result => .result,
                .remote_error => .remote_error,
                else => .other,
            },
            else => .other,
        };
    }

    fn validateFieldValue(
        self: *ParseState,
        role: Role,
        field: Field,
        kind: ValueKind,
    ) !void {
        switch (role) {
            .root => switch (field) {
                .jsonrpc => if (kind != .string) return error.InvalidEnvelope,
                .id => if (kind != .number) return error.ResponseIdMismatch,
                .result => {
                    self.root_result_seen = true;
                    if (kind != .object) return error.InvalidEnvelope;
                },
                .remote_error => {
                    self.root_error_seen = true;
                    if (kind != .object) return error.InvalidEnvelope;
                },
                else => {},
            },
            .result => switch (field) {
                .result_type => if (kind != .string) return error.InvalidField,
                .content => {
                    self.content_seen = true;
                    if (kind != .array) return error.InvalidField;
                },
                .structured_content => self.structured_content_seen = true,
                .is_error => if (kind != .boolean) return error.InvalidField,
                .meta => if (kind != .object) return error.InvalidField,
                else => {},
            },
            .remote_error => switch (field) {
                .error_code => if (kind != .number) return error.InvalidEnvelope,
                .error_message => if (kind != .string) return error.InvalidEnvelope,
                else => {},
            },
            .other => {},
        }
    }

    fn startString(self: *ParseState) !void {
        if (self.string_active or self.number_active) return error.InvalidJson;
        const frame = self.current();
        self.string_active = true;
        self.string_is_key = frame != null and frame.?.kind == .object and frame.?.expects_key;
        self.string_field = if (self.string_is_key or frame == null) .none else frame.?.pending_field;
        self.string_len = 0;
        self.string_prefix_len = 0;
        self.string_hash = std.crypto.hash.sha2.Sha256.init(.{});
        self.string_invalid_text = false;
    }

    fn appendString(self: *ParseState, bytes: []const u8) !void {
        if (!self.string_active) try self.startString();
        self.string_len = std.math.add(u64, self.string_len, bytes.len) catch
            return error.ResourceLimit;
        if (self.string_len > MAX_RESPONSE_BYTES) return error.ResourceLimit;
        for (bytes) |byte| {
            if (byte < 0x20 and byte != '\t' and byte != '\r' and byte != '\n')
                self.string_invalid_text = true;
        }
        self.string_hash.update(bytes);
        const room = self.string_prefix.len - self.string_prefix_len;
        const copy_len = @min(room, bytes.len);
        @memcpy(
            self.string_prefix[self.string_prefix_len .. self.string_prefix_len + copy_len],
            bytes[0..copy_len],
        );
        self.string_prefix_len += copy_len;
    }

    fn finishString(self: *ParseState) !void {
        if (!self.string_active or self.string_invalid_text) return error.InvalidField;
        defer self.string_active = false;
        const complete = self.string_len == self.string_prefix_len;
        const value = self.string_prefix[0..self.string_prefix_len];
        if (self.string_is_key) {
            const frame = self.current() orelse return error.InvalidJson;
            if (frame.kind != .object or !frame.expects_key) return error.InvalidJson;
            if (self.string_len == 0 or self.string_len > self.limits.max_text_bytes)
                return error.ResourceLimit;
            var digest: [32]u8 = undefined;
            self.string_hash.final(&digest);
            const inserted = try frame.keys.getOrPut(self.allocator, digest);
            if (inserted.found_existing) return error.DuplicateField;
            frame.pending_field = if (complete)
                classifyField(frame.role, value)
            else
                .other;
            frame.expects_key = false;
            return;
        }

        _ = try self.admitValue(.string);
        const frame_role = if (self.frames.items.len == 0)
            Role.other
        else
            self.frames.items[self.frames.items.len - 1].role;
        _ = frame_role;
        switch (self.string_field) {
            .jsonrpc => {
                self.root_jsonrpc_seen = true;
                self.root_jsonrpc_ok = complete and std.mem.eql(u8, value, "2.0");
            },
            .result_type => {
                self.result_type = if (!complete)
                    .unsupported
                else if (std.mem.eql(u8, value, "complete"))
                    .complete
                else if (std.mem.eql(u8, value, "input_required"))
                    .input_required
                else
                    .unsupported;
            },
            .error_message => {
                self.remote_message_seen = true;
                if (self.string_len > self.limits.max_text_bytes) return error.ResourceLimit;
            },
            else => {},
        }
    }

    fn startNumber(self: *ParseState) !void {
        if (self.number_active or self.string_active) return error.InvalidJson;
        const frame = self.current();
        self.number_active = true;
        self.number_field = if (frame == null or frame.?.kind == .array or frame.?.expects_key)
            .none
        else
            frame.?.pending_field;
        self.number_prefix_len = 0;
        self.number_truncated = false;
    }

    fn appendNumber(self: *ParseState, bytes: []const u8) !void {
        if (!self.number_active) try self.startNumber();
        const room = self.number_prefix.len - self.number_prefix_len;
        const copy_len = @min(room, bytes.len);
        @memcpy(
            self.number_prefix[self.number_prefix_len .. self.number_prefix_len + copy_len],
            bytes[0..copy_len],
        );
        self.number_prefix_len += copy_len;
        if (copy_len != bytes.len) self.number_truncated = true;
    }

    fn finishNumber(self: *ParseState) !void {
        if (!self.number_active) return error.InvalidJson;
        defer self.number_active = false;
        _ = try self.admitValue(.number);
        const value = self.number_prefix[0..self.number_prefix_len];
        switch (self.number_field) {
            .id => {
                self.root_id_seen = true;
                self.root_id_ok = !self.number_truncated and
                    (std.fmt.parseInt(u64, value, 10) catch null) == self.expected_id;
            },
            .error_code => {
                self.remote_code_seen = true;
                self.remote_code = if (self.number_truncated)
                    null
                else
                    std.fmt.parseInt(i64, value, 10) catch null;
            },
            else => {},
        }
    }

    fn scalar(self: *ParseState, kind: ValueKind) !void {
        const frame = self.current();
        const field = if (frame == null or frame.?.kind == .array or frame.?.expects_key)
            .none
        else
            frame.?.pending_field;
        _ = try self.admitValue(kind);
        if (field == .is_error and kind == .boolean) {
            // Caller sets the actual boolean value because kind alone cannot.
        }
    }

    fn finish(self: *ParseState) ParsedOutcome(struct { start: u64, end: u64, is_error: bool }) {
        if (self.root_values != 1 or self.frames.items.len != 0 or
            !self.root_jsonrpc_seen or !self.root_jsonrpc_ok)
            return .{ .diagnostic = Diagnostic.init(.invalid_envelope) };
        if (!self.root_id_seen or !self.root_id_ok)
            return .{ .diagnostic = Diagnostic.init(.response_id_mismatch) };
        if (self.root_result_seen == self.root_error_seen)
            return .{ .diagnostic = Diagnostic.init(.invalid_envelope) };
        if (self.root_error_seen) {
            if (!self.remote_code_seen or self.remote_code == null or !self.remote_message_seen)
                return .{ .diagnostic = Diagnostic.init(.invalid_envelope) };
            return .{ .diagnostic = .{
                .code = if (self.remote_code.? == -32601) .method_not_found else .remote_error,
                .rpc_code = self.remote_code,
            } };
        }
        if (self.era == .modern_2026_07_28) switch (self.result_type) {
            .missing => return .{ .diagnostic = Diagnostic.init(.missing_result_type) },
            .input_required => return .{ .diagnostic = Diagnostic.init(.input_required_unsupported) },
            .unsupported => return .{ .diagnostic = Diagnostic.init(.unsupported_result_type) },
            .complete => {},
        };
        if (self.require_content and !self.content_seen)
            return .{ .diagnostic = Diagnostic.init(.missing_required_field) };
        if (!self.is_error and self.has_output_schema and !self.structured_content_seen)
            return .{ .diagnostic = Diagnostic.init(.invalid_field) };
        const start = self.result_start orelse
            return .{ .diagnostic = Diagnostic.init(.invalid_envelope) };
        const end = self.result_end orelse
            return .{ .diagnostic = Diagnostic.init(.invalid_envelope) };
        if (end <= start)
            return .{ .diagnostic = Diagnostic.init(.invalid_envelope) };
        return .{ .value = .{ .start = start, .end = end, .is_error = self.is_error } };
    }
};

fn classifyField(role: Role, value: []const u8) Field {
    return switch (role) {
        .root => if (std.mem.eql(u8, value, "jsonrpc"))
            .jsonrpc
        else if (std.mem.eql(u8, value, "id"))
            .id
        else if (std.mem.eql(u8, value, "result"))
            .result
        else if (std.mem.eql(u8, value, "error"))
            .remote_error
        else
            .other,
        .result => if (std.mem.eql(u8, value, "resultType"))
            .result_type
        else if (std.mem.eql(u8, value, "content"))
            .content
        else if (std.mem.eql(u8, value, "structuredContent"))
            .structured_content
        else if (std.mem.eql(u8, value, "isError"))
            .is_error
        else if (std.mem.eql(u8, value, "_meta"))
            .meta
        else
            .other,
        .remote_error => if (std.mem.eql(u8, value, "code"))
            .error_code
        else if (std.mem.eql(u8, value, "message"))
            .error_message
        else
            .other,
        .other => .other,
    };
}

fn mapParseError(err: anyerror) Diagnostic {
    return Diagnostic.init(switch (err) {
        error.ResourceLimit => .resource_limit,
        error.ResponseIdMismatch => .response_id_mismatch,
        error.InvalidEnvelope => .invalid_envelope,
        error.InvalidField, error.DuplicateField => .invalid_field,
        else => .invalid_json,
    });
}

fn publishRange(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    capture: *artifact_store.Capture,
    start: u64,
    length: u64,
) !tool_result.ToolResultBody {
    var spool = try artifact_store.Spool.begin(allocator, artifact_root);
    defer spool.deinit();
    try capture.copyRangeTo(&spool, start, length);
    const completed = try spool.finish();
    return tool_result.ToolResultBody.fromCompletedSpool(completed, .json);
}

pub fn project(
    allocator: std.mem.Allocator,
    capture: *artifact_store.Capture,
    artifact_root: []const u8,
    expected_id: u64,
    era: Era,
    limits: Limits,
    budget: result_budget.Budget,
    has_output_schema: bool,
    require_content: bool,
) error{OutOfMemory}!Outcome {
    capture.rewind() catch return .{ .diagnostic = Diagnostic.init(.resource_limit) };
    var scanner = std.json.Scanner.initStreaming(allocator);
    defer scanner.deinit();
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    var state = ParseState{
        .allocator = allocator,
        .expected_id = expected_id,
        .era = era,
        .limits = limits,
        .has_output_schema = has_output_schema,
        .require_content = require_content,
    };
    defer state.deinit();

    var input: [32 * 1024]u8 = undefined;
    var ended = false;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                const count = capture.read(&input) catch
                    return .{ .diagnostic = Diagnostic.init(.resource_limit) };
                if (count == 0) {
                    if (ended) return .{ .diagnostic = Diagnostic.init(.invalid_json) };
                    ended = true;
                    scanner.endInput();
                } else {
                    scanner.feedInput(input[0..count]);
                }
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .diagnostic = Diagnostic.init(.invalid_json) },
        };
        const offset = diagnostics.getByteOffset();
        switch (token) {
            .object_begin => state.beginContainer(.object, offset) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .array_begin => state.beginContainer(.array, offset) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .object_end => state.endContainer(.object, offset) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .array_end => state.endContainer(.array, offset) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .partial_string => |bytes| state.appendString(bytes) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .partial_string_escaped_1 => |bytes| state.appendString(bytes[0..]) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .partial_string_escaped_2 => |bytes| state.appendString(bytes[0..]) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .partial_string_escaped_3 => |bytes| state.appendString(bytes[0..]) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .partial_string_escaped_4 => |bytes| state.appendString(bytes[0..]) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .string => |bytes| {
                state.appendString(bytes) catch |err|
                    return .{ .diagnostic = mapParseError(err) };
                state.finishString() catch |err|
                    return .{ .diagnostic = mapParseError(err) };
            },
            .partial_number => |bytes| state.appendNumber(bytes) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .number => |bytes| {
                state.appendNumber(bytes) catch |err|
                    return .{ .diagnostic = mapParseError(err) };
                state.finishNumber() catch |err|
                    return .{ .diagnostic = mapParseError(err) };
            },
            .true, .false => {
                const field = if (state.current()) |frame|
                    if (frame.kind == .object and !frame.expects_key) frame.pending_field else .none
                else
                    .none;
                state.scalar(.boolean) catch |err|
                    return .{ .diagnostic = mapParseError(err) };
                if (field == .is_error) state.is_error = token == .true;
            },
            .null => state.scalar(.null) catch |err|
                return .{ .diagnostic = mapParseError(err) },
            .end_of_document => break,
            .allocated_number, .allocated_string => unreachable,
        }
    }

    const parsed = state.finish();
    const range = switch (parsed) {
        .diagnostic => |diagnostic| return .{ .diagnostic = diagnostic },
        .value => |value| value,
    };
    const length_u64 = range.end - range.start;
    if (range.is_error) {
        const detail_len: usize = @intCast(@min(length_u64, 64 * 1024));
        const prefix = capture.readRangeAlloc(allocator, range.start, detail_len) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = Diagnostic.init(.resource_limit) };
        };
        defer allocator.free(prefix);
        const detail = if (length_u64 == detail_len)
            try allocator.dupe(u8, prefix)
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}\n[MCP error truncated: original_bytes={d}]",
                .{ prefix, length_u64 },
            );
        const structured = tool_error.ToolError.init(
            .other,
            .user_error,
            detail,
            true,
        );
        defer structured.deinit(allocator);
        const encoded = structured.toJson(allocator) catch return error.OutOfMemory;
        defer allocator.free(encoded);
        const body = tool_result.ToolResultBody.initStructuredError(
            allocator,
            encoded,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = Diagnostic.init(.resource_limit) };
        };
        return .{ .result = body };
    }
    if (length_u64 <= budget.per_result_bytes) {
        const bytes = capture.readRangeAlloc(allocator, range.start, @intCast(length_u64)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = Diagnostic.init(.resource_limit) };
        };
        return .{ .result = tool_result.ToolResultBody.initInline(bytes) };
    }
    if (length_u64 > artifact_store.MAX_ARTIFACT_BYTES)
        return .{ .diagnostic = Diagnostic.init(.resource_limit) };
    const body = publishRange(allocator, artifact_root, capture, range.start, length_u64) catch |err| {
        // Keep a complete bounded result renderable when CAS publication fails.
        if (!result_budget.retainInlineAfterFailedPublish(
            err,
            length_u64,
            true,
            result_budget.PER_RESULT_MAX_BYTES,
        )) {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = Diagnostic.init(.resource_limit) };
        }
        const bytes = capture.readRangeAlloc(allocator, range.start, @intCast(length_u64)) catch |read_err| {
            if (read_err == error.OutOfMemory) return error.OutOfMemory;
            return .{ .diagnostic = Diagnostic.init(.resource_limit) };
        };
        return .{ .result = tool_result.ToolResultBody.initInline(bytes) };
    };
    return .{ .result = body };
}

fn writeSuccessfulResultOfSize(
    capture: *artifact_store.Capture,
    result_bytes: usize,
) !void {
    const envelope_prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":";
    const result_prefix = "{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":{\"payload\":\"";
    const result_suffix = "\"}}";
    if (result_bytes < result_prefix.len + result_suffix.len)
        return error.ResultTooSmall;

    try capture.write(envelope_prefix);
    try capture.write(result_prefix);
    var block: [4096]u8 = undefined;
    @memset(&block, 'm');
    var remaining = result_bytes - result_prefix.len - result_suffix.len;
    while (remaining != 0) {
        const count = @min(remaining, block.len);
        try capture.write(block[0..count]);
        remaining -= count;
    }
    try capture.write(result_suffix);
    try capture.write("}");
}

fn fillSessionArtifactQuota(allocator: std.mem.Allocator, root: []const u8) !void {
    const seed = try artifact_store.persist(allocator, root, "seed");
    _ = seed;
    const filler = try std.fmt.allocPrintSentinel(
        allocator,
        "{s}/tool-results/sha256/quota-fixture.blob",
        .{root},
        0,
    );
    defer allocator.free(filler);
    const fd = pfs.open(
        filler.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true },
        0o600,
    );
    if (fd < 0) return error.QuotaFixtureOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.setSize(fd, artifact_store.MAX_SESSION_BYTES);
}

test "stream projector publishes above caller per-result budget" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try writeSuccessfulResultOfSize(&capture, 30_000);
    try capture.seal();

    const budget = result_budget.Budget.fromModel(200_000);
    try std.testing.expectEqual(@as(usize, 25_000), budget.per_result_bytes);
    var outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        budget,
        true,
        true,
    );
    defer if (outcome == .result) outcome.result.deinit(allocator);
    try std.testing.expect(outcome == .result);
    try std.testing.expect(outcome.result == .artifact);
    try std.testing.expectEqual(@as(u64, 30_000), outcome.result.artifact.stored.bytes);
}

test "stream projector inlines at caller per-result budget" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try writeSuccessfulResultOfSize(&capture, 25_000);
    try capture.seal();

    const budget = result_budget.Budget.fromModel(200_000);
    try std.testing.expectEqual(@as(usize, 25_000), budget.per_result_bytes);
    var outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        budget,
        true,
        true,
    );
    defer if (outcome == .result) outcome.result.deinit(allocator);
    try std.testing.expect(outcome == .result);
    try std.testing.expect(outcome.result == .@"inline");
    try std.testing.expectEqual(@as(usize, 25_000), outcome.result.@"inline".bytes.len);
}

test "stream projector retains bounded result inline when publication fails" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try fillSessionArtifactQuota(allocator, root);
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try writeSuccessfulResultOfSize(&capture, 30_000);
    try capture.seal();

    const budget = result_budget.Budget.fromModel(200_000);
    var outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        budget,
        true,
        true,
    );
    defer if (outcome == .result) outcome.result.deinit(allocator);
    try std.testing.expect(outcome == .result);
    try std.testing.expect(outcome.result == .@"inline");
    try std.testing.expectEqual(@as(usize, 30_000), outcome.result.@"inline".bytes.len);
}

test "stream projector rejects over-ceiling result when publication fails" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try fillSessionArtifactQuota(allocator, root);
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try writeSuccessfulResultOfSize(&capture, 96 * 1024);
    try capture.seal();

    const budget = result_budget.Budget.fromModel(1_000_000);
    try std.testing.expectEqual(result_budget.PER_RESULT_MAX_BYTES, budget.per_result_bytes);
    const outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        budget,
        true,
        true,
    );
    try std.testing.expect(outcome == .diagnostic);
    try std.testing.expectEqual(DiagnosticCode.resource_limit, outcome.diagnostic.code);
}

test "stream projector publishes only a large successful result range" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try capture.write("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":{\"payload\":\"");
    var block: [4096]u8 = undefined;
    @memset(&block, 'm');
    var remaining: usize = 96 * 1024;
    while (remaining != 0) {
        const count = @min(remaining, block.len);
        try capture.write(block[0..count]);
        remaining -= count;
    }
    try capture.write("\"}}}");
    try capture.seal();
    var outcome = try project(
        allocator,
        &capture,
        root,
        7,
        .modern_2026_07_28,
        .{},
        .{ .per_result_bytes = result_budget.PER_RESULT_MAX_BYTES },
        true,
        true,
    );
    defer if (outcome == .result) outcome.result.deinit(allocator);
    try std.testing.expect(outcome == .result);
    try std.testing.expect(outcome.result == .artifact);
    try std.testing.expect(outcome.result.artifact.stored.bytes > 96 * 1024);
    var first = try artifact_store.readChunk(
        allocator,
        root,
        outcome.result.artifact.stored.id(),
        0,
        128,
    );
    defer first.deinit();
    try std.testing.expect(std.mem.startsWith(u8, first.bytes, "{\"resultType\""));
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "jsonrpc") == null);
}

test "stream projector rejects remote error without publishing it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var capture = try artifact_store.Capture.begin(allocator, root, MAX_RESPONSE_BYTES);
    defer capture.deinit();
    try capture.write("{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"missing\"}}");
    try capture.seal();
    const outcome = try project(
        allocator,
        &capture,
        root,
        3,
        .classic_2025_11_25,
        .{},
        .floor,
        false,
        true,
    );
    try std.testing.expect(outcome == .diagnostic);
    try std.testing.expectEqual(DiagnosticCode.method_not_found, outcome.diagnostic.code);
}
