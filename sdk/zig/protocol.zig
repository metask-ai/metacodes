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
    allow_session,
    deny_once,
    deny_session,
};

pub const MAX_ANSWER_VALUES_PER_QUESTION_V1: usize = 64;

pub const Answer = struct {
    values: []const []const u8,
};

pub const UiRequest = union(enum) {
    ask_question: []const AskQuestion,
    permission: struct { tool: []const u8, args: []const u8 },
};

pub const UiResponse = union(enum) {
    answers: []const Answer,
    permission: PermissionChoice,
};

pub const SkillCatalogHealth = enum {
    healthy,
    degraded,
};

pub const SkillCatalogIssueCode = enum {
    invalid_definition,
    source_conflict,
    invalid_resource,
    invalid_invocation_name,
};

pub const SkillSourceScope = enum {
    enterprise,
    personal,
    project,
    plugin,
};

pub const SkillArgumentSchema = struct {
    schema: []const u8,
    max_values: u32,
    names: []const []const u8,
};

pub const SkillDescriptor = struct {
    skill_id: []const u8,
    invocation_name: []const u8,
    display_name: []const u8,
    description: []const u8,
    argument_schema: SkillArgumentSchema,
};

pub const SkillCatalogIssue = struct {
    code: SkillCatalogIssueCode,
    invocation_name: ?[]const u8,
    source_scope: SkillSourceScope,
};

/// Source-free projection of the `metask.skill-catalog/v1` descriptor.
/// It deliberately excludes Skill bodies, physical paths, and policy state.
pub const SkillCatalog = struct {
    schema: []const u8,
    catalog_scope_id: []const u8,
    catalog_revision: []const u8,
    health: SkillCatalogHealth,
    skills: []const SkillDescriptor,
    issues: []const SkillCatalogIssue,
};

pub const ParsedCoreEvent = std.json.Parsed(DecodedCoreEvent);
pub const ParsedUiRequest = std.json.Parsed(UiRequest);
pub const ParsedUiResponse = std.json.Parsed(UiResponse);
pub const ParsedSkillCatalog = std.json.Parsed(SkillCatalog);

pub const MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1: usize = 4 * 1024 * 1024;
pub const MAX_SKILL_CATALOG_SKILLS_V1: usize = 1024;
pub const MAX_SKILL_ARGUMENT_VALUES_V1: usize = 64;
pub const MAX_SKILL_ARGUMENT_JSON_BYTES_V1: usize = 1024 * 1024;

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

pub const SkillCatalogDecodeError = DecodeError || error{ResourceLimit};

pub const SkillArgumentsEncodeError = error{
    OutOfMemory,
    InvalidArguments,
    ResourceLimit,
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

/// Decodes and owns a `metask.skill-catalog/v1` descriptor. The returned value
/// is independent of the AgentCore-owned ABI output buffer, so that buffer may
/// be released immediately after this call succeeds.
pub fn decodeSkillCatalog(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) SkillCatalogDecodeError!ParsedSkillCatalog {
    if (encoded.len > MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1)
        return error.ResourceLimit;
    var parsed = try decode(SkillCatalog, allocator, encoded);
    errdefer parsed.deinit();
    try validateSkillCatalog(parsed.value);
    return parsed;
}

pub fn encodeUiResponse(allocator: std.mem.Allocator, request: UiRequest, response: UiResponse) EncodeError![]u8 {
    switch (request) {
        .ask_question => |questions| switch (response) {
            .answers => |answers| {
                if (answers.len != questions.len) return error.InvalidResponse;
                for (questions, answers) |question, answer| {
                    if (question.options.len == 0) return error.InvalidResponse;
                    if (question.multi) {
                        if (answer.values.len == 0 or answer.values.len > MAX_ANSWER_VALUES_PER_QUESTION_V1)
                            return error.InvalidResponse;
                    } else if (answer.values.len != 1) {
                        return error.InvalidResponse;
                    }
                }
            },
            else => return error.MismatchedResponse,
        },
        .permission => if (response != .permission) return error.MismatchedResponse,
    }
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}

/// Encodes the only valid non-empty Skill argument wire shape. The returned
/// bytes are allocator-owned and remain borrowed by `sessionRunSkill` only for
/// that synchronous call.
pub fn encodeSkillArguments(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) SkillArgumentsEncodeError![]u8 {
    if (values.len > MAX_SKILL_ARGUMENT_VALUES_V1)
        return error.InvalidArguments;
    var raw_values_bytes: usize = 0;
    for (values) |value| {
        raw_values_bytes = std.math.add(
            usize,
            raw_values_bytes,
            value.len,
        ) catch return error.ResourceLimit;
        if (raw_values_bytes > MAX_SKILL_ARGUMENT_JSON_BYTES_V1)
            return error.ResourceLimit;
        if (!std.unicode.utf8ValidateSlice(value))
            return error.InvalidArguments;
    }

    const payload = struct { values: []const []const u8 }{ .values = values };
    var count_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&count_buffer);
    std.json.Stringify.value(payload, .{}, &discarding.writer) catch
        return error.OutOfMemory;
    const encoded_len_u64 = discarding.fullCount();
    if (encoded_len_u64 > MAX_SKILL_ARGUMENT_JSON_BYTES_V1 or
        encoded_len_u64 > std.math.maxInt(usize))
        return error.ResourceLimit;
    const encoded_len: usize = @intCast(encoded_len_u64);

    var allocating = std.Io.Writer.Allocating.initCapacity(
        allocator,
        encoded_len,
    ) catch return error.OutOfMemory;
    defer allocating.deinit();
    std.json.Stringify.value(payload, .{}, &allocating.writer) catch
        return error.OutOfMemory;
    const encoded = allocating.toOwnedSlice() catch return error.OutOfMemory;
    std.debug.assert(encoded.len == encoded_len);
    return encoded;
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

fn validateSkillCatalog(catalog: SkillCatalog) SkillCatalogDecodeError!void {
    if (!std.mem.eql(u8, catalog.schema, "metask.skill-catalog/v1") or
        !lowerHex64(catalog.catalog_scope_id) or
        !lowerHex64(catalog.catalog_revision))
        return error.InvalidPayload;
    if (catalog.skills.len > MAX_SKILL_CATALOG_SKILLS_V1)
        return error.ResourceLimit;

    switch (catalog.health) {
        .healthy => if (catalog.issues.len != 0) return error.InvalidPayload,
        .degraded => if (catalog.issues.len == 0) return error.InvalidPayload,
    }

    for (catalog.skills) |skill| {
        if (!lowerHex64(skill.skill_id) or
            !validInvocationName(skill.invocation_name) or
            !std.mem.eql(u8, skill.argument_schema.schema, "metask.skill-arguments/v1") or
            skill.argument_schema.max_values != MAX_SKILL_ARGUMENT_VALUES_V1 or
            !validArgumentNames(skill.argument_schema.names))
            return error.InvalidPayload;
    }
    for (catalog.issues) |issue| {
        if (issue.invocation_name) |name| {
            if (!validInvocationName(name)) return error.InvalidPayload;
        }
    }
}

fn lowerHex64(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f'))
            return false;
    }
    return true;
}

fn validInvocationName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!std.ascii.isAlphanumeric(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '_' and byte != ':' and byte != '-')
            return false;
    }
    return true;
}

fn validArgumentNames(names: []const []const u8) bool {
    if (names.len > MAX_SKILL_ARGUMENT_VALUES_V1) return false;
    for (names, 0..) |name, index| {
        if (name.len == 0 or name.len > 64 or
            (!std.ascii.isAlphabetic(name[0]) and name[0] != '_'))
            return false;
        for (name[1..]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_')
                return false;
        }
        for (names[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) return false;
        }
    }
    return true;
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

    const first_values = [_][]const u8{"Yes"};
    const second_values = [_][]const u8{"需要转义 \"quote\""};
    const answers = [_]Answer{
        .{ .values = &first_values },
        .{ .values = &second_values },
    };
    const ask_request = UiRequest{ .ask_question = &.{
        .{ .question = "First?", .header = "One", .multi = false, .options = &.{.{ .label = "Yes", .description = "Proceed" }} },
        .{ .question = "Second?", .header = "Two", .multi = false, .options = &.{.{ .label = "Custom", .description = "Free text is allowed" }} },
    } };
    const encoded = try encodeUiResponse(a, ask_request, .{ .answers = &answers });
    defer a.free(encoded);
    try std.testing.expectEqualStrings("{\"answers\":[{\"values\":[\"Yes\"]},{\"values\":[\"需要转义 \\\"quote\\\"\"]}]}", encoded);

    const permission_request = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const permission = try encodeUiResponse(a, permission_request, .{ .permission = .allow_session });
    defer a.free(permission);
    try std.testing.expectEqualStrings("{\"permission\":\"allow_session\"}", permission);
    try std.testing.expectError(error.MismatchedResponse, encodeUiResponse(a, permission_request, .{ .answers = &answers }));
    try std.testing.expectError(error.InvalidResponse, encodeUiResponse(a, ask_request, .{ .answers = answers[0..1] }));
}

test "answer cardinality uses an independent wire cap and preserves free text values" {
    const a = std.testing.allocator;
    const option = [_]AskOption{.{ .label = "Known", .description = "Catalog option" }};
    const multi_request = UiRequest{ .ask_question = &.{.{
        .question = "Choose or explain",
        .header = "Choice",
        .multi = true,
        .options = &option,
    }} };
    const free_text_values = [_][]const u8{ "Known", "free text outside options" };
    const free_text_answers = [_]Answer{.{ .values = &free_text_values }};
    const encoded = try encodeUiResponse(a, multi_request, .{ .answers = &free_text_answers });
    defer a.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"answers\":[{\"values\":[\"Known\",\"free text outside options\"]}]}",
        encoded,
    );

    const empty_values = [_][]const u8{};
    const empty_answers = [_]Answer{.{ .values = &empty_values }};
    try std.testing.expectError(
        error.InvalidResponse,
        encodeUiResponse(a, multi_request, .{ .answers = &empty_answers }),
    );

    var too_many_values: [MAX_ANSWER_VALUES_PER_QUESTION_V1 + 1][]const u8 = undefined;
    for (&too_many_values) |*value| value.* = "x";
    const too_many_answers = [_]Answer{.{ .values = &too_many_values }};
    try std.testing.expectError(
        error.InvalidResponse,
        encodeUiResponse(a, multi_request, .{ .answers = &too_many_answers }),
    );

    const single_request = UiRequest{ .ask_question = &.{.{
        .question = "One answer",
        .header = "One",
        .multi = false,
        .options = &option,
    }} };
    try std.testing.expectError(
        error.InvalidResponse,
        encodeUiResponse(a, single_request, .{ .answers = &free_text_answers }),
    );

    const no_options_request = UiRequest{ .ask_question = &.{.{
        .question = "Impossible",
        .header = "None",
        .multi = true,
        .options = &.{},
    }} };
    try std.testing.expectError(
        error.InvalidResponse,
        encodeUiResponse(a, no_options_request, .{ .answers = &free_text_answers }),
    );
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

test "Skill catalog decoder owns and validates the public descriptor" {
    const a = std.testing.allocator;
    const scope_id = "0" ** 64;
    const revision = "1" ** 64;
    const skill_id = "c97ace4c8fef2cee8fa0f3c9f52aab18dbd4f42438afe362ffb8f75ce4c04b84";
    const encoded = try std.fmt.allocPrint(
        a,
        "{{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"healthy\",\"skills\":[{{\"skill_id\":\"{s}\",\"invocation_name\":\"review\",\"display_name\":\"Review\",\"description\":\"Review a target\",\"argument_schema\":{{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[\"target\"]}}}}],\"issues\":[]}}",
        .{ scope_id, revision, skill_id },
    );
    var parsed = try decodeSkillCatalog(a, encoded);
    @memset(encoded, 'x');
    a.free(encoded);
    defer parsed.deinit();

    try std.testing.expectEqual(SkillCatalogHealth.healthy, parsed.value.health);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.skills.len);
    try std.testing.expectEqualStrings("review", parsed.value.skills[0].invocation_name);
    try std.testing.expectEqualStrings(
        "target",
        parsed.value.skills[0].argument_schema.names[0],
    );
}

test "Skill catalog decoder rejects schema and semantic contradictions" {
    const a = std.testing.allocator;
    const hash = "0" ** 64;
    const wrong_schema = try std.fmt.allocPrint(
        a,
        "{{\"schema\":\"future\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"healthy\",\"skills\":[],\"issues\":[]}}",
        .{ hash, hash },
    );
    defer a.free(wrong_schema);
    try std.testing.expectError(
        error.InvalidPayload,
        decodeSkillCatalog(a, wrong_schema),
    );

    const contradictory_health = try std.fmt.allocPrint(
        a,
        "{{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"degraded\",\"skills\":[],\"issues\":[]}}",
        .{ hash, hash },
    );
    defer a.free(contradictory_health);
    try std.testing.expectError(
        error.InvalidPayload,
        decodeSkillCatalog(a, contradictory_health),
    );
}

test "Skill catalog decoder preserves identity semantics for the consumer" {
    const a = std.testing.allocator;
    const hash = "0" ** 64;
    const review_id = "c97ace4c8fef2cee8fa0f3c9f52aab18dbd4f42438afe362ffb8f75ce4c04b84";
    const mismatched = try std.fmt.allocPrint(
        a,
        "{{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"healthy\",\"skills\":[{{\"skill_id\":\"{s}\",\"invocation_name\":\"workctl\",\"display_name\":\"Workctl\",\"description\":\"Operate Work Agent\",\"argument_schema\":{{\"schema\":\"metask.skill-arguments/v1\",\"max_values\":64,\"names\":[]}}}}],\"issues\":[]}}",
        .{ hash, hash, review_id },
    );
    defer a.free(mismatched);
    var mismatched_parsed = try decodeSkillCatalog(a, mismatched);
    defer mismatched_parsed.deinit();
    try std.testing.expectEqualStrings(
        review_id,
        mismatched_parsed.value.skills[0].skill_id,
    );

    const skill = SkillDescriptor{
        .skill_id = review_id,
        .invocation_name = "review",
        .display_name = "Review",
        .description = "Review code",
        .argument_schema = .{
            .schema = "metask.skill-arguments/v1",
            .max_values = MAX_SKILL_ARGUMENT_VALUES_V1,
            .names = &.{},
        },
    };
    const duplicate_catalog = SkillCatalog{
        .schema = "metask.skill-catalog/v1",
        .catalog_scope_id = hash,
        .catalog_revision = hash,
        .health = .healthy,
        .skills = &.{ skill, skill },
        .issues = &.{},
    };
    const duplicate = try std.json.Stringify.valueAlloc(a, duplicate_catalog, .{});
    defer a.free(duplicate);
    var duplicate_parsed = try decodeSkillCatalog(a, duplicate);
    defer duplicate_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), duplicate_parsed.value.skills.len);
    try std.testing.expectEqualStrings(
        duplicate_parsed.value.skills[0].skill_id,
        duplicate_parsed.value.skills[1].skill_id,
    );
}

test "Skill catalog decoder enforces the public Skill slot limit" {
    const a = std.testing.allocator;
    const hash = "0" ** 64;
    const skill = SkillDescriptor{
        .skill_id = "c97ace4c8fef2cee8fa0f3c9f52aab18dbd4f42438afe362ffb8f75ce4c04b84",
        .invocation_name = "review",
        .display_name = "Review",
        .description = "Review code",
        .argument_schema = .{
            .schema = "metask.skill-arguments/v1",
            .max_values = MAX_SKILL_ARGUMENT_VALUES_V1,
            .names = &.{},
        },
    };
    const skills = try a.alloc(SkillDescriptor, MAX_SKILL_CATALOG_SKILLS_V1 + 1);
    defer a.free(skills);
    @memset(skills, skill);
    const oversized_catalog = SkillCatalog{
        .schema = "metask.skill-catalog/v1",
        .catalog_scope_id = hash,
        .catalog_revision = hash,
        .health = .healthy,
        .skills = skills,
        .issues = &.{},
    };
    const oversized = try std.json.Stringify.valueAlloc(a, oversized_catalog, .{});
    defer a.free(oversized);
    try expectSkillCatalogDecodeError(error.ResourceLimit, a, oversized);
}

test "Skill catalog decoder exposes typed degraded issues" {
    const a = std.testing.allocator;
    const hash = "0" ** 64;
    const encoded = try std.fmt.allocPrint(
        a,
        "{{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"degraded\",\"skills\":[],\"issues\":[{{\"code\":\"invalid_definition\",\"invocation_name\":\"review\",\"source_scope\":\"project\"}},{{\"code\":\"invalid_invocation_name\",\"invocation_name\":null,\"source_scope\":\"personal\"}}]}}",
        .{ hash, hash },
    );
    defer a.free(encoded);
    var parsed = try decodeSkillCatalog(a, encoded);
    defer parsed.deinit();

    try std.testing.expectEqual(SkillCatalogHealth.degraded, parsed.value.health);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.issues.len);
    try std.testing.expectEqual(
        SkillCatalogIssueCode.invalid_definition,
        parsed.value.issues[0].code,
    );
    try std.testing.expectEqualStrings(
        "review",
        parsed.value.issues[0].invocation_name.?,
    );
    try std.testing.expectEqual(
        SkillSourceScope.project,
        parsed.value.issues[0].source_scope,
    );
    try std.testing.expectEqual(
        SkillCatalogIssueCode.invalid_invocation_name,
        parsed.value.issues[1].code,
    );
    try std.testing.expect(parsed.value.issues[1].invocation_name == null);
    try std.testing.expectEqual(
        SkillSourceScope.personal,
        parsed.value.issues[1].source_scope,
    );
}

fn expectSkillCatalogDecodeError(
    expected: SkillCatalogDecodeError,
    allocator: std.mem.Allocator,
    encoded: []const u8,
) !void {
    var parsed = decodeSkillCatalog(allocator, encoded) catch |err| {
        try std.testing.expectEqual(expected, err);
        return;
    };
    defer parsed.deinit();
    return error.TestExpectedError;
}

test "Skill arguments encoder emits the exact bounded wire shape" {
    const a = std.testing.allocator;
    const values = [_][]const u8{
        "C:\\work\\main.zig",
        "quoted \"target\"\nnext",
    };
    const encoded = try encodeSkillArguments(a, &values);
    defer a.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"values\":[\"C:\\\\work\\\\main.zig\",\"quoted \\\"target\\\"\\nnext\"]}",
        encoded,
    );

    var too_many: [MAX_SKILL_ARGUMENT_VALUES_V1 + 1][]const u8 = undefined;
    for (&too_many) |*value| value.* = "x";
    try std.testing.expectError(
        error.InvalidArguments,
        encodeSkillArguments(a, &too_many),
    );
    const invalid_utf8 = [_]u8{0xff};
    const invalid_values = [_][]const u8{&invalid_utf8};
    try std.testing.expectError(
        error.InvalidArguments,
        encodeSkillArguments(a, &invalid_values),
    );

    const oversized_invalid = try a.alloc(
        u8,
        MAX_SKILL_ARGUMENT_JSON_BYTES_V1 + 1,
    );
    defer a.free(oversized_invalid);
    @memset(oversized_invalid, 0xff);
    try std.testing.expectError(
        error.ResourceLimit,
        encodeSkillArguments(a, &.{oversized_invalid}),
    );

    const escaped = try a.alloc(u8, 200_000);
    defer a.free(escaped);
    @memset(escaped, 0);
    try std.testing.expectError(
        error.ResourceLimit,
        encodeSkillArguments(a, &.{escaped}),
    );
}

test "decoder and encoder normalize allocation failure" {
    var decode_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, decodeCoreEvent(decode_failing.allocator(), "{\"text_chunk\":\"x\"}"));
    var encode_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const values = [_][]const u8{"Yes"};
    const answers = [_]Answer{.{ .values = &values }};
    const request = UiRequest{ .ask_question = &.{.{ .question = "Continue?", .header = "Choice", .multi = false, .options = &.{.{ .label = "Yes", .description = "Proceed" }} }} };
    try std.testing.expectError(error.OutOfMemory, encodeUiResponse(encode_failing.allocator(), request, .{ .answers = &answers }));

    var catalog_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        decodeSkillCatalog(
            catalog_failing.allocator(),
            "{\"schema\":\"metask.skill-catalog/v1\"}",
        ),
    );
    var arguments_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        encodeSkillArguments(arguments_failing.allocator(), &.{"x"}),
    );
}
