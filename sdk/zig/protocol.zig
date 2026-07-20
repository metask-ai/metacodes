//! Typed JSON protocol shipped beside the AgentCore binary ABI v1.
//!
//! This module is source-free: it mirrors the stable wire contract without
//! importing metacodes implementation modules. Known payloads ignore additive
//! fields. Unknown observation events are preserved for forward compatibility;
//! unknown UI/control messages and invalid known payloads fail closed.

const std = @import("std");

pub const UsageDelta = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const CoreEvent = union(enum) {
    text_chunk: []const u8,
    tool_start: struct {
        id: []const u8,
        name: []const u8,
        input: []const u8,
    },
    tool_progress: struct {
        id: []const u8,
        text: []const u8,
    },
    progress: struct {
        turn: u32,
        tool_name: []const u8,
        tool_input: []const u8,
        tool_calls: u32,
    },
    tool_result: struct {
        id: []const u8,
        name: []const u8,
        input: []const u8,
        content: []const u8,
        is_error: bool,
        elapsed_ms: u64 = 0,
    },
    usage: UsageDelta,
    context_warning: struct {
        current_tokens: u64,
        warning_threshold: u64,
        auto_compact_threshold: u64,
        blocking_limit: u64,
        level: []const u8,
    },
    auto_compact: struct {
        dropped: u32,
        kept: u32,
        before_tokens: u64 = 0,
        after_tokens: u64 = 0,
        cause: []const u8 = "trigger",
    },
    retry_notice: struct {
        attempt: u32,
        max: u32,
        delay_ms: u64,
    },
    stream_done,
};

/// A valid, single-tag observation event added after this SDK was shipped.
/// `payload_json` is an owned, normalized JSON encoding of the tag payload.
pub const UnknownCoreEvent = struct {
    tag: []const u8,
    payload_json: []const u8,
};

pub const DecodedCoreEvent = union(enum) {
    known: CoreEvent,
    unknown: UnknownCoreEvent,
};

pub const AskOption = struct {
    label: []const u8,
    description: []const u8,
    preview: []const u8 = "",
};

pub const AskQuestion = struct {
    question: []const u8,
    header: []const u8,
    multi: bool,
    options: []const AskOption,
};

pub const PermissionChoice = enum {
    allow_once,
    allow_always,
    deny_once,
    deny_tool_session,
};

pub const UiRequest = union(enum) {
    ask_question: []const AskQuestion,
    permission: struct { tool: []const u8, args: []const u8 },
};

pub const UiResponse = union(enum) {
    answers: []const []const u8,
    permission: PermissionChoice,
};

pub const ParsedCoreEvent = std.json.Parsed(DecodedCoreEvent);
pub const ParsedUiRequest = std.json.Parsed(UiRequest);
pub const ParsedUiResponse = std.json.Parsed(UiResponse);

pub const DecodeError = error{
    OutOfMemory,
    MalformedJson,
    UnknownTag,
    InvalidPayload,
};

pub const EncodeError = error{
    OutOfMemory,
    MismatchedResponse,
    InvalidResponse,
};

pub fn decodeCoreEvent(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!ParsedCoreEvent {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // The known-event path is hot (especially text_chunk/tool_progress), so
    // inspect only the first object key before doing one typed parse. Building
    // a complete dynamic Value and then a second typed representation doubled
    // allocation and copying for every event.
    var scanner = std.json.Scanner.initCompleteInput(a, encoded);
    defer scanner.deinit();
    const begin = scanner.next() catch |err| return normalizeDecodeError(err);
    if (begin != .object_begin) return error.InvalidPayload;
    const tag_token = scanner.nextAllocMax(a, .alloc_if_needed, encoded.len) catch |err|
        return normalizeDecodeError(err);
    const tag = switch (tag_token) {
        .string => |value| value,
        .allocated_string => |value| value,
        else => return error.InvalidPayload,
    };
    if (std.meta.stringToEnum(std.meta.Tag(CoreEvent), tag) != null) {
        const known = std.json.parseFromSliceLeaky(CoreEvent, a, encoded, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        }) catch |err| return normalizeDecodeError(err);
        return .{ .arena = arena, .value = .{ .known = known } };
    }

    // Unknown observation tags are rare and need an owned normalized payload,
    // so only this compatibility path pays for a dynamic JSON tree.
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return normalizeDecodeError(err);
    if (root != .object or root.object.count() != 1) return error.InvalidPayload;
    var fields = root.object.iterator();
    const field = fields.next() orelse return error.InvalidPayload;
    const payload_json = std.json.Stringify.valueAlloc(a, field.value_ptr.*, .{}) catch return error.OutOfMemory;
    return .{
        .arena = arena,
        .value = .{ .unknown = .{
            .tag = field.key_ptr.*,
            .payload_json = payload_json,
        } },
    };
}

pub fn decodeUiRequest(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!ParsedUiRequest {
    return decode(UiRequest, allocator, encoded);
}

/// Primarily used by the binary facade to validate Host-owned response bytes
/// against the same source-free schema shipped to consumers.
pub fn decodeUiResponse(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!ParsedUiResponse {
    return decode(UiResponse, allocator, encoded);
}

pub fn encodeUiResponse(allocator: std.mem.Allocator, request: UiRequest, response: UiResponse) EncodeError![]u8 {
    switch (request) {
        .ask_question => |questions| switch (response) {
            .answers => |answers| if (answers.len != questions.len) return error.InvalidResponse,
            else => return error.MismatchedResponse,
        },
        .permission => if (response != .permission) return error.MismatchedResponse,
    }
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}

fn decode(comptime T: type, allocator: std.mem.Allocator, encoded: []const u8) DecodeError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return normalizeDecodeError(err);
}

fn normalizeDecodeError(err: anyerror) DecodeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError, error.UnexpectedEndOfInput, error.BufferUnderrun => error.MalformedJson,
        error.UnknownField => error.UnknownTag,
        else => error.InvalidPayload,
    };
}

test "CoreEvent decoder covers every ABI v1 tag" {
    const cases = [_][]const u8{
        "{\"text_chunk\":\"hello\"}",
        "{\"tool_start\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\"}}",
        "{\"tool_progress\":{\"id\":\"t1\",\"text\":\"working\"}}",
        "{\"progress\":{\"turn\":1,\"tool_name\":\"Read\",\"tool_input\":\"{}\",\"tool_calls\":2}}",
        "{\"tool_result\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"elapsed_ms\":18446744073709551615}}",
        "{\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"cache_read_input_tokens\":3,\"cache_creation_input_tokens\":4}}",
        "{\"context_warning\":{\"current_tokens\":1,\"warning_threshold\":2,\"auto_compact_threshold\":3,\"blocking_limit\":4,\"level\":\"medium\"}}",
        "{\"auto_compact\":{\"dropped\":1,\"kept\":2,\"before_tokens\":3,\"after_tokens\":4,\"cause\":\"trigger\"}}",
        "{\"retry_notice\":{\"attempt\":1,\"max\":2,\"delay_ms\":3}}",
        "{\"stream_done\":{}}",
    };
    try std.testing.expectEqual(std.meta.fields(std.meta.Tag(CoreEvent)).len, cases.len);
    for (cases) |encoded| {
        const parsed = try decodeCoreEvent(std.testing.allocator, encoded);
        parsed.deinit();
    }
}

test "decoded strings are owned independently of callback input" {
    const allocator = std.testing.allocator;
    const encoded = try allocator.dupe(u8, "{\"text_chunk\":\"owned\"}");
    var parsed = try decodeCoreEvent(allocator, encoded);
    @memset(encoded, 'x');
    allocator.free(encoded);
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |event| try std.testing.expectEqualStrings("owned", event.text_chunk),
        .unknown => return error.UnexpectedUnknownEvent,
    }
}

test "known payloads accept additive fields" {
    var parsed = try decodeCoreEvent(std.testing.allocator, "{\"retry_notice\":{\"attempt\":1,\"max\":2,\"delay_ms\":3,\"future_hint\":true}}");
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |event| try std.testing.expectEqual(@as(u64, 3), event.retry_notice.delay_ms),
        .unknown => return error.UnexpectedUnknownEvent,
    }

    var ui = try decodeUiRequest(std.testing.allocator, "{\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\",\"future_hint\":true}}");
    defer ui.deinit();
    try std.testing.expectEqualStrings("Bash", ui.value.permission.tool);
}

test "wire integers accept full u32 and u64 ranges" {
    var parsed = try decodeCoreEvent(std.testing.allocator, "{\"progress\":{\"turn\":4294967295,\"tool_name\":\"Read\",\"tool_input\":\"{}\",\"tool_calls\":4294967295}}");
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |event| {
            try std.testing.expectEqual(std.math.maxInt(u32), event.progress.turn);
            try std.testing.expectEqual(std.math.maxInt(u32), event.progress.tool_calls);
        },
        .unknown => return error.UnexpectedUnknownEvent,
    }
}

test "CoreEvent decoder preserves unknown observation tags" {
    var parsed = try decodeCoreEvent(std.testing.allocator, "{\"future_event\":{\"answer\":42}}");
    defer parsed.deinit();
    switch (parsed.value) {
        .known => return error.UnexpectedKnownEvent,
        .unknown => |event| {
            try std.testing.expectEqualStrings("future_event", event.tag);
            try std.testing.expectEqualStrings("{\"answer\":42}", event.payload_json);
        },
    }
}

test "CoreEvent decoder normalizes malformed and invalid inputs" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MalformedJson, decodeCoreEvent(a, "{"));
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(a, "{\"stream_done\":{},\"future_event\":{}}"));
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(a, "{\"stream_done\":{},\"stream_done\":{}}"));
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(a, "{\"retry_notice\":{\"attempt\":1,\"max\":2}}"));
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(a, "{\"retry_notice\":{\"attempt\":-1,\"max\":2,\"delay_ms\":3}}"));
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(a, "{\"retry_notice\":{\"attempt\":1,\"max\":2,\"delay_ms\":18446744073709551616}}"));
}

test "UiRequest decoder covers every tag and response encoder enforces pairing" {
    const a = std.testing.allocator;
    const requests = [_][]const u8{
        "{\"ask_question\":[{\"question\":\"Continue?\",\"header\":\"Choice\",\"multi\":false,\"options\":[{\"label\":\"Yes\",\"description\":\"Proceed\",\"preview\":\"\"}]}]}",
        "{\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\"}}",
    };
    try std.testing.expectEqual(std.meta.fields(std.meta.Tag(UiRequest)).len, requests.len);
    try std.testing.expectEqual(@as(usize, 2), std.meta.fields(std.meta.Tag(UiResponse)).len);
    for (requests) |encoded| {
        const parsed = try decodeUiRequest(a, encoded);
        parsed.deinit();
    }

    const answers = [_][]const u8{ "Yes", "需要转义 \"quote\"" };
    const ask_request = UiRequest{ .ask_question = &.{
        .{ .question = "First?", .header = "One", .multi = false, .options = &.{} },
        .{ .question = "Second?", .header = "Two", .multi = false, .options = &.{} },
    } };
    const encoded = try encodeUiResponse(a, ask_request, .{ .answers = &answers });
    defer a.free(encoded);
    try std.testing.expectEqualStrings("{\"answers\":[\"Yes\",\"需要转义 \\\"quote\\\"\"]}", encoded);

    const permission_request = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const permission = try encodeUiResponse(a, permission_request, .{ .permission = .allow_always });
    defer a.free(permission);
    try std.testing.expectEqualStrings("{\"permission\":\"allow_always\"}", permission);
    try std.testing.expectError(error.MismatchedResponse, encodeUiResponse(a, permission_request, .{ .answers = &answers }));
    try std.testing.expectError(error.InvalidResponse, encodeUiResponse(a, ask_request, .{ .answers = answers[0..1] }));
}

test "UiRequest decoder rejects unknown tags and invalid payloads" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MalformedJson, decodeUiRequest(a, "{"));
    try std.testing.expectError(error.UnknownTag, decodeUiRequest(a, "{\"future\":{}}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"permission\":{\"tool\":\"Bash\"}}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\"},\"future\":{}}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\"},\"permission\":{\"tool\":\"Bash\",\"args\":\"{}\"}}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"ask_question\":{}}"));
}

test "UiResponse decoder rejects unknown tags and invalid payloads" {
    const a = std.testing.allocator;
    var permission = try decodeUiResponse(a, "{\"permission\":\"allow_once\"}");
    defer permission.deinit();
    try std.testing.expectEqual(PermissionChoice.allow_once, permission.value.permission);
    try std.testing.expectError(error.UnknownTag, decodeUiResponse(a, "{\"future\":{}}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiResponse(a, "{\"permission\":\"future\"}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiResponse(a, "{\"permission\":\"allow_once\",\"answers\":[]}"));
}

test "decoder and encoder normalize allocation failure" {
    var decode_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodeCoreEvent(decode_failing.allocator(), "{\"text_chunk\":\"x\"}"));
    var encode_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const answers = [_][]const u8{"Yes"};
    const request = UiRequest{ .ask_question = &.{.{ .question = "Continue?", .header = "Choice", .multi = false, .options = &.{} }} };
    try std.testing.expectError(error.OutOfMemory, encodeUiResponse(encode_failing.allocator(), request, .{ .answers = &answers }));
}
