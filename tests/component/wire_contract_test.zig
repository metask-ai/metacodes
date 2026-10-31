//! Contract: the versioned wire lines (core/protocol/wire.zig) for every
//! CoreEvent tag and every UiRequest kind, byte for byte against
//! tests/fixtures/wire/v1. A Host in another language can use the same files
//! as conformance vectors.
//!
//! A kernel change that renames or reshapes any event field fails here. The
//! fix is a deliberate one: either bump `wire.SCHEMA_VERSION` with a new
//! fixture directory, or keep the old spelling in wire.zig. Adding a CoreEvent
//! tag without a sample fails too.
//!
//! The capability exchange (doc/WIRE_PROTOCOL.md §2) is pinned the same way:
//! capability_frames.jsonl holds frontend frames, capability_replies.jsonl
//! core's reply to each (accepted or refused), and requests.jsonl ends with
//! one `ui_request_unavailable` line per routing reason. Every refusal reason
//! but FrameTooLarge (a 64 KiB frame; wire.zig tests it) has a frame.
//!
//! Regenerating after a deliberate change:
//!   METACODES_WIRE_FIXTURE_DUMP=<dir> zig build test:integration-times -Dtfilter=wire_contract
//! writes events.jsonl/requests.jsonl/host_events.jsonl/capability_replies.jsonl
//! to <dir> instead of comparing.

const std = @import("std");
const cc = @import("cc");

const CoreEvent = cc.ui_event.CoreEvent;
const UiRequest = cc.ui_request.UiRequest;

const EVENTS_FIXTURE = @embedFile("../fixtures/wire/v1/events.jsonl");
const REQUESTS_FIXTURE = @embedFile("../fixtures/wire/v1/requests.jsonl");
const HOST_FIXTURE = @embedFile("../fixtures/wire/v1/host_events.jsonl");
const FRAMES_FIXTURE = @embedFile("../fixtures/wire/v1/capability_frames.jsonl");
const REPLIES_FIXTURE = @embedFile("../fixtures/wire/v1/capability_replies.jsonl");

const trace: [12]u8 = "0123456789ab".*;

const file_refs = [_]cc.file_reference.FileReference{
    .{ .locator = .{ .workspace_path = "src/a.zig" }, .title = "a.zig", .kind = "source", .range = .{ .start = .{ .line = 1, .column = 0 }, .end = .{ .line = 2, .column = 4 } } },
};
const changes = [_]cc.file_change.Record{
    .{
        .locator = .{ .workspace_path = "src/b.zig" },
        .from_locator = .{ .workspace_path = "src/old_b.zig" },
        .kind = .moved,
        .status = .applied,
        .tool = "ApplyPatch",
        .tool_use_id = "tu_2",
        .agent_depth = 1,
        .before_bytes = 10,
        .after_bytes = 12,
        .unified_diff = "@@ -1 +1 @@\n-a\n+b\n",
        .diff_complete = true,
    },
};

const sample_goal = cc.core_goal.Goal{
    .id = "0123456789abcdef01234567".*,
    .objective = @constCast("ship \"wire\""),
    .status = .budget_limited,
    .token_budget = 100,
    .tokens_used = 120,
    .time_used_ms = 5,
    .created_at_ms = 1,
    .updated_at_ms = 2,
};

fn samples(manifest_entries: []cc.prompt_sections.ManifestEntry) [48]CoreEvent {
    return .{
        .{ .text_chunk = "hello \"wire\"\n" },
        .{ .thinking_chunk = "considering" },
        .stream_begin,
        .{ .tool_start = .{ .id = "tu_1", .name = "Read", .input = "{\"file_path\":\"src/a.zig\"}" } },
        .{ .set_current_tool = .{ .name = "Read" } },
        .{ .tool_progress = .{ .id = "tu_1", .text = "half way" } },
        .{ .progress = .{ .turn = 1, .tool_name = "Read", .tool_input = "src/a.zig", .tool_calls = 1 } },
        .clear_current_tool,
        .{ .tool_result = .{ .id = "tu_1", .name = "Read", .input = "{}", .content = "ok", .is_error = false, .elapsed_ms = 5, .file_refs = &file_refs } },
        .{ .file_changes = .{ .id = "tu_2", .name = "ApplyPatch", .changes = &changes, .overflow = false, .lost = false } },
        .{ .usage = .{ .input_tokens = 1, .output_tokens = 2, .cache_read_input_tokens = 3, .cache_creation_input_tokens = 4 } },
        .{ .config_changed = .{ .model = "model-b" } },
        .{ .config_changed = .{ .mode = .accept_edits } },
        .{ .config_changed = .{ .dirs = "/srv/extra" } },
        .{ .config_changed = .{ .reasoning = .high } },
        .{ .config_changed = .{ .route = .{ .provider_id = "p", .channel_id = "c", .protocol = "anthropic", .request_model_id = "m", .offer_id = "offer-0123456789abcdef0123456789abcdef", .credential_ref = null, .scope = "session" } } },
        .{ .session_lifecycle = .{ .created = "0123456789abcdef01234567" } },
        .{ .session_lifecycle = .{ .closed = "0123456789abcdef01234567" } },
        .{ .agent_lifecycle = .{ .spawned = .{ .id = "job_1", .agent_type = "Explore", .desc = "look around", .foreground = true } } },
        .{ .agent_lifecycle = .{ .status = .{ .id = "job_1", .state = "running", .turns = 2, .tool_calls = 3 } } },
        .{ .agent_lifecycle = .{ .done = .{ .id = "job_1", .state = "done", .turns = 4, .tool_calls = 5, .tokens = 600 } } },
        .{ .tasks_changed = .invalidated },
        .{ .tasks_changed = .{ .task = .{ .id = "t1", .state = "in_progress", .claimed_by = "agent-1" } } },
        .{ .context_warning = .{ .current_tokens = 1, .warning_threshold = 2, .auto_compact_threshold = 3, .blocking_limit = 4, .level = "warning" } },
        .{ .auto_compact = .{ .dropped = 1, .kept = 2, .before_tokens = 3, .after_tokens = 4, .cause = "trigger" } },
        .{ .context_projection = .{ .kind = "large_tool_result_truncation", .changed_items = 1, .bytes_before = 10, .bytes_after = 5, .active_messages = 3, .cause = "pressure" } },
        .{ .retry_notice = .{ .attempt = 1, .max = 3, .delay_ms = 500 } },
        .{ .input_adopted = .{ .input_id = 7, .sequence = 1, .turn = 2 } },
        .{ .environment_fault = .{ .tool = "Bash", .code = "working_directory_unavailable", .detail = "gone", .count = 1, .limit = 3 } },
        .stream_done,
        .{ .output_segment_begin = .{ .index = 0, .turn = 1, .group = 0 } },
        .{ .output_segment_end = .{ .index = 0, .turn = 1, .group = 0, .disposition = .final, .bytes = 5 } },
        .{ .ui_request_pending = .{ .tool_use_id = "tu_3", .request_json = "{\"kind\":\"video_timeline\"}" } },
        .ui_request_resolved,
        .{ .prompt_manifest = .{ .entries = manifest_entries, .sha256 = [_]u8{0xcd} ** 32 } },
        .{ .goal_updated = &sample_goal },
        .{ .diag_turn_begin = .{ .trace_id = trace, .depth = 0, .turn = 1 } },
        .{ .diag_turn_end = .{ .trace_id = trace, .depth = 0, .turn = 1, .tool_calls = 2 } },
        .{ .diag_model_request = .{ .trace_id = trace, .depth = 0, .turn = 1, .attempt = 1, .elapsed_ms = 30, .outcome = "ok" } },
        .{ .diag_compact_request = .{ .trace_id = trace, .depth = 0, .turn = 2, .elapsed_ms = 40, .outcome = "ok", .cause = "threshold" } },
        .{ .diag_compact_begin = .{ .trace_id = trace, .depth = 0, .turn = 2, .cause = "threshold" } },
        .{ .diag_compact_end = .{ .trace_id = trace, .depth = 0, .turn = 2, .elapsed_ms = 41, .outcome = "ok", .cause = "threshold" } },
        .{ .diag_tool_stage = .{ .trace_id = trace, .depth = 0, .turn = 1, .tool_calls = 2, .elapsed_ms = 7 } },
        .{ .diag_breaker_tripped = .{ .trace_id = trace, .depth = 0, .same_err_count = 3 } },
        .{ .diag_cache_break = .{ .trace_id = trace, .depth = 0, .cache_read = 10, .cache_creation = 20 } },
        .{ .diag_continuation = .{ .trace_id = trace, .depth = 0, .n = 1, .max = 3 } },
        .{ .policy_decision = .{ .trace_id = trace, .depth = 0, .id = "tu_1", .tool = "Bash", .decision = "allow", .source = "mode", .allowed = true } },
        .{ .diag_run_end = .{ .trace_id = trace, .depth = 0, .turns = 2, .tool_calls = 3, .stop_reason_name = "end_turn" } },
    };
}

const options = [_]cc.ui_request.AskOption{
    .{ .label = "Ship", .description = "Release now", .preview = "" },
    .{ .label = "Wait", .description = "Hold the release", .preview = "## Plan\n- wait" },
};
const questions = [_]cc.ui_request.AskQuestion{
    .{ .question = "Ship now?", .header = "Decision", .multi = false, .options = &options },
    .{ .question = "Which targets?", .header = "Targets", .multi = true, .options = &options },
};
const requests = [_]UiRequest{
    .{ .permission = .{ .tool = "Bash", .args = "{\"command\":\"rm -r build\"}" } },
    .{ .ask_question = &questions },
    .{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } },
};

fn fixtureLines(fixture: []const u8) []const u8 {
    return std.mem.trimEnd(u8, fixture, "\n");
}

fn compareOrDump(allocator: std.mem.Allocator, lines: []const []const u8, fixture: []const u8, name: []const u8) !void {
    if (std.c.getenv("METACODES_WIRE_FIXTURE_DUMP")) |raw_dir| {
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ std.mem.span(raw_dir), name }, 0);
        defer allocator.free(path);
        const file = std.c.fopen(path.ptr, "wb") orelse return error.FixtureDumpFailed;
        defer _ = std.c.fclose(file);
        for (lines) |line| {
            _ = std.c.fwrite(line.ptr, 1, line.len, file);
            _ = std.c.fwrite("\n", 1, 1, file);
        }
        return;
    }
    var expected = std.mem.splitScalar(u8, fixtureLines(fixture), '\n');
    for (lines, 0..) |line, index| {
        const want = expected.next() orelse {
            std.debug.print("{s}: fixture ends before line {d}: {s}\n", .{ name, index + 1, line });
            return error.WireFixtureMismatch;
        };
        std.testing.expectEqualStrings(want, line) catch |err| {
            std.debug.print("{s}: line {d} differs\n", .{ name, index + 1 });
            return err;
        };
    }
    if (expected.next()) |extra| {
        std.debug.print("{s}: fixture has more lines than samples: {s}\n", .{ name, extra });
        return error.WireFixtureMismatch;
    }
}

test "wire_contract: every CoreEvent tag has a pinned v1 line" {
    const a = std.testing.allocator;
    var manifest_entries = [_]cc.prompt_sections.ManifestEntry{
        .{ .id = "metacodes:identity", .order = 0, .origin = .kernel, .class = .replaceable, .sha256 = [_]u8{0xab} ** 32 },
        .{ .id = "host:rules", .order = 500, .origin = .host, .class = .removable, .sha256 = [_]u8{0x01} ** 32 },
    };
    const events = samples(&manifest_entries);

    inline for (std.meta.fields(CoreEvent)) |field| {
        var sampled = false;
        for (events) |event| sampled = sampled or std.mem.eql(u8, @tagName(event), field.name);
        if (!sampled) {
            std.debug.print("wire fixture has no sample of CoreEvent.{s}\n", .{field.name});
            return error.MissingWireSample;
        }
    }

    var lines: [events.len][]u8 = undefined;
    var written: usize = 0;
    defer for (lines[0..written]) |line| a.free(line);
    for (events, 0..) |event, index| {
        lines[index] = try cc.wire.writeEvent(a, event);
        written += 1;
    }
    try compareOrDump(a, &lines, EVENTS_FIXTURE, "events.jsonl");
}

/// What a frontend that renders permission prompts and video_timeline@1 is
/// spared: one request per `Unavailable` reason, in its order.
const routed_away = [_]UiRequest{
    .{ .ask_question = &questions },
    .{ .custom = .{ .kind = "video_timeline@2", .payload_json = "{\"clips\":[]}" } },
    .{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } },
};

test "wire_contract: every UiRequest kind, close outcome and unavailable reason has a pinned v1 line" {
    const a = std.testing.allocator;
    const closed_count = std.meta.fields(cc.wire.RequestClosed).len;
    var lines: [requests.len + closed_count + routed_away.len][]u8 = undefined;
    var written: usize = 0;
    defer for (lines[0..written]) |line| a.free(line);

    inline for (std.meta.fields(UiRequest)) |field| {
        var sampled = false;
        for (requests) |request| sampled = sampled or std.mem.eql(u8, @tagName(request), field.name);
        if (!sampled) {
            std.debug.print("wire fixture has no sample of UiRequest.{s}\n", .{field.name});
            return error.MissingWireSample;
        }
    }

    for (&requests, 0..) |*request, index| {
        lines[index] = try cc.wire.writeRequest(a, index + 1, request);
        written += 1;
    }
    inline for (std.meta.fields(cc.wire.RequestClosed), 0..) |field, index| {
        lines[requests.len + index] = try cc.wire.writeRequestClosed(a, index + 1, @enumFromInt(field.value));
        written += 1;
    }

    // The unavailable lines come from routing, not from naming a reason.
    var declaration = try cc.wire.parseCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"permission\"],\"custom\":[\"video_timeline@1\"]}");
    defer declaration.deinit();
    const capabilities = &declaration.capabilities;
    try std.testing.expectEqual(cc.frontend_capabilities.Route.deliver, cc.frontend_capabilities.route(capabilities, &requests[0]));
    const timeline_v1 = UiRequest{ .custom = .{ .kind = "video_timeline@1", .payload_json = "{}" } };
    try std.testing.expectEqual(cc.frontend_capabilities.Route.deliver, cc.frontend_capabilities.route(capabilities, &timeline_v1));
    inline for (std.meta.fields(cc.frontend_capabilities.Unavailable), 0..) |field, index| {
        const route = cc.frontend_capabilities.route(capabilities, &routed_away[index]);
        try std.testing.expectEqual(cc.frontend_capabilities.Route{ .unavailable = @enumFromInt(field.value) }, route);
        lines[requests.len + closed_count + index] = try cc.wire.writeRequestUnavailable(a, &routed_away[index], route.unavailable);
        written += 1;
    }
    try compareOrDump(a, &lines, REQUESTS_FIXTURE, "requests.jsonl");
}

test "wire_contract: each capability frame gets its pinned reply; every refusal reason has a frame" {
    const a = std.testing.allocator;
    var replies: std.ArrayList([]u8) = .empty;
    defer {
        for (replies.items) |line| a.free(line);
        replies.deinit(a);
    }
    var refused: std.ArrayList([]const u8) = .empty;
    defer refused.deinit(a);
    var frames = std.mem.splitScalar(u8, fixtureLines(FRAMES_FIXTURE), '\n');
    while (frames.next()) |frame| {
        const reply = if (cc.wire.acceptCapabilities(a, frame)) |accepted| blk: {
            var declaration = accepted.declaration;
            declaration.deinit();
            break :blk accepted.line;
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => |reason| blk: {
                try refused.append(a, @errorName(reason));
                break :blk try cc.wire.writeCapabilitiesRefused(a, reason);
            },
        };
        try replies.append(a, reply);
    }
    try compareOrDump(a, replies.items, REPLIES_FIXTURE, "capability_replies.jsonl");

    inline for (@typeInfo(cc.wire.RefusalError).error_set.?) |reason| {
        var seen = std.mem.eql(u8, reason.name, "FrameTooLarge");
        for (refused.items) |name| seen = seen or std.mem.eql(u8, name, reason.name);
        if (!seen) {
            std.debug.print("capability_frames.jsonl has no frame refused as {s}\n", .{reason.name});
            return error.MissingWireSample;
        }
    }
}

const host_events = [_]cc.wire.HostEvent{
    .{ .user_message = .{ .run_id = 3, .trace_id = "trace-1", .text = "fix the build" } },
    .{ .run_done = .{ .run_id = 3, .trace_id = "trace-1", .stop_reason = "end_turn" } },
    .{ .run_done = .{ .run_id = 4, .error_name = "ProviderUnavailable" } },
    .{ .run_done = .{ .run_id = 5, .stop_reason = "api_error", .model_error = .{
        .category = .payment_required,
        .code = "insufficient_balance",
        .type = null,
        .message = "Top up",
        .http_status = 402,
        .request_id = "req-1",
        .retry = .not_retryable,
        .retry_after_ms = null,
        .attempts = 1,
        .truncated = false,
    } } },
    .{ .command_result = .{ .command = "set_model", .ok = true } },
    .{ .command_result = .{ .command = "set_reasoning_effort", .ok = false, .error_name = "AgentEffortUnsupportedProvider" } },
    .{ .session_poisoned = .{ .error_name = "CallbackFailed", .dropped = 2 } },
};

test "wire_contract: every HostEvent tag and the Run context form have a pinned v1 line" {
    const a = std.testing.allocator;
    inline for (std.meta.fields(cc.wire.HostEvent)) |field| {
        var sampled = false;
        for (host_events) |event| sampled = sampled or std.mem.eql(u8, @tagName(event), field.name);
        if (!sampled) {
            std.debug.print("wire fixture has no sample of HostEvent.{s}\n", .{field.name});
            return error.MissingWireSample;
        }
    }
    var lines: [host_events.len + 2][]u8 = undefined;
    var written: usize = 0;
    defer for (lines[0..written]) |line| a.free(line);
    for (host_events, 0..) |event, index| {
        lines[index] = try cc.wire.writeHostEvent(a, event);
        written += 1;
    }
    lines[host_events.len] = try cc.wire.writeRunEvent(a, .{ .run_id = 3, .trace_id = "trace-1" }, .{ .text_chunk = "on it" });
    written += 1;
    lines[host_events.len + 1] = try cc.wire.writeRunEvent(a, .{ .run_id = 4 }, .stream_done);
    written += 1;
    try compareOrDump(a, &lines, HOST_FIXTURE, "host_events.jsonl");
}

test "wire_contract: every v1 request line parses as JSON and names its kind" {
    var lines = std.mem.splitScalar(u8, fixtureLines(REQUESTS_FIXTURE), '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("v").?.integer);
        try std.testing.expect(parsed.value.object.get("type") != null);
    }
    var events = std.mem.splitScalar(u8, fixtureLines(EVENTS_FIXTURE), '\n');
    while (events.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("v").?.integer);
    }
}
