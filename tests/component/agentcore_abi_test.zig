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

        var session_config = std.mem.zeroes(wire.SessionConfigV1);
        session_config.struct_size = @sizeOf(wire.SessionConfigV1);
        session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
        session_config.permission_mode_code = wire.PERMISSION_BYPASS;
        session_config.shell_policy_code = wire.SHELL_DISABLED;
        session_config.api_key = sdk.bytesView("test-key");
        session_config.model = sdk.bytesView(model);
        session_config.base_url = sdk.bytesView(base_url);
        session_config.workspace_root = sdk.bytesView(root);
        session_config.workspace_home = sdk.bytesView(root);
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
    const skill_dir = try std.fs.path.join(
        allocator,
        &.{ root, ".metacodes", "skills", invocation_name },
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
    config: *const wire.SessionConfigV1,
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
    const api_key = try sdk.borrowedBytes(config.api_key);
    if (api_key.len != 0) try std.testing.expect(std.mem.indexOf(u8, diagnostic_bytes, api_key) == null);
    api.bufferRelease()(diagnostic);
    try std.testing.expect(diagnostic.ptr == null and diagnostic.len == 0);
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

test "L2 Revision 5 public mutations and compact use the exact hard-cut table" {
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
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.shell_policy_code = wire.SHELL_DISABLED;
    config.api_key = sdk.bytesView("test-key");
    config.model = sdk.bytesView("old-model");
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.skill_selection = &selection;
    config.permission_rules = &initial_rules;
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

    config.skill_selection = null;
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

test "L2 Revision 5 imported permission rules control the next Run" {
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
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_DEFAULT;
    config.shell_policy_code = wire.SHELL_DISABLED;
    config.api_key = sdk.bytesView("test-key");
    config.model = sdk.bytesView("test-model");
    config.base_url = sdk.bytesView(url);
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.allowed_tools = &builtins;
    config.allowed_tool_count = builtins.len;
    config.permission_rules = &initial_rules;
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
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.shell_policy_code = wire.SHELL_DISABLED;
    config.api_key = sdk.bytesView("test-key");
    config.model = sdk.bytesView("test-model");
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.allowed_tools = &read_only;
    config.allowed_tool_count = read_only.len;

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

    config.workspace_root = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    config.workspace_root = sdk.bytesView(root);

    config.workspace_home = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    config.workspace_home = sdk.bytesView(root);

    const missing = [_]wire.BytesViewV1{sdk.bytesView("Grep")};
    config.allowed_tools = &missing;
    config.allowed_tool_count = missing.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const duplicate = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Read") };
    config.allowed_tools = &duplicate;
    config.allowed_tool_count = duplicate.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const disabled_shell = [_]wire.BytesViewV1{sdk.bytesView("Bash")};
    config.allowed_tools = &disabled_shell;
    config.allowed_tool_count = disabled_shell.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    config.allowed_tools = null;
    config.allowed_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
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
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.api_key = sdk.bytesView("test-key");
    config.model = sdk.bytesView("test-model");
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.allowed_tools = &read_only;
    config.allowed_tool_count = read_only.len;
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.on_event = Probe.event;

    config.shell_policy_code = wire.SHELL_UNRESTRICTED;
    var unrestricted: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionCreate()(runtime, &config, &callbacks, &unrestricted, &diagnostic),
    );
    try std.testing.expect(unrestricted != null);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(unrestricted, &diagnostic));

    config.shell_policy_code = wire.SHELL_SANDBOXED;
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

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);

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

    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.shell_policy_code = wire.SHELL_DISABLED;
    config.api_key = sdk.bytesView("test-key");
    config.model = sdk.bytesView("old-model");
    config.base_url = sdk.bytesView(url);
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
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

test "L2 Revision 5 catalog and explicit selection bind before Session" {
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

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.skill_catalog = catalog;
    var skill_selection = allSkillsEnabledSelection();
    session_config.skill_selection = &skill_selection;
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

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("session-locked-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.skill_catalog = catalog;
    var skill_selection = allSkillsEnabledSelection();
    session_config.skill_selection = &skill_selection;
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
        &.{ root, ".metacodes", "skills", "review" },
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
        &.{ root, ".metacodes", "skills", "private-deploy" },
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
        &.{ root, ".metacodes", "skills", "root-policy" },
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
        &.{ root, ".metacodes", "skills", "child" },
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
        &.{ root, ".metacodes", "skills", "forked" },
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
    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.allowed_tools = &allowed;
    session_config.allowed_tool_count = allowed.len;
    session_config.skill_catalog = catalog;
    var skill_selection = allSkillsEnabledSelection();
    session_config.skill_selection = &skill_selection;

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
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result);

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

    session_config.provider_kind_code = wire.PROVIDER_OPENAI;
    session_config.base_url = sdk.bytesView(openai_url);
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

    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.base_url = sdk.bytesView(fatal_url);
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
    var session_config = wire.SessionConfigV1{
        .struct_size = @sizeOf(wire.SessionConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_BYPASS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("test-key"),
        .model = sdk.bytesView("test-model"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .skill_catalog = null,
        .skill_selection = null,
        .permission_rules = null,
        .reserved = [_]u64{0} ** 4,
    };
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
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result);
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

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
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
    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("failure-test-key");
    session_config.model = sdk.bytesView("failure-test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.allowed_tools = &allowed;
    session_config.allowed_tool_count = allowed.len;
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

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("event-fatal-key");
    session_config.model = sdk.bytesView("event-fatal-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
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

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("event-abort-key");
    session_config.model = sdk.bytesView("event-abort-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
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
    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.allowed_tools = &allowed;
    session_config.allowed_tool_count = allowed.len;
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

test "L2 every UiRequestV1 mapping preserves its complete payload" {
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
    try expectMappedUiRequestEquals(&permission, .{ .permission = .{ .tool = "Bash", .args = "{}" } });
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &plan),
    );
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &custom),
    );
}
