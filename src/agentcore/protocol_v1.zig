//! Stable AgentCore ABI v1 wire adapter.
//!
//! Internal CoreEvent/UiRequest types may evolve with metacodes frontends and
//! daemon features. This module is the explicit boundary that decides which
//! values cross `metacodes_agentcore_get_api(1)`. The public DTOs live in the
//! source-free SDK and are imported here as the single wire-schema truth.

const std = @import("std");
const core = @import("metacodes-core");
const public = @import("metacodes_agentcore_protocol");

const InternalEvent = core.protocol.ui_event.CoreEvent;
const InternalUiRequest = core.protocol.ui_request.UiRequest;
const InternalUiResponse = core.protocol.ui_request.UiResponse;

/// Map an internal event to the frozen ABI v1 event set. Returning null is an
/// explicit decision that an internal-only event does not cross this ABI.
/// The exhaustive switch makes future CoreEvent additions a compile failure
/// here instead of an accidental public wire change.
pub fn event(value: InternalEvent) ?public.CoreEvent {
    return switch (value) {
        .text_chunk => |v| .{ .text_chunk = v },
        .stream_begin => .stream_begin,
        .tool_start => |v| .{ .tool_start = .{ .id = v.id, .name = v.name, .input = v.input } },
        .set_current_tool => |v| .{ .set_current_tool = .{ .name = v.name } },
        .tool_progress => |v| .{ .tool_progress = .{ .id = v.id, .text = v.text } },
        .progress => |v| .{ .progress = .{
            .turn = v.turn,
            .tool_name = v.tool_name,
            .tool_input = v.tool_input,
            .tool_calls = v.tool_calls,
        } },
        .clear_current_tool => .clear_current_tool,
        .tool_result => |v| .{ .tool_result = .{
            .id = v.id,
            .name = v.name,
            .input = v.input,
            .content = v.content,
            .is_error = v.is_error,
            .elapsed_ms = v.elapsed_ms,
        } },
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
        .diag_turn_begin => |v| .{ .diag_turn_begin = .{ .trace_id = v.trace_id, .depth = v.depth, .turn = v.turn } },
        .diag_turn_end => |v| .{ .diag_turn_end = .{
            .trace_id = v.trace_id,
            .depth = v.depth,
            .turn = v.turn,
            .tool_calls = v.tool_calls,
        } },
        .diag_breaker_tripped => |v| .{ .diag_breaker_tripped = .{
            .trace_id = v.trace_id,
            .depth = v.depth,
            .same_err_count = v.same_err_count,
        } },
        .diag_cache_break => |v| .{ .diag_cache_break = .{
            .trace_id = v.trace_id,
            .depth = v.depth,
            .cache_read = v.cache_read,
            .cache_creation = v.cache_creation,
        } },
        .diag_continuation => |v| .{ .diag_continuation = .{
            .trace_id = v.trace_id,
            .depth = v.depth,
            .n = v.n,
            .max = v.max,
        } },
        .diag_run_end => |v| .{ .diag_run_end = .{
            .trace_id = v.trace_id,
            .depth = v.depth,
            .turns = v.turns,
            .tool_calls = v.tool_calls,
            .stop_reason_name = v.stop_reason_name,
        } },

        // These events belong to App/daemon coordination. AgentCore v1 owns
        // immutable Session configuration and does not expose Task/KG agents,
        // so exporting them would promise capabilities the facade cannot use.
        .config_changed, .session_lifecycle, .agent_lifecycle, .tasks_changed, .ui_request_pending => null,
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
        .permission => |v| .{ .permission = .{ .tool = v.tool, .args = v.args } },
        .plan_approval => |v| .{ .plan_approval = .{
            .plan_md = v.plan_md,
            .kg_step_count = std.math.cast(u64, v.kg_step_count) orelse return error.IntegerOverflow,
        } },
        .custom => |v| .{ .custom = .{ .kind = v.kind, .payload_json = v.payload_json } },
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
                for (answers, copied) |answer, *dest| {
                    dest.* = try allocator.dupe(u8, answer);
                    copied_count += 1;
                }
                out.* = .{ .answers = copied };
            },
            else => return error.InvalidUiResponse,
        },
        .permission => switch (parsed.value) {
            .permission => |choice| out.* = .{ .permission = switch (choice) {
                .allow_once => .allow_once,
                .allow_always => .allow_always,
                .deny_once => .deny_once,
                .deny_tool_session => .deny_tool_session,
            } },
            else => return error.InvalidUiResponse,
        },
        .plan_approval => switch (parsed.value) {
            .plan_approval => |choice| out.* = .{ .plan_approval = switch (choice) {
                .approve_default => .approve_default,
                .approve_accept_edits => .approve_accept_edits,
                .reject => .reject,
            } },
            else => return error.InvalidUiResponse,
        },
        .custom => switch (parsed.value) {
            .custom => |value| out.* = .{ .custom = try allocator.dupe(u8, value) },
            else => return error.InvalidUiResponse,
        },
    }
}

test "internal-only events are explicitly excluded from ABI v1" {
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
