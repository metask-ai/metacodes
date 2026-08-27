const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const Server = @import("mock_server.zig").Server;

comptime {
    if (wire.ABI_REVISION != 14 or
        @intFromEnum(wire.Status.skill_catalog_incomplete) != 27 or
        wire.MCP_NEGOTIATION_AUTO != 1 or
        wire.MCP_NEGOTIATION_MODERN_ONLY != 2 or
        wire.MCP_NEGOTIATION_LEGACY_ONLY != 3 or
        wire.MCP_NEGOTIATION_LEGACY_2025_06_ONLY != 4 or
        wire.MCP_ERA_2026_07_28 != 1 or
        wire.MCP_ERA_2025_11_25 != 2 or
        wire.MCP_ERA_2025_06_18 != 3 or
        wire.MCP_APPLY_APPLIED != 1 or
        wire.MCP_APPLY_SUPERSEDED != 2 or
        wire.MCP_APPLY_REJECTED != 3)
        @compileError("source-free Revision 14 codes must match the public contract");
    if (@hasDecl(wire, "SessionRefreshSkillCatalogFnV1") or
        @hasField(wire.ApiV1, "session_refresh_skill_catalog"))
        @compileError("revision 14 must not expose the removed catalog refresh entry");
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

const Probe = struct {
    identity_mutex: SpinMutex = .{},
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
    saw_final_text: bool = false,
    saw_final_output_segment: bool = false,
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
        HOST_SSE,
        HOST_STREAM_SSE,
        READ_ARTIFACT_SSE,
        FINAL_SSE,
        FINAL_SSE,
        FINAL_SSE,
    };
    const server = try Server.start(init.io, &bodies);
    defer server.stop();
    const url = try server.url(a);

    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read") };
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
        .reserved = [_]u64{0} ** 1,
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

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("Read"), sdk.bytesView("HostEcho"), sdk.bytesView("HostStream") };
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
        .reserved0 = 0,
        .reserved = [_]u64{0} ** 3,
    };
    var config = wire.SessionCreateConfigV1{
        .struct_size = @sizeOf(wire.SessionCreateConfigV1),
        .reserved0 = 0,
        .host = &session_host,
        .model = sdk.bytesView("artifact-model"),
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
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 6, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    const encoded_arguments = try sdk.encodeSkillArguments(
        a,
        &.{"artifact-target"},
    );
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
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn or result.tool_calls != 5) return error.UnexpectedRunResult;
    if (probe.ui_calls != 1 or probe.ui_releases != 1 or probe.host_calls != 1 or probe.host_releases != 1) return error.CallbackContractFailed;
    if (probe.host_stream_calls != 1 or probe.host_stream_writes <= 1 or
        probe.host_stream_max_chunk_bytes != 64 * 1024)
        return error.StreamCallbackContractFailed;
    if (!probe.saw_read_result or !probe.saw_host_result or !probe.saw_stream_envelope or
        !probe.saw_artifact_recovery or !probe.saw_final_text or !probe.saw_final_output_segment)
        return error.MissingCoreEvent;
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
    session_host.skill_catalog = restored_catalog;
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

    try probe.beginRun(3);
    try expectStatus(.ok, api.session().runText(
        session,
        3,
        sdk.bytesView("continue after source-free restore"),
        &options,
        &result,
        &diagnostic,
    ), diagnostic);
    try probe.endRun(3);
    if (try sdk.StopReason.fromCode(result.stop_reason_code) != .end_turn)
        return error.UnexpectedRunResult;

    try probe.unregisterSession(session.?);
    try expectStatus(.ok, api.session().destroy()(session, &diagnostic), diagnostic);
    session = null;
    try expectStatus(.ok, api.runtime().destroy()(runtime, &diagnostic), diagnostic);
    runtime = null;

    std.debug.print("AgentCore source-free consumer: Revision 14 Agent Runtime, active-Run journal, Host/MCP streaming, process-plugin configuration, Workspace Skill Catalog, tools, checkpoint, Runtime rebuild, restore and continued Run OK\n", .{});
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

fn expectStatus(expected: sdk.Status, actual_code: u32, diagnostic: wire.OwnedBytesV1) !void {
    const actual = sdk.Status.fromCode(actual_code) catch return error.UnknownStatus;
    if (actual == expected) return;
    const message = sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len }) catch "invalid diagnostic";
    std.debug.print("AgentCore status {s}, expected {s}: {s}\n", .{ @tagName(actual), @tagName(expected), message });
    return error.UnexpectedStatus;
}
