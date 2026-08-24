//! Stable AgentCore ABI v1 wire adapter.
//!
//! Internal CoreEvent/UiRequest types may evolve with the execution engine and
//! Host integrations. This module is the explicit boundary that decides which
//! values cross `metask_agentcore_get_api(1)`. The public DTOs live in the
//! source-free SDK and are imported here as the single wire-schema truth.

const std = @import("std");
const core = @import("metacodes-core");
const public = @import("metask_agentcore_protocol");

const InternalEvent = core.protocol.ui_event.CoreEvent;
const InternalUiRequest = core.protocol.ui_request.UiRequest;
const InternalUiResponse = core.protocol.ui_request.UiResponse;
const internal_file_reference = core.file_reference;

// The event adapter borrows the reference slice for the duration of the
// synchronous callback. Keep the zero-copy cast, but make its safety claim
// executable: a change to either side's DTO layout must fail compilation at
// this ABI boundary instead of silently reinterpreting bytes.
comptime {
    if (@sizeOf(internal_file_reference.FileReference) != @sizeOf(public.FileReference) or
        @offsetOf(internal_file_reference.FileReference, "locator") != @offsetOf(public.FileReference, "locator") or
        @offsetOf(internal_file_reference.FileReference, "title") != @offsetOf(public.FileReference, "title") or
        @offsetOf(internal_file_reference.FileReference, "kind") != @offsetOf(public.FileReference, "kind") or
        @offsetOf(internal_file_reference.FileReference, "range") != @offsetOf(public.FileReference, "range"))
        @compileError("AgentCore FileReference internal/public layout drift; update the explicit ABI adapter");
    if (@sizeOf(internal_file_reference.Locator) != @sizeOf(public.FileReferenceLocator) or
        @sizeOf(internal_file_reference.Range) != @sizeOf(public.FileReferenceRange) or
        @sizeOf(internal_file_reference.Position) != @sizeOf(public.FileReferencePosition))
        @compileError("AgentCore file-reference nested DTO layout drift");
}

/// Map an internal event to the frozen ABI v1 event set. Returning null is an
/// explicit decision that an internal-only event does not cross this ABI.
/// The exhaustive switch makes future CoreEvent additions a compile failure
/// here instead of an accidental public wire change.
pub fn event(value: InternalEvent) ?public.CoreEvent {
    return switch (value) {
        .text_chunk => |v| .{ .text_chunk = v },
        .thinking_chunk => |v| .{ .thinking_chunk = v },
        .tool_start => |v| .{ .tool_start = .{ .id = v.id, .name = v.name, .input = v.input } },
        .tool_progress => |v| .{ .tool_progress = .{ .id = v.id, .text = v.text } },
        .progress => |v| .{ .progress = .{
            .turn = v.turn,
            .tool_name = v.tool_name,
            .tool_input = v.tool_input,
            .tool_calls = v.tool_calls,
        } },
        .tool_result => |v| .{
            .tool_result = .{
                .id = v.id,
                .name = v.name,
                .input = v.input,
                .content = v.content,
                .is_error = v.is_error,
                .elapsed_ms = v.elapsed_ms,
                // Internal and public DTOs intentionally have identical frozen
                // field layouts but live in separate modules. The slice is
                // borrowed for the synchronous event call; no allocation or UI
                // policy is introduced at this ABI adapter boundary.
                .file_refs = if (v.file_refs) |refs| @ptrCast(refs) else null,
            },
        },
        .usage => |v| .{ .usage = .{
            .input_tokens = v.input_tokens,
            .output_tokens = v.output_tokens,
            .cache_read_input_tokens = v.cache_read_input_tokens,
            .cache_creation_input_tokens = v.cache_creation_input_tokens,
        } },
        .context_warning => |v| .{ .context_warning = .{
            .current_tokens = v.current_tokens,
            .warning_threshold = v.warning_threshold,
            .auto_compact_threshold = v.auto_compact_threshold,
            .blocking_limit = v.blocking_limit,
            .level = v.level,
        } },
        .auto_compact => |v| .{ .auto_compact = .{
            .dropped = v.dropped,
            .kept = v.kept,
            .before_tokens = v.before_tokens,
            .after_tokens = v.after_tokens,
            .cause = v.cause,
        } },
        .retry_notice => |v| .{ .retry_notice = .{
            .attempt = v.attempt,
            .max = v.max,
            .delay_ms = v.delay_ms,
        } },
        .stream_done => .stream_done,

        // Presentation hints, diagnostics and App/daemon coordination remain
        // internal. Exporting them would freeze UI policy or implementation
        // details rather than AgentSession observations.
        .stream_begin,
        .set_current_tool,
        .clear_current_tool,
        .diag_turn_begin,
        .diag_turn_end,
        .diag_model_request,
        .diag_compact_request,
        .diag_compact_begin,
        .diag_compact_end,
        .diag_tool_stage,
        .diag_breaker_tripped,
        .diag_cache_break,
        .diag_continuation,
        .context_projection,
        .policy_decision,
        .diag_run_end,
        .config_changed,
        .session_lifecycle,
        .agent_lifecycle,
        .tasks_changed,
        .ui_request_pending,
        .ui_request_resolved,
        // Output-semantics and file-change evidence stay internal **for now**.
        // The AgentCore facade's own projector already consumes
        // `output_segment_end` to reconstruct the final answer correctly, which
        // is the behavior consumers actually observe. Exporting the raw events
        // would widen a frozen C ABI (public header, symbol gate, version bump,
        // consumer sign-off) — deliberately out of scope here, and registered as
        // such in doc/CORE_REFERENCE.md §7 rather than left silent.
        .output_segment_begin,
        .output_segment_end,
        .file_changes,
        => null,
    };
}

/// Serialize the internal UI request through the public ABI v1 DTO rather than
/// relying on the internal union's incidental JSON representation.
pub fn encodeUiRequest(allocator: std.mem.Allocator, request: *const InternalUiRequest) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const mapped: public.UiRequest = switch (request.*) {
        .ask_question => |questions| blk: {
            const out = try a.alloc(public.AskQuestion, questions.len);
            for (questions, out) |question, *dest| {
                if (question.options.len == 0) return error.InvalidUiRequest;
                const options = try a.alloc(public.AskOption, question.options.len);
                for (question.options, options) |option, *option_dest| {
                    option_dest.* = .{
                        .label = option.label,
                        .description = option.description,
                        .preview = option.preview,
                    };
                }
                dest.* = .{
                    .question = question.question,
                    .header = question.header,
                    .multi = question.multi,
                    .options = options,
                };
            }
            break :blk .{ .ask_question = out };
        },
        // Revision 6 Permission is encoded by session_permission.zig because
        // it requires Session/Run/request/generation identities unavailable
        // in this presentation-only Core request.
        .permission, .plan_approval, .custom => return error.UnsupportedUiRequest,
    };
    return std.json.Stringify.valueAlloc(allocator, mapped, .{});
}

/// Validate Host response JSON with the public SDK schema, enforce request /
/// response pairing, then copy owned data into the core response allocator.
pub fn decodeUiResponse(
    allocator: std.mem.Allocator,
    request: *const InternalUiRequest,
    encoded: []const u8,
    out: *InternalUiResponse,
) !void {
    var parsed = try public.decodeUiResponse(allocator, encoded);
    defer parsed.deinit();

    switch (request.*) {
        .ask_question => |questions| switch (parsed.value) {
            .answers => |answers| {
                if (answers.len != questions.len) return error.InvalidUiResponse;
                const copied = try allocator.alloc([]const u8, answers.len);
                var copied_count: usize = 0;
                errdefer {
                    for (copied[0..copied_count]) |answer| allocator.free(@constCast(answer));
                    allocator.free(copied);
                }
                for (questions, answers, copied) |question, answer, *dest| {
                    if (question.options.len == 0) return error.InvalidUiResponse;
                    if (question.multi) {
                        if (answer.values.len == 0 or answer.values.len > public.MAX_ANSWER_VALUES_PER_QUESTION_V1)
                            return error.InvalidUiResponse;
                    } else if (answer.values.len != 1) {
                        return error.InvalidUiResponse;
                    }
                    dest.* = try std.mem.join(allocator, ", ", answer.values);
                    copied_count += 1;
                }
                out.* = .{ .answers = copied };
            },
            else => return error.InvalidUiResponse,
        },
        .permission, .plan_approval, .custom => return error.UnsupportedUiRequest,
    }
}

test "internal-only events are explicitly excluded from ABI v1" {
    try std.testing.expect(event(.stream_begin) == null);
    try std.testing.expect(event(.{ .set_current_tool = .{ .name = "Read" } }) == null);
    try std.testing.expect(event(.clear_current_tool) == null);
    const trace_id = [_]u8{0} ** 12;
    try std.testing.expect(event(.{ .diag_turn_begin = .{ .trace_id = trace_id, .depth = 0, .turn = 1 } }) == null);
    try std.testing.expect(event(.{ .diag_turn_end = .{ .trace_id = trace_id, .depth = 0, .turn = 1, .tool_calls = 0 } }) == null);
    try std.testing.expect(event(.{ .diag_model_request = .{ .trace_id = trace_id, .depth = 0, .turn = 1, .attempt = 1, .elapsed_ms = 2, .outcome = "ok" } }) == null);
    try std.testing.expect(event(.{ .diag_compact_request = .{ .trace_id = trace_id, .depth = 0, .turn = 1, .elapsed_ms = 2, .outcome = "success", .cause = "threshold" } }) == null);
    try std.testing.expect(event(.{ .diag_tool_stage = .{ .trace_id = trace_id, .depth = 0, .turn = 1, .tool_calls = 2, .elapsed_ms = 3 } }) == null);
    try std.testing.expect(event(.{ .diag_breaker_tripped = .{ .trace_id = trace_id, .depth = 0, .same_err_count = 1 } }) == null);
    try std.testing.expect(event(.{ .diag_cache_break = .{ .trace_id = trace_id, .depth = 0, .cache_read = 1, .cache_creation = 2 } }) == null);
    try std.testing.expect(event(.{ .diag_continuation = .{ .trace_id = trace_id, .depth = 0, .n = 1, .max = 2 } }) == null);
    try std.testing.expect(event(.{ .context_projection = .{
        .kind = "large_tool_result_truncation",
        .changed_items = 1,
        .bytes_before = 1024,
        .bytes_after = 512,
        .active_messages = 3,
        .cause = "threshold",
    } }) == null);
    try std.testing.expect(event(.{ .policy_decision = .{ .trace_id = trace_id, .depth = 0, .id = "tool-id", .tool = "Bash", .decision = "deny", .source = "settings", .allowed = false } }) == null);
    try std.testing.expect(event(.{ .diag_run_end = .{ .trace_id = trace_id, .depth = 0, .turns = 1, .tool_calls = 0, .stop_reason_name = "end_turn" } }) == null);
    try std.testing.expect(event(.{ .config_changed = .{ .model = "x" } }) == null);
    try std.testing.expect(event(.{ .session_lifecycle = .{ .created = "s" } }) == null);
    try std.testing.expect(event(.{ .agent_lifecycle = .{ .status = .{
        .id = "a",
        .state = "running",
        .turns = 1,
        .tool_calls = 2,
    } } }) == null);
    try std.testing.expect(event(.{ .tasks_changed = .{ .invalidated = {} } }) == null);
    try std.testing.expect(event(.{ .ui_request_pending = .{ .tool_use_id = "t", .request_json = "{}" } }) == null);
}

test "plan and custom UI requests are not part of ABI v1" {
    const plan = InternalUiRequest{ .plan_approval = .{ .plan_md = "example" } };
    const custom = InternalUiRequest{ .custom = .{ .kind = "example", .payload_json = "{}" } };
    try std.testing.expectError(error.UnsupportedUiRequest, encodeUiRequest(std.testing.allocator, &plan));
    try std.testing.expectError(error.UnsupportedUiRequest, encodeUiRequest(std.testing.allocator, &custom));
    var out: InternalUiResponse = undefined;
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        decodeUiResponse(std.testing.allocator, &plan, "{\"answers\":[]}", &out),
    );
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        decodeUiResponse(std.testing.allocator, &custom, "{\"answers\":[]}", &out),
    );
}

test "AskQuestion response validation preserves value boundaries until core projection" {
    const options = [_]core.tool_context.AskOption{.{
        .label = "Known",
        .description = "Catalog option",
    }};
    const multi_questions = [_]core.tool_context.AskQuestion{.{
        .question = "Choose or explain",
        .header = "Choice",
        .multi = true,
        .options = &options,
    }};
    const multi_request = InternalUiRequest{ .ask_question = &multi_questions };
    var out: InternalUiResponse = undefined;
    try decodeUiResponse(
        std.testing.allocator,
        &multi_request,
        "{\"answers\":[{\"values\":[\"Known\",\"free text\"]}]}",
        &out,
    );
    switch (out) {
        .answers => |answers| {
            defer {
                for (answers) |answer| std.testing.allocator.free(@constCast(answer));
                std.testing.allocator.free(@constCast(answers));
            }
            try std.testing.expectEqualStrings("Known, free text", answers[0]);
        },
        else => return error.UnexpectedUiResponse,
    }

    try std.testing.expectError(
        error.InvalidUiResponse,
        decodeUiResponse(
            std.testing.allocator,
            &multi_request,
            "{\"answers\":[{\"values\":[]}]}",
            &out,
        ),
    );

    const single_questions = [_]core.tool_context.AskQuestion{.{
        .question = "One",
        .header = "One",
        .multi = false,
        .options = &options,
    }};
    const single_request = InternalUiRequest{ .ask_question = &single_questions };
    try std.testing.expectError(
        error.InvalidUiResponse,
        decodeUiResponse(
            std.testing.allocator,
            &single_request,
            "{\"answers\":[{\"values\":[\"one\",\"two\"]}]}",
            &out,
        ),
    );

    const no_options_questions = [_]core.tool_context.AskQuestion{.{
        .question = "Impossible",
        .header = "None",
        .multi = true,
        .options = &.{},
    }};
    const no_options_request = InternalUiRequest{ .ask_question = &no_options_questions };
    try std.testing.expectError(
        error.InvalidUiResponse,
        decodeUiResponse(
            std.testing.allocator,
            &no_options_request,
            "{\"answers\":[{\"values\":[\"free text\"]}]}",
            &out,
        ),
    );
    try std.testing.expectError(
        error.InvalidUiRequest,
        encodeUiRequest(std.testing.allocator, &no_options_request),
    );
}
