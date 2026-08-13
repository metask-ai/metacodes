const std = @import("std");
const harness = @import("harness");
const abi = @import("agentcore-abi");
const sdk = @import("agentcore-sdk");
const core = @import("metacodes-core");
const sync = @import("platform").sync;
const wire = sdk.types;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const API_ERROR_SSE =
    "data: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"model not found\"}}\n\n";

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"review\\\",\\\"values\\\":[\\\"src/main.zig\\\"]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const CHILD_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_child_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_child_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"child\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HIDDEN_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_hidden_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_hidden_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"private-deploy\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FORK_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_fork_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_fork_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"forked\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const BLOCKED_MODEL_SKILL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_blocked_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_blocked_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"blocked\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const WRITE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_write\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"blocked.txt\\\",\\\"content\\\":\\\"must-not-write\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SKILL_THEN_GLOB_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_serial_skill\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_serial_skill\",\"name\":\"Skill\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"name\\\":\\\"root-policy\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_serial_glob\",\"name\":\"Glob\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"**/*\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_SKILL_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_skill\",\"type\":\"function\",\"function\":{\"name\":\"Skill\",\"arguments\":\"\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"name\\\":\\\"re\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"view\\\",\\\"values\\\":[\\\"README.md\\\"]}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

const OPENAI_FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"openai skill done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const CONTINUATION_HEAD_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cont_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"head\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const CONTINUATION_TAIL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"cont_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":6,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"tail\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Independent Host-side oracle for the public A1 recipe. It deliberately
/// knows nothing about Conversation internals.
const ReconstructionProbe = struct {
    current: [128]u8 = undefined,
    current_len: usize = 0,
    answer: [256]u8 = undefined,
    answer_len: usize = 0,
    stream_done_count: usize = 0,
    usage: sdk.protocol.UsageDelta = .{},

    fn checkedAdd(dst: *u64, value: u64) bool {
        dst.* = std.math.add(u64, dst.*, value) catch return false;
        return true;
    }

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *ReconstructionProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |decoded| decoded,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .text_chunk => |text| {
                if (text.len > self.current.len - self.current_len) return wire.EVENT_FATAL;
                @memcpy(self.current[self.current_len..][0..text.len], text);
                self.current_len += text.len;
            },
            .stream_done => {
                if (self.current_len > self.answer.len - self.answer_len) return wire.EVENT_FATAL;
                @memcpy(self.answer[self.answer_len..][0..self.current_len], self.current[0..self.current_len]);
                self.answer_len += self.current_len;
                self.current_len = 0;
                self.stream_done_count += 1;
            },
            .tool_start, .tool_result => {
                self.answer_len = 0;
                self.current_len = 0;
            },
            .usage => |usage| {
                if (!checkedAdd(&self.usage.input_tokens, usage.input_tokens) or
                    !checkedAdd(&self.usage.output_tokens, usage.output_tokens) or
                    !checkedAdd(&self.usage.cache_read_input_tokens, usage.cache_read_input_tokens) or
                    !checkedAdd(&self.usage.cache_creation_input_tokens, usage.cache_creation_input_tokens))
                    return wire.EVENT_FATAL;
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }
};

test "Host reconstruction oracle resets at public tool boundaries" {
    var probe = ReconstructionProbe{};
    const events = [_][]const u8{
        "{\"text_chunk\":\"provisional\"}",
        "{\"stream_done\":{}}",
        "{\"text_chunk\":\"unclosed\"}",
        "{\"tool_start\":{\"id\":\"t\",\"name\":\"Read\",\"input\":\"{}\"}}",
        "{\"tool_result\":{\"id\":\"t\",\"name\":\"Read\",\"input\":\"{}\",\"content\":\"ok\",\"is_error\":false}}",
        "{\"text_chunk\":\"final\"}",
        "{\"stream_done\":{}}",
    };
    for (events) |encoded| {
        try std.testing.expectEqual(
            wire.EVENT_CONTINUE,
            ReconstructionProbe.event(&probe, null, sdk.bytesView(encoded)),
        );
    }
    try std.testing.expectEqualStrings("final", probe.answer[0..probe.answer_len]);
}

/// Test Host registry implementing the consumer-side §4 contract. The binding
/// is keyed by opaque Session handle, deep-copies session_id, and performs the
/// first bind and every comparison under the same per-registry mutex.
const HostIdentityRegistry = struct {
    const Entry = struct {
        session: ?*wire.SessionHandle = null,
        len: u8 = 0,
        bytes: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined,
    };

    mutex: sync.Mutex = .{},
    entries: [2]Entry = .{ .{}, .{} },

    fn accept(self: *HostIdentityRegistry, session: *wire.SessionHandle, session_id: []const u8) bool {
        if (session_id.len == 0 or session_id.len > wire.MAX_SESSION_ID_BYTES_V1) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.session == session) {
                return entry.len == session_id.len and std.mem.eql(u8, entry.bytes[0..entry.len], session_id);
            }
        }
        for (&self.entries) |*entry| {
            if (entry.session == null) {
                entry.session = session;
                entry.len = @intCast(session_id.len);
                @memcpy(entry.bytes[0..session_id.len], session_id);
                return true;
            }
        }
        return false;
    }
};

const Probe = struct {
    registry: HostIdentityRegistry = .{},
    expected_session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 1,
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    saw_tool_start: bool = false,
    saw_tool_result: bool = false,
    saw_run_state: bool = false,
    run_state_sequence_valid: bool = true,
    run_state_saw_starting: bool = false,
    run_state_saw_executing_tools: bool = false,
    run_state_saw_waiting_ui: bool = false,
    run_state_saw_completed: bool = false,
    run_state_terminal_empty: bool = false,
    run_state_invariant_valid: bool = true,
    run_state_last_run_id: u64 = 0,
    run_state_last_seq: u64 = 0,

    fn context(self: *Probe, run_ptr: ?*const wire.RunContextV1) ?sdk.RunContext {
        const run = sdk.validateRunContext(run_ptr) catch return null;
        if (run.session != self.expected_session or run.run_id != self.expected_run_id or run.session_id.len != 24)
            return null;
        if (!self.registry.accept(run.session, run.session_id)) return null;
        return run;
    }

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        _ = self.context(run_ptr) orelse return wire.EVENT_FATAL;
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known_event| switch (known_event) {
                .tool_start => self.saw_tool_start = true,
                .tool_result => self.saw_tool_result = true,
                .run_state => |state| {
                    self.saw_run_state = true;
                    if (state.phase == .generating and state.in_flight_tools.len != 0)
                        self.run_state_invariant_valid = false;
                    if (self.run_state_last_run_id != state.run_id) {
                        self.run_state_last_run_id = state.run_id;
                        self.run_state_last_seq = 0;
                    }
                    if (state.transition_seq != self.run_state_last_seq + 1)
                        self.run_state_sequence_valid = false;
                    self.run_state_last_seq = state.transition_seq;
                    switch (state.phase) {
                        .starting => self.run_state_saw_starting = true,
                        .executing_tools => self.run_state_saw_executing_tools = true,
                        .waiting_ui => self.run_state_saw_waiting_ui = true,
                        .completed => {
                            self.run_state_saw_completed = true;
                            self.run_state_terminal_empty = state.in_flight_tools.len == 0;
                        },
                        else => {},
                    }
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, request_json: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        _ = self.context(run_ptr) orelse return wire.UI_FATAL;
        const bytes = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, bytes) catch return wire.UI_FATAL;
        defer parsed.deinit();
        if (parsed.value != .ask_question) return wire.UI_FATAL;
        self.ui_calls += 1;
        const values = [_][]const u8{"Yes"};
        const answers = [_]sdk.protocol.Answer{.{ .values = &values }};
        const response = sdk.encodeUiResponse(std.heap.c_allocator, parsed.value, .{ .answers = &answers }) catch return wire.UI_FATAL;
        (out orelse {
            std.heap.c_allocator.free(response);
            return wire.UI_FATAL;
        }).* = .{ .ptr = response.ptr, .len = response.len };
        return wire.UI_ANSWERED;
    }

    fn uiRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.ui_releases += 1;
        if (out) |value| {
            if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..@intCast(value.len)]);
            value.* = .{ .ptr = null, .len = 0 };
        }
    }

    fn host(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        _ = self.context(run_ptr) orelse return wire.HOST_FATAL;
        if (std.mem.indexOf(u8, sdk.borrowedBytes(args) catch return wire.HOST_FAILED, "hello") == null) return wire.HOST_FAILED;
        self.host_calls += 1;
        const result = "host-ok";
        (out orelse return wire.HOST_FAILED).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn hostRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.host_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const UiFailureMode = enum {
    fatal,
    oversized,
    unavailable,
    cancelled_with_buffer,
    unknown,
    abort_twice,
};

fn acceptEvent(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
    return wire.EVENT_CONTINUE;
}

const UiFailureProbe = struct {
    mode: UiFailureMode,
    api: ?sdk.Api = null,
    calls: usize = 0,
    releases: usize = 0,
    byte: u8 = 0,
    nested_run_status: u32 = std.math.maxInt(u32),
    nested_destroy_status: u32 = std.math.maxInt(u32),
    first_abort_status: u32 = std.math.maxInt(u32),
    second_abort_status: u32 = std.math.maxInt(u32),

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *UiFailureProbe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        self.calls += 1;
        return switch (self.mode) {
            .fatal => wire.UI_FATAL,
            .oversized => blk: {
                (out orelse return wire.UI_FATAL).* = .{
                    .ptr = @ptrCast(&self.byte),
                    .len = wire.MAX_UI_RESPONSE_BYTES_V1 + 1,
                };
                break :blk wire.UI_ANSWERED;
            },
            .unavailable => wire.UI_UNAVAILABLE,
            .cancelled_with_buffer => blk: {
                (out orelse return wire.UI_FATAL).* = .{
                    .ptr = @ptrCast(&self.byte),
                    .len = 1,
                };
                break :blk wire.UI_CANCELLED;
            },
            .unknown => std.math.maxInt(u32),
            .abort_twice => blk: {
                const api = self.api orelse return wire.UI_FATAL;
                const run = sdk.validateRunContext(run_ptr) catch return wire.UI_FATAL;
                var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
                defer api.bufferRelease()(&diagnostic);
                self.nested_run_status = api.sessionRunText(
                    run.session,
                    run.run_id + 1,
                    sdk.bytesView("nested callback run"),
                    null,
                    null,
                    &diagnostic,
                );
                api.bufferRelease()(&diagnostic);
                self.nested_destroy_status = api.sessionDestroy()(run.session, &diagnostic);
                api.bufferRelease()(&diagnostic);
                self.first_abort_status = api.sessionAbort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                api.bufferRelease()(&diagnostic);
                self.second_abort_status = api.sessionAbort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                break :blk wire.UI_UNAVAILABLE;
            },
        };
    }

    fn release(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *UiFailureProbe = @ptrCast(@alignCast(raw orelse return));
        self.releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const FatalEventProbe = struct {
    calls: usize = 0,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        const self: *FatalEventProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        self.calls += 1;
        return wire.EVENT_FATAL;
    }
};

const NestedSkillFatalProbe = struct {
    calls: usize = 0,
    failed: bool = false,

    fn event(
        raw: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *NestedSkillFatalProbe = @ptrCast(@alignCast(
            raw orelse return wire.EVENT_FATAL,
        ));
        self.calls += 1;
        const bytes = sdk.borrowedBytes(event_json) catch
            return wire.EVENT_FATAL;
        if (std.mem.indexOf(u8, bytes, "\"text_chunk\":\"done\"") != null) {
            self.failed = true;
            return wire.EVENT_FATAL;
        }
        return wire.EVENT_CONTINUE;
    }
};

const AbortEventProbe = struct {
    api: sdk.Api,
    calls: usize = 0,
    stale_abort_status: u32 = std.math.maxInt(u32),
    abort_status: u32 = std.math.maxInt(u32),

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        const self: *AbortEventProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        self.calls += 1;
        if (self.calls == 1) {
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const wrong_run_id: u64 = 2;
            self.stale_abort_status = self.api.sessionAbort()(run.session, wrong_run_id, wire.ABORT_USER_REQUEST, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
            self.abort_status = self.api.sessionAbort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
        }
        return wire.EVENT_CONTINUE;
    }
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

fn allSkillsEnabledSelection() wire.SkillSelectionV1 {
    var selection = std.mem.zeroes(wire.SkillSelectionV1);
    selection.struct_size = @sizeOf(wire.SkillSelectionV1);
    selection.default_state_code = wire.SKILL_SELECTION_ENABLED;
    return selection;
}

const PublicSessionFixture = struct {
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle = null,
    session: ?*wire.SessionHandle = null,
    diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

    fn init(root: []const u8, base_url: []const u8, model: []const u8) !PublicSessionFixture {
        return initWithBudget(root, base_url, model, null);
    }

    fn initWithBudget(
        root: []const u8,
        base_url: []const u8,
        model: []const u8,
        budget: ?*const wire.DurableBudgetProfileV1,
    ) !PublicSessionFixture {
        const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
            return error.MissingApi;
        var self = PublicSessionFixture{
            .api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api))),
        };
        errdefer self.deinit();

        var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
        runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            self.api.runtimeCreate()(&runtime_config, &self.runtime, &self.diagnostic),
        );

        var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
        host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
        host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
        host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
        host_config.shell_policy_code = wire.SHELL_DISABLED;
        host_config.api_key = sdk.bytesView("test-key");
        host_config.base_url = sdk.bytesView(base_url);
        host_config.workspace_root = sdk.bytesView(root);
        host_config.workspace_home = sdk.bytesView(root);
        host_config.durable_budget = budget;
        var session_config = sessionCreateConfig(&host_config, model);
        var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
        callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
        callbacks.on_event = acceptEvent;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            self.api.sessionCreate()(
                self.runtime,
                &session_config,
                &callbacks,
                &self.session,
                &self.diagnostic,
            ),
        );
        return self;
    }

    fn deinit(self: *PublicSessionFixture) void {
        if (self.session) |handle| {
            _ = self.api.sessionDestroy()(handle, &self.diagnostic);
            self.session = null;
            self.releaseDiagnostic();
        }
        if (self.runtime) |handle| {
            _ = self.api.runtimeDestroy()(handle, &self.diagnostic);
            self.runtime = null;
            self.releaseDiagnostic();
        }
        self.releaseDiagnostic();
    }

    fn releaseDiagnostic(self: *PublicSessionFixture) void {
        self.api.bufferRelease()(&self.diagnostic);
    }

    fn runText(self: *PublicSessionFixture, run_id: u64, prompt: []const u8) !wire.RunResultV1 {
        var options = std.mem.zeroes(wire.RunOptionsV1);
        options.struct_size = @sizeOf(wire.RunOptionsV1);
        options.max_turns = 1;
        var result = std.mem.zeroes(wire.RunResultV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            self.api.sessionRunText(
                self.session,
                run_id,
                sdk.bytesView(prompt),
                &options,
                &result,
                &self.diagnostic,
            ),
        );
        return result;
    }
};

test "L2 durable budget profile crosses the public wire and rejects before Run admission" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    var server = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const budget = wire.DurableBudgetProfileV1{
        .struct_size = @sizeOf(wire.DurableBudgetProfileV1),
        .reserved0 = 0,
        .hard_bytes = 4 * 1024 * 1024,
        .soft_bytes = 3 * 1024 * 1024,
        .input_cap_bytes = 512,
        .provider_request_cap_bytes = 512 * 1024,
        .provider_result_cap_bytes = 64 * 1024,
        .tool_result_cap_bytes = 64 * 1024,
        .mcp_result_cap_bytes = 64 * 1024,
        .audit_reserve_bytes = 64 * 1024,
        .terminal_reserve_bytes = 64 * 1024,
        .reserved = [_]u64{0} ** 4,
    };
    var fixture = try PublicSessionFixture.initWithBudget(
        root,
        url,
        "test-model",
        &budget,
    );
    defer fixture.deinit();

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionDescribe()(
            fixture.session,
            &description,
            &fixture.diagnostic,
        ),
    );
    {
        defer fixture.api.bufferRelease()(&description);
        const encoded = try sdk.borrowedBytes(.{
            .ptr = description.ptr,
            .len = description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(
            budget.hard_bytes,
            decoded.value.budget.hard_bytes,
        );
        try std.testing.expectEqual(
            budget.soft_bytes,
            decoded.value.budget.soft_bytes,
        );
    }

    var oversized: [513]u8 = undefined;
    @memset(&oversized, 'x');
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_BUDGET_REQUIRED,
        fixture.api.sessionRunText(
            fixture.session,
            1,
            sdk.bytesView(&oversized),
            &options,
            &result,
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();
    result = try fixture.runText(1, "short input reuses the unconsumed run id");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

fn appendCompactablePublicHistory(fixture: *PublicSessionFixture) !void {
    const old_context = [_]u8{'A'} ** 8192;
    var result = try fixture.runText(1, &old_context);
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    for (2..7) |run_id| {
        result = try fixture.runText(run_id, "recent context");
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    }
}

fn writeSkillFixture(
    allocator: std.mem.Allocator,
    root: []const u8,
    invocation_name: []const u8,
    contents: []const u8,
) !void {
    try writeSkillFixtureInSource(
        allocator,
        root,
        ".agents",
        invocation_name,
        contents,
    );
}

fn writeSkillFixtureInSource(
    allocator: std.mem.Allocator,
    root: []const u8,
    source_dir: []const u8,
    invocation_name: []const u8,
    contents: []const u8,
) !void {
    const skill_dir = try std.fs.path.join(
        allocator,
        &.{ root, source_dir, "skills", invocation_name },
    );
    defer allocator.free(skill_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, skill_dir);
    const skill_path = try std.fs.path.join(
        allocator,
        &.{ skill_dir, "SKILL.md" },
    );
    defer allocator.free(skill_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = skill_path,
        .data = contents,
    });
}

const CatalogIdentities = struct {
    revision: []u8,
    skill_id: []u8,
};

fn extractCatalogIdentities(
    allocator: std.mem.Allocator,
    descriptor_json: []const u8,
    invocation_name: []const u8,
) !CatalogIdentities {
    const parsed = try sdk.decodeSkillCatalog(allocator, descriptor_json);
    defer parsed.deinit();
    for (parsed.value.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, invocation_name)) {
            const revision = try allocator.dupe(u8, parsed.value.catalog_revision);
            errdefer allocator.free(revision);
            return .{
                .revision = revision,
                .skill_id = try allocator.dupe(u8, skill.skill_id),
            };
        }
    }
    return error.SkillMissingFromCatalog;
}

fn expectInvalidSessionConfig(
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    config: *const wire.SessionCreateConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
    diagnostic: *wire.OwnedBytesV1,
) !void {
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionCreate()(runtime, config, callbacks, &session, diagnostic),
    );
    try std.testing.expect(session == null);
    try std.testing.expect(diagnostic.ptr != null and diagnostic.len != 0);
    const diagnostic_bytes = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
    const api_key = try sdk.borrowedBytes(config.host.?.api_key);
    if (api_key.len != 0) try std.testing.expect(std.mem.indexOf(u8, diagnostic_bytes, api_key) == null);
    api.bufferRelease()(diagnostic);
    try std.testing.expect(diagnostic.ptr == null and diagnostic.len == 0);
}

fn sessionCreateConfig(
    host: *const wire.SessionHostConfigV1,
    model: []const u8,
) wire.SessionCreateConfigV1 {
    var config = std.mem.zeroes(wire.SessionCreateConfigV1);
    config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    config.host = host;
    config.model = sdk.bytesView(model);
    return config;
}

const PublicMcpProbe = struct {
    const Connection = struct {
        owner: ?*anyopaque = null,
        purpose_code: u32 = 0,
        era_code: u32 = 0,
        closed: bool = false,
    };

    server_era_code: u32 = wire.MCP_ERA_2026_07_28,
    advertise_tools: bool = true,
    required_task: bool = false,
    tool_count: u8 = 1,
    probe_open_status: u32 = wire.MCP_OPEN_OK,
    probe_exchange_status: ?u32 = null,
    connections: [8]Connection = [_]Connection{.{}} ** 8,
    connection_count: usize = 0,
    open_attempts: u32 = 0,
    probe_open_attempts: u32 = 0,
    actual_open_attempts: u32 = 0,
    opens: u32 = 0,
    probe_opens: u32 = 0,
    actual_opens: u32 = 0,
    actual_2025_11_opens: u32 = 0,
    actual_2025_06_opens: u32 = 0,
    request_attempts: u32 = 0,
    requests: u32 = 0,
    list_requests: u32 = 0,
    list_requests_by_era: [4]u32 = [_]u32{0} ** 4,
    call_requests: u32 = 0,
    notifications: u32 = 0,
    notifications_by_era: [4]u32 = [_]u32{0} ** 4,
    closes: u32 = 0,
    double_closes: u32 = 0,
    releases: u32 = 0,
    connector_retains: u32 = 0,
    connector_releases: u32 = 0,

    fn connector(self: *@This()) wire.McpConnectorV1 {
        var result = std.mem.zeroes(wire.McpConnectorV1);
        result.struct_size = @sizeOf(wire.McpConnectorV1);
        result.ctx = self;
        result.open = open;
        result.request = request;
        result.notify = notify;
        result.close = close;
        result.release_response = releaseResponse;
        result.retain_connector = retainConnector;
        result.release_connector = releaseConnector;
        return result;
    }

    fn retainConnector(raw: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        self.connector_retains += 1;
    }

    fn releaseConnector(raw: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        self.connector_releases += 1;
    }

    fn open(
        raw: ?*anyopaque,
        purpose_code: u32,
        requested_era_code: u32,
        _: u32,
        out_connection_ctx: ?*?*anyopaque,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_OPEN_FATAL));
        const out = out_connection_ctx orelse return wire.MCP_OPEN_FATAL;
        out.* = null;
        self.open_attempts += 1;
        switch (purpose_code) {
            wire.MCP_CONNECTION_DISPOSABLE_PROBE => {
                self.probe_open_attempts += 1;
                if (requested_era_code != wire.MCP_ERA_2026_07_28)
                    return wire.MCP_OPEN_FATAL;
                if (self.probe_open_status != wire.MCP_OPEN_OK)
                    return self.probe_open_status;
                self.probe_opens += 1;
            },
            wire.MCP_CONNECTION_ACTUAL => {
                self.actual_open_attempts += 1;
                if (self.server_era_code == wire.MCP_ERA_2026_07_28 and
                    requested_era_code != wire.MCP_ERA_2026_07_28)
                    return wire.MCP_OPEN_NETWORK_ERROR;
                if (self.server_era_code == wire.MCP_ERA_2025_11_25 and
                    requested_era_code != wire.MCP_ERA_2025_11_25)
                    return wire.MCP_OPEN_NETWORK_ERROR;
                if (self.server_era_code == wire.MCP_ERA_2025_06_18 and
                    requested_era_code != wire.MCP_ERA_2025_11_25 and
                    requested_era_code != wire.MCP_ERA_2025_06_18)
                    return wire.MCP_OPEN_NETWORK_ERROR;
                self.actual_opens += 1;
                if (requested_era_code == wire.MCP_ERA_2025_11_25)
                    self.actual_2025_11_opens += 1;
                if (requested_era_code == wire.MCP_ERA_2025_06_18)
                    self.actual_2025_06_opens += 1;
            },
            else => return wire.MCP_OPEN_FATAL,
        }
        if (self.connection_count == self.connections.len)
            return wire.MCP_OPEN_FATAL;
        const connection = &self.connections[self.connection_count];
        self.connection_count += 1;
        connection.* = .{
            .owner = raw,
            .purpose_code = purpose_code,
            .era_code = requested_era_code,
        };
        self.opens += 1;
        out.* = connection;
        return wire.MCP_OPEN_OK;
    }

    fn request(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        request_json: wire.BytesViewV1,
        _: u32,
        _: ?*const wire.McpCancellationV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_EXCHANGE_FATAL));
        const connection = liveConnection(raw, connection_ctx) orelse
            return wire.MCP_EXCHANGE_FATAL;
        const out = out_response orelse return wire.MCP_EXCHANGE_FATAL;
        out.* = .{ .ptr = null, .len = 0 };
        self.request_attempts += 1;
        if (connection.purpose_code == wire.MCP_CONNECTION_DISPOSABLE_PROBE)
            if (self.probe_exchange_status) |status| return status;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.MCP_EXCHANGE_FATAL;
        const id = requestId(encoded) orelse return wire.MCP_EXCHANGE_FATAL;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null) blk: {
            if (connection.era_code != wire.MCP_ERA_2026_07_28)
                return wire.MCP_EXCHANGE_FATAL;
            break :blk if (self.server_era_code == wire.MCP_ERA_2026_07_28) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}",
                .{id},
            );
        } else if (std.mem.indexOf(u8, encoded, "initialize") != null) blk: {
            if (connection.purpose_code != wire.MCP_CONNECTION_ACTUAL or
                connection.era_code == wire.MCP_ERA_2026_07_28)
                return wire.MCP_EXCHANGE_FATAL;
            break :blk std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{s},\"serverInfo\":{{\"name\":\"public-test\",\"version\":\"1\"}}}}}}",
                .{
                    id,
                    mcpVersion(self.server_era_code) orelse return wire.MCP_EXCHANGE_FATAL,
                    if (self.advertise_tools) "{\"tools\":{}}" else "{}",
                },
            );
        } else if (std.mem.indexOf(u8, encoded, "tools/list") != null) blk: {
            if (connection.purpose_code != wire.MCP_CONNECTION_ACTUAL or
                connection.era_code != self.server_era_code)
                return wire.MCP_EXCHANGE_FATAL;
            self.list_requests += 1;
            self.list_requests_by_era[
                eraIndex(connection.era_code) orelse
                    return wire.MCP_EXCHANGE_FATAL
            ] += 1;
            if (self.tool_count == 0 or self.tool_count > 2)
                return wire.MCP_EXCHANGE_FATAL;
            break :blk if (self.required_task) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"tasked\",\"inputSchema\":{{\"type\":\"object\"}},\"execution\":{{\"taskSupport\":\"required\"}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.server_era_code == wire.MCP_ERA_2026_07_28 and self.tool_count == 2) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}},{{\"name\":\"alerts\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.server_era_code == wire.MCP_ERA_2026_07_28) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else if (self.tool_count == 2) std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}},{{\"name\":\"alerts\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}",
                .{id},
            ) else std.fmt.allocPrint(
                std.heap.c_allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"],\"additionalProperties\":false}},\"outputSchema\":{{\"type\":\"object\",\"properties\":{{\"ok\":{{\"type\":\"boolean\"}}}},\"required\":[\"ok\"]}}}}]}}}}",
                .{id},
            );
        } else if (std.mem.indexOf(u8, encoded, "tools/call") != null) {
            self.call_requests += 1;
            return wire.MCP_EXCHANGE_FATAL;
        } else return wire.MCP_EXCHANGE_FATAL;
        const owned = response catch return wire.MCP_EXCHANGE_FATAL;
        self.requests += 1;
        out.* = .{ .ptr = owned.ptr, .len = owned.len };
        return wire.MCP_EXCHANGE_RESPONSE;
    }

    fn notify(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        notification_json: wire.BytesViewV1,
        _: u32,
        _: ?*const wire.McpCancellationV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.MCP_NOTIFY_FATAL));
        const connection = liveConnection(raw, connection_ctx) orelse
            return wire.MCP_NOTIFY_FATAL;
        if (connection.purpose_code != wire.MCP_CONNECTION_ACTUAL or
            connection.era_code == wire.MCP_ERA_2026_07_28)
            return wire.MCP_NOTIFY_FATAL;
        const encoded = sdk.borrowedBytes(notification_json) catch
            return wire.MCP_NOTIFY_FATAL;
        if (std.mem.indexOf(u8, encoded, "notifications/initialized") == null)
            return wire.MCP_NOTIFY_FATAL;
        self.notifications += 1;
        self.notifications_by_era[
            eraIndex(connection.era_code) orelse
                return wire.MCP_NOTIFY_FATAL
        ] += 1;
        return wire.MCP_NOTIFY_OK;
    }

    fn close(raw: ?*anyopaque, connection_ctx: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse return));
        if (connection.owner != raw) return;
        if (connection.closed) {
            self.double_closes += 1;
            return;
        }
        connection.closed = true;
        self.closes += 1;
    }

    fn expectClosedExactlyOnce(self: *const @This()) !void {
        try std.testing.expectEqual(self.opens, self.closes);
        try std.testing.expectEqual(@as(u32, 0), self.double_closes);
        for (self.connections[0..self.connection_count]) |connection|
            try std.testing.expect(connection.closed);
    }

    fn releaseResponse(
        raw: ?*anyopaque,
        connection_ctx: ?*anyopaque,
        response: ?*wire.OwnedBytesV1,
    ) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        _ = liveConnection(raw, connection_ctx) orelse return;
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn liveConnection(raw: ?*anyopaque, connection_ctx: ?*anyopaque) ?*Connection {
        const connection: *Connection = @ptrCast(@alignCast(connection_ctx orelse return null));
        if (connection.owner != raw or connection.closed) return null;
        return connection;
    }

    fn eraIndex(era_code: u32) ?usize {
        if (era_code < wire.MCP_ERA_2026_07_28 or
            era_code > wire.MCP_ERA_2025_06_18)
            return null;
        return @intCast(era_code);
    }

    fn requestId(encoded: []const u8) ?u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return null) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch null;
    }

    fn mcpVersion(era_code: u32) ?[]const u8 {
        return switch (era_code) {
            wire.MCP_ERA_2026_07_28 => "2026-07-28",
            wire.MCP_ERA_2025_11_25 => "2025-11-25",
            wire.MCP_ERA_2025_06_18 => "2025-06-18",
            else => null,
        };
    }
};

const PublicCheckpointBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_offset: usize = 0,
    writes: u32 = 0,
    reads: u32 = 0,
    fail_write: bool = false,
    fail_read: bool = false,

    fn deinit(self: *@This()) void {
        self.bytes.deinit(std.heap.c_allocator);
    }

    fn resetRead(self: *@This()) void {
        self.read_offset = 0;
        self.reads = 0;
    }

    fn sink(self: *@This()) wire.CheckpointSinkV1 {
        var result = std.mem.zeroes(wire.CheckpointSinkV1);
        result.struct_size = @sizeOf(wire.CheckpointSinkV1);
        result.ctx = self;
        result.write = write;
        return result;
    }

    fn source(self: *@This()) wire.CheckpointSourceV1 {
        self.resetRead();
        var result = std.mem.zeroes(wire.CheckpointSourceV1);
        result.struct_size = @sizeOf(wire.CheckpointSourceV1);
        result.ctx = self;
        result.read = read;
        return result;
    }

    fn write(raw: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.CHECKPOINT_IO_FATAL));
        if (self.fail_write) return wire.CHECKPOINT_IO_FAILED;
        const part = sdk.borrowedBytes(chunk) catch return wire.CHECKPOINT_IO_FATAL;
        self.bytes.appendSlice(std.heap.c_allocator, part) catch return wire.CHECKPOINT_IO_FATAL;
        self.writes += 1;
        return wire.CHECKPOINT_IO_OK;
    }

    fn read(
        raw: ?*anyopaque,
        destination: ?[*]u8,
        capacity_raw: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.CHECKPOINT_IO_FATAL));
        const written = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        written.* = 0;
        if (self.fail_read) return wire.CHECKPOINT_IO_FAILED;
        const capacity = std.math.cast(usize, capacity_raw) orelse return wire.CHECKPOINT_IO_FATAL;
        if (self.read_offset == self.bytes.items.len) return wire.CHECKPOINT_IO_OK;
        if (capacity == 0) return wire.CHECKPOINT_IO_FATAL;
        const out = destination orelse return wire.CHECKPOINT_IO_FATAL;
        const count = @min(capacity, self.bytes.items.len - self.read_offset);
        @memcpy(out[0..count], self.bytes.items[self.read_offset..][0..count]);
        self.read_offset += count;
        self.reads += 1;
        written.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

test "L2 Revision 7 public MCP exact 2025-06 and AUTO reopen reach one canonical catalog" {
    const cases = [_]struct {
        policy: u32,
        probe_opens: u32,
        actual_11_opens: u32,
        actual_06_opens: u32,
        closes_before_destroy: u32,
    }{
        .{
            .policy = wire.MCP_NEGOTIATION_LEGACY_2025_06_ONLY,
            .probe_opens = 0,
            .actual_11_opens = 0,
            .actual_06_opens = 1,
            .closes_before_destroy = 0,
        },
        .{
            .policy = wire.MCP_NEGOTIATION_AUTO,
            .probe_opens = 1,
            .actual_11_opens = 1,
            .actual_06_opens = 1,
            .closes_before_destroy = 2,
        },
    };
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    for (cases, 0..) |case, index| {
        var probe = PublicMcpProbe{ .server_era_code = wire.MCP_ERA_2025_06_18 };
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = case.policy;
        server.server_binding_identity = [_]u8{@intCast(0x60 + index)} ** 32;
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView(if (index == 0) "exact06" else "auto06");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        const servers = [_]wire.McpServerV1{server};
        var config = std.mem.zeroes(wire.RuntimeConfigV1);
        config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        config.mcp_servers = &servers;
        config.mcp_server_count = servers.len;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeCreate()(&config, &runtime, &diagnostic),
        );
        defer api.bufferRelease()(&diagnostic);
        var generation: u64 = 0;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeRefreshMcp()(runtime, &generation, &diagnostic),
        );
        try std.testing.expectEqual(@as(u64, 1), generation);
        var description = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeDescribeMcp()(runtime, &description, &diagnostic),
        );
        const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
        const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.tools.len);
        try std.testing.expectEqualStrings(
            "2025-06-18",
            decoded.value.servers[0].negotiated_protocol,
        );
        api.bufferRelease()(&description);
        try std.testing.expectEqual(case.probe_opens, probe.probe_opens);
        try std.testing.expectEqual(case.actual_11_opens, probe.actual_2025_11_opens);
        try std.testing.expectEqual(case.actual_06_opens, probe.actual_2025_06_opens);
        try std.testing.expectEqual(
            @as(usize, @intCast(case.probe_opens + case.actual_11_opens + case.actual_06_opens)),
            probe.connection_count,
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            probe.notifications_by_era[wire.MCP_ERA_2025_11_25],
        );
        try std.testing.expectEqual(
            @as(u32, 1),
            probe.notifications_by_era[wire.MCP_ERA_2025_06_18],
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            probe.list_requests_by_era[wire.MCP_ERA_2025_11_25],
        );
        try std.testing.expectEqual(
            @as(u32, 1),
            probe.list_requests_by_era[wire.MCP_ERA_2025_06_18],
        );
        if (case.policy == wire.MCP_NEGOTIATION_AUTO) {
            try std.testing.expect(probe.connections[0].closed);
            try std.testing.expect(probe.connections[1].closed);
            try std.testing.expect(!probe.connections[2].closed);
            try std.testing.expectEqual(
                wire.MCP_CONNECTION_DISPOSABLE_PROBE,
                probe.connections[0].purpose_code,
            );
            try std.testing.expectEqual(
                wire.MCP_ERA_2025_11_25,
                probe.connections[1].era_code,
            );
            try std.testing.expectEqual(
                wire.MCP_ERA_2025_06_18,
                probe.connections[2].era_code,
            );
        }
        try std.testing.expectEqual(case.closes_before_destroy, probe.closes);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeDestroy()(runtime, &diagnostic),
        );
        runtime = null;
        try probe.expectClosedExactlyOnce();
    }
}

test "L2 Revision 7 public MCP Apply publishes complete sets and replaces changed instances" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var first_probe = PublicMcpProbe{};
    var rejected_probe = PublicMcpProbe{ .server_era_code = wire.MCP_ERA_2025_11_25 };
    var second_probe = PublicMcpProbe{};
    var server = std.mem.zeroes(wire.McpServerV1);
    server.struct_size = @sizeOf(wire.McpServerV1);
    server.transport_code = wire.MCP_TRANSPORT_STDIO;
    server.negotiation_policy_code = wire.MCP_NEGOTIATION_MODERN_ONLY;
    server.server_binding_identity = [_]u8{0xd1} ** 32;
    server.configuration_fingerprint = [_]u8{0xa1} ** 32;
    server.namespace = sdk.bytesView("live");
    server.client_name = sdk.bytesView("agentcore-r7-test");
    server.client_version = sdk.bytesView("7");
    server.timeout_ms = 1000;
    server.connector = first_probe.connector();
    var servers = [_]wire.McpServerV1{server};

    var configuration = std.mem.zeroes(wire.McpConfigurationV1);
    configuration.struct_size = @sizeOf(wire.McpConfigurationV1);
    configuration.desired_revision = 1;
    configuration.servers = &servers;
    configuration.server_count = servers.len;
    var report = std.mem.zeroes(wire.McpApplyReportV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(@as(u32, @sizeOf(wire.McpApplyReportV1)), report.struct_size);
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 1), report.desired_revision);
    try std.testing.expectEqual(@as(u64, 1), report.active_revision);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 1), first_probe.actual_opens);

    configuration.desired_revision = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 1), first_probe.actual_opens);

    servers[0].configuration_fingerprint = [_]u8{0xaf} ** 32;
    servers[0].connector = rejected_probe.connector();
    configuration.desired_revision = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_REJECTED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 3), report.desired_revision);
    try std.testing.expectEqual(@as(u64, 2), report.active_revision);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 0), first_probe.closes);
    try std.testing.expectEqual(@as(u32, 1), rejected_probe.actual_open_attempts);

    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeDescribeMcp()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();
    api.bufferRelease()(&description);
    try std.testing.expectEqual(@as(u64, 1), decoded.value.catalog_generation);
    try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
    try std.testing.expectEqualStrings("live", decoded.value.servers[0].namespace);

    // A rejected revision remains retryable. Reusing revision 3 with a healthy
    // connector must replace the last-known-good generation atomically.
    servers[0].configuration_fingerprint = [_]u8{0xa2} ** 32;
    servers[0].connector = second_probe.connector();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 2), report.catalog_generation);
    try std.testing.expectEqual(@as(u32, 1), second_probe.actual_opens);
    try first_probe.expectClosedExactlyOnce();

    configuration.desired_revision = 4;
    configuration.servers = null;
    configuration.server_count = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_APPLIED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 3), report.catalog_generation);
    try second_probe.expectClosedExactlyOnce();

    configuration.desired_revision = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
    );
    try std.testing.expectEqual(wire.MCP_APPLY_SUPERSEDED, report.disposition_code);
    try std.testing.expectEqual(@as(u64, 4), report.desired_revision);
    try std.testing.expectEqual(@as(u64, 4), report.active_revision);
    try std.testing.expectEqual(@as(u64, 3), report.catalog_generation);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
    try std.testing.expectEqual(first_probe.connector_retains, first_probe.connector_releases);
    try std.testing.expectEqual(rejected_probe.connector_retains, rejected_probe.connector_releases);
    try std.testing.expectEqual(second_probe.connector_retains, second_probe.connector_releases);
}

test "L2 Revision 7 public MCP Apply requires explicit instance identity and lifetime" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    const invalid_contracts = [_]enum { zero_fingerprint, retain, release }{
        .zero_fingerprint,
        .retain,
        .release,
    };
    for (invalid_contracts) |invalid| {
        var probe = PublicMcpProbe{};
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = wire.MCP_NEGOTIATION_MODERN_ONLY;
        server.server_binding_identity = [_]u8{0xd2} ** 32;
        server.configuration_fingerprint = [_]u8{0xb1} ** 32;
        server.namespace = sdk.bytesView("lifetime");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        switch (invalid) {
            .zero_fingerprint => server.configuration_fingerprint = [_]u8{0} ** 32,
            .retain => server.connector.retain_connector = null,
            .release => server.connector.release_connector = null,
        }
        var servers = [_]wire.McpServerV1{server};
        var configuration = std.mem.zeroes(wire.McpConfigurationV1);
        configuration.struct_size = @sizeOf(wire.McpConfigurationV1);
        configuration.desired_revision = 1;
        configuration.servers = &servers;
        configuration.server_count = servers.len;
        var report = std.mem.zeroes(wire.McpApplyReportV1);

        try std.testing.expectEqual(
            wire.STATUS_INVALID_ARGUMENT,
            api.runtimeApplyMcpConfiguration()(runtime, &configuration, &report, &diagnostic),
        );
        try std.testing.expectEqual(@as(u32, 0), probe.connector_retains);
        try std.testing.expectEqual(@as(u32, 0), probe.connector_releases);
        try std.testing.expectEqual(@as(u32, 0), probe.open_attempts);
        api.bufferRelease()(&diagnostic);
    }
}

test "L2 public MCP wire failures preserve downgrade and no-replay semantics" {
    const cases = [_]struct {
        transport: u32,
        probe_open_status: u32 = wire.MCP_OPEN_OK,
        probe_exchange_status: ?u32 = null,
        expected_servers: usize,
        expected_issue: ?[]const u8,
        expected_actual_attempts: u32,
        expected_request_attempts: u32,
        expected_tools: usize = 0,
        expected_protocol: ?[]const u8 = null,
    }{
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_open_status = wire.MCP_OPEN_TIMEOUT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 2,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_open_status = wire.MCP_OPEN_CHILD_EXIT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 2,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_open_status = wire.MCP_OPEN_NETWORK_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 0,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_open_status = wire.MCP_OPEN_AUTH_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 0,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_open_status = wire.MCP_OPEN_SERVER_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 0,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_TIMEOUT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 3,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_CHILD_EXIT,
            .expected_servers = 1,
            .expected_issue = null,
            .expected_actual_attempts = 1,
            .expected_request_attempts = 3,
            .expected_tools = 1,
            .expected_protocol = "2025-11-25",
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_exchange_status = wire.MCP_EXCHANGE_NETWORK_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_exchange_status = wire.MCP_EXCHANGE_AUTH_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STREAMABLE_HTTP,
            .probe_exchange_status = wire.MCP_EXCHANGE_SERVER_ERROR,
            .expected_servers = 0,
            .expected_issue = "downgrade_refused",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_CANCELLED,
            .expected_servers = 0,
            .expected_issue = "probe_failed",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
        .{
            .transport = wire.MCP_TRANSPORT_STDIO,
            .probe_exchange_status = wire.MCP_EXCHANGE_INDETERMINATE,
            .expected_servers = 0,
            .expected_issue = "probe_failed",
            .expected_actual_attempts = 0,
            .expected_request_attempts = 1,
        },
    };
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    for (cases, 0..) |case, index| {
        var probe = PublicMcpProbe{
            .server_era_code = wire.MCP_ERA_2025_11_25,
            .probe_open_status = case.probe_open_status,
            .probe_exchange_status = case.probe_exchange_status,
        };
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = case.transport;
        server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
        server.server_binding_identity = [_]u8{@intCast(0x79 + index)} ** 32;
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView("failure");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        const servers = [_]wire.McpServerV1{server};
        var config = std.mem.zeroes(wire.RuntimeConfigV1);
        config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        config.mcp_servers = &servers;
        config.mcp_server_count = servers.len;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&diagnostic);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeCreate()(&config, &runtime, &diagnostic),
        );
        var generation: u64 = 0;
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeRefreshMcp()(runtime, &generation, &diagnostic),
        );
        var description = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeDescribeMcp()(runtime, &description, &diagnostic),
        );
        const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
        const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(case.expected_servers, decoded.value.servers.len);
        try std.testing.expectEqual(case.expected_tools, decoded.value.tools.len);
        if (case.expected_protocol) |expected| try std.testing.expectEqualStrings(
            expected,
            decoded.value.servers[0].negotiated_protocol,
        );
        if (case.expected_issue) |expected| {
            try std.testing.expectEqual(@as(usize, 1), decoded.value.issues.len);
            try std.testing.expectEqualStrings(expected, decoded.value.issues[0].kind);
        } else {
            try std.testing.expectEqual(@as(usize, 0), decoded.value.issues.len);
        }
        api.bufferRelease()(&description);
        try std.testing.expectEqual(@as(u32, 1), probe.probe_open_attempts);
        try std.testing.expectEqual(case.expected_actual_attempts, probe.actual_open_attempts);
        try std.testing.expectEqual(case.expected_request_attempts, probe.request_attempts);
        try std.testing.expectEqual(
            wire.STATUS_OK,
            api.runtimeDestroy()(runtime, &diagnostic),
        );
        runtime = null;
        try probe.expectClosedExactlyOnce();
    }
}

test "L2 public MCP catalog preserves heterogeneous multi-server tool windows" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));

    var first_probe = PublicMcpProbe{ .tool_count = 2 };
    var second_probe = PublicMcpProbe{ .tool_count = 1 };
    const bindings = [_][32]u8{
        [_]u8{0x83} ** 32,
        [_]u8{0x84} ** 32,
    };
    const namespaces = [_][]const u8{ "single", "double" };
    var servers = [_]wire.McpServerV1{
        std.mem.zeroes(wire.McpServerV1),
        std.mem.zeroes(wire.McpServerV1),
    };
    const connectors = [_]wire.McpConnectorV1{
        first_probe.connector(),
        second_probe.connector(),
    };
    for (&servers, 0..) |*server, index| {
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
        server.server_binding_identity = bindings[index];
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView(namespaces[index]);
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = connectors[index];
    }
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.mcp_servers = &servers;
    config.mcp_server_count = servers.len;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&config, &runtime, &diagnostic),
    );
    var generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeRefreshMcp()(runtime, &generation, &diagnostic),
    );
    var description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeDescribeMcp()(runtime, &description, &diagnostic),
    );
    const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
    defer decoded.deinit();
    api.bufferRelease()(&description);

    try std.testing.expectEqual(@as(usize, 2), decoded.value.servers.len);
    try std.testing.expectEqual(@as(usize, 3), decoded.value.tools.len);
    const expected_counts = [_]u32{ 2, 1 };
    var next_tool_offset: u32 = 0;
    for (decoded.value.servers, expected_counts, 0..) |server, expected_count, index| {
        try std.testing.expectEqual(next_tool_offset, server.tool_offset);
        try std.testing.expectEqual(expected_count, server.tool_count);
        try std.testing.expectEqualStrings(namespaces[index], server.namespace);
        try std.testing.expectEqual(@as(usize, 64), server.server_binding_identity.len);
        const start: usize = @intCast(server.tool_offset);
        const end: usize = @intCast(server.tool_offset + server.tool_count);
        for (decoded.value.tools[start..end]) |tool| try std.testing.expectEqualSlices(
            u8,
            server.server_binding_identity,
            tool.server_binding_identity,
        );
        next_tool_offset += server.tool_count;
    }
    try std.testing.expectEqual(@as(u32, 3), next_tool_offset);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeDestroy()(runtime, &diagnostic),
    );
    runtime = null;
    try first_probe.expectClosedExactlyOnce();
    try second_probe.expectClosedExactlyOnce();
}

test "L2 Revision 7 MCP no-tools and required-task peers expose zero executable tools" {
    const cases = [_]struct {
        era: u32,
        policy: u32,
        advertise_tools: bool,
        required_task: bool,
        expected_list_requests: u32,
        expected_issues: usize,
        expected_protocol: []const u8,
    }{
        .{
            .era = wire.MCP_ERA_2025_11_25,
            .policy = wire.MCP_NEGOTIATION_LEGACY_ONLY,
            .advertise_tools = false,
            .required_task = false,
            .expected_list_requests = 0,
            .expected_issues = 0,
            .expected_protocol = "2025-11-25",
        },
        .{
            .era = wire.MCP_ERA_2026_07_28,
            .policy = wire.MCP_NEGOTIATION_AUTO,
            .advertise_tools = true,
            .required_task = true,
            .expected_list_requests = 1,
            .expected_issues = 1,
            .expected_protocol = "2026-07-28",
        },
    };
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    for (cases, 0..) |case, index| {
        var probe = PublicMcpProbe{
            .server_era_code = case.era,
            .advertise_tools = case.advertise_tools,
            .required_task = case.required_task,
        };
        var server = std.mem.zeroes(wire.McpServerV1);
        server.struct_size = @sizeOf(wire.McpServerV1);
        server.transport_code = wire.MCP_TRANSPORT_STDIO;
        server.negotiation_policy_code = case.policy;
        server.server_binding_identity = [_]u8{@intCast(0x70 + index)} ** 32;
        server.configuration_fingerprint = server.server_binding_identity;
        server.namespace = sdk.bytesView(if (index == 0) "notools" else "required");
        server.client_name = sdk.bytesView("agentcore-r7-test");
        server.client_version = sdk.bytesView("7");
        server.timeout_ms = 1000;
        server.connector = probe.connector();
        const servers = [_]wire.McpServerV1{server};
        var config = std.mem.zeroes(wire.RuntimeConfigV1);
        config.struct_size = @sizeOf(wire.RuntimeConfigV1);
        config.mcp_servers = &servers;
        config.mcp_server_count = servers.len;
        var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
        defer api.bufferRelease()(&diagnostic);
        var runtime: ?*wire.RuntimeHandle = null;
        try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&config, &runtime, &diagnostic));
        var generation: u64 = 0;
        try std.testing.expectEqual(wire.STATUS_OK, api.runtimeRefreshMcp()(runtime, &generation, &diagnostic));
        var description = std.mem.zeroes(wire.OwnedBytesV1);
        try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDescribeMcp()(runtime, &description, &diagnostic));
        const encoded = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
        const decoded = try sdk.decodeMcpCatalog(std.testing.allocator, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
        try std.testing.expectEqualStrings(
            case.expected_protocol,
            decoded.value.servers[0].negotiated_protocol,
        );
        try std.testing.expectEqual(@as(usize, 0), decoded.value.tools.len);
        try std.testing.expectEqual(case.expected_issues, decoded.value.issues.len);
        if (case.required_task) try std.testing.expectEqualStrings(
            "task_required_unsupported",
            decoded.value.issues[0].kind,
        );
        try std.testing.expectEqual(case.expected_list_requests, probe.list_requests);
        try std.testing.expectEqual(@as(u32, 0), probe.call_requests);
        api.bufferRelease()(&description);
        try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
        runtime = null;
        try probe.expectClosedExactlyOnce();
    }
}

const PublicPermissionProbe = struct {
    expected_session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 1,
    fatal_on_permission: bool = false,
    ui_calls: u32 = 0,
    ui_releases: u32 = 0,
    host_calls: u32 = 0,
    host_releases: u32 = 0,
    callback_provenance: u32 = 0,
    raw_arguments_leaked: bool = false,

    fn validRun(self: *@This(), run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        return run.session == self.expected_session and
            run.run_id == self.expected_run_id and
            run.session_id.len == 24;
    }

    fn event(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.validRun(run_ptr)) return wire.EVENT_FATAL;
        const encoded = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, encoded) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        const event_value = switch (parsed.value) {
            .known => |value| value,
            .unknown => return wire.EVENT_CONTINUE,
        };
        switch (event_value) {
            .permission_provenance => |provenance| {
                if (self.fatal_on_permission) return wire.EVENT_FATAL;
                if (std.mem.indexOf(u8, encoded, "hello") != null) {
                    self.raw_arguments_leaked = true;
                    return wire.EVENT_FATAL;
                }
                if (provenance.source == .callback) {
                    if (provenance.decision != .allow or
                        provenance.callback_outcome != .answered or
                        provenance.response != .allow_once or
                        provenance.request_id == null or
                        provenance.tool.namespace != .host or
                        !std.mem.eql(u8, provenance.tool.name, "HostEcho") or
                        provenance.used_session_rule)
                        return wire.EVENT_FATAL;
                    self.callback_provenance += 1;
                }
            },
            else => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        request_json: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.validRun(run_ptr)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const request = switch (parsed.value) {
            .permission => |value| value,
            else => return wire.UI_FATAL,
        };
        if (!std.mem.eql(u8, request.type, "permission") or
            request.run_id != 1 or
            request.policy_generation != 1 or
            request.tool.namespace != .host or
            !std.mem.eql(u8, request.tool.name, "HostEcho") or
            std.mem.indexOf(u8, request.arguments_json, "hello") == null or
            request.candidate != null)
            return wire.UI_FATAL;
        var permits_once = false;
        for (request.responses) |choice| {
            if (choice == .allow_once) permits_once = true;
            if (choice == .allow_session or choice == .deny_session)
                return wire.UI_FATAL;
        }
        if (!permits_once) return wire.UI_FATAL;
        const response = sdk.protocol.PermissionResponse{
            .permission = .allow_once,
            .request_id = request.request_id,
            .policy_generation = request.policy_generation,
        };
        const response_json = sdk.encodeUiResponse(
            std.heap.c_allocator,
            parsed.value,
            .{ .permission = response },
        ) catch return wire.UI_FATAL;
        const out = out_response orelse {
            std.heap.c_allocator.free(response_json);
            return wire.UI_FATAL;
        };
        out.* = .{ .ptr = response_json.ptr, .len = response_json.len };
        self.ui_calls += 1;
        return wire.UI_ANSWERED;
    }

    fn releaseUi(raw: ?*anyopaque, response: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        const out = response orelse return;
        if (out.ptr) |ptr| {
            const len = std.math.cast(usize, out.len) orelse return;
            std.heap.c_allocator.free(ptr[0..len]);
            self.ui_releases += 1;
        }
        out.* = .{ .ptr = null, .len = 0 };
    }

    fn host(
        raw: ?*anyopaque,
        run_ptr: ?*const wire.RunContextV1,
        arguments_json: wire.BytesViewV1,
        out_result: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        if (!self.validRun(run_ptr)) return wire.HOST_FATAL;
        const arguments = sdk.borrowedBytes(arguments_json) catch return wire.HOST_FATAL;
        if (std.mem.indexOf(u8, arguments, "hello") == null) return wire.HOST_FAILED;
        const result = "host-ok";
        (out_result orelse return wire.HOST_FATAL).* = .{
            .ptr = @constCast(result.ptr),
            .len = result.len,
        };
        self.host_calls += 1;
        return wire.HOST_OK;
    }

    fn releaseHost(raw: ?*anyopaque, result: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        if (result) |out| {
            if (out.ptr != null) self.host_releases += 1;
            out.* = .{ .ptr = null, .len = 0 };
        }
    }
};

fn publicCheckpointLimits() wire.CheckpointLimitsV1 {
    var limits = std.mem.zeroes(wire.CheckpointLimitsV1);
    limits.struct_size = @sizeOf(wire.CheckpointLimitsV1);
    limits.hard_bytes = 16 * 1024 * 1024;
    limits.max_section_bytes = 8 * 1024 * 1024;
    limits.max_string_bytes = 1024 * 1024;
    limits.max_messages = 1024;
    limits.max_blocks_per_message = 64;
    limits.chunk_bytes = 4096;
    return limits;
}

test "L2 SDK rejects API tables that violate rigid v1 discovery" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const actual: *const wire.ApiV1 = @ptrCast(@alignCast(raw_api));
    _ = try sdk.Api.validate(actual);

    var nonzero_reserved = actual.*;
    nonzero_reserved.reserved[0] = 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&nonzero_reserved));

    var wrong_revision = actual.*;
    wrong_revision.abi_revision = wire.ABI_REVISION - 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&wrong_revision));

    var nonzero_header_reserved = actual.*;
    nonzero_header_reserved.reserved0 = 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&nonzero_header_reserved));

    inline for (.{
        wire.CAP_RUNTIME,
        wire.CAP_BUILTIN_TOOLS,
        wire.CAP_HOST_SYNC_TOOLS,
        wire.CAP_HOST_UI,
        wire.CAP_CORE_EVENTS_JSON,
        wire.CAP_ABORT,
        wire.CAP_SKILL_CATALOG,
        wire.CAP_TYPED_RUN_INPUT,
        wire.CAP_SESSION_MODEL_MUTATION,
        wire.CAP_MANUAL_COMPACT,
        wire.CAP_SKILL_SELECTION,
        wire.CAP_HOST_PERMISSION_RULES,
    }) |capability| {
        var missing_capability = actual.*;
        missing_capability.capabilities &= ~capability;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&missing_capability));
    }

    var extra_capability = actual.*;
    extra_capability.capabilities |= @as(u64, 1) << 63;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&extra_capability));
}

test "L2 Revision 7 public mutations and compact use the exact hard-cut table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    const initial_allow = [_]wire.BytesViewV1{sdk.bytesView("Read(*)")};
    var initial_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    initial_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    initial_rules.allow = &initial_allow;
    initial_rules.allow_count = initial_allow.len;
    var selection = allSkillsEnabledSelection();
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_selection = &selection;
    host_config.permission_rules = &initial_rules;
    var config = sessionCreateConfig(&host_config, "old-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);

    host_config.skill_selection = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionSetModel()(session, sdk.bytesView(""), &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionSetModel()(session, sdk.bytesView("new-model"), &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.sessionUpdateSkills()(session, null, &selection, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionUpdateSkills()(session, null, null, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var empty_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    empty_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdatePermissionRules()(session, &empty_rules, &diagnostic),
    );
    const malformed_rule = [_]wire.BytesViewV1{sdk.bytesView("Bash(")};
    var malformed_rules = empty_rules;
    malformed_rules.allow = &malformed_rule;
    malformed_rules.allow_count = malformed_rule.len;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionUpdatePermissionRules()(session, &malformed_rules, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionCompact()(session, 0, &compact_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCompact()(session, 1, &compact_result, &diagnostic),
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(wire.CompactResultV1)),
        compact_result.struct_size,
    );
    try std.testing.expectEqual(wire.COMPACT_NO_CHANGE, compact_result.outcome_code);
    try std.testing.expectEqual(
        wire.STATUS_STALE_COMPACT,
        api.sessionCompact()(session, 1, &compact_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_TOO_LATE,
        api.sessionAbortCompact()(session, 1, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionAbortCompact()(session, 0, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionAbortCompact()(session, 2, &diagnostic),
    );
}

test "L2 Revision 7 public MCP checkpoint restore facade preserves Conversation under narrower current authority" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const provider_bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var provider = try harness.MockServer.startCassette(&provider_bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var mcp_probe = PublicMcpProbe{};
    var mcp_server = std.mem.zeroes(wire.McpServerV1);
    mcp_server.struct_size = @sizeOf(wire.McpServerV1);
    mcp_server.transport_code = wire.MCP_TRANSPORT_STDIO;
    mcp_server.negotiation_policy_code = wire.MCP_NEGOTIATION_AUTO;
    mcp_server.server_binding_identity = [_]u8{0x42} ** 32;
    mcp_server.configuration_fingerprint = mcp_server.server_binding_identity;
    mcp_server.namespace = sdk.bytesView("weather");
    mcp_server.client_name = sdk.bytesView("agentcore-component-test");
    mcp_server.client_version = sdk.bytesView("6");
    mcp_server.timeout_ms = 1000;
    mcp_server.connector = mcp_probe.connector();
    const mcp_servers = [_]wire.McpServerV1{mcp_server};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.mcp_servers = &mcp_servers;
    runtime_config.mcp_server_count = mcp_servers.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var session: ?*wire.SessionHandle = null;
    defer {
        if (session) |handle| {
            _ = api.sessionDestroy()(handle, &diagnostic);
            session = null;
            api.bufferRelease()(&diagnostic);
        }
        if (runtime) |handle| {
            _ = api.runtimeDestroy()(handle, &diagnostic);
            runtime = null;
            api.bufferRelease()(&diagnostic);
        }
    }
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );

    var mcp_description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_MCP_NOT_REFRESHED,
        api.runtimeDescribeMcp()(runtime, &mcp_description, &diagnostic),
    );
    try std.testing.expect(mcp_description.ptr == null and mcp_description.len == 0);
    api.bufferRelease()(&diagnostic);

    var catalog_generation: u64 = 0;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeRefreshMcp()(runtime, &catalog_generation, &diagnostic),
    );
    try std.testing.expectEqual(@as(u64, 1), catalog_generation);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeDescribeMcp()(runtime, &mcp_description, &diagnostic),
    );
    var catalog_binding: [64]u8 = undefined;
    var catalog_binding_len: usize = 0;
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = mcp_description.ptr,
            .len = mcp_description.len,
        });
        const decoded = try sdk.decodeMcpCatalog(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(u64, 1), decoded.value.catalog_generation);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.servers.len);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.tools.len);
        try std.testing.expectEqualStrings("2026-07-28", decoded.value.servers[0].negotiated_protocol);
        try std.testing.expectEqualStrings("private", decoded.value.servers[0].cache_scope);
        try std.testing.expect(decoded.value.servers[0].fresh);
        try std.testing.expect(decoded.value.servers[0].ttl_remaining_ms <= 1000);
        try std.testing.expectEqualStrings("weather", decoded.value.tools[0].canonical_name);
        try std.testing.expectEqualStrings(
            decoded.value.servers[0].server_binding_identity,
            decoded.value.tools[0].server_binding_identity,
        );
        catalog_binding_len = decoded.value.servers[0].server_binding_identity.len;
        try std.testing.expect(catalog_binding_len <= catalog_binding.len);
        @memcpy(
            catalog_binding[0..catalog_binding_len],
            decoded.value.servers[0].server_binding_identity,
        );
    }
    api.bufferRelease()(&mcp_description);

    var selector = std.mem.zeroes(wire.McpSelectorV1);
    selector.struct_size = @sizeOf(wire.McpSelectorV1);
    selector.server_binding_identity = [_]u8{0x42} ** 32;
    selector.tool_name = sdk.bytesView("weather");
    const selectors = [_]wire.McpSelectorV1{selector};
    var selected_mcp = std.mem.zeroes(wire.McpSelectionV1);
    selected_mcp.struct_size = @sizeOf(wire.McpSelectionV1);
    selected_mcp.selectors = &selectors;
    selected_mcp.selector_count = selectors.len;
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.mcp_selection = &selected_mcp;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );

    var session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined;
    var session_id_len: usize = 0;
    var session_description = std.mem.zeroes(wire.OwnedBytesV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionDescribe()(session, &session_description, &diagnostic),
    );
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = session_description.ptr,
            .len = session_description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.LogicalSessionOrigin.fresh, decoded.value.origin);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.mcp.tools.len);
        try std.testing.expectEqualStrings("weather", decoded.value.mcp.tools[0].canonical_name);
        session_id_len = decoded.value.session_id.len;
        @memcpy(session_id[0..session_id_len], decoded.value.session_id);
    }
    api.bufferRelease()(&session_description);

    var bad_selector = selector;
    bad_selector.tool_name = sdk.bytesView("missing");
    const bad_selectors = [_]wire.McpSelectorV1{bad_selector};
    var bad_selection = selected_mcp;
    bad_selection.selectors = &bad_selectors;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_MCP_SELECTION,
        api.sessionUpdateMcp()(session, &bad_selection, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var empty_selection = std.mem.zeroes(wire.McpSelectionV1);
    empty_selection.struct_size = @sizeOf(wire.McpSelectionV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdateMcp()(session, &empty_selection, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionDescribe()(session, &session_description, &diagnostic),
    );
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = session_description.ptr,
            .len = session_description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(@as(usize, 0), decoded.value.mcp.tools.len);
    }
    api.bufferRelease()(&session_description);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdateMcp()(session, &selected_mcp, &diagnostic),
    );

    var run_options = std.mem.zeroes(wire.RunOptionsV1);
    run_options.struct_size = @sizeOf(wire.RunOptionsV1);
    run_options.max_turns = 1;
    var run_result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            1,
            sdk.bytesView("remember this before restore"),
            &run_options,
            &run_result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, run_result.stop_reason_code);

    var checkpoint = PublicCheckpointBuffer{};
    defer checkpoint.deinit();
    var limits = publicCheckpointLimits();
    var sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &limits;
    export_config.sink = &sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    checkpoint.fail_write = true;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_IO,
        api.sessionExportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 0), checkpoint.bytes.items.len);
    api.bufferRelease()(&diagnostic);
    checkpoint.fail_write = false;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionExportCheckpoint()(session, &export_config, &export_result, &diagnostic),
    );
    try std.testing.expectEqual(@as(u64, 1), export_result.checkpoint_generation);
    try std.testing.expectEqual(@as(u64, checkpoint.bytes.items.len), export_result.total_bytes);
    try std.testing.expect(export_result.chunk_count != 0 and checkpoint.writes != 0);

    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;

    var restore_host = host;
    restore_host.mcp_selection = null;
    var source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &restore_host;
    restore_config.source = &source;
    restore_config.limits = &limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);

    const original_magic = checkpoint.bytes.items[0];
    checkpoint.bytes.items[0] = 'X';
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_CORRUPT,
        api.sessionRestore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    checkpoint.bytes.items[0] = original_magic;

    var schema_revision_bytes: [4]u8 = undefined;
    @memcpy(&schema_revision_bytes, checkpoint.bytes.items[16..20]);
    std.mem.writeInt(u32, checkpoint.bytes.items[16..20], 2, .little);
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_UNSUPPORTED,
        api.sessionRestore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    @memcpy(checkpoint.bytes.items[16..20], &schema_revision_bytes);

    var abi_revision_bytes: [4]u8 = undefined;
    @memcpy(&abi_revision_bytes, checkpoint.bytes.items[20..24]);
    std.mem.writeInt(u32, checkpoint.bytes.items[20..24], 6, .little);
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_INCOMPATIBLE,
        api.sessionRestore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    @memcpy(checkpoint.bytes.items[20..24], &abi_revision_bytes);

    var undersized_limits = limits;
    undersized_limits.hard_bytes = checkpoint.bytes.items.len - 1;
    restore_config.limits = &undersized_limits;
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionRestore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    api.bufferRelease()(&diagnostic);
    restore_config.limits = &limits;

    checkpoint.fail_read = true;
    try std.testing.expectEqual(
        wire.STATUS_CHECKPOINT_IO,
        api.sessionRestore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(session == null);
    try std.testing.expect(restore_report.ptr == null and restore_report.len == 0);
    api.bufferRelease()(&diagnostic);

    checkpoint.fail_read = false;
    source = checkpoint.source();
    restore_config.source = &source;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRestore()(
            runtime,
            &restore_config,
            &callbacks,
            &session,
            &restore_report,
            &diagnostic,
        ),
    );
    try std.testing.expect(checkpoint.reads != 0);
    var restored_policy_generation: u64 = 0;
    var restored_catalog_generation: u64 = 0;
    var restored_issue_id: [64]u8 = undefined;
    var restored_issue_id_len: usize = 0;
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = restore_report.ptr,
            .len = restore_report.len,
        });
        const decoded = try sdk.decodeRestoreReport(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.RestoreHealth.degraded, decoded.value.health);
        try std.testing.expectEqualStrings(session_id[0..session_id_len], decoded.value.session_id);
        try std.testing.expectEqual(
            export_result.checkpoint_generation,
            decoded.value.checkpoint_generation,
        );
        restored_policy_generation = decoded.value.policy_generation;
        restored_catalog_generation = decoded.value.catalog_generation;
        try std.testing.expectEqual(catalog_generation, restored_catalog_generation);
        try std.testing.expectEqual(@as(u32, 0), decoded.value.mcp.restored_bindings);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.mcp.invalidated_bindings);
        try std.testing.expect(decoded.value.issues.len != 0);
        const issue = decoded.value.issues[0];
        try std.testing.expectEqual(sdk.protocol.AuthoritySubsystem.mcp, issue.subsystem);
        try std.testing.expectEqualStrings(
            catalog_binding[0..catalog_binding_len],
            issue.server_binding_identity.?,
        );
        restored_issue_id_len = issue.issue_id.len;
        try std.testing.expect(restored_issue_id_len <= restored_issue_id.len);
        @memcpy(restored_issue_id[0..restored_issue_id_len], issue.issue_id);
    }
    api.bufferRelease()(&restore_report);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionDescribe()(session, &session_description, &diagnostic),
    );
    {
        const encoded = try sdk.borrowedBytes(.{
            .ptr = session_description.ptr,
            .len = session_description.len,
        });
        const decoded = try sdk.decodeSessionDescription(a, encoded);
        defer decoded.deinit();
        try std.testing.expectEqual(sdk.protocol.LogicalSessionOrigin.restored, decoded.value.origin);
        try std.testing.expectEqualStrings(session_id[0..session_id_len], decoded.value.session_id);
        try std.testing.expectEqual(@as(u64, 1), decoded.value.last_run_id);
        try std.testing.expectEqual(
            export_result.checkpoint_generation,
            decoded.value.checkpoint_generation,
        );
        try std.testing.expectEqual(restored_policy_generation, decoded.value.policy_generation);
        try std.testing.expectEqual(restored_catalog_generation, decoded.value.catalog_generation);
        try std.testing.expect(decoded.value.conversation.message_count != 0);
        try std.testing.expectEqual(@as(usize, 0), decoded.value.mcp.tools.len);
        try std.testing.expectEqual(@as(u32, 1), decoded.value.restore.invalidated_mcp_bindings);
        try std.testing.expectEqual(@as(usize, 1), decoded.value.restore.issues.len);
        try std.testing.expectEqualStrings(
            restored_issue_id[0..restored_issue_id_len],
            decoded.value.restore.issues[0].issue_id,
        );
        try std.testing.expectEqualStrings(
            catalog_binding[0..catalog_binding_len],
            decoded.value.restore.issues[0].server_binding_identity.?,
        );
    }
    api.bufferRelease()(&session_description);

    run_result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            2,
            sdk.bytesView("continue after restore"),
            &run_options,
            &run_result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, run_result.stop_reason_code);

    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
    try std.testing.expectEqual(@as(u32, 2), mcp_probe.opens);
    try std.testing.expectEqual(@as(u32, 1), mcp_probe.probe_opens);
    try std.testing.expectEqual(@as(u32, 1), mcp_probe.actual_opens);
    try mcp_probe.expectClosedExactlyOnce();
    try std.testing.expectEqual(mcp_probe.requests, mcp_probe.releases);
}

test "L2 Revision 7 public Permission callback and provenance bind the exact Host invocation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE, HOST_SSE };
    var provider = try harness.MockServer.startCassette(&bodies, 0);
    defer provider.stop();
    const base_url = try provider.urlOwned(a);
    defer a.free(base_url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var probe = PublicPermissionProbe{};
    var host_tool = std.mem.zeroes(wire.HostToolV1);
    host_tool.struct_size = @sizeOf(wire.HostToolV1);
    host_tool.ctx = &probe;
    host_tool.name = sdk.bytesView("HostEcho");
    host_tool.description = sdk.bytesView("Echo a value through the Host");
    host_tool.input_schema_json = sdk.bytesView(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
    );
    host_tool.execute = PublicPermissionProbe.host;
    host_tool.release_result = PublicPermissionProbe.releaseHost;
    const host_tools = [_]wire.HostToolV1{host_tool};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = &host_tools;
    runtime_config.host_tool_count = host_tools.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    const allowed_tools = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("test-key");
    host.base_url = sdk.bytesView(base_url);
    host.workspace_root = sdk.bytesView(root);
    host.workspace_home = sdk.bytesView(root);
    host.allowed_tools = &allowed_tools;
    host.allowed_tool_count = allowed_tools.len;
    var create_config = sessionCreateConfig(&host, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = PublicPermissionProbe.event;
    callbacks.on_ui_request = PublicPermissionProbe.ui;
    callbacks.release_response = PublicPermissionProbe.releaseUi;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &create_config, &callbacks, &session, &diagnostic),
    );
    probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            1,
            sdk.bytesView("invoke the Host echo"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.ui_releases);
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_releases);
    try std.testing.expectEqual(@as(u32, 1), probe.callback_provenance);
    try std.testing.expect(!probe.raw_arguments_leaked);

    // Permission provenance uses the same fatal-aware Run event lifecycle as
    // every other public event. A Host rejection aborts before dispatch and
    // cannot be converted into an ordinary model-visible deny.
    probe.expected_run_id = 2;
    probe.fatal_on_permission = true;
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.sessionRunText(
            session,
            2,
            sdk.bytesView("invoke the Host echo again"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), probe.host_calls);
    try std.testing.expectEqual(@as(u32, 1), probe.host_releases);
}

test "L2 Revision 7 imported permission rules control the next Run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ WRITE_SSE, FINAL_SSE, WRITE_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    const builtins = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    const deny_write = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var initial_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    initial_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    initial_rules.deny = &deny_write;
    initial_rules.deny_count = deny_write.len;
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_DEFAULT;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &builtins;
    host_config.allowed_tool_count = builtins.len;
    host_config.permission_rules = &initial_rules;
    var config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            1,
            sdk.bytesView("attempt denied write"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    const written_path = try std.fs.path.join(a, &.{ root, "blocked.txt" });
    defer a.free(written_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, written_path, .{}),
    );

    const allow_write = [_]wire.BytesViewV1{sdk.bytesView("Write")};
    var replacement_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    replacement_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    replacement_rules.allow = &allow_write;
    replacement_rules.allow_count = allow_write.len;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdatePermissionRules()(session, &replacement_rules, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            2,
            sdk.bytesView("attempt allowed write"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.Io.Dir.cwd().access(std.testing.io, written_path, .{});
}

test "L2 invalid Session configuration publishes no handle and diagnostics never leak credentials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Bash") };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;

    var excessive_runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    excessive_runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    excessive_runtime_config.builtin_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.runtimeCreate()(&excessive_runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = Probe.event;
    const read_only = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &read_only;
    host_config.allowed_tool_count = read_only.len;
    var config = sessionCreateConfig(&host_config, "test-model");

    var missing_event_callbacks = callbacks;
    missing_event_callbacks.on_event = null;
    try expectInvalidSessionConfig(api, runtime.?, &config, &missing_event_callbacks, &diagnostic);

    var metadata_byte: u8 = 'x';
    const valid_model = config.model;
    config.model = .{ .ptr = @ptrCast(&metadata_byte), .len = wire.MAX_METADATA_STRING_BYTES_V1 + 1 };
    var metadata_limited_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionCreate()(runtime, &config, &callbacks, &metadata_limited_session, &diagnostic),
    );
    try std.testing.expect(metadata_limited_session == null);
    api.bufferRelease()(&diagnostic);
    config.model = valid_model;

    host_config.workspace_root = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    host_config.workspace_root = sdk.bytesView(root);

    host_config.workspace_home = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    host_config.workspace_home = sdk.bytesView(root);

    const missing = [_]wire.BytesViewV1{sdk.bytesView("Grep")};
    host_config.allowed_tools = &missing;
    host_config.allowed_tool_count = missing.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const duplicate = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Read") };
    host_config.allowed_tools = &duplicate;
    host_config.allowed_tool_count = duplicate.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const disabled_shell = [_]wire.BytesViewV1{sdk.bytesView("Bash")};
    host_config.allowed_tools = &disabled_shell;
    host_config.allowed_tool_count = disabled_shell.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    host_config.allowed_tools = null;
    host_config.allowed_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
    var limited_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionCreate()(runtime, &config, &callbacks, &limited_session, &diagnostic),
    );
    try std.testing.expect(limited_session == null);
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 sandbox admission is eager while unrestricted skips the probe" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    const read_only = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &read_only;
    host_config.allowed_tool_count = read_only.len;
    var config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = Probe.event;

    host_config.shell_policy_code = wire.SHELL_UNRESTRICTED;
    var unrestricted: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &unrestricted, &diagnostic),
    );
    try std.testing.expect(unrestricted != null);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(unrestricted, &diagnostic));

    host_config.shell_policy_code = wire.SHELL_SANDBOXED;
    var sandboxed: ?*wire.SessionHandle = null;
    const status = api.sessionCreate()(runtime, &config, &callbacks, &sandboxed, &diagnostic);
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expectEqual(wire.STATUS_OK, status);
        try std.testing.expect(sandboxed != null);
        try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(sandboxed, &diagnostic));
    } else {
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, status);
        try std.testing.expect(sandboxed == null);
    }
}

test "L2 public events reconstruct continuation output and observable run usage" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ CONTINUATION_HEAD_SSE, CONTINUATION_TAIL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "test-model");

    var probe = ReconstructionProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = ReconstructionProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(session, 1, sdk.bytesView("continue fixture"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqualStrings("headtail", probe.answer[0..probe.answer_len]);
    try std.testing.expectEqual(@as(usize, 2), probe.stream_done_count);
    try std.testing.expectEqual(@as(u64, 11), probe.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), probe.usage.output_tokens);
}

test "L2 session_set_model preserves Conversation and changes the next Run request" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var config = sessionCreateConfig(&host_config, "old-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &session, &diagnostic),
    );
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };
    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            1,
            sdk.bytesView("first prompt"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionSetModel()(session, sdk.bytesView("new-model"), &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            2,
            sdk.bytesView("second prompt"),
            &options,
            &result,
            &diagnostic,
        ),
    );

    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const first = server.requestAt(0) orelse return error.NoRequestCaptured;
    const second = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"model\":\"old-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"model\":\"new-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "\"text\":\"done\"") != null);
}

test "L2 invalid model is a recoverable provider outcome through the public facade" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ API_ERROR_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "old-model");
    defer fixture.deinit();

    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionSetModel()(
            fixture.session,
            sdk.bytesView("invalid-model"),
            &fixture.diagnostic,
        ),
    );
    var result = try fixture.runText(1, "provider validates this model");
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);

    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionSetModel()(
            fixture.session,
            sdk.bytesView("recovered-model"),
            &fixture.diagnostic,
        ),
    );
    result = try fixture.runText(2, "continue after recovery");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const failed = server.requestAt(0) orelse return error.NoRequestCaptured;
    const recovered = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, failed.body(), "\"model\":\"invalid-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, recovered.body(), "\"model\":\"recovered-model\"") != null);
}

test "L2 unnamed Provider HTTP 529 crosses AgentCore ABI without killing the Host" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"provider overloaded\"}}",
        0,
        "HTTP/1.1 529 Site Overloaded",
    );
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "test-model");
    defer fixture.deinit();

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionRunText(
            fixture.session,
            1,
            sdk.bytesView("exercise unnamed provider status"),
            &options,
            &result,
            &fixture.diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_API_ERROR, result.stop_reason_code);

    const diagnostic = try sdk.borrowedBytes(.{
        .ptr = fixture.diagnostic.ptr,
        .len = fixture.diagnostic.len,
    });
    // Provider failures are Run outcomes, not facade failures, so the ABI
    // diagnostic is a valid empty buffer and the error is carried by stop_reason.
    try std.testing.expectEqual(@as(usize, 0), diagnostic.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(diagnostic));
    fixture.releaseDiagnostic();

    // The Host remains in control and can safely destroy the same Session.
    const session = fixture.session orelse return error.MissingSession;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionDestroy()(session, &fixture.diagnostic),
    );
    fixture.session = null;
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "L2 public compact commits a summary and reports COMPACT_COMPACTED" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "compact-model");
    defer fixture.deinit();
    try appendCompactablePublicHistory(&fixture);

    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionCompact()(
            fixture.session,
            1,
            &compact_result,
            &fixture.diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.COMPACT_COMPACTED, compact_result.outcome_code);
    try std.testing.expect(compact_result.after_context_tokens < compact_result.before_context_tokens);
    try std.testing.expect(compact_result.input_tokens > 0);
    try std.testing.expect(compact_result.output_tokens > 0);

    const result = try fixture.runText(7, "continue after compact");
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 8), server.requestCount());
    const summary_request = server.requestAt(6) orelse return error.NoRequestCaptured;
    const post_compact = server.requestAt(7) orelse return error.NoRequestCaptured;
    const old_context_needle = [_]u8{'A'} ** 128;
    try std.testing.expect(std.mem.indexOf(u8, summary_request.body(), &old_context_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, post_compact.body(), &old_context_needle) == null);
    try std.testing.expect(std.mem.indexOf(u8, post_compact.body(), "Another language model started") != null);
    try std.testing.expect(std.mem.indexOf(u8, post_compact.body(), "done") != null);
}

test "L2 public compact abort is concurrent bounded and leaves the facade reusable" {
    const CompactWorker = struct {
        api: sdk.Api,
        session: *wire.SessionHandle,
        status: u32 = std.math.maxInt(u32),
        result: wire.CompactResultV1 = std.mem.zeroes(wire.CompactResultV1),
        diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

        fn run(self: *@This()) void {
            self.status = self.api.sessionCompact()(
                self.session,
                2,
                &self.result,
                &self.diagnostic,
            );
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var fixture = try PublicSessionFixture.init(root, url, "compact-model");
    defer fixture.deinit();
    try appendCompactablePublicHistory(&fixture);

    server.gateNextResponse();
    var worker = CompactWorker{ .api = fixture.api, .session = fixture.session.? };
    const compact_thread = try std.Thread.spawn(.{}, CompactWorker.run, .{&worker});
    var joined = false;
    defer if (!joined) {
        server.releaseGatedResponse();
        compact_thread.join();
    };
    try server.waitUntilResponseGated();

    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        fixture.api.sessionSetModel()(
            fixture.session,
            sdk.bytesView("must-not-race-compact"),
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionAbortCompact()(
            fixture.session,
            2,
            &fixture.diagnostic,
        ),
    );
    server.releaseGatedResponse();
    compact_thread.join();
    joined = true;
    defer fixture.api.bufferRelease()(&worker.diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, worker.status);
    try std.testing.expectEqual(wire.COMPACT_ABORTED, worker.result.outcome_code);
    try std.testing.expectEqual(
        wire.STATUS_TOO_LATE,
        fixture.api.sessionAbortCompact()(
            fixture.session,
            2,
            &fixture.diagnostic,
        ),
    );
    fixture.releaseDiagnostic();
    try std.testing.expectEqual(
        wire.STATUS_OK,
        fixture.api.sessionSetModel()(
            fixture.session,
            sdk.bytesView("model-after-abort"),
            &fixture.diagnostic,
        ),
    );
}

test "L2 Revision 7 catalog and explicit selection bind before Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "review",
        "---\nname: Review \"quoted\"\ndescription: Public \\ typed invocation fixture\narguments: [target]\n---\nREVIEW_SKILL_SENTINEL $target",
    );
    try writeSkillFixture(
        a,
        root,
        "workctl",
        "---\nname: Workctl\ndescription: Second public typed invocation fixture\narguments: [target]\n---\nWORKCTL_SKILL_SENTINEL $target",
    );
    try writeSkillFixture(
        a,
        root,
        "broken",
        "---\nname: Broken\ncontext: surprise\n---\nBROKEN_SKILL_SENTINEL",
    );
    try writeSkillFixtureInSource(
        a,
        root,
        ".metacodes",
        "metacodes-only",
        "---\nname: Product Legacy\n---\nMUST_NOT_ENTER_AGENTCORE_CATALOG",
    );
    try writeSkillFixtureInSource(
        a,
        root,
        ".claude",
        "claude-only",
        "---\nname: Claude Legacy\n---\nMUST_NOT_ENTER_AGENTCORE_CATALOG",
    );

    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("epoch-1"),
        .reserved = [_]u64{0} ** 3,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skillCatalogRelease()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeQuerySkillCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{ .ptr = descriptor.ptr, .len = descriptor.len });
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "\"invocation_name\":\"review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "\"invocation_name\":\"workctl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "metacodes-only") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "claude-only") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "\"body\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, descriptor_bytes, "source_path") == null);
    var decoded = try sdk.decodeSkillCatalog(a, descriptor_bytes);
    defer decoded.deinit();
    try std.testing.expectEqual(sdk.SkillCatalogHealth.degraded, decoded.value.health);
    try std.testing.expectEqual(@as(usize, 1), decoded.value.issues.len);
    try std.testing.expectEqual(
        sdk.SkillCatalogIssueCode.invalid_definition,
        decoded.value.issues[0].code,
    );
    try std.testing.expectEqualStrings(
        "broken",
        decoded.value.issues[0].invocation_name.?,
    );
    var found_escaped_review = false;
    for (decoded.value.skills) |skill| {
        if (!std.mem.eql(u8, skill.invocation_name, "review")) continue;
        found_escaped_review = true;
        try std.testing.expectEqualStrings("Review \"quoted\"", skill.display_name);
        try std.testing.expectEqualStrings(
            "Public \\ typed invocation fixture",
            skill.description,
        );
    }
    try std.testing.expect(found_escaped_review);
    const ids = try extractCatalogIdentities(a, descriptor_bytes, "review");
    defer a.free(ids.revision);
    defer a.free(ids.skill_id);
    const workctl_ids = try extractCatalogIdentities(a, descriptor_bytes, "workctl");
    defer a.free(workctl_ids.revision);
    defer a.free(workctl_ids.skill_id);
    try std.testing.expectEqualStrings(ids.revision, workctl_ids.revision);
    try std.testing.expect(!std.mem.eql(u8, ids.skill_id, workctl_ids.skill_id));
    api.bufferRelease()(&descriptor);

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_catalog = catalog;
    var skill_selection = allSkillsEnabledSelection();
    host_config.skill_selection = &skill_selection;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var probe = ReconstructionProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = ReconstructionProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.skillCatalogRelease()(catalog, &diagnostic));
    catalog = null;
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeQuerySkillCatalog()(runtime, &query, &catalog, &descriptor, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdateSkills()(session, catalog, &skill_selection, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.skillCatalogRelease()(catalog, &diagnostic));
    catalog = null;
    api.bufferRelease()(&descriptor);

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    const encoded_arguments = try sdk.encodeSkillArguments(
        a,
        &.{"src/main.zig"},
    );
    defer a.free(encoded_arguments);
    const disabled_ids = [_]wire.BytesViewV1{sdk.bytesView(ids.skill_id)};
    var disabled_selection = allSkillsEnabledSelection();
    disabled_selection.exception_skill_ids = &disabled_ids;
    disabled_selection.exception_skill_id_count = disabled_ids.len;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdateSkills()(session, null, &disabled_selection, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_SKILL_POLICY_VIOLATION,
        api.sessionRunSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionUpdateSkills()(session, null, &skill_selection, &diagnostic),
    );
    var stale: [64]u8 = undefined;
    @memcpy(&stale, ids.revision);
    stale[0] = if (stale[0] == '0') '1' else '0';
    try std.testing.expectEqual(
        wire.STATUS_STALE_CATALOG,
        api.sessionRunSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(&stale),
            sdk.bytesView(""),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_SKILL_ARGUMENTS,
        api.sessionRunSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView("{}"),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    var noncanonical_empty: u8 = 0;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_SKILL_ARGUMENTS,
        api.sessionRunSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            .{ .ptr = @ptrCast(&noncanonical_empty), .len = 0 },
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    const missing_id = [_]u8{'f'} ** 64;
    try std.testing.expectEqual(
        wire.STATUS_SKILL_NOT_FOUND,
        api.sessionRunSkill(
            session,
            1,
            sdk.bytesView(&missing_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(""),
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunSkill(
            session,
            1,
            sdk.bytesView(ids.skill_id),
            sdk.bytesView(ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunSkill(
            session,
            2,
            sdk.bytesView(workctl_ids.skill_id),
            sdk.bytesView(workctl_ids.revision),
            sdk.bytesView(encoded_arguments),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const review_request = server.requestAt(0) orelse return error.NoRequestCaptured;
    const workctl_request = server.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(
        std.mem.indexOf(u8, review_request.body(), "REVIEW_SKILL_SENTINEL") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, review_request.body(), "WORKCTL_SKILL_SENTINEL") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, workctl_request.body(), "WORKCTL_SKILL_SENTINEL") != null,
    );
    try std.testing.expect(!server.captureOverflowed());
}

test "L2 AgentCore Skill forks cannot override the Session model" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    try writeSkillFixture(
        a,
        root,
        "blocked",
        "---\n" ++
            "name: Blocked\n" ++
            "description: Attempt a forbidden model override\n" ++
            "context: fork\n" ++
            "model: arbitrary-model-id\n" ++
            "---\n" ++
            "BLOCKED_CHILD_MODEL_SENTINEL",
    );

    const bodies = [_][]const u8{
        BLOCKED_MODEL_SKILL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("model-binding-epoch"),
        .reserved = [_]u64{0} ** 3,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skillCatalogRelease()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeQuerySkillCatalog()(
            runtime,
            &query,
            &catalog,
            &descriptor,
            &diagnostic,
        ),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    });
    const blocked = try extractCatalogIdentities(
        a,
        descriptor_bytes,
        "blocked",
    );
    defer a.free(blocked.revision);
    defer a.free(blocked.skill_id);

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.skill_catalog = catalog;
    var skill_selection = allSkillsEnabledSelection();
    host_config.skill_selection = &skill_selection;
    var session_config = sessionCreateConfig(&host_config, "session-locked-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(
            runtime,
            &session_config,
            &callbacks,
            &session,
            &diagnostic,
        ),
    );
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);

    const blocked_status = api.sessionRunSkill(
        session,
        1,
        sdk.bytesView(blocked.skill_id),
        sdk.bytesView(blocked.revision),
        sdk.bytesView(""),
        &options,
        &result,
        &diagnostic,
    );
    try std.testing.expectEqual(wire.STATUS_SKILL_UNAVAILABLE, blocked_status);
    const rejected_diagnostic = try sdk.borrowedBytes(.{
        .ptr = diagnostic.ptr,
        .len = diagnostic.len,
    });
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            rejected_diagnostic,
            "ModelOverrideUnavailable",
        ) != null,
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            1,
            sdk.bytesView("Invoke the blocked Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    for (0..server.requestCount()) |index| {
        const request = server.requestAt(index) orelse
            return error.NoRequestCaptured;
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                request.body(),
                "BLOCKED_CHILD_MODEL_SENTINEL",
            ) == null,
        );
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                request.body(),
                "arbitrary-model-id",
            ) == null,
        );
        try std.testing.expectEqualStrings(
            "\"session-locked-model\"",
            request.jsonField("model").?,
        );
    }
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            server.requestAt(1).?.body(),
            "ModelOverrideUnavailable",
        ) != null,
    );

    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            2,
            sdk.bytesView("Continue after the rejected Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try std.testing.expect(!server.captureOverflowed());
}

test "L2 bound catalog executes model Skill and preserves nested policy lineage" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const review_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "review" },
    );
    defer a.free(review_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, review_dir);
    const review_path = try std.fs.path.join(
        a,
        &.{ review_dir, "SKILL.md" },
    );
    defer a.free(review_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = review_path,
        .data = "---\n" ++
            "name: Review\n" ++
            "description: Review a target selected by the model\n" ++
            "arguments: [target]\n" ++
            "---\n" ++
            "Review $target using the bound snapshot.",
    });

    const hidden_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "private-deploy" },
    );
    defer a.free(hidden_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, hidden_dir);
    const hidden_path = try std.fs.path.join(
        a,
        &.{ hidden_dir, "SKILL.md" },
    );
    defer a.free(hidden_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = hidden_path,
        .data = "---\n" ++
            "name: Hidden Deploy\n" ++
            "description: hidden-deploy-secret\n" ++
            "disable-model-invocation: true\n" ++
            "---\n" ++
            "Never advertise this body.",
    });

    const root_skill_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "root-policy" },
    );
    defer a.free(root_skill_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root_skill_dir);
    const root_skill_path = try std.fs.path.join(
        a,
        &.{ root_skill_dir, "SKILL.md" },
    );
    defer a.free(root_skill_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = root_skill_path,
        .data = "---\n" ++
            "name: Root Policy\n" ++
            "description: Narrow the external invocation to Read\n" ++
            "allowed-tools: Read\n" ++
            "---\n" ++
            "Invoke the child Skill, then continue.",
    });

    const child_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "child" },
    );
    defer a.free(child_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child_dir);
    const child_path = try std.fs.path.join(
        a,
        &.{ child_dir, "SKILL.md" },
    );
    defer a.free(child_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = child_path,
        .data = "---\n" ++
            "name: Child\n" ++
            "description: Nested child with no additional grant\n" ++
            "---\n" ++
            "Child activation body.",
    });

    const fork_dir = try std.fs.path.join(
        a,
        &.{ root, ".agents", "skills", "forked" },
    );
    defer a.free(fork_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, fork_dir);
    const fork_path = try std.fs.path.join(
        a,
        &.{ fork_dir, "SKILL.md" },
    );
    defer a.free(fork_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = fork_path,
        .data = "---\n" ++
            "name: Forked\n" ++
            "description: Run a fresh child that may invoke another Skill\n" ++
            "context: fork\n" ++
            "---\n" ++
            "AGENTCORE_FORK_CHILD_SENTINEL Invoke the child Skill and return its result.",
    });

    const bodies = [_][]const u8{
        SKILL_SSE,
        FINAL_SSE,
        SKILL_THEN_GLOB_SSE,
        FINAL_SSE,
        CHILD_SKILL_SSE,
        WRITE_SSE,
        FINAL_SSE,
        HIDDEN_SKILL_SSE,
        FINAL_SSE,
        FORK_SKILL_SSE,
        CHILD_SKILL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse
        return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);

    const builtins = [_]wire.BytesViewV1{
        sdk.bytesView("Read"),
        sdk.bytesView("Write"),
        sdk.bytesView("Glob"),
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeCreate()(&runtime_config, &runtime, &diagnostic),
    );
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .workspace_epoch = sdk.bytesView("model-tool-epoch"),
        .reserved = [_]u64{0} ** 3,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skillCatalogRelease()(handle, &diagnostic);
    };
    var descriptor = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&descriptor);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.runtimeQuerySkillCatalog()(
            runtime,
            &query,
            &catalog,
            &descriptor,
            &diagnostic,
        ),
    );
    const descriptor_bytes = try sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    });
    const root_identity = try extractCatalogIdentities(
        a,
        descriptor_bytes,
        "root-policy",
    );
    defer a.free(root_identity.revision);
    defer a.free(root_identity.skill_id);

    const allowed = [_]wire.BytesViewV1{
        sdk.bytesView("Read"),
        sdk.bytesView("Write"),
        sdk.bytesView("Glob"),
    };
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    host_config.skill_catalog = catalog;
    var skill_selection = allSkillsEnabledSelection();
    host_config.skill_selection = &skill_selection;
    var session_config = sessionCreateConfig(&host_config, "test-model");

    var probe = Probe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = Probe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(
            runtime,
            &session_config,
            &callbacks,
            &session,
            &diagnostic,
        ),
    );
    probe.expected_session = session;
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 3;
    var result = std.mem.zeroes(wire.RunResultV1);
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            1,
            sdk.bytesView("Use the review Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result and probe.saw_run_state);
    try std.testing.expect(probe.run_state_sequence_valid);
    try std.testing.expect(probe.run_state_invariant_valid);
    try std.testing.expect(probe.run_state_saw_starting and
        probe.run_state_saw_executing_tools and
        probe.run_state_saw_completed and
        probe.run_state_terminal_empty);

    const body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, body, "\"name\":\"Skill\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, body, "# Skill: Review") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, body, "Review src/main.zig using the bound snapshot.") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, body, "hidden-deploy-secret") == null,
    );

    probe.expected_run_id = 2;
    options.max_turns = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            2,
            sdk.bytesView("Activate root-policy, then Glob in the same response."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    const serial_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    const serial_result = std.mem.indexOf(u8, serial_body, "tu_serial_glob") orelse
        return error.MissingSerializedToolResult;
    try std.testing.expect(
        std.mem.indexOfPos(
            u8,
            serial_body,
            serial_result,
            "outside the current execution policy",
        ) != null,
    );

    probe.expected_run_id = 3;
    options.max_turns = 5;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunSkill(
            session,
            3,
            sdk.bytesView(root_identity.skill_id),
            sdk.bytesView(root_identity.revision),
            sdk.bytesView(""),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    const nested_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, nested_body, "# Skill: Child") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, nested_body, "outside the current execution policy") != null,
    );
    const blocked_path = try std.fs.path.join(a, &.{ root, "blocked.txt" });
    defer a.free(blocked_path);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().access(std.testing.io, blocked_path, .{}),
    );

    probe.expected_run_id = 4;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            4,
            sdk.bytesView("Try the hidden Skill name."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    const hidden_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, hidden_body, "Never advertise this body.") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, hidden_body, "PolicyViolation") != null or
            std.mem.indexOf(u8, hidden_body, "policy_violation") != null,
    );

    probe.expected_run_id = 5;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            session,
            5,
            sdk.bytesView("Use the forked Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    const fork_body = (server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, fork_body, "# Skill: Forked (forked)") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, fork_body, "done") != null,
    );
    var found_fork_child = false;
    for (0..server.requestCount()) |index| {
        const request = server.requestAt(index) orelse continue;
        if (std.mem.indexOf(
            u8,
            request.body(),
            "AGENTCORE_FORK_CHILD_SENTINEL",
        ) == null) continue;
        found_fork_child = true;
        try std.testing.expectEqualStrings(
            "\"test-model\"",
            request.jsonField("model").?,
        );
    }
    try std.testing.expect(found_fork_child);
    try std.testing.expect(!server.captureOverflowed());

    const openai_bodies = [_][]const u8{
        OPENAI_SKILL_SSE,
        OPENAI_FINAL_SSE,
    };
    var openai_server = try harness.MockServer.startCassette(
        &openai_bodies,
        0,
    );
    defer openai_server.stop();
    const openai_url = try openai_server.urlOwned(a);
    defer a.free(openai_url);

    host_config.provider_kind_code = wire.PROVIDER_OPENAI;
    host_config.base_url = sdk.bytesView(openai_url);
    var openai_probe = Probe{};
    callbacks.ctx = &openai_probe;
    var openai_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(
            runtime,
            &session_config,
            &callbacks,
            &openai_session,
            &diagnostic,
        ),
    );
    openai_probe.expected_session = openai_session;
    defer if (openai_session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    options.max_turns = 3;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(
            openai_session,
            1,
            sdk.bytesView("Use review through the OpenAI interface."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    const openai_body = (openai_server.lastRequest() orelse
        return error.NoRequestCaptured).body();
    try std.testing.expect(
        std.mem.indexOf(u8, openai_body, "\"name\":\"Skill\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, openai_body, "# Skill: Review") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            openai_body,
            "Review README.md using the bound snapshot.",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, openai_body, "\"tool_call_id\":\"call_skill\"") != null,
    );

    const fatal_bodies = [_][]const u8{
        FORK_SKILL_SSE,
        FINAL_SSE,
    };
    var fatal_server = try harness.MockServer.startCassette(
        &fatal_bodies,
        0,
    );
    defer fatal_server.stop();
    const fatal_url = try fatal_server.urlOwned(a);
    defer a.free(fatal_url);

    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.base_url = sdk.bytesView(fatal_url);
    var fatal_probe = NestedSkillFatalProbe{};
    var fatal_callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    fatal_callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    fatal_callbacks.ctx = &fatal_probe;
    fatal_callbacks.on_event = NestedSkillFatalProbe.event;
    var fatal_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(
            runtime,
            &session_config,
            &fatal_callbacks,
            &fatal_session,
            &diagnostic,
        ),
    );
    defer if (fatal_session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.sessionRunText(
            fatal_session,
            1,
            sdk.bytesView("Run the forked Skill."),
            &options,
            &result,
            &diagnostic,
        ),
    );
    try std.testing.expect(fatal_probe.failed);
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.sessionRunText(
            fatal_session,
            2,
            sdk.bytesView("A callback-failed Session stays poisoned."),
            &options,
            &result,
            &diagnostic,
        ),
    );
}

test "L2 opaque ABI routes Host callbacks and enforces Run admission identifiers" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, HOST_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Host echo"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = Probe.host,
        .release_result = Probe.hostRelease,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = wire.RuntimeConfigV1{
        .struct_size = @sizeOf(wire.RuntimeConfigV1),
        .reserved0 = 0,
        .builtin_tools = &builtins,
        .builtin_tool_count = builtins.len,
        .host_tools = @ptrCast(&host),
        .host_tool_count = 1,
        .mcp_servers = null,
        .mcp_server_count = 0,
        .mcp_catalog_limits = null,
        .reserved = [_]u64{0} ** 4,
    };
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("HostEcho") };
    var host_config = wire.SessionHostConfigV1{
        .struct_size = @sizeOf(wire.SessionHostConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_FULL_ACCESS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("test-key"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .skill_catalog = null,
        .skill_selection = null,
        .permission_rules = null,
        .mcp_selection = null,
        .durable_budget = null,
        .reserved = [_]u64{0} ** 4,
    };
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = wire.SessionCallbacksV1{
        .struct_size = @sizeOf(wire.SessionCallbacksV1),
        .reserved0 = 0,
        .ctx = &probe,
        .on_event = Probe.event,
        .on_ui_request = Probe.ui,
        .release_response = Probe.uiRelease,
        .reserved = [_]u64{0} ** 4,
    };
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    probe.expected_session = session;
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(wire.STATUS_BUSY, api.runtimeDestroy()(runtime, &diagnostic));
    api.bufferRelease()(&diagnostic);

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 5, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.sessionAbort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionRunText(session, 0, sdk.bytesView("zero is not a Run identifier"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    var invalid_utf8: u8 = 0xff;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionRunText(
            session,
            1,
            .{ .ptr = @ptrCast(&invalid_utf8), .len = wire.MAX_PROMPT_BYTES_V1 + 1 },
            &options,
            &result,
            &diagnostic,
        ),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionRunText(session, 1, sdk.bytesView("exercise ABI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.ui_releases);
    try std.testing.expectEqual(@as(usize, 1), probe.host_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.host_releases);
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result and probe.saw_run_state);
    try std.testing.expect(probe.run_state_saw_waiting_ui);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "Yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "host-ok") != null);
    options.max_turns = wire.MAX_TURNS_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionRunText(session, 2, sdk.bytesView("must not start"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    options.max_turns = 5;
    probe.expected_run_id = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(session, 2, sdk.bytesView("run after pre-admission rejection"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRunText(session, 2, sdk.bytesView("accepted identifiers cannot be reused"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRunText(session, 1, sdk.bytesView("accepted identifiers cannot move backwards"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    probe.expected_run_id = 20;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(session, 20, sdk.bytesView("Run identifiers may skip"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const max_run_id = std.math.maxInt(u64);
    probe.expected_run_id = max_run_id;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(session, max_run_id, sdk.bytesView("consume the final Run identifier"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRunText(session, max_run_id, sdk.bytesView("UINT64_MAX cannot repeat"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRunText(session, 1, sdk.bytesView("UINT64_MAX cannot wrap to a low identifier"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var second_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &second_session, &diagnostic));
    defer if (second_session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };
    probe.expected_session = second_session;
    probe.expected_run_id = max_run_id;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(second_session, max_run_id, sdk.bytesView("Run identifiers are scoped to a Session"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(second_session, &diagnostic));
    second_session = null;

    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 facade gate covers the core-idle epilogue until sessionRun returns" {
    const Barrier = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        seen_run_id: std.atomic.Value(u64) = .init(0),

        fn hook(raw: *anyopaque, run_id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.seen_run_id.store(run_id, .release);
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        }

        fn wait(self: *@This()) !void {
            for (0..1_000_000) |_| {
                if (self.entered.load(.acquire)) return;
                std.Thread.yield() catch {};
            }
            return error.EpilogueHookTimeout;
        }
    };
    const RunWorker = struct {
        api: sdk.Api,
        session: *wire.SessionHandle,
        status: u32 = std.math.maxInt(u32),
        result: wire.RunResultV1 = undefined,
        diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

        fn run(self: *@This()) void {
            var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 1, .reserved = [_]u64{0} ** 4 };
            self.status = self.api.sessionRunText(self.session, 1, sdk.bytesView("pause in facade epilogue"), &options, &self.result, &self.diagnostic);
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.start(FINAL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var barrier = Barrier{};
    abi.setTestEpilogueHook(.{ .ctx = &barrier, .runFn = Barrier.hook });
    defer abi.setTestEpilogueHook(null);
    var worker = RunWorker{ .api = api, .session = session.? };
    const run_thread = try std.Thread.spawn(.{}, RunWorker.run, .{&worker});
    var joined = false;
    defer if (!joined) {
        barrier.release.store(true, .release);
        run_thread.join();
    };
    try barrier.wait();
    try std.testing.expectEqual(@as(u64, 1), barrier.seen_run_id.load(.acquire));

    var competing_result: wire.RunResultV1 = undefined;
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 1, .reserved = [_]u64{0} ** 4 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionRunText(session, 2, sdk.bytesView("must not enter during epilogue"), &options, &competing_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_BUSY, api.sessionDestroy()(session, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionSetModel()(session, sdk.bytesView(""), &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionUpdateSkills()(session, null, null, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionUpdatePermissionRules()(session, null, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionCompact()(session, 0, &compact_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);

    barrier.release.store(true, .release);
    run_thread.join();
    joined = true;
    defer api.bufferRelease()(&worker.diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, worker.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, worker.result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "Host registry first identity binding is atomic under concurrent callbacks" {
    const Worker = struct {
        registry: *HostIdentityRegistry,
        session: *wire.SessionHandle,
        session_id: []const u8,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        accepted: bool = false,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            self.accepted = self.registry.accept(self.session, self.session_id);
        }
    };
    const Race = struct {
        fn run(first_id: []const u8, second_id: []const u8) ![2]bool {
            var session_storage: u8 = 0;
            const session: *wire.SessionHandle = @ptrCast(&session_storage);
            var registry = HostIdentityRegistry{};
            var ready = std.atomic.Value(u32).init(0);
            var start = std.atomic.Value(bool).init(false);
            var first = Worker{ .registry = &registry, .session = session, .session_id = first_id, .ready = &ready, .start = &start };
            var second = Worker{ .registry = &registry, .session = session, .session_id = second_id, .ready = &ready, .start = &start };
            const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
            errdefer {
                start.store(true, .release);
                first_thread.join();
            }
            const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
            while (ready.load(.acquire) != 2) std.Thread.yield() catch {};
            start.store(true, .release);
            first_thread.join();
            second_thread.join();
            return .{ first.accepted, second.accepted };
        }
    };

    const id_a = "000000000000000000000001";
    const id_b = "000000000000000000000002";
    for (0..64) |_| {
        const same = try Race.run(id_a, id_a);
        try std.testing.expect(same[0] and same[1]);
        const competing = try Race.run(id_a, id_b);
        try std.testing.expect(competing[0] != competing[1]);
    }
}

test "L2 invalid UTF-8 Host tool result is released and does not poison Session" {
    const FailureProbe = struct {
        calls: usize = 0,
        releases: usize = 0,
        invalid_utf8: [1]u8 = .{0xff},

        fn host(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
            self.calls += 1;
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &self.invalid_utf8, .len = self.invalid_utf8.len };
            return wire.HOST_OK;
        }

        fn release(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            self.releases += 1;
            if (out) |value| value.* = .{ .ptr = null, .len = 0 };
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = FailureProbe{};
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Always fail"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = FailureProbe.host,
        .release_result = FailureProbe.release,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("failure-test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host_config, "failure-test-model");
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = acceptEvent;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 4, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionRunText(session, 1, sdk.bytesView("invoke failing host"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);

    try std.testing.expectEqual(wire.STATUS_OK, api.sessionRunText(session, 2, sdk.bytesView("run again"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Event callback fatal aborts the Run and poisons the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("event-fatal-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "event-fatal-model");
    var probe = FatalEventProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = FatalEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.sessionRunText(session, 1, sdk.bytesView("fail event delivery"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.sessionAbort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.sessionRunText(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Event callback may cooperatively abort without poisoning the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("event-abort-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    var session_config = sessionCreateConfig(&host_config, "event-abort-model");
    var probe = AbortEventProbe{ .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = AbortEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(session, 1, sdk.bytesView("abort from callback"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, probe.stale_abort_status);
    try std.testing.expectEqual(wire.STATUS_OK, probe.abort_status);
    try std.testing.expectEqual(wire.STOP_ABORTED, result.stop_reason_code);

    probe.calls = 1;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRunText(session, 2, sdk.bytesView("run after abort"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

fn expectUiOutcome(mode: UiFailureMode, expected_releases: usize, expected_status: u32, expected_stop: u32) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var host_config = std.mem.zeroes(wire.SessionHostConfigV1);
    host_config.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host_config.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host_config.shell_policy_code = wire.SHELL_DISABLED;
    host_config.api_key = sdk.bytesView("test-key");
    host_config.base_url = sdk.bytesView(url);
    host_config.workspace_root = sdk.bytesView(root);
    host_config.workspace_home = sdk.bytesView(root);
    host_config.allowed_tools = &allowed;
    host_config.allowed_tool_count = allowed.len;
    var session_config = sessionCreateConfig(&host_config, "test-model");
    var probe = UiFailureProbe{ .mode = mode, .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = acceptEvent;
    callbacks.on_ui_request = UiFailureProbe.ui;
    callbacks.release_response = UiFailureProbe.release;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(expected_status, api.sessionRunText(session, 1, sdk.bytesView("ask through Host UI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(expected_releases, probe.releases);
    api.bufferRelease()(&diagnostic);
    if (expected_status == wire.STATUS_CALLBACK_FAILED) {
        try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.sessionRunText(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic));
        api.bufferRelease()(&diagnostic);
    } else {
        try std.testing.expectEqual(expected_stop, result.stop_reason_code);
        if (mode == .abort_twice) {
            try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_run_status);
            try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_destroy_status);
            try std.testing.expectEqual(wire.STATUS_OK, probe.first_abort_status);
            try std.testing.expectEqual(wire.STATUS_OK, probe.second_abort_status);
        }
        try std.testing.expectEqual(wire.STATUS_OK, api.sessionRunText(session, 2, sdk.bytesView("Session remains reusable"), &options, &result, &diagnostic));
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Host UI fatal aborts the Run and poisons the ABI Session" {
    try expectUiOutcome(.fatal, 0, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 oversized Host UI response is released and poisons the ABI Session" {
    try expectUiOutcome(.oversized, 1, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 unknown Host UI status poisons the ABI Session" {
    try expectUiOutcome(.unknown, 0, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 unavailable Host UI is a reusable business outcome" {
    try expectUiOutcome(.unavailable, 0, wire.STATUS_OK, wire.STOP_END_TURN);
}

test "L2 cancelled AskQuestion releases Host bytes and leaves the Session reusable" {
    try expectUiOutcome(.cancelled_with_buffer, 1, wire.STATUS_OK, wire.STOP_END_TURN);
}

test "L2 Host UI callback may repeat abort while nested run and destroy stay busy" {
    try expectUiOutcome(.abort_twice, 0, wire.STATUS_OK, wire.STOP_ABORTED);
}

fn expectMappedEventEquals(event: core.protocol.ui_event.CoreEvent, expected: sdk.CoreEvent) !void {
    const mapped = abi.protocol_v1.event(event) orelse return error.UnexpectedInternalOnlyEvent;
    try std.testing.expectEqualDeep(expected, mapped);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, mapped, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try sdk.decodeCoreEvent(std.testing.allocator, encoded);
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |actual| try std.testing.expectEqualDeep(expected, actual),
        .unknown => return error.UnexpectedUnknownEvent,
    }
}

test "L2 every public AgentCoreEventV1 mapping preserves its complete payload" {
    try expectMappedEventEquals(.{ .text_chunk = "text-sentinel" }, .{ .text_chunk = "text-sentinel" });
    try expectMappedEventEquals(
        .{ .tool_start = .{ .id = "tool-id", .name = "ToolName", .input = "input-json" } },
        .{ .tool_start = .{ .id = "tool-id", .name = "ToolName", .input = "input-json" } },
    );
    try expectMappedEventEquals(
        .{ .tool_progress = .{ .id = "progress-id", .text = "progress-text" } },
        .{ .tool_progress = .{ .id = "progress-id", .text = "progress-text" } },
    );
    try expectMappedEventEquals(
        .{ .progress = .{ .turn = 11, .tool_name = "ProgressTool", .tool_input = "progress-input", .tool_calls = 22 } },
        .{ .progress = .{ .turn = 11, .tool_name = "ProgressTool", .tool_input = "progress-input", .tool_calls = 22 } },
    );
    try expectMappedEventEquals(
        .{ .tool_result = .{
            .id = "result-id",
            .name = "ResultTool",
            .input = "result-input",
            .content = "result-content",
            .is_error = true,
            .elapsed_ms = 33,
        } },
        .{ .tool_result = .{
            .id = "result-id",
            .name = "ResultTool",
            .input = "result-input",
            .content = "result-content",
            .is_error = true,
            .elapsed_ms = 33,
        } },
    );
    try expectMappedEventEquals(
        .{ .usage = .{
            .input_tokens = 101,
            .output_tokens = 202,
            .cache_read_input_tokens = 303,
            .cache_creation_input_tokens = 404,
        } },
        .{ .usage = .{
            .input_tokens = 101,
            .output_tokens = 202,
            .cache_read_input_tokens = 303,
            .cache_creation_input_tokens = 404,
        } },
    );
    try expectMappedEventEquals(
        .{ .context_warning = .{
            .current_tokens = 1001,
            .warning_threshold = 2002,
            .auto_compact_threshold = 3003,
            .blocking_limit = 4004,
            .level = "warning-level",
        } },
        .{ .context_warning = .{
            .current_tokens = 1001,
            .warning_threshold = 2002,
            .auto_compact_threshold = 3003,
            .blocking_limit = 4004,
            .level = "warning-level",
        } },
    );
    try expectMappedEventEquals(
        .{ .auto_compact = .{
            .dropped = 12,
            .kept = 23,
            .before_tokens = 3400,
            .after_tokens = 4500,
            .cause = "compact-cause",
        } },
        .{ .auto_compact = .{
            .dropped = 12,
            .kept = 23,
            .before_tokens = 3400,
            .after_tokens = 4500,
            .cause = "compact-cause",
        } },
    );
    try expectMappedEventEquals(
        .{ .retry_notice = .{ .attempt = 13, .max = 24, .delay_ms = 3500 } },
        .{ .retry_notice = .{ .attempt = 13, .max = 24, .delay_ms = 3500 } },
    );
    try expectMappedEventEquals(.stream_done, .stream_done);
}

fn expectMappedUiRequestEquals(request: *const core.protocol.ui_request.UiRequest, expected: sdk.UiRequest) !void {
    const encoded = try abi.protocol_v1.encodeUiRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(encoded);
    const parsed = try sdk.decodeUiRequest(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(expected, parsed.value);
}

test "L2 AskUserQuestion mapping is complete and canonical Permission bypasses presentation wire" {
    const options = [_]core.tool_context.AskOption{
        .{ .label = "Yes", .description = "Proceed", .preview = "preview" },
        .{ .label = "No", .description = "Stop" },
    };
    const questions = [_]core.tool_context.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &options,
    }};
    const ask = core.protocol.ui_request.UiRequest{ .ask_question = &questions };
    const permission = core.protocol.ui_request.UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const plan = core.protocol.ui_request.UiRequest{ .plan_approval = .{ .plan_md = "Do it", .kg_step_count = 2 } };
    const custom = core.protocol.ui_request.UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } };
    const public_options = [_]sdk.protocol.AskOption{
        .{ .label = "Yes", .description = "Proceed", .preview = "preview" },
        .{ .label = "No", .description = "Stop", .preview = "" },
    };
    const public_questions = [_]sdk.protocol.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &public_options,
    }};
    try expectMappedUiRequestEquals(&ask, .{ .ask_question = &public_questions });
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &permission),
    );
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &plan),
    );
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &custom),
    );
}
