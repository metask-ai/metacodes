const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const Server = @import("mock_server.zig").Server;

/// Revision 23: the goal the consumer sets before its checkpoint.
const CONSUMER_GOAL = "ship the source-free Zig consumer";

/// `goal->get`, decoded and validated; the caller frees `arena`.
fn readGoal(
    api: sdk.Api,
    arena: std.mem.Allocator,
    session: ?*wire.SessionHandle,
    diagnostic: *wire.OwnedBytesV1,
) !?sdk.protocol.Goal {
    var json = std.mem.zeroes(wire.OwnedBytesV1);
    try expectStatus(.ok, api.goal().get()(session, &json, diagnostic), diagnostic.*);
    defer api.bufferRelease()(&json);
    const encoded = try sdk.borrowedBytes(.{ .ptr = json.ptr, .len = json.len });
    return (try sdk.decodeGoalDocument(arena, encoded)).goal;
}

comptime {
    if (wire.ABI_REVISION != 26 or
        wire.MAX_CREDENTIAL_BYTES_V1 != 16 * 1024 or
        wire.MAX_SUBMITTED_INPUTS_V1 != 64 or
        wire.MAX_SUBMITTED_INPUT_BYTES_V1 != 16 * 1024 * 1024 or
        wire.PROMPT_OP_ADD != 1 or
        wire.PROMPT_OP_REPLACE != 2 or
        wire.PROMPT_OP_REMOVE != 3 or
        wire.MAX_PROMPT_PROFILE_SECTIONS_V1 != 64 or
        wire.MAX_CONTEXT_BLOCKS_V1 != 32 or
        @intFromEnum(wire.Status.skill_catalog_incomplete) != 27 or
        @intFromEnum(wire.Status.image_input_unsupported) != 28 or
        @intFromEnum(wire.Status.image_input_capability_unknown) != 29 or
        wire.CAPABILITY_SUPPORTED != 1 or
        wire.CAPABILITY_UNSUPPORTED != 2 or
        wire.MAX_MODEL_CAPABILITIES_V1 != 256 or
        wire.MAX_MODEL_CAPABILITY_MODEL_BYTES_V1 != 256 or
        wire.TIME_CONTEXT_SYSTEM != 0 or
        wire.TIME_CONTEXT_UTC_OFFSET != 1 or
        wire.TIME_CONTEXT_OFF != 2 or
        wire.MIN_UTC_OFFSET_MINUTES_V1 != -840 or
        wire.MAX_UTC_OFFSET_MINUTES_V1 != 840 or
        wire.RUN_INPUT_MULTIMODAL != 3 or
        wire.RUN_INPUT_PART_TEXT != 1 or
        wire.RUN_INPUT_PART_IMAGE != 2 or
        wire.MAX_RUN_INPUT_PARTS_V1 != 64 or
        wire.MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1 != 5_000_000 or
        wire.PROTOCOL_DEFAULT != 0 or
        wire.OPENAI_PROTOCOL_RESPONSES != 1 or
        wire.MCP_NEGOTIATION_AUTO != 1 or
        wire.MCP_NEGOTIATION_MODERN_ONLY != 2 or
        wire.MCP_NEGOTIATION_LEGACY_ONLY != 3 or
        wire.MCP_NEGOTIATION_LEGACY_2025_06_ONLY != 4 or
        wire.MCP_ERA_2026_07_28 != 1 or
        wire.MCP_ERA_2025_11_25 != 2 or
        wire.MCP_ERA_2025_06_18 != 3 or
        wire.MCP_APPLY_APPLIED != 1 or
        wire.MCP_APPLY_SUPERSEDED != 2 or
        wire.MCP_APPLY_REJECTED != 3 or
        @intFromEnum(wire.Status.goal_conflict) != 30 or
        wire.RUN_INPUT_GOAL_CONTINUATION != 4 or
        wire.GOAL_FIELD_OBJECTIVE != 1 or
        wire.GOAL_FIELD_TOKEN_BUDGET != 2 or
        wire.GOAL_FIELD_ACTION != 4 or
        wire.GOAL_ACTION_PAUSE != 1 or
        wire.GOAL_ACTION_ACTIVATE != 2 or
        wire.GOAL_ACTION_COMPLETE != 3 or
        wire.GOAL_ACTION_BLOCK != 4 or
        wire.MAX_GOAL_OBJECTIVE_CODEPOINTS_V1 != 4000 or
        wire.MAX_GOAL_OBJECTIVE_BYTES_V1 != 16_384 or
        wire.TEAM_ROLE_LEAD != 1 or
        wire.TEAM_ROLE_MEMBER != 2 or
        wire.MAX_TEAM_NAME_BYTES_V1 != 64 or
        wire.MAX_TEAM_MEMBER_BYTES_V1 != 64)
        @compileError("source-free Revision 23-26 codes must match the public contract");
    if (@hasDecl(wire, "SessionRefreshSkillCatalogFnV1") or
        @hasField(wire.ApiV1, "session_refresh_skill_catalog"))
        @compileError("revision 24 must not expose the removed catalog refresh entry");
    if (wire.MAX_SKILL_FILE_CONTENT_BYTES_V1 != 16 * 1024 * 1024 or
        wire.MAX_SKILL_CONTENT_BYTES_V1 != 32 * 1024 * 1024 or
        wire.MAX_SKILL_FILES_V1 != 1024 or
        wire.MAX_SKILL_ENTRIES_V1 != 4096 or
        wire.MAX_SKILL_DIRECTORY_DEPTH_V1 != 64 or
        wire.MAX_SKILL_RELATIVE_PATH_BYTES_V1 != 4096 or
        wire.MAX_SKILL_CATALOG_CONTENT_BYTES_V1 != 64 * 1024 * 1024 or
        wire.MAX_SKILL_CATALOG_FILES_V1 != 16384 or
        wire.MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1 != 65536 or
        wire.MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1 != 256 * 1024 * 1024)
        @compileError("source-free Skill catalog limits must match the public contract");
}

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const WRITE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m_write\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"write\",\"name\":\"Write\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"artifact-write.txt\\\",\\\"content\\\":\\\"artifact-write-ok\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_STREAM_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m_stream\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"stream\",\"name\":\"HostStream\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const READ_ARTIFACT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m_read_artifact\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"read_artifact\",\"name\":\"ReadArtifact\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"artifact_id\\\":\\\"sha256:9ca0f6d6ecaa02f28448fadfba21f7fada5244afdc3bc247ceaf96ce2d82f00c\\\",\\\"offset\\\":0,\\\"limit\\\":64}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m4\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"artifact done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const RESPONSES_FINAL_SSE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_consumer\",\"output_index\":0,\"delta\":\"source-free responses done\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_consumer\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null)
            std.Thread.yield() catch {};
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

/// Host input submitted to Run 1 from inside its AskUserQuestion callback.
const STEERING_INPUT_ID: u64 = 0x5eed;
const STEERING_TEXT = "Also mention the artifact steering note.";

const Probe = struct {
    identity_mutex: SpinMutex = .{},
    /// Set for the Run whose UI callback submits STEERING_TEXT (Revision 20).
    api: ?sdk.Api = null,
    submit_during_ui: bool = false,
    submitted_sequence: u32 = 0,
    saw_input_adopted: bool = false,
    /// Issue #408: the one `model_error` of the Run expected to fail on the model.
    model_errors: u32 = 0,
    model_error_matches: bool = false,
    session: ?*wire.SessionHandle = null,
    active_run_id: u64 = 0,
    bound_session_id_len: u8 = 0,
    bound_session_id: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined,
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    host_stream_calls: usize = 0,
    host_stream_writes: usize = 0,
    host_stream_max_chunk_bytes: usize = 0,
    saw_read_result: bool = false,
    saw_host_result: bool = false,
    saw_stream_envelope: bool = false,
    saw_artifact_recovery: bool = false,
    saw_file_change: bool = false,
    saw_final_text: bool = false,
    saw_final_output_segment: bool = false,
    /// A Run announced the manifest of the system prompt it sends.
    saw_prompt_manifest: bool = false,
    /// Revision 23: `goal_updated` events for the consumer's goal.
    goal_updates: u32 = 0,
    /// Revision 25: the armed HostEcho call rotates the provider credential
    /// from inside its own callback, after a candidate the library refuses.
    rotate_in_host: bool = false,
    rotate_refused_status: u32 = std.math.maxInt(u32),
    rotate_status: u32 = std.math.maxInt(u32),
    output_segment_open: bool = false,
    output_segment_index: u32 = 0,
    output_segment_turn: u32 = 0,
    output_segment_group: u32 = 0,
    output_segment_bytes: u64 = 0,

    fn registerSession(self: *Probe, session: *wire.SessionHandle) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.session != null) return error.SessionAlreadyRegistered;
        self.session = session;
    }

    fn unregisterSession(self: *Probe, session: *wire.SessionHandle) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.session != session or self.active_run_id != 0)
            return error.InvalidHostLifecycle;
        self.session = null;
    }

    fn beginRun(self: *Probe, run_id: u64) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.session == null or self.active_run_id != 0 or run_id == 0) return error.InvalidHostLifecycle;
        self.active_run_id = run_id;
    }

    fn endRun(self: *Probe, run_id: u64) !void {
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (self.active_run_id != run_id or self.output_segment_open)
            return error.InvalidHostLifecycle;
        self.active_run_id = 0;
    }

    fn acceptContext(self: *Probe, run_ptr: ?*const wire.RunContextV1) bool {
        const run = sdk.validateRunContext(run_ptr) catch return false;
        self.identity_mutex.lock();
        defer self.identity_mutex.unlock();
        if (run.session != self.session or run.run_id != self.active_run_id) return false;
        if (self.bound_session_id_len == 0) {
            self.bound_session_id_len = @intCast(run.session_id.len);
            @memcpy(self.bound_session_id[0..run.session_id.len], run.session_id);
            return true;
        }
        return self.bound_session_id_len == run.session_id.len and
            std.mem.eql(u8, self.bound_session_id[0..self.bound_session_id_len], run.session_id);
    }

    fn event(raw: ?*anyopaque, run: ?*const wire.RunContextV1, json_view: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        if (!self.acceptContext(run)) return wire.EVENT_FATAL;
        const json = sdk.borrowedBytes(json_view) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, json) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known_event| switch (known_event) {
                .output_segment_begin => |segment| {
                    if (self.output_segment_open) return wire.EVENT_FATAL;
                    self.output_segment_open = true;
                    self.output_segment_index = segment.index;
                    self.output_segment_turn = segment.turn;
                    self.output_segment_group = segment.group;
                    self.output_segment_bytes = 0;
                },
                .tool_result => |result| {
                    if (std.mem.eql(u8, result.name, "Read") and !result.is_error and
                        std.mem.indexOf(u8, result.content, "artifact-read-ok") != null)
                        self.saw_read_result = true;
                    if (std.mem.eql(u8, result.name, "HostEcho") and !result.is_error and
                        std.mem.eql(u8, result.content, "artifact-host-ok"))
                        self.saw_host_result = true;
                    if (std.mem.eql(u8, result.name, "HostStream") and !result.is_error and
                        std.mem.indexOf(u8, result.content, "metacodes.tool-result-projection.v1") != null and
                        std.mem.indexOf(u8, result.content, "ReadArtifact") != null)
                        self.saw_stream_envelope = true;
                    if (std.mem.eql(u8, result.name, "ReadArtifact") and !result.is_error and
                        std.mem.indexOf(u8, result.content, "aaaaaaaaaaaaaaaa") != null)
                        self.saw_artifact_recovery = true;
                },
                .file_changes => |batch| {
                    if (!std.mem.eql(u8, batch.id, "write") or
                        !std.mem.eql(u8, batch.name, "Write") or
                        batch.changes.len != 1 or batch.overflow or batch.lost)
                        return wire.EVENT_FATAL;
                    const change = batch.changes[0];
                    const path = switch (change.locator) {
                        .workspace_path => |value| value,
                        else => return wire.EVENT_FATAL,
                    };
                    if (!std.mem.eql(u8, path, "artifact-write.txt") or
                        change.from_locator != null or
                        change.kind != .created or change.status != .applied or
                        !std.mem.eql(u8, change.tool, "Write") or
                        !std.mem.eql(u8, change.tool_use_id, "write") or
                        change.agent_depth != 0 or change.before_bytes != 0 or
                        change.after_bytes != "artifact-write-ok".len or
                        !change.diff_complete or change.unified_diff == null or
                        std.mem.indexOf(u8, change.unified_diff.?, "+artifact-write-ok") == null)
                        return wire.EVENT_FATAL;
                    self.saw_file_change = true;
                },
                .text_chunk => |text| {
                    if (!self.output_segment_open) return wire.EVENT_FATAL;
                    self.output_segment_bytes = std.math.add(
                        u64,
                        self.output_segment_bytes,
                        @intCast(text.len),
                    ) catch return wire.EVENT_FATAL;
                    if (std.mem.eql(u8, text, "artifact done")) self.saw_final_text = true;
                },
                .output_segment_end => |segment| {
                    if (!self.output_segment_open or
                        segment.index != self.output_segment_index or
                        segment.turn != self.output_segment_turn or
                        segment.group != self.output_segment_group or
                        segment.bytes != self.output_segment_bytes)
                        return wire.EVENT_FATAL;
                    self.output_segment_open = false;
                    if (segment.disposition == .final and segment.bytes == "artifact done".len)
                        self.saw_final_output_segment = true;
                },
                .model_error => |detail| {
                    self.model_errors += 1;
                    self.model_error_matches = detail.run_id == 3 and detail.category == .unknown and
                        detail.retry == .unknown and detail.http_status == 200 and
                        std.mem.eql(u8, detail.code orelse "", "insufficient_balance") and
                        std.mem.eql(u8, detail.type orelse "", "billing_error") and
                        std.mem.eql(u8, detail.message, "Balance too low") and
                        std.mem.eql(u8, detail.request_id orelse "", "req-consumer-1");
                },
                .input_adopted => |adopted| {
                    // Submitted during the AskUserQuestion callback of turn 1,
                    // adopted at the boundary before turn 2's request.
                    if (adopted.input_id != STEERING_INPUT_ID or adopted.sequence != 1 or
                        adopted.turn != 2 or self.saw_input_adopted)
                        return wire.EVENT_FATAL;
                    self.saw_input_adopted = true;
                },
                .prompt_manifest => |manifest| {
                    var host_section = false;
                    for (manifest.sections) |section| {
                        if (std.mem.eql(u8, section.id, "host:artifact-consumer") and section.origin == .host)
                            host_section = true;
                    }
                    if (!host_section or manifest.sha256.len != 64) return wire.EVENT_FATAL;
                    self.saw_prompt_manifest = true;
                },
                .goal_updated => |goal| {
                    if (!std.mem.eql(u8, goal.objective, CONSUMER_GOAL) or goal.tokens_used == 0)
                        return wire.EVENT_FATAL;
                    self.goal_updates += 1;
                },
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, run: ?*const wire.RunContextV1, request: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        if (!self.acceptContext(run)) return wire.UI_FATAL;
        const encoded = sdk.borrowedBytes(request) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, encoded) catch return wire.UI_FATAL;
        defer parsed.deinit();
        const questions = switch (parsed.value) {
            .ask_question => |questions| questions,
            else => return wire.UI_FATAL,
        };
        if (questions.len != 1 or !std.mem.eql(u8, questions[0].question, "Continue?") or
            questions[0].options.len != 2 or !std.mem.eql(u8, questions[0].options[0].label, "Yes"))
            return wire.UI_FATAL;
        self.ui_calls += 1;
        if (self.submit_during_ui) {
            // Revision 20: more input while a UI request is pending. It is
            // queued, never taken as the answer, and adopted at the next turn
            // boundary; this callback still answers the question itself.
            const api = self.api orelse return wire.UI_FATAL;
            const run_id = (sdk.validateRunContext(run) catch return wire.UI_FATAL).run_id;
            var receipt = std.mem.zeroes(wire.InputReceiptV1);
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const status = api.session().submitInput(
                self.session,
                run_id,
                STEERING_INPUT_ID,
                sdk.bytesView(STEERING_TEXT),
                &receipt,
                &diagnostic,
            );
            api.bufferRelease()(&diagnostic);
            if (status != @intFromEnum(sdk.Status.ok) or receipt.struct_size != @sizeOf(wire.InputReceiptV1) or
                receipt.sequence != 1)
                return wire.UI_FATAL;
            // The same id is refused for the rest of this Run.
            const duplicate = api.session().submitInput(self.session, run_id, STEERING_INPUT_ID, sdk.bytesView("again"), &receipt, &diagnostic);
            api.bufferRelease()(&diagnostic);
            if (duplicate != @intFromEnum(sdk.Status.invalid_argument)) return wire.UI_FATAL;
            self.submitted_sequence = 1;
            self.submit_during_ui = false;
        }
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
            const len = std.math.cast(usize, value.len) orelse return;
            if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..len]);
            value.* = .{ .ptr = null, .len = 0 };
        }
    }

    fn host(raw: ?*anyopaque, run: ?*const wire.RunContextV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        if (!self.acceptContext(run)) return wire.HOST_FATAL;
        const Args = struct { text: []const u8 };
        const encoded = sdk.borrowedBytes(args) catch return wire.HOST_FAILED;
        const parsed = std.json.parseFromSlice(Args, std.heap.c_allocator, encoded, .{}) catch return wire.HOST_FAILED;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.text, "hello")) return wire.HOST_FAILED;
        if (self.rotate_in_host) {
            self.rotate_in_host = false;
            const api = self.api orelse return wire.HOST_FATAL;
            var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
            self.rotate_refused_status = api.session().updateCredential()(run.?.session, sdk.bytesView("zig\nrotated"), &diagnostic);
            api.bufferRelease()(&diagnostic);
            self.rotate_status = api.session().updateCredential()(run.?.session, sdk.bytesView("zig-rotated-key"), &diagnostic);
            api.bufferRelease()(&diagnostic);
        }
        self.host_calls += 1;
        const result = "artifact-host-ok";
        (out orelse return wire.HOST_FAILED).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn hostRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.host_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }

    fn hostStream(
        raw: ?*anyopaque,
        run: ?*const wire.RunContextV1,
        _: wire.BytesViewV1,
        sink_ptr: ?*const wire.HostResultSinkV1,
        out_media_code: ?*u32,
        out_detail: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FATAL));
        if (!self.acceptContext(run)) return wire.HOST_FATAL;
        const sink = sink_ptr orelse return wire.HOST_FATAL;
        if (sink.struct_size != @sizeOf(wire.HostResultSinkV1) or
            sink.write == null or sink.max_bytes != wire.MAX_HOST_STREAM_ARTIFACT_BYTES_V1)
            return wire.HOST_FATAL;
        (out_detail orelse return wire.HOST_FATAL).* = .{ .ptr = null, .len = 0 };
        self.host_stream_calls += 1;
        var chunk: [64 * 1024]u8 = undefined;
        @memset(&chunk, 'a');
        var remaining: usize = 17 * 1024 * 1024 + 19;
        while (remaining != 0) {
            const count = @min(remaining, chunk.len);
            if (sink.write.?(sink.ctx, sdk.bytesView(chunk[0..count])) != wire.HOST_SINK_OK)
                return wire.HOST_FAILED;
            self.host_stream_writes += 1;
            self.host_stream_max_chunk_bytes = @max(self.host_stream_max_chunk_bytes, count);
            remaining -= count;
        }
        (out_media_code orelse return wire.HOST_FATAL).* = wire.HOST_STREAM_MEDIA_TEXT_UTF8;
        return wire.HOST_OK;
    }

    fn hostStreamRelease(_: ?*anyopaque, detail: ?*wire.OwnedBytesV1) callconv(.c) void {
        if (detail) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const CheckpointBuffer = struct {
    bytes: std.ArrayList(u8) = .empty,
    read_offset: usize = 0,

    fn deinit(self: *@This()) void {
        self.bytes.deinit(std.heap.c_allocator);
    }

    fn sink(self: *@This()) wire.CheckpointSinkV1 {
        var result = std.mem.zeroes(wire.CheckpointSinkV1);
        result.struct_size = @sizeOf(wire.CheckpointSinkV1);
        result.ctx = self;
        result.write = write;
        return result;
    }

    fn source(self: *@This()) wire.CheckpointSourceV1 {
        self.read_offset = 0;
        var result = std.mem.zeroes(wire.CheckpointSourceV1);
        result.struct_size = @sizeOf(wire.CheckpointSourceV1);
        result.ctx = self;
        result.read = read;
        return result;
    }

    fn write(raw: ?*anyopaque, chunk: wire.BytesViewV1) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse
            return wire.CHECKPOINT_IO_FATAL));
        const part = sdk.borrowedBytes(chunk) catch
            return wire.CHECKPOINT_IO_FATAL;
        self.bytes.appendSlice(std.heap.c_allocator, part) catch
            return wire.CHECKPOINT_IO_FATAL;
        return wire.CHECKPOINT_IO_OK;
    }

    fn read(
        raw: ?*anyopaque,
        destination: ?[*]u8,
        capacity_raw: u64,
        out_len: ?*u64,
    ) callconv(.c) u32 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse
            return wire.CHECKPOINT_IO_FATAL));
        const written = out_len orelse return wire.CHECKPOINT_IO_FATAL;
        written.* = 0;
        if (self.read_offset == self.bytes.items.len)
            return wire.CHECKPOINT_IO_OK;
        const capacity = std.math.cast(usize, capacity_raw) orelse
            return wire.CHECKPOINT_IO_FATAL;
        if (capacity == 0) return wire.CHECKPOINT_IO_FATAL;
        const output = destination orelse return wire.CHECKPOINT_IO_FATAL;
        const count = @min(capacity, self.bytes.items.len - self.read_offset);
        @memcpy(output[0..count], self.bytes.items[self.read_offset..][0..count]);
        self.read_offset += count;
        written.* = count;
        return wire.CHECKPOINT_IO_OK;
    }
};

fn checkpointLimits() wire.CheckpointLimitsV1 {
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

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const api = try sdk.Api.discover();
    if (api.raw.abi_revision != wire.ABI_REVISION) return error.UnexpectedRevision;
    if (sdk.metask_agentcore_get_api(2) != null) return error.UnexpectedAbi;
    try verifyRevisionMismatchRejection(api);

    const process_root = try std.process.currentPathAlloc(init.io, a);
    var name_buf: [128]u8 = undefined;
    const workspace_name = try std.fmt.bufPrint(&name_buf, ".agentcore-consumer-{d}", .{std.Thread.getCurrentId()});
    const workspace = try std.fs.path.join(a, &.{ process_root, workspace_name });
    try std.Io.Dir.cwd().createDirPath(init.io, workspace);
    defer std.Io.Dir.cwd().deleteTree(init.io, workspace) catch {};
    const file_name = "artifact-read.txt";
    const file_path = try std.fs.path.join(a, &.{ workspace, file_name });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = file_path, .data = "artifact-read-ok" });
    const skill_dir = try std.fs.path.join(a, &.{ workspace, ".agents", "skills", "review" });
    try std.Io.Dir.cwd().createDirPath(init.io, skill_dir);
    const skill_path = try std.fs.path.join(a, &.{ skill_dir, "SKILL.md" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = skill_path,
        .data = "---\nname: Review\ndescription: Source-free typed invocation fixture\narguments: [target]\n---\nREVIEW_SKILL_SENTINEL $target",
    });
    const workctl_dir = try std.fs.path.join(a, &.{ workspace, ".agents", "skills", "workctl" });
    try std.Io.Dir.cwd().createDirPath(init.io, workctl_dir);
    const workctl_path = try std.fs.path.join(a, &.{ workctl_dir, "SKILL.md" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = workctl_path,
        .data = "---\nname: Workctl\ndescription: Second source-free typed invocation fixture\narguments: [target]\n---\nWORKCTL_SKILL_SENTINEL $target",
    });
    const oversized_dir = try std.fs.path.join(a, &.{ workspace, ".agents", "skills", "oversized" });
    try std.Io.Dir.cwd().createDirPath(init.io, oversized_dir);
    const oversized_skill_path = try std.fs.path.join(a, &.{ oversized_dir, "SKILL.md" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = oversized_skill_path,
        .data = "---\nname: Oversized\n---\nOVERSIZED_SKILL_SENTINEL",
    });
    const oversized_asset = try a.alloc(
        u8,
        @as(usize, @intCast(wire.MAX_SKILL_FILE_CONTENT_BYTES_V1)) + 1,
    );
    @memset(oversized_asset, 'x');
    const oversized_asset_path = try std.fs.path.join(a, &.{ oversized_dir, "asset.bin" });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = oversized_asset_path,
        .data = oversized_asset,
    });
    // Source-free proof: the model supplies a relative file path and the
    // binary facade resolves it against workspace_root, not process cwd.
    const read_sse = try readToolSse(a, file_name);
    const bodies = [_][]const u8{
        ASK_SSE,
        read_sse,
        WRITE_SSE,
        HOST_SSE,
        HOST_STREAM_SSE,
        READ_ARTIFACT_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    const server = try Server.start(init.io, &bodies);
    defer server.stop();
    const url = try server.url(a);

    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read"), sdk.bytesView("Write") };
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
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    // Revision 24 (issue #277): admit the team tools so a team Session can run
    // them. The main Session below carries no team config, so it is unaffected.
    runtime_config.enable_teams = 1;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    var plugin_config = std.mem.zeroes(wire.RuntimePluginConfigV1);
    plugin_config.struct_size = @sizeOf(wire.RuntimePluginConfigV1);
    var host_stream = wire.HostStreamToolV1{
        .struct_size = @sizeOf(wire.HostStreamToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostStream"),
        .description = sdk.bytesView("Source-free Host byte-zero streaming fixture"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{},\"required\":[]}"),
        .execute_stream = Probe.hostStream,
        .release_detail = Probe.hostStreamRelease,
        .reserved = [_]u64{0} ** 2,
    };
    plugin_config.host_stream_tools = @ptrCast(&host_stream);
    plugin_config.host_stream_tool_count = 1;
    try expectStatus(.ok, api.runtime().create()(
        &runtime_config,
        &plugin_config,
        &runtime,
        &diagnostic,
    ), diagnostic);
    defer if (runtime) |handle| {
        _ = api.runtime().destroy()(handle, &diagnostic);
    };
    var mcp_configuration = std.mem.zeroes(wire.McpConfigurationV1);
    mcp_configuration.struct_size = @sizeOf(wire.McpConfigurationV1);
    mcp_configuration.desired_revision = 1;
    var mcp_report = std.mem.zeroes(wire.McpApplyReportV1);
    try expectStatus(.ok, api.mcp().applyConfiguration()(
        runtime,
        &mcp_configuration,
        &mcp_report,
        &diagnostic,
    ), diagnostic);
    if (mcp_report.struct_size != @sizeOf(wire.McpApplyReportV1) or
        mcp_report.disposition_code != wire.MCP_APPLY_APPLIED or
        mcp_report.desired_revision != 1 or mcp_report.active_revision != 1 or
        mcp_report.catalog_generation != 1)
        return error.InvalidMcpApplyReport;

    var query = wire.SkillCatalogQueryV1{
        .struct_size = @sizeOf(wire.SkillCatalogQueryV1),
        .reserved0 = 0,
        .workspace_root = sdk.bytesView(workspace),
        .workspace_home = sdk.bytesView(workspace),
        .workspace_epoch = sdk.bytesView("fixture-epoch"),
        .additional_sources = null,
        .additional_source_count = 0,
        .default_user_source_priority = 0,
        .default_workspace_source_priority = 0,
    };
    var catalog: ?*wire.SkillCatalogHandle = null;
    defer if (catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    var descriptor = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&descriptor);
    try expectStatus(.ok, api.skill().resolveCatalog()(
        runtime,
        &query,
        &catalog,
        &descriptor,
        &diagnostic,
    ), diagnostic);
    if (catalog == null or descriptor.ptr == null or descriptor.len == 0)
        return error.MissingSkillCatalog;
    const descriptor_bytes = try sdk.borrowedBytes(.{
        .ptr = descriptor.ptr,
        .len = descriptor.len,
    });
    const decoded_catalog = try sdk.decodeSkillCatalog(a, descriptor_bytes);
    defer decoded_catalog.deinit();
    if (decoded_catalog.value.health != .degraded or
        decoded_catalog.value.issues.len != 1 or
        decoded_catalog.value.issues[0].code != .invalid_resource or
        decoded_catalog.value.issues[0].reason != .file_too_large or
        !std.mem.eql(u8, decoded_catalog.value.issues[0].skill_policy_key orelse "", "oversized"))
        return error.InvalidCatalogIsolation;
    const identities = try catalogIdentities(a, descriptor_bytes, "review");
    const workctl_identities = try catalogIdentities(a, descriptor_bytes, "workctl");
    if (!std.mem.eql(u8, identities.revision, workctl_identities.revision) or
        std.mem.eql(u8, identities.skill_id, workctl_identities.skill_id))
        return error.InvalidCatalogDescriptor;
    api.bufferRelease()(&descriptor);

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read"), sdk.bytesView("Write"), sdk.bytesView("HostEcho"), sdk.bytesView("HostStream") };
    const granted_skill_ids = [_]wire.BytesViewV1{
        sdk.bytesView(identities.skill_id),
        sdk.bytesView(workctl_identities.skill_id),
    };
    var skill_policy = std.mem.zeroes(wire.SkillPolicyV1);
    skill_policy.struct_size = @sizeOf(wire.SkillPolicyV1);
    skill_policy.granted_skill_ids = &granted_skill_ids;
    skill_policy.granted_skill_id_count = granted_skill_ids.len;
    var initial_rules = std.mem.zeroes(wire.PermissionRuleSetV1);
    initial_rules.struct_size = @sizeOf(wire.PermissionRuleSetV1);
    var session_host = wire.SessionHostConfigV1{
        .struct_size = @sizeOf(wire.SessionHostConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_FULL_ACCESS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("artifact-key"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView(workspace),
        .workspace_home = sdk.bytesView(workspace),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .skill_catalog = catalog,
        .skill_policy = &skill_policy,
        .permission_rules = &initial_rules,
        .mcp_selection = null,
        .durable_budget = null,
        .run_journal_mode_code = wire.RUN_JOURNAL_DURABLE_WORKSPACE,
        .protocol_kind_code = wire.PROTOCOL_DEFAULT,
        .model_capabilities = null,
        .model_capability_count = 0,
        .team = null,
    };
    // A Host section the Session renders into every Run's system prompt and
    // carries through its checkpoint.
    const prompt_sections = [_]wire.PromptSectionV1{.{
        .struct_size = @sizeOf(wire.PromptSectionV1),
        .op_code = wire.PROMPT_OP_ADD,
        .id = sdk.bytesView("host:artifact-consumer"),
        .order = 500,
        .text = sdk.bytesView("Answer as the artifact consumer."),
        .interpolate = 0,
        .reserved0 = 0,
        .reserved = [_]u64{0} ** 2,
    }};
    const prompt_profile = wire.PromptProfileV1{
        .struct_size = @sizeOf(wire.PromptProfileV1),
        .reserved0 = 0,
        .sections = &prompt_sections,
        .section_count = prompt_sections.len,
        .reserved = [_]u64{0} ** 4,
    };
    var config = wire.SessionCreateConfigV1{
        .struct_size = @sizeOf(wire.SessionCreateConfigV1),
        .reserved0 = 0,
        .host = &session_host,
        .model = sdk.bytesView("artifact-model"),
        .prompt_profile = &prompt_profile,
        .reserved = [_]u64{0} ** 3,
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
    try expectStatus(.ok, api.session().create()(runtime, &config, &callbacks, &session, &diagnostic), diagnostic);
    try expectStatus(.ok, api.skill().releaseCatalog()(catalog, &diagnostic), diagnostic);
    catalog = null;
    try probe.registerSession(session.?);
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    try expectStatus(
        .ok,
        api.sessionControl().setModel()(session, sdk.bytesView("artifact-model-v2"), &diagnostic),
        diagnostic,
    );
    try expectStatus(
        .ok,
        api.skill().bindPolicy()(session, null, &skill_policy, &diagnostic),
        diagnostic,
    );
    try expectStatus(
        .ok,
        api.sessionControl().updatePermissionRules()(session, &initial_rules, &diagnostic),
        diagnostic,
    );
    // The mode changes in place: same handle, a new policy generation, and
    // describe names the mode. An unknown code and a repeat change nothing.
    const full_access = try describePermission(a, api, session);
    if (full_access.mode != .full_access) return error.InvalidPermissionMode;
    try expectStatus(
        .ok,
        api.sessionControl().updatePermissionMode()(session, wire.PERMISSION_DEFAULT, &diagnostic),
        diagnostic,
    );
    const default_mode = try describePermission(a, api, session);
    if (default_mode.mode != .default or default_mode.generation != full_access.generation + 1)
        return error.InvalidPermissionMode;
    try expectStatus(
        .invalid_argument,
        api.sessionControl().updatePermissionMode()(session, 99, &diagnostic),
        diagnostic,
    );
    api.bufferRelease()(&diagnostic);
    try expectStatus(
        .ok,
        api.sessionControl().updatePermissionMode()(session, wire.PERMISSION_DEFAULT, &diagnostic),
        diagnostic,
    );
    if ((try describePermission(a, api, session)).generation != default_mode.generation)
        return error.InvalidPermissionMode;
    try expectStatus(
        .ok,
        api.sessionControl().updatePermissionMode()(session, wire.PERMISSION_FULL_ACCESS, &diagnostic),
        diagnostic,
    );
    const restored_mode = try describePermission(a, api, session);
    if (restored_mode.mode != .full_access or restored_mode.generation != default_mode.generation + 1)
        return error.InvalidPermissionMode;
    var compact_result = std.mem.zeroes(wire.CompactResultV1);
    try expectStatus(
        .ok,
        api.sessionControl().compact()(session, 1, &compact_result, &diagnostic),
        diagnostic,
    );
    if (compact_result.struct_size != @sizeOf(wire.CompactResultV1) or
        compact_result.outcome_code != wire.COMPACT_NO_CHANGE)
        return error.InvalidCompactResult;
    try expectStatus(
        .too_late,
        api.sessionControl().abortCompact()(session, 1, &diagnostic),
        diagnostic,
    );
    api.bufferRelease()(&diagnostic);
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 7, .context_blocks = null, .context_block_count = 0, .time_context_code = wire.TIME_CONTEXT_SYSTEM, .utc_offset_minutes = 0, .reserved = [_]u64{0} ** 1 };
    var result: wire.RunResultV1 = undefined;
    const encoded_arguments = try sdk.encodeSkillArguments(
        a,
        &.{"artifact-target"},
    );
    probe.api = api;
    probe.submit_during_ui = true;
    try probe.beginRun(1);
    try expectStatus(.ok, api.session().runSkill(
        session,
        1,
        sdk.bytesView(identities.skill_id),
        sdk.bytesView(identities.revision),
        sdk.bytesView(encoded_arguments),
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(1);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or result.tool_calls != 6) return error.UnexpectedRunResult;
    if (probe.ui_calls != 1 or probe.ui_releases != 1 or probe.host_calls != 1 or probe.host_releases != 1) return error.CallbackContractFailed;
    if (probe.host_stream_calls != 1 or probe.host_stream_writes <= 1 or
        probe.host_stream_max_chunk_bytes != 64 * 1024)
        return error.StreamCallbackContractFailed;
    if (!probe.saw_read_result or !probe.saw_file_change or !probe.saw_host_result or !probe.saw_stream_envelope or
        !probe.saw_artifact_recovery or !probe.saw_final_text or !probe.saw_final_output_segment)
        return error.MissingCoreEvent;
    // Revision 20 reconciliation: the one input submitted mid-Run was accepted
    // and adopted, and the Run that took it is over for further input.
    if (probe.submitted_sequence != 1 or !probe.saw_input_adopted or
        result.input_accepted_count != 1 or result.input_adopted_count != 1)
        return error.SubmittedInputNotReconciled;
    {
        var receipt = std.mem.zeroes(wire.InputReceiptV1);
        try expectStatus(.too_late, api.session().submitInput(session, 1, 7, sdk.bytesView("late"), &receipt, &diagnostic), diagnostic);
        api.bufferRelease()(&diagnostic);
        try expectStatus(.stale_run, api.session().submitInput(session, 99, 7, sdk.bytesView("stale"), &receipt, &diagnostic), diagnostic);
        api.bufferRelease()(&diagnostic);
        if (receipt.sequence != 0) return error.SubmittedInputNotReconciled;
    }
    try probe.beginRun(2);
    try expectStatus(.ok, api.session().runSkill(
        session,
        2,
        sdk.bytesView(workctl_identities.skill_id),
        sdk.bytesView(workctl_identities.revision),
        sdk.bytesView(encoded_arguments),
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(2);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or
        result.tool_calls != 0)
        return error.UnexpectedRunResult;

    // Revision 23: a goal set before the checkpoint travels with it.
    var goal_arena = std.heap.ArenaAllocator.init(a);
    defer goal_arena.deinit();
    var consumer_goal = std.mem.zeroes(wire.GoalSetV1);
    consumer_goal.struct_size = @sizeOf(wire.GoalSetV1);
    consumer_goal.objective = sdk.bytesView(CONSUMER_GOAL);
    try expectStatus(.ok, api.goal().set()(session, &consumer_goal, &diagnostic), diagnostic);
    const goal_before = (try readGoal(api, goal_arena.allocator(), session, &diagnostic)) orelse
        return error.MissingGoal;
    if (goal_before.status != .active or goal_before.token_budget != null or goal_before.tokens_used != 0)
        return error.UnexpectedGoal;

    var checkpoint = CheckpointBuffer{};
    defer checkpoint.deinit();
    var checkpoint_limits = checkpointLimits();
    var checkpoint_sink = checkpoint.sink();
    var export_config = std.mem.zeroes(wire.CheckpointExportConfigV1);
    export_config.struct_size = @sizeOf(wire.CheckpointExportConfigV1);
    export_config.limits = &checkpoint_limits;
    export_config.sink = &checkpoint_sink;
    var export_result = std.mem.zeroes(wire.CheckpointExportResultV1);
    try expectStatus(
        .ok,
        api.sessionControl().exportCheckpoint()(
            session,
            &export_config,
            &export_result,
            &diagnostic,
        ),
        diagnostic,
    );
    if (checkpoint.bytes.items.len == 0 or export_result.checkpoint_generation != 1 or
        export_result.total_bytes != @as(u64, @intCast(checkpoint.bytes.items.len)))
        return error.InvalidCheckpoint;

    try probe.unregisterSession(session.?);
    try expectStatus(.ok, api.session().destroy()(session, &diagnostic), diagnostic);
    session = null;
    try expectStatus(.ok, api.runtime().destroy()(runtime, &diagnostic), diagnostic);
    runtime = null;

    try expectStatus(.ok, api.runtime().create()(
        &runtime_config,
        &plugin_config,
        &runtime,
        &diagnostic,
    ), diagnostic);
    var restored_catalog: ?*wire.SkillCatalogHandle = null;
    defer if (restored_catalog) |handle| {
        _ = api.skill().releaseCatalog()(handle, &diagnostic);
    };
    try expectStatus(.ok, api.skill().resolveCatalog()(
        runtime,
        &query,
        &restored_catalog,
        &descriptor,
        &diagnostic,
    ), diagnostic);
    api.bufferRelease()(&descriptor);
    const responses_server = try Server.start(init.io, &.{ RESPONSES_FINAL_SSE, RESPONSES_FINAL_SSE, RESPONSES_FINAL_SSE });
    defer responses_server.stop();
    const responses_url = try responses_server.url(a);
    session_host.provider_kind_code = wire.PROVIDER_OPENAI;
    session_host.protocol_kind_code = wire.OPENAI_PROTOCOL_RESPONSES;
    session_host.base_url = sdk.bytesView(responses_url);
    session_host.skill_catalog = restored_catalog;
    // Revision 21: restore takes the current Host's capability declarations
    // (checkpoints carry none). `artifact-vision` is in no built-in model
    // family; only this declaration lets an image reach the Responses wire.
    const restore_capabilities = [_]wire.ModelCapabilityV1{.{
        .struct_size = @sizeOf(wire.ModelCapabilityV1),
        .image_input_code = wire.CAPABILITY_SUPPORTED,
        .model = sdk.bytesView("artifact-vision"),
        .reserved = [_]u64{0} ** 2,
    }};
    session_host.model_capabilities = &restore_capabilities;
    session_host.model_capability_count = restore_capabilities.len;
    var checkpoint_source = checkpoint.source();
    var restore_config = std.mem.zeroes(wire.SessionRestoreConfigV1);
    restore_config.struct_size = @sizeOf(wire.SessionRestoreConfigV1);
    restore_config.host = &session_host;
    restore_config.source = &checkpoint_source;
    restore_config.limits = &checkpoint_limits;
    var restore_report = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&restore_report);
    try expectStatus(.ok, api.sessionControl().restore()(
        runtime,
        &restore_config,
        &callbacks,
        &session,
        &restore_report,
        &diagnostic,
    ), diagnostic);
    try expectStatus(
        .ok,
        api.skill().releaseCatalog()(restored_catalog, &diagnostic),
        diagnostic,
    );
    restored_catalog = null;
    session_host.skill_catalog = null;
    try probe.registerSession(session.?);
    {
        const encoded_report = try sdk.borrowedBytes(.{
            .ptr = restore_report.ptr,
            .len = restore_report.len,
        });
        const parsed_report = try sdk.decodeRestoreReport(a, encoded_report);
        defer parsed_report.deinit();
        if (parsed_report.value.checkpoint_generation != 1 or
            parsed_report.value.session_id.len == 0)
            return error.InvalidRestoreReport;
    }
    api.bufferRelease()(&restore_report);

    // The checkpoint intentionally carries the earlier fixture model, which
    // nothing declares able to take images: an image Run is refused before any
    // provider round as CAPABILITY_UNKNOWN (not UNSUPPORTED), and its id stays
    // reusable. Then select the model the Host declared vision-capable.
    const probe_parts = [_]wire.RunInputPartV1{
        sdk.textPart("describe the attached icon"),
        sdk.imagePart("image/png", "aWNvbi1ieXRlcw=="),
    };
    try expectStatus(.image_input_capability_unknown, api.session().runMultimodal(
        session,
        3,
        &probe_parts,
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    api.bufferRelease()(&diagnostic);
    try expectStatus(
        .ok,
        api.sessionControl().setModel()(session, sdk.bytesView("artifact-vision"), &diagnostic),
        diagnostic,
    );

    try probe.beginRun(3);
    try expectStatus(.ok, api.session().runText(
        session,
        3,
        sdk.bytesView("continue through Responses after source-free restore"),
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(3);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn)
        return error.UnexpectedRunResult;

    // Revision 15 multimodal input over the same restored Responses Session:
    // an ordered text+image parts array is a first-class Run input.
    const multimodal_parts = [_]wire.RunInputPartV1{
        sdk.textPart("describe the attached icon"),
        sdk.imagePart("image/png", "aWNvbi1ieXRlcw=="),
    };
    // Revision 22: a Host west of UTC gives its offset for this Run.
    var west_options = options;
    west_options.time_context_code = wire.TIME_CONTEXT_UTC_OFFSET;
    west_options.utc_offset_minutes = -300;
    try probe.beginRun(4);
    try expectStatus(.ok, api.session().runMultimodal(
        session,
        4,
        &multimodal_parts,
        &west_options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(4);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn)
        return error.UnexpectedRunResult;
    if (!probe.saw_prompt_manifest) return error.MissingPromptManifest;

    // Revision 23: the restored Session has the checkpoint's goal, same id
    // and objective. It was active, so the Runs since the restore were
    // charged to it; a goal-continuation Run is charged too and reports it.
    {
        const restored_goal = (try readGoal(api, goal_arena.allocator(), session, &diagnostic)) orelse
            return error.MissingGoal;
        if (!std.mem.eql(u8, restored_goal.id, goal_before.id) or restored_goal.status != .active or
            !std.mem.eql(u8, restored_goal.objective, CONSUMER_GOAL) or restored_goal.tokens_used == 0)
            return error.UnexpectedGoal;
        const updates_before = probe.goal_updates;
        var continuation = std.mem.zeroes(wire.RunInputV1);
        continuation.struct_size = @sizeOf(wire.RunInputV1);
        continuation.kind_code = wire.RUN_INPUT_GOAL_CONTINUATION;
        try probe.beginRun(5);
        try expectStatus(.ok, api.session().runInput()(session, 5, &continuation, &options, &result, &diagnostic), diagnostic);
        try probe.endRun(5);
        if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or
            probe.goal_updates == updates_before)
            return error.UnexpectedRunResult;
        const charged_goal = (try readGoal(api, goal_arena.allocator(), session, &diagnostic)) orelse
            return error.MissingGoal;
        if (charged_goal.tokens_used <= restored_goal.tokens_used) return error.UnexpectedGoal;
    }

    // ── Revision 24 (issue #277): the host-scheduled team table ───────────
    // A source-free host reaches `team->describe` and `team->poll` on a lead
    // Session with teams enabled. A lead that has not yet run `TeamCreate`
    // has no team, so both report empty. The populated lead-delegates /
    // member-replies / poll round-trip is the AgentCore L2 team test.
    {
        var team_cfg = std.mem.zeroes(wire.TeamConfigV1);
        team_cfg.struct_size = @sizeOf(wire.TeamConfigV1);
        team_cfg.role_code = wire.TEAM_ROLE_LEAD;
        team_cfg.team_name = sdk.bytesView("");

        const team_allowed = [_]wire.BytesViewV1{sdk.bytesView("Read")};
        var team_host = std.mem.zeroes(wire.SessionHostConfigV1);
        team_host.struct_size = @sizeOf(wire.SessionHostConfigV1);
        team_host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
        team_host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
        team_host.shell_policy_code = wire.SHELL_DISABLED;
        team_host.api_key = sdk.bytesView("artifact-key");
        team_host.base_url = sdk.bytesView(url);
        team_host.workspace_root = sdk.bytesView(workspace);
        team_host.workspace_home = sdk.bytesView(workspace);
        team_host.allowed_tools = &team_allowed;
        team_host.allowed_tool_count = team_allowed.len;
        team_host.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
        team_host.team = &team_cfg;

        var team_create = std.mem.zeroes(wire.SessionCreateConfigV1);
        team_create.struct_size = @sizeOf(wire.SessionCreateConfigV1);
        team_create.host = &team_host;
        team_create.model = sdk.bytesView("artifact-model");

        var team_session: ?*wire.SessionHandle = null;
        try expectStatus(.ok, api.session().create()(runtime, &team_create, &callbacks, &team_session, &diagnostic), diagnostic);
        defer if (team_session) |handle| {
            _ = api.session().destroy()(handle, &diagnostic);
        };

        var team_json = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        defer api.bufferRelease()(&team_json);
        try expectStatus(.ok, api.team().describe()(team_session, &team_json, &diagnostic), diagnostic);
        const team_text = try sdk.borrowedBytes(.{ .ptr = team_json.ptr, .len = team_json.len });
        if (!std.mem.eql(u8, team_text, "{\"team\":null}")) return error.UnexpectedTeamDescription;

        var poll_json = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        defer api.bufferRelease()(&poll_json);
        try expectStatus(.ok, api.team().poll()(team_session, &poll_json, &diagnostic), diagnostic);
        const poll_text = try sdk.borrowedBytes(.{ .ptr = poll_json.ptr, .len = poll_json.len });
        if (!std.mem.eql(u8, poll_text, "{\"input\":null}")) return error.UnexpectedTeamPoll;
    }

    try probe.unregisterSession(session.?);
    try expectStatus(.ok, api.session().destroy()(session, &diagnostic), diagnostic);
    session = null;
    try credentialRotation(a, init.io, api, runtime, &callbacks, &probe, workspace, &prompt_profile);
    try expectStatus(.ok, api.runtime().destroy()(runtime, &diagnostic), diagnostic);
    runtime = null;

    std.debug.print("AgentCore source-free consumer: Revision 26 Agent Runtime, credential rotation, goals, host-scheduled team, time context, Host model capabilities, active-Run input, prompt profile, permission mode update, OpenAI Responses, multimodal input, active-Run journal, Host/MCP streaming, process-plugin configuration, Workspace Skill Catalog, tools, checkpoint, Runtime rebuild, restore and continued Run OK\n", .{});
}

/// Revision 25 (#336): one Session's provider credential, rotated twice
/// against a loopback provider that records each request's authorization
/// header. The Run's first request carries the creation key; its HostEcho
/// callback rotates the key (after a refused candidate), so the Run's second
/// request carries the rotation; an update while idle reaches the next Run;
/// refusals keep the key; describe never names a key. The Session carries the
/// consumer's prompt profile, whose Host section the Probe requires in every
/// `prompt_manifest`.
/// A provider's answer inside an accepted stream, in a vocabulary AgentCore has
/// no opinion about.
const MODEL_ERROR_SSE =
    "data: {\"type\":\"error\",\"error\":{\"type\":\"billing_error\",\"code\":\"insufficient_balance\",\"message\":\"Balance too low\"},\"request_id\":\"req-consumer-1\"}\n\n";

fn credentialRotation(
    a: std.mem.Allocator,
    io: std.Io,
    api: sdk.Api,
    runtime: ?*wire.RuntimeHandle,
    callbacks: *const wire.SessionCallbacksV1,
    probe: *Probe,
    workspace: []const u8,
    prompt_profile: *const wire.PromptProfileV1,
) !void {
    const server = try Server.start(io, &.{ HOST_SSE, FINAL_SSE, FINAL_SSE, MODEL_ERROR_SSE });
    defer server.destroy();
    var joined = false;
    defer if (!joined) server.join();
    const url = try server.url(a);
    const allowed = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    host.permission_mode_code = wire.PERMISSION_FULL_ACCESS;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView("zig-consumer-key");
    host.base_url = sdk.bytesView(url);
    host.workspace_root = sdk.bytesView(workspace);
    host.workspace_home = sdk.bytesView(workspace);
    host.allowed_tools = &allowed;
    host.allowed_tool_count = allowed.len;
    host.run_journal_mode_code = wire.RUN_JOURNAL_EPHEMERAL;
    var create = std.mem.zeroes(wire.SessionCreateConfigV1);
    create.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    create.host = &host;
    create.model = sdk.bytesView("artifact-model");
    create.prompt_profile = prompt_profile;

    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var session: ?*wire.SessionHandle = null;
    try expectStatus(.ok, api.session().create()(runtime, &create, callbacks, &session, &diagnostic), diagnostic);
    defer if (session) |handle| {
        _ = api.session().destroy()(handle, &diagnostic);
    };
    probe.bound_session_id_len = 0;
    try probe.registerSession(session.?);

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 4;
    var result = std.mem.zeroes(wire.RunResultV1);
    probe.api = api;
    probe.rotate_in_host = true;
    try probe.beginRun(1);
    try expectStatus(.ok, api.session().runText(session, 1, sdk.bytesView("rotate the credential"), &options, &result, &diagnostic), diagnostic);
    try probe.endRun(1);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or result.turns != 2)
        return error.CredentialRotationRunFailed;
    try expectStatus(.invalid_argument, probe.rotate_refused_status, .{ .ptr = null, .len = 0 });
    try expectStatus(.ok, probe.rotate_status, .{ .ptr = null, .len = 0 });

    try expectStatus(.ok, api.session().updateCredential()(session, sdk.bytesView("zig-idle-key"), &diagnostic), diagnostic);
    // Refusals name the rule, never the bytes, and keep the idle key.
    try expectStatus(.invalid_argument, api.session().updateCredential()(session, sdk.bytesView(""), &diagnostic), diagnostic);
    api.bufferRelease()(&diagnostic);
    const too_long = try a.alloc(u8, @as(usize, @intCast(wire.MAX_CREDENTIAL_BYTES_V1)) + 1);
    @memset(too_long, 'k');
    try expectStatus(.resource_limit, api.session().updateCredential()(session, sdk.bytesView(too_long), &diagnostic), diagnostic);
    api.bufferRelease()(&diagnostic);
    try expectStatus(.invalid_argument, api.session().updateCredential()(session, sdk.bytesView("zig idle key"), &diagnostic), diagnostic);
    const refusal = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
    if (std.mem.indexOf(u8, refusal, "zig idle key") != null) return error.CredentialInDiagnostic;
    api.bufferRelease()(&diagnostic);

    try probe.beginRun(2);
    try expectStatus(.ok, api.session().runText(session, 2, sdk.bytesView("once more"), &options, &result, &diagnostic), diagnostic);
    try probe.endRun(2);
    if (probe.model_errors != 0) return error.UnexpectedModelError;

    // Issue #408: the ABI call succeeds, the stop reason says the model failed
    // and the diagnostic stays empty, and the typed event says why.
    try probe.beginRun(3);
    try expectStatus(.ok, api.session().runText(session, 3, sdk.bytesView("fail on the model"), &options, &result, &diagnostic), diagnostic);
    try probe.endRun(3);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .api_error or diagnostic.len != 0)
        return error.ModelFailureRunResult;
    if (probe.model_errors != 1 or !probe.model_error_matches) return error.ModelErrorNotReceived;

    var description = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&description);
    try expectStatus(.ok, api.sessionControl().describe()(session, &description, &diagnostic), diagnostic);
    const described = try sdk.borrowedBytes(.{ .ptr = description.ptr, .len = description.len });
    for ([_][]const u8{ "zig-consumer-key", "zig-rotated-key", "zig-idle-key" }) |key| {
        if (std.mem.indexOf(u8, described, key) != null) return error.CredentialInDescription;
    }

    try probe.unregisterSession(session.?);
    try expectStatus(.ok, api.session().destroy()(session, &diagnostic), diagnostic);
    session = null;
    server.join();
    joined = true;
    const expected = [_][]const u8{ "Bearer zig-consumer-key", "Bearer zig-rotated-key", "Bearer zig-idle-key" };
    for (expected, 0..) |want, index| {
        if (!std.mem.eql(u8, server.authorization(index), want)) {
            std.debug.print("credential rotation request {d} carried [{s}]\n", .{ index, server.authorization(index) });
            return error.CredentialRotationHeaderMismatch;
        }
    }
}

const CatalogIdentities = struct {
    revision: []const u8,
    skill_id: []const u8,
};

fn catalogIdentities(
    allocator: std.mem.Allocator,
    descriptor_json: []const u8,
    invocation_name: []const u8,
) !CatalogIdentities {
    const parsed = try sdk.decodeSkillCatalog(allocator, descriptor_json);
    defer parsed.deinit();
    for (parsed.value.skills) |skill| {
        if (std.mem.eql(u8, skill.invocation_name, invocation_name)) {
            if (skill.argument_schema.names.len != 1 or
                !std.mem.eql(u8, skill.argument_schema.names[0], "target"))
                return error.InvalidCatalogDescriptor;
            return .{
                .revision = try allocator.dupe(u8, parsed.value.catalog_revision),
                .skill_id = try allocator.dupe(u8, skill.skill_id),
            };
        }
    }
    return error.SkillMissingFromCatalog;
}

fn verifyRevisionMismatchRejection(api: sdk.Api) !void {
    var wrong_revision = api.raw.*;
    wrong_revision.abi_revision = wire.ABI_REVISION - 1;
    if (sdk.Api.validate(&wrong_revision)) |_| return error.WrongRevisionAccepted else |err| {
        if (err != error.UnsupportedAbi) return err;
    }
}

fn readToolSse(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

const DescribedPermission = struct {
    mode: sdk.protocol.PermissionMode,
    generation: u64,
};

fn describePermission(a: std.mem.Allocator, api: sdk.Api, session: ?*wire.SessionHandle) !DescribedPermission {
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var description = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&description);
    try expectStatus(.ok, api.sessionControl().describe()(session, &description, &diagnostic), diagnostic);
    const decoded = try sdk.decodeSessionDescription(a, try sdk.borrowedBytes(.{
        .ptr = description.ptr,
        .len = description.len,
    }));
    defer decoded.deinit();
    return .{ .mode = decoded.value.permission_mode, .generation = decoded.value.policy_generation };
}

fn expectStatus(expected: sdk.Status, actual_code: u32, diagnostic: wire.OwnedBytesV1) !void {
    const actual = sdk.Status.fromCode(actual_code) catch return error.UnknownStatus;
    if (actual == expected) return;
    const message = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "invalid diagnostic";
    std.debug.print("AgentCore status {s}, expected {s}: {s}\n", .{ @tagName(actual), @tagName(expected), message });
    return error.UnexpectedStatus;
}
