//! Typed JSON protocol shipped beside the AgentCore binary ABI v1.
//!
//! This module is source-free: it mirrors the stable wire contract without
//! importing metacodes implementation modules. Known payloads ignore additive
//! fields. Unknown observation events are preserved for forward compatibility;
//! unknown UI/control messages and invalid known payloads fail closed.

const std = @import("std");

pub const PermissionChoice = enum {
    deny_once,
    deny_session,
    allow_once,
    allow_session,
};

pub const PermissionDecision = enum {
    deny,
    ask,
    allow,
};

pub const PermissionDecisionSource = enum {
    core_safety,
    active_skill,
    explicit_deny,
    session_deny,
    explicit_ask,
    explicit_allow,
    session_allow,
    builtin_classification,
    mode_fallback,
    callback,
};

pub const PermissionCallbackOutcome = enum {
    answered,
    user_cancelled,
    unavailable,
    contract_failure,
};

pub const PermissionToolNamespace = enum {
    builtin,
    host,
    mcp,
};

pub const PermissionTool = struct {
    namespace: PermissionToolNamespace,
    name: []const u8,
    binding: []const u8,
};

pub const PermissionCandidateScope = enum {
    exact_arguments,
};

pub const PermissionCandidate = struct {
    rule_id: []const u8,
    scope: PermissionCandidateScope,
};

/// Exact Revision 8 Permission callback request. Unlike AskUserQuestion this
/// is a flat typed object, identified by `type == "permission"`.
pub const PermissionRequest = struct {
    type: []const u8,
    request_id: []const u8,
    session_id: []const u8,
    run_id: u64,
    tool_call_id: []const u8,
    tool: PermissionTool,
    canonical_arguments_digest: []const u8,
    policy_generation: u64,
    arguments_json: []const u8,
    responses: []const PermissionChoice,
    candidate: ?PermissionCandidate,
};

/// The response echoes the request and policy generation. Session-scoped
/// choices additionally echo the exact candidate rule id.
pub const PermissionResponse = struct {
    permission: PermissionChoice,
    request_id: []const u8,
    policy_generation: u64,
    rule_id: ?[]const u8 = null,
};

/// Normalized observation emitted for every canonical Permission decision or
/// callback outcome. It contains identities and digests, never credentials or
/// raw Tool arguments.
pub const PermissionProvenance = struct {
    decision: PermissionDecision,
    source: PermissionDecisionSource,
    matched_rule_id: ?[]const u8,
    session_id: []const u8,
    run_id: u64,
    tool_call_id: []const u8,
    request_id: ?[]const u8,
    tool: PermissionTool,
    canonical_arguments_digest: []const u8,
    policy_generation: u64,
    used_session_rule: bool,
    callback_outcome: ?PermissionCallbackOutcome,
    response: ?PermissionChoice,
};

pub const UsageDelta = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const RunStatePhase = enum {
    starting,
    generating,
    executing_tools,
    waiting_ui,
    retrying,
    compacting,
    finalizing,
    completed,
    failed,
    aborted,
    poisoned,
};

pub const RunStateTool = struct {
    tool_call_id: []const u8,
    name: []const u8,
};

pub const RunState = struct {
    run_id: u64,
    transition_seq: u64,
    phase: RunStatePhase,
    turn: u32,
    tool_calls: u32,
    in_flight_tools: []const RunStateTool,
};

pub const FileReferenceLocator = union(enum) {
    workspace_path: []const u8,
    absolute_path: []const u8,
    uri: []const u8,
};

pub const FileReferencePosition = struct {
    line: u32,
    column: u32,
};

pub const FileReferenceRange = struct {
    start: FileReferencePosition,
    end: FileReferencePosition,
};

pub const FileReference = struct {
    locator: FileReferenceLocator,
    title: []const u8,
    kind: []const u8,
    range: ?FileReferenceRange = null,
};

pub const MAX_FILE_REFS_PER_TOOL_RESULT_V1: usize = 32;
pub const MAX_FILE_REF_PATH_BYTES_V1: usize = 4096;
pub const MAX_FILE_REF_URI_BYTES_V1: usize = 8192;
pub const MAX_FILE_REF_TITLE_BYTES_V1: usize = 256;
pub const MAX_FILE_REF_KIND_BYTES_V1: usize = 64;

pub const CoreEvent = union(enum) {
    text_chunk: []const u8,
    thinking_chunk: []const u8,
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
        file_refs: ?[]const FileReference = null,
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
    run_state: RunState,
    permission_provenance: PermissionProvenance,
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

pub const MAX_ANSWER_VALUES_PER_QUESTION_V1: usize = 64;

pub const Answer = struct {
    values: []const []const u8,
};

pub const UiRequest = union(enum) {
    ask_question: []const AskQuestion,
    permission: PermissionRequest,
};

pub const UiResponse = union(enum) {
    answers: []const Answer,
    permission: PermissionResponse,
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

pub const SkillCatalogResourceReason = enum {
    file_too_large,
    skill_too_large,
    too_many_files,
    too_many_entries,
    directory_too_deep,
    path_too_long,
    unsupported_entry,
    resource_unavailable,
    resource_changed,
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
    reason: ?SkillCatalogResourceReason,
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

pub const McpCatalogServer = struct {
    server_binding_identity: []const u8,
    namespace: []const u8,
    negotiated_protocol: []const u8,
    server_fingerprint: []const u8,
    cache_scope: []const u8,
    fresh: bool,
    ttl_remaining_ms: u64,
    tool_offset: u32,
    tool_count: u32,
};

pub const McpCatalogTool = struct {
    server_binding_identity: []const u8,
    canonical_name: []const u8,
    schema_fingerprint: []const u8,
    permission_binding: []const u8,
};

pub const McpCatalogIssue = struct {
    issue_id: []const u8,
    server_binding_identity: []const u8,
    tool_name: ?[]const u8,
    kind: []const u8,
    detail: []const u8,
};

pub const McpCatalog = struct {
    schema: []const u8,
    catalog_generation: u64,
    catalog_fingerprint: []const u8,
    servers: []const McpCatalogServer,
    tools: []const McpCatalogTool,
    issues: []const McpCatalogIssue,
};

pub const AuthoritySubsystem = enum {
    skill,
    permission,
    mcp,
};

pub const AuthorityIssueReason = enum {
    unavailable,
    identity_changed,
    schema_changed,
    policy_changed,
    authority_narrowed,
};

pub const AuthorityIssue = struct {
    issue_id: []const u8,
    subsystem: AuthoritySubsystem,
    reason: AuthorityIssueReason,
    skill_id: ?[]const u8,
    permission_rule_id: ?[]const u8,
    server_binding_identity: ?[]const u8,
    authority_binding: ?[]const u8,
    canonical_name: ?[]const u8,
};

pub const SessionMcpTool = struct {
    model_name: []const u8,
    namespace: []const u8,
    canonical_name: []const u8,
    server_binding_identity: []const u8,
    schema_fingerprint: []const u8,
    permission_binding: []const u8,
    negotiated_protocol: []const u8,
};

pub const LogicalSessionOrigin = enum {
    fresh,
    restored,
};

pub const SessionLifecycle = enum {
    idle,
    busy,
    poisoned,
};

pub const RestoreHealth = enum {
    complete,
    degraded,
};

pub const DurableBudgetOutcome = enum {
    none,
    budget_required,
    budget_exhausted,
    resource_limit,
};

pub const SessionDescription = struct {
    schema: []const u8,
    session_id: []const u8,
    origin: LogicalSessionOrigin,
    lifecycle: SessionLifecycle,
    registered: bool,
    last_run_id: u64,
    last_compact_id: u64,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    model: []const u8,
    conversation: struct {
        message_count: u64,
        compact_boundary: u64,
    },
    skill: struct {
        catalog_revision: ?[]const u8,
    },
    mcp: struct {
        selection_fingerprint: []const u8,
        tools: []const SessionMcpTool,
    },
    budget: struct {
        hard_bytes: u64,
        soft_bytes: u64,
        durable_usage_bytes: u64,
        available_bytes: u64,
        compaction_recommended: bool,
        last_outcome: DurableBudgetOutcome,
        required_bytes: u64,
    },
    restore: struct {
        health: RestoreHealth,
        invalidated_skill_authority: u32,
        invalidated_permission_rules: u32,
        invalidated_mcp_bindings: u32,
        issues: []const AuthorityIssue,
    },
};

pub const SkillRestoreDisposition = enum {
    not_bound,
    restored,
    narrowed,
    unavailable,
    changed,
};

pub const RestoreReport = struct {
    schema: []const u8,
    health: RestoreHealth,
    session_id: []const u8,
    checkpoint_generation: u64,
    policy_generation: u64,
    catalog_generation: u64,
    skill: struct {
        disposition: SkillRestoreDisposition,
        checkpoint_enabled: u32,
        restored_enabled: u32,
        invalidated: u32,
    },
    permission: struct {
        restored_rules: u32,
        invalidated_rules: u32,
    },
    mcp: struct {
        restored_bindings: u32,
        invalidated_bindings: u32,
    },
    issues: []const AuthorityIssue,
};

pub const ParsedCoreEvent = std.json.Parsed(DecodedCoreEvent);
pub const ParsedUiRequest = std.json.Parsed(UiRequest);
pub const ParsedUiResponse = std.json.Parsed(UiResponse);
pub const ParsedSkillCatalog = std.json.Parsed(SkillCatalog);
pub const ParsedMcpCatalog = std.json.Parsed(McpCatalog);
pub const ParsedSessionDescription = std.json.Parsed(SessionDescription);
pub const ParsedRestoreReport = std.json.Parsed(RestoreReport);

pub const MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1: usize = 4 * 1024 * 1024;
pub const MAX_SKILL_CATALOG_SKILLS_V1: usize = 1024;
pub const MAX_SKILL_FILE_CONTENT_BYTES_V1: usize = 16 * 1024 * 1024;
pub const MAX_SKILL_CONTENT_BYTES_V1: usize = 32 * 1024 * 1024;
pub const MAX_SKILL_FILES_V1: usize = 1024;
pub const MAX_SKILL_ENTRIES_V1: usize = 4096;
pub const MAX_SKILL_DIRECTORY_DEPTH_V1: usize = 64;
pub const MAX_SKILL_RELATIVE_PATH_BYTES_V1: usize = 4096;
pub const MAX_SKILL_CATALOG_CONTENT_BYTES_V1: usize = 64 * 1024 * 1024;
pub const MAX_SKILL_CATALOG_FILES_V1: usize = 16384;
pub const MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1: usize = 65536;
pub const MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1: usize = 256 * 1024 * 1024;
pub const MAX_SKILL_ARGUMENT_VALUES_V1: usize = 64;
pub const MAX_SKILL_ARGUMENT_JSON_BYTES_V1: usize = 1024 * 1024;
pub const MAX_DESCRIPTION_JSON_BYTES_V1: usize = 16 * 1024 * 1024;
pub const MAX_MCP_SERVERS_V1: usize = 64;
pub const MAX_MCP_TOOLS_V1: usize = 1024;
pub const MAX_AUTHORITY_ISSUES_V1: usize = 4096;
pub const MAX_PERMISSION_ARGUMENT_JSON_BYTES_V1: usize = 1024 * 1024;

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
        switch (known) {
            .permission_provenance => |value| try validatePermissionProvenance(value),
            .tool_result => |value| try validateFileReferences(value.file_refs),
            else => {},
        }
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

fn validateFileReferences(refs: ?[]const FileReference) DecodeError!void {
    const values = refs orelse return;
    if (values.len > MAX_FILE_REFS_PER_TOOL_RESULT_V1) return error.InvalidPayload;
    for (values) |ref| {
        if (ref.title.len > MAX_FILE_REF_TITLE_BYTES_V1 or ref.kind.len > MAX_FILE_REF_KIND_BYTES_V1)
            return error.InvalidPayload;
        switch (ref.locator) {
            .workspace_path, .absolute_path => |path| {
                if (path.len > MAX_FILE_REF_PATH_BYTES_V1) return error.InvalidPayload;
            },
            .uri => |uri| {
                if (uri.len > MAX_FILE_REF_URI_BYTES_V1) return error.InvalidPayload;
            },
        }
        if (ref.range) |range| {
            if (range.start.line == 0 or range.end.line == 0 or
                range.start.column == 0 or range.end.column == 0)
                return error.InvalidPayload;
            if (range.end.line < range.start.line or
                (range.end.line == range.start.line and range.end.column < range.start.column))
                return error.InvalidPayload;
        }
    }
}

pub fn decodeUiRequest(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!ParsedUiRequest {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return normalizeDecodeError(err);
    if (root != .object) return error.InvalidPayload;
    if (root.object.get("type")) |kind| {
        if (kind != .string or !std.mem.eql(u8, kind.string, "permission"))
            return error.UnknownTag;
        const request = std.json.parseFromSliceLeaky(PermissionRequest, a, encoded, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        }) catch |err| return normalizeDecodeError(err);
        try validatePermissionRequest(a, request);
        return .{ .arena = arena, .value = .{ .permission = request } };
    }
    if (root.object.get("ask_question") != null) {
        if (root.object.count() != 1) return error.InvalidPayload;
        const request = std.json.parseFromSliceLeaky(UiRequest, a, encoded, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        }) catch |err| return normalizeDecodeError(err);
        return .{ .arena = arena, .value = request };
    }
    return error.UnknownTag;
}

/// Primarily used by the binary facade to validate Host-owned response bytes
/// against the same source-free schema shipped to consumers.
pub fn decodeUiResponse(allocator: std.mem.Allocator, encoded: []const u8) DecodeError!ParsedUiResponse {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| return normalizeDecodeError(err);
    if (root != .object) return error.InvalidPayload;
    if (root.object.get("answers") != null) {
        if (root.object.count() != 1) return error.InvalidPayload;
        const response = std.json.parseFromSliceLeaky(UiResponse, a, encoded, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        }) catch |err| return normalizeDecodeError(err);
        return .{ .arena = arena, .value = response };
    }
    if (root.object.get("permission") != null) {
        const response = std.json.parseFromSliceLeaky(PermissionResponse, a, encoded, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .@"error",
        }) catch |err| return normalizeDecodeError(err);
        try validatePermissionResponse(response);
        return .{ .arena = arena, .value = .{ .permission = response } };
    }
    return error.UnknownTag;
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

pub fn decodeMcpCatalog(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) SkillCatalogDecodeError!ParsedMcpCatalog {
    if (encoded.len > MAX_DESCRIPTION_JSON_BYTES_V1) return error.ResourceLimit;
    var parsed = try decode(McpCatalog, allocator, encoded);
    errdefer parsed.deinit();
    try validateMcpCatalog(parsed.value);
    return parsed;
}

pub fn decodeSessionDescription(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) SkillCatalogDecodeError!ParsedSessionDescription {
    if (encoded.len > MAX_DESCRIPTION_JSON_BYTES_V1) return error.ResourceLimit;
    var parsed = try decode(SessionDescription, allocator, encoded);
    errdefer parsed.deinit();
    try validateSessionDescription(parsed.value);
    return parsed;
}

pub fn decodeRestoreReport(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) SkillCatalogDecodeError!ParsedRestoreReport {
    if (encoded.len > MAX_DESCRIPTION_JSON_BYTES_V1) return error.ResourceLimit;
    var parsed = try decode(RestoreReport, allocator, encoded);
    errdefer parsed.deinit();
    try validateRestoreReport(parsed.value);
    return parsed;
}

pub fn encodeUiResponse(allocator: std.mem.Allocator, request: UiRequest, response: UiResponse) EncodeError![]u8 {
    return switch (request) {
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
                const dto = struct { answers: []const Answer }{ .answers = answers };
                return std.json.Stringify.valueAlloc(allocator, dto, .{}) catch error.OutOfMemory;
            },
            else => error.MismatchedResponse,
        },
        .permission => |permission_request| switch (response) {
            .permission => |permission_response| {
                try validatePermissionResponseForRequest(permission_request, permission_response);
                return std.json.Stringify.valueAlloc(allocator, permission_response, .{}) catch error.OutOfMemory;
            },
            else => error.MismatchedResponse,
        },
    };
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
        if ((issue.code == .invalid_resource) != (issue.reason != null))
            return error.InvalidPayload;
        if (issue.invocation_name) |name| {
            if (!validInvocationName(name)) return error.InvalidPayload;
        }
    }
}

fn validatePermissionRequest(
    allocator: std.mem.Allocator,
    request: PermissionRequest,
) DecodeError!void {
    if (!std.mem.eql(u8, request.type, "permission") or
        !lowerHex64(request.request_id) or
        !validSessionId(request.session_id) or
        request.run_id == 0 or
        request.policy_generation == 0 or
        !validBoundedText(request.tool_call_id, 4096) or
        !validPermissionTool(request.tool) or
        !lowerHex64(request.canonical_arguments_digest) or
        request.arguments_json.len == 0 or
        request.arguments_json.len > MAX_PERMISSION_ARGUMENT_JSON_BYTES_V1 or
        !std.unicode.utf8ValidateSlice(request.arguments_json))
        return error.InvalidPayload;
    const arguments = std.json.parseFromSliceLeaky(std.json.Value, allocator, request.arguments_json, .{
        .duplicate_field_behavior = .@"error",
    }) catch |err| return normalizeDecodeError(err);
    if (arguments != .object) return error.InvalidPayload;

    if (request.candidate) |candidate| {
        if (!lowerHex64(candidate.rule_id) or candidate.scope != .exact_arguments)
            return error.InvalidPayload;
        if (request.responses.len != 3 and request.responses.len != 4)
            return error.InvalidPayload;
        if (request.responses[0] != .deny_once or
            request.responses[1] != .deny_session or
            request.responses[2] != .allow_once or
            (request.responses.len == 4 and request.responses[3] != .allow_session))
            return error.InvalidPayload;
    } else {
        if (request.responses.len != 2 or
            request.responses[0] != .deny_once or
            request.responses[1] != .allow_once)
            return error.InvalidPayload;
    }
}

fn validatePermissionResponse(response: PermissionResponse) DecodeError!void {
    if (!lowerHex64(response.request_id) or response.policy_generation == 0)
        return error.InvalidPayload;
    switch (response.permission) {
        .deny_once, .allow_once => if (response.rule_id != null)
            return error.InvalidPayload,
        .deny_session, .allow_session => if (response.rule_id == null or
            !lowerHex64(response.rule_id.?)) return error.InvalidPayload,
    }
}

fn validatePermissionResponseForRequest(
    request: PermissionRequest,
    response: PermissionResponse,
) EncodeError!void {
    if (!std.mem.eql(u8, request.request_id, response.request_id) or
        request.policy_generation != response.policy_generation or
        !containsPermissionChoice(request.responses, response.permission))
        return error.InvalidResponse;
    switch (response.permission) {
        .deny_once, .allow_once => if (response.rule_id != null)
            return error.InvalidResponse,
        .deny_session, .allow_session => {
            const candidate = request.candidate orelse return error.InvalidResponse;
            const rule_id = response.rule_id orelse return error.InvalidResponse;
            if (!std.mem.eql(u8, candidate.rule_id, rule_id))
                return error.InvalidResponse;
        },
    }
}

fn validatePermissionProvenance(value: PermissionProvenance) DecodeError!void {
    if (!validSessionId(value.session_id) or value.run_id == 0 or
        value.policy_generation == 0 or
        !validBoundedText(value.tool_call_id, 4096) or
        !validPermissionTool(value.tool) or
        !lowerHex64(value.canonical_arguments_digest))
        return error.InvalidPayload;
    if (value.matched_rule_id) |rule_id| if (!lowerHex64(rule_id))
        return error.InvalidPayload;
    if (value.request_id) |request_id| if (!lowerHex64(request_id))
        return error.InvalidPayload;
    if (value.source == .callback) {
        const outcome = value.callback_outcome orelse return error.InvalidPayload;
        if (value.request_id == null) return error.InvalidPayload;
        if (outcome == .answered) {
            const response = value.response orelse return error.InvalidPayload;
            if ((value.decision == .allow) !=
                (response == .allow_once or response == .allow_session))
                return error.InvalidPayload;
        } else if (value.response != null) {
            return error.InvalidPayload;
        }
    } else if (value.request_id != null or value.callback_outcome != null or value.response != null) {
        return error.InvalidPayload;
    }
}

fn validateMcpCatalog(catalog: McpCatalog) SkillCatalogDecodeError!void {
    if (!std.mem.eql(u8, catalog.schema, "agentcore.mcp-catalog/v1") or
        !lowerHex64(catalog.catalog_fingerprint))
        return error.InvalidPayload;
    if (catalog.servers.len > MAX_MCP_SERVERS_V1 or
        catalog.tools.len > MAX_MCP_TOOLS_V1 or
        catalog.issues.len > MAX_AUTHORITY_ISSUES_V1)
        return error.ResourceLimit;
    for (catalog.servers) |server| {
        if (!lowerHex64(server.server_binding_identity) or
            !lowerHex64(server.server_fingerprint) or
            !validBoundedText(server.namespace, 128) or
            !validMcpProtocol(server.negotiated_protocol) or
            (!std.mem.eql(u8, server.cache_scope, "private") and
                !std.mem.eql(u8, server.cache_scope, "public")))
            return error.InvalidPayload;
        const end = std.math.add(u32, server.tool_offset, server.tool_count) catch
            return error.InvalidPayload;
        if (end > catalog.tools.len) return error.InvalidPayload;
        for (catalog.tools[server.tool_offset..end]) |tool| {
            if (!std.mem.eql(u8, tool.server_binding_identity, server.server_binding_identity))
                return error.InvalidPayload;
        }
    }
    for (catalog.tools) |tool| try validateMcpIdentity(
        tool.server_binding_identity,
        tool.canonical_name,
        tool.schema_fingerprint,
        tool.permission_binding,
        null,
    );
    for (catalog.issues) |issue| {
        if (!lowerHex64(issue.issue_id) or
            !lowerHex64(issue.server_binding_identity) or
            !validBoundedText(issue.kind, 128) or
            !std.unicode.utf8ValidateSlice(issue.detail))
            return error.InvalidPayload;
        if (issue.tool_name) |name| if (!validBoundedText(name, 128))
            return error.InvalidPayload;
    }
}

fn validateSessionDescription(description: SessionDescription) SkillCatalogDecodeError!void {
    if (!std.mem.eql(u8, description.schema, "agentcore.session-description/v1") or
        !validSessionId(description.session_id) or
        description.policy_generation == 0 or
        !validBoundedText(description.model, 4096) or
        description.conversation.compact_boundary > description.conversation.message_count or
        !lowerHex64(description.mcp.selection_fingerprint))
        return error.InvalidPayload;
    if (description.skill.catalog_revision) |revision| if (!lowerHex64(revision))
        return error.InvalidPayload;
    if (description.mcp.tools.len > MAX_MCP_TOOLS_V1 or
        description.restore.issues.len > MAX_AUTHORITY_ISSUES_V1)
        return error.ResourceLimit;
    for (description.mcp.tools) |tool| try validateMcpIdentity(
        tool.server_binding_identity,
        tool.canonical_name,
        tool.schema_fingerprint,
        tool.permission_binding,
        tool.negotiated_protocol,
    );
    if (description.budget.soft_bytes > description.budget.hard_bytes or
        description.budget.durable_usage_bytes > description.budget.hard_bytes or
        description.budget.available_bytes !=
            description.budget.hard_bytes - description.budget.durable_usage_bytes)
        return error.InvalidPayload;
    try validateRestoreSummary(
        description.restore.health,
        description.restore.invalidated_skill_authority,
        description.restore.invalidated_permission_rules,
        description.restore.invalidated_mcp_bindings,
        description.restore.issues,
    );
}

fn validateRestoreReport(report: RestoreReport) SkillCatalogDecodeError!void {
    if (!std.mem.eql(u8, report.schema, "agentcore.restore-report/v1") or
        !validSessionId(report.session_id) or
        report.checkpoint_generation == 0 or
        report.policy_generation == 0)
        return error.InvalidPayload;
    if (report.issues.len > MAX_AUTHORITY_ISSUES_V1) return error.ResourceLimit;
    try validateRestoreSummary(
        report.health,
        report.skill.invalidated,
        report.permission.invalidated_rules,
        report.mcp.invalidated_bindings,
        report.issues,
    );
}

fn validateRestoreSummary(
    health: RestoreHealth,
    invalidated_skill: u32,
    invalidated_permission: u32,
    invalidated_mcp: u32,
    issues: []const AuthorityIssue,
) SkillCatalogDecodeError!void {
    const invalidated = invalidated_skill != 0 or invalidated_permission != 0 or invalidated_mcp != 0;
    if ((health == .complete and (invalidated or issues.len != 0)) or
        (health == .degraded and !invalidated and issues.len == 0))
        return error.InvalidPayload;
    for (issues) |issue| try validateAuthorityIssue(issue);
}

fn validateAuthorityIssue(issue: AuthorityIssue) SkillCatalogDecodeError!void {
    if (!lowerHex64(issue.issue_id)) return error.InvalidPayload;
    if (issue.skill_id) |value| if (!lowerHex64(value)) return error.InvalidPayload;
    if (issue.permission_rule_id) |value| if (!lowerHex64(value)) return error.InvalidPayload;
    if (issue.server_binding_identity) |value| if (!lowerHex64(value)) return error.InvalidPayload;
    if (issue.authority_binding) |value| if (!lowerHex64(value)) return error.InvalidPayload;
    if (issue.canonical_name) |value| if (!validBoundedText(value, 128))
        return error.InvalidPayload;
}

fn validateMcpIdentity(
    server_binding_identity: []const u8,
    canonical_name: []const u8,
    schema_fingerprint: []const u8,
    permission_binding: []const u8,
    negotiated_protocol: ?[]const u8,
) SkillCatalogDecodeError!void {
    if (!lowerHex64(server_binding_identity) or
        !validBoundedText(canonical_name, 128) or
        !lowerHex64(schema_fingerprint) or
        !lowerHex64(permission_binding))
        return error.InvalidPayload;
    if (negotiated_protocol) |protocol| if (!validMcpProtocol(protocol))
        return error.InvalidPayload;
}

fn validPermissionTool(tool: PermissionTool) bool {
    if (!validBoundedText(tool.name, 128) or !lowerHex64(tool.binding)) return false;
    const all_zero = allAsciiZero(tool.binding);
    return if (tool.namespace == .builtin) all_zero else !all_zero;
}

fn containsPermissionChoice(values: []const PermissionChoice, choice: PermissionChoice) bool {
    for (values) |value| if (value == choice) return true;
    return false;
}

fn validSessionId(value: []const u8) bool {
    return value.len == 24 and lowerHex(value);
}

fn validMcpProtocol(value: []const u8) bool {
    return std.mem.eql(u8, value, "2026-07-28") or
        std.mem.eql(u8, value, "2025-11-25") or
        std.mem.eql(u8, value, "2025-06-18");
}

fn validBoundedText(value: []const u8, max: usize) bool {
    return value.len != 0 and value.len <= max and std.unicode.utf8ValidateSlice(value);
}

fn allAsciiZero(value: []const u8) bool {
    for (value) |byte| if (byte != '0') return false;
    return true;
}

fn lowerHex(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

fn lowerHex64(value: []const u8) bool {
    return value.len == 64 and lowerHex(value);
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

fn testPermissionRequest() PermissionRequest {
    return .{
        .type = "permission",
        .request_id = "1111111111111111111111111111111111111111111111111111111111111111",
        .session_id = "000000000000000000000001",
        .run_id = 9,
        .tool_call_id = "tool-9",
        .tool = .{
            .namespace = .builtin,
            .name = "Bash",
            .binding = "0000000000000000000000000000000000000000000000000000000000000000",
        },
        .canonical_arguments_digest = "3333333333333333333333333333333333333333333333333333333333333333",
        .policy_generation = 7,
        .arguments_json = "{\"command\":\"git status\"}",
        .responses = &.{ .deny_once, .deny_session, .allow_once, .allow_session },
        .candidate = .{
            .rule_id = "2222222222222222222222222222222222222222222222222222222222222222",
            .scope = .exact_arguments,
        },
    };
}

test "CoreEvent decoder covers every ABI v1 tag" {
    const cases = [_][]const u8{
        "{\"text_chunk\":\"hello\"}",
        "{\"thinking_chunk\":\"private reasoning\"}",
        "{\"tool_start\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\"}}",
        "{\"tool_progress\":{\"id\":\"t1\",\"text\":\"working\"}}",
        "{\"progress\":{\"turn\":1,\"tool_name\":\"Read\",\"tool_input\":\"{}\",\"tool_calls\":2}}",
        "{\"tool_result\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"elapsed_ms\":18446744073709551615}}",
        "{\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"cache_read_input_tokens\":3,\"cache_creation_input_tokens\":4}}",
        "{\"context_warning\":{\"current_tokens\":1,\"warning_threshold\":2,\"auto_compact_threshold\":3,\"blocking_limit\":4,\"level\":\"medium\"}}",
        "{\"auto_compact\":{\"dropped\":1,\"kept\":2,\"before_tokens\":3,\"after_tokens\":4,\"cause\":\"trigger\"}}",
        "{\"retry_notice\":{\"attempt\":1,\"max\":2,\"delay_ms\":3}}",
        "{\"run_state\":{\"run_id\":9,\"transition_seq\":1,\"phase\":\"starting\",\"turn\":0,\"tool_calls\":0,\"in_flight_tools\":[]}}",
        "{\"permission_provenance\":{\"decision\":\"allow\",\"source\":\"explicit_allow\",\"matched_rule_id\":null,\"session_id\":\"000000000000000000000001\",\"run_id\":1,\"tool_call_id\":\"tool-1\",\"request_id\":null,\"tool\":{\"namespace\":\"builtin\",\"name\":\"Read\",\"binding\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"canonical_arguments_digest\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"policy_generation\":1,\"used_session_rule\":false,\"callback_outcome\":null,\"response\":null}}",
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

    var ui = try decodeUiRequest(std.testing.allocator, "{\"type\":\"permission\",\"request_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"session_id\":\"000000000000000000000001\",\"run_id\":9,\"tool_call_id\":\"tool-9\",\"tool\":{\"namespace\":\"builtin\",\"name\":\"Bash\",\"binding\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"canonical_arguments_digest\":\"3333333333333333333333333333333333333333333333333333333333333333\",\"policy_generation\":7,\"arguments_json\":\"{\\\"command\\\":\\\"git status\\\"}\",\"responses\":[\"deny_once\",\"deny_session\",\"allow_once\",\"allow_session\"],\"candidate\":{\"rule_id\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"scope\":\"exact_arguments\"},\"future_hint\":true}");
    defer ui.deinit();
    try std.testing.expectEqualStrings("Bash", ui.value.permission.tool.name);
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

test "CoreEvent decoder accepts bounded file references and rejects oversized ones" {
    var parsed = try decodeCoreEvent(std.testing.allocator,
        "{\"tool_result\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"file_refs\":[{\"locator\":{\"workspace_path\":\"src/main.zig\"},\"title\":\"main.zig\",\"kind\":\"read\",\"range\":{\"start\":{\"line\":1,\"column\":1},\"end\":{\"line\":2,\"column\":1}}}]}}",
    );
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |event| switch (event) {
            .tool_result => |result| {
                try std.testing.expect(result.file_refs != null);
                try std.testing.expectEqual(@as(usize, 1), result.file_refs.?.len);
                try std.testing.expectEqualStrings("read", result.file_refs.?[0].kind);
                try std.testing.expectEqual(@as(u32, 2), result.file_refs.?[0].range.?.end.line);
            },
            else => return error.UnexpectedEvent,
        },
        .unknown => return error.UnexpectedEvent,
    }

    var oversized = std.ArrayList(u8).empty;
    defer oversized.deinit(std.testing.allocator);
    try oversized.appendSlice(std.testing.allocator, "{\"tool_result\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"file_refs\":[");
    var i: usize = 0;
    while (i < MAX_FILE_REFS_PER_TOOL_RESULT_V1 + 1) : (i += 1) {
        if (i != 0) try oversized.append(std.testing.allocator, ',');
        try oversized.appendSlice(std.testing.allocator, "{\"locator\":{\"workspace_path\":\"x\"}}");
    }
    try oversized.appendSlice(std.testing.allocator, "]}}");
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(std.testing.allocator, oversized.items));
    try std.testing.expectError(error.InvalidPayload, decodeCoreEvent(std.testing.allocator,
        "{\"tool_result\":{\"id\":\"t1\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false,\"file_refs\":[{\"locator\":{\"workspace_path\":\"x\"},\"title\":\"x\",\"kind\":\"read\",\"range\":{\"start\":{\"line\":3,\"column\":1},\"end\":{\"line\":2,\"column\":1}}}]}}",
    ));
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
        "{\"type\":\"permission\",\"request_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"session_id\":\"000000000000000000000001\",\"run_id\":9,\"tool_call_id\":\"tool-9\",\"tool\":{\"namespace\":\"builtin\",\"name\":\"Bash\",\"binding\":\"0000000000000000000000000000000000000000000000000000000000000000\"},\"canonical_arguments_digest\":\"3333333333333333333333333333333333333333333333333333333333333333\",\"policy_generation\":7,\"arguments_json\":\"{\\\"command\\\":\\\"git status\\\"}\",\"responses\":[\"deny_once\",\"deny_session\",\"allow_once\",\"allow_session\"],\"candidate\":{\"rule_id\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"scope\":\"exact_arguments\"}}",
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

    const permission_request = UiRequest{ .permission = testPermissionRequest() };
    const permission_response = PermissionResponse{
        .permission = .allow_session,
        .request_id = permission_request.permission.request_id,
        .policy_generation = permission_request.permission.policy_generation,
        .rule_id = permission_request.permission.candidate.?.rule_id,
    };
    const permission = try encodeUiResponse(a, permission_request, .{ .permission = permission_response });
    defer a.free(permission);
    try std.testing.expectEqualStrings("{\"permission\":\"allow_session\",\"request_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"policy_generation\":7,\"rule_id\":\"2222222222222222222222222222222222222222222222222222222222222222\"}", permission);
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
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"type\":\"permission\"}"));
    try std.testing.expectError(error.UnknownTag, decodeUiRequest(a, "{\"type\":\"future\"}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"type\":\"permission\",\"type\":\"permission\"}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiRequest(a, "{\"ask_question\":{}}"));
}

test "UiResponse decoder rejects unknown tags and invalid payloads" {
    const a = std.testing.allocator;
    var permission = try decodeUiResponse(a, "{\"permission\":\"allow_once\",\"request_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"policy_generation\":7}");
    defer permission.deinit();
    try std.testing.expectEqual(PermissionChoice.allow_once, permission.value.permission.permission);
    try std.testing.expectError(error.UnknownTag, decodeUiResponse(a, "{\"future\":{}}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiResponse(a, "{\"permission\":\"future\"}"));
    try std.testing.expectError(error.InvalidPayload, decodeUiResponse(a, "{\"permission\":\"allow_once\",\"request_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"policy_generation\":7,\"answers\":[]}"));
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
        "{{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"degraded\",\"skills\":[],\"issues\":[{{\"code\":\"invalid_definition\",\"reason\":null,\"invocation_name\":\"review\",\"source_scope\":\"project\"}},{{\"code\":\"invalid_invocation_name\",\"reason\":null,\"invocation_name\":null,\"source_scope\":\"personal\"}},{{\"code\":\"invalid_resource\",\"reason\":\"file_too_large\",\"invocation_name\":\"tinykg\",\"source_scope\":\"personal\"}}]}}",
        .{ hash, hash },
    );
    defer a.free(encoded);
    var parsed = try decodeSkillCatalog(a, encoded);
    defer parsed.deinit();

    try std.testing.expectEqual(SkillCatalogHealth.degraded, parsed.value.health);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.issues.len);
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
    try std.testing.expectEqual(
        SkillCatalogIssueCode.invalid_resource,
        parsed.value.issues[2].code,
    );
    try std.testing.expectEqual(
        SkillCatalogResourceReason.file_too_large,
        parsed.value.issues[2].reason.?,
    );
}

test "Skill catalog decoder enforces issue code and resource reason pairing" {
    const a = std.testing.allocator;
    const hash = "0" ** 64;
    const cases = [_][]const u8{
        "{\"code\":\"invalid_resource\",\"reason\":null,\"invocation_name\":\"review\",\"source_scope\":\"project\"}",
        "{\"code\":\"invalid_definition\",\"reason\":\"file_too_large\",\"invocation_name\":\"review\",\"source_scope\":\"project\"}",
    };
    for (cases) |issue| {
        const encoded = try std.fmt.allocPrint(
            a,
            "{{\"schema\":\"metask.skill-catalog/v1\",\"catalog_scope_id\":\"{s}\",\"catalog_revision\":\"{s}\",\"health\":\"degraded\",\"skills\":[],\"issues\":[{s}]}}",
            .{ hash, hash, issue },
        );
        defer a.free(encoded);
        try std.testing.expectError(error.InvalidPayload, decodeSkillCatalog(a, encoded));
    }
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
