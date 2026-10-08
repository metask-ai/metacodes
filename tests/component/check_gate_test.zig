//! L2: the host check gate and the blocking Stop hook. When the model ends
//! its turn after changing the workspace, the host runs the pinned check
//! command itself; in enforce mode a clean failure continues the same
//! conversation with the verdict, within the continuation budget; observe
//! mode runs the same check and only records it; a turn with no new work is
//! never checked; a check whose files the run changed is tainted and never
//! continues. A Stop hook that blocks continues the run with its reason, at
//! most `MAX_STOP_HOOK_BLOCKS` times, and sees `stop_hook_active` once it has
//! sent the run back. Task-agnostic process rules — these tests carry no
//! benchmark content. Formal model:
//! control-plane/lean/MetaCodesControl/CheckGate.lean.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const gate_mod = cc.check_gate;
const hooks = cc.permission_hooks;

fn endTurn(allocator: std.mem.Allocator, id: []const u8, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, text },
    );
}

fn toolSse(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input, .{}, &escaped.writer);
    const encoded = try escaped.toOwnedSlice();
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, name, encoded },
    );
}

/// A Write of `content` to `<root>/<name>`.
fn writeSse(allocator: std.mem.Allocator, id: []const u8, root: []const u8, name: []const u8, content: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    defer allocator.free(path);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"file_path\":");
    try std.json.Stringify.encodeJsonString(path, .{}, &aw.writer);
    try aw.writer.writeAll(",\"content\":");
    try std.json.Stringify.encodeJsonString(content, .{}, &aw.writer);
    try aw.writer.writeByte('}');
    const input = try aw.toOwnedSlice();
    defer allocator.free(input);
    return toolSse(allocator, id, "Write", input);
}

const RecordSink = struct {
    records: usize = 0,
    enforced: bool = false,
    checks: u8 = 255,
    continuations: u8 = 255,
    max_continuations: u8 = 0,
    final_verdict: cc.tools.tool_observation.CheckGateVerdict = .not_run,
    unchecked_changes: bool = false,
    stop_hook_blocks: u8 = 255,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .check_gate => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.checks = record.checks;
                self.continuations = record.continuations;
                self.max_continuations = record.max_continuations;
                self.final_verdict = record.final_verdict;
                self.unchecked_changes = record.unchecked_changes;
                self.stop_hook_blocks = record.stop_hook_blocks;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const MAX_REQUESTS = 10;

const GateRun = struct {
    requests: usize,
    /// Marker occurrences per request body. An injected continuation stays in
    /// the conversation, so request N carries every one injected before it.
    markers: [MAX_REQUESTS]usize = [_]usize{0} ** MAX_REQUESTS,
    stop_markers: [MAX_REQUESTS]usize = [_]usize{0} ** MAX_REQUESTS,
    last_body: ?[]u8 = null,
    record: RecordSink,

    fn deinit(self: *GateRun, allocator: std.mem.Allocator) void {
        if (self.last_body) |bytes| allocator.free(bytes);
    }

    fn expectMarkers(self: *const GateRun, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| try std.testing.expectEqual(count, self.markers[index]);
    }

    fn expectStopMarkers(self: *const GateRun, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| try std.testing.expectEqual(count, self.stop_markers[index]);
    }
};

const RunConfig = struct {
    gate: ?gate_mod.Options = null,
    hookset: ?*const hooks.HookSet = null,
    /// Attach a read-state table, so Write enforces must-read-first like the
    /// REPL and headless hosts do.
    read_state: bool = false,
};

fn runGate(
    allocator: std.mem.Allocator,
    root: []const u8,
    config: RunConfig,
    responses: []const []const u8,
) !GateRun {
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "produce result.txt");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    permission.hooks = config.hookset;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = RecordSink{};
    var read_state = cc.core_read_state.ReadState.init(allocator);
    defer read_state.deinit();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 16,
            .system_prompt = "STABLE-PREFIX",
            .check_gate = config.gate,
            .read_state = if (config.read_state) &read_state else null,
            .tool_observer = record.sink(),
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    var out = GateRun{ .requests = server.requestCount(), .record = record };
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (index < MAX_REQUESTS) {
            out.markers[index] = std.mem.count(u8, request.body(), gate_mod.MARKER);
            out.stop_markers[index] = std.mem.count(u8, request.body(), gate_mod.STOP_HOOK_MARKER);
        }
        if (server.requestAt(index + 1) == null) out.last_body = try allocator.dupe(u8, request.body());
    }
    return out;
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

fn fileExists(allocator: std.mem.Allocator, root: []const u8, name: []const u8) !bool {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    defer allocator.free(path);
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

/// The pinned check every test uses: passes only when result.txt holds the
/// right line; every run leaves a mark so a test can prove it ran (or not).
const CHECK = "echo run >> check-runs.log; grep -qx 'TOTAL=42' result.txt";

test "L2 check gate: a clean failure continues the run with the verdict until the check passes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const wrong = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(wrong);
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const right = try writeSse(a, "write_2", root, "result.txt", "TOTAL=42\n");
    defer a.free(right);
    const done_2 = try endTurn(a, "done_2", "fixed");
    defer a.free(done_2);
    const responses = [_][]const u8{ wrong, done_1, right, done_2 };
    var run = try runGate(a, root, .{ .gate = .{ .command = CHECK, .mode = .enforce, .max_continuations = 3 } }, &responses);
    defer run.deinit(a);
    // The continuation rides request 3 (after the first end_turn) and stays
    // in the history; the first request is untouched.
    try run.expectMarkers(&.{ 0, 0, 1, 1 });
    const body = run.last_body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "Result: FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "TOTAL=42") != null); // the pinned command is quoted
    try std.testing.expect(std.mem.indexOf(u8, body, "continuations left after this one: 2") != null);
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.enforced);
    try std.testing.expectEqual(@as(u8, 2), run.record.checks);
    try std.testing.expectEqual(@as(u8, 1), run.record.continuations);
    try std.testing.expectEqual(@as(u8, 3), run.record.max_continuations);
    try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.passed, run.record.final_verdict);
    try std.testing.expect(!run.record.unchecked_changes);
}

test "L2 check gate: observe mode runs the same check and never touches the conversation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const wrong = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(wrong);
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const responses = [_][]const u8{ wrong, done_1 };
    var run = try runGate(a, root, .{ .gate = .{ .command = CHECK, .mode = .observe } }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expect(try fileExists(a, root, "check-runs.log"));
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(!run.record.enforced);
    try std.testing.expectEqual(@as(u8, 1), run.record.checks);
    try std.testing.expectEqual(@as(u8, 0), run.record.continuations);
    try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.failed, run.record.final_verdict);
}

test "L2 check gate: the continuation budget is a hard bound" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    var owned: [6][]u8 = undefined;
    for (0..3) |i| {
        var id_buf: [16]u8 = undefined;
        owned[2 * i] = try writeSse(a, try std.fmt.bufPrint(&id_buf, "write_{d}", .{i}), root, "result.txt", "TOTAL=0\n");
        owned[2 * i + 1] = try endTurn(a, "done", "done");
    }
    defer for (owned) |sse| a.free(sse);
    const responses = [_][]const u8{ owned[0], owned[1], owned[2], owned[3], owned[4], owned[5] };
    var run = try runGate(a, root, .{ .gate = .{ .command = CHECK, .mode = .enforce, .max_continuations = 2 } }, &responses);
    defer run.deinit(a);
    // Two continuations (requests 3 and 5), then the third failure finishes.
    try run.expectMarkers(&.{ 0, 0, 1, 1, 2, 2 });
    try std.testing.expectEqual(@as(u8, 3), run.record.checks);
    try std.testing.expectEqual(@as(u8, 2), run.record.continuations);
    try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.failed, run.record.final_verdict);
}

test "L2 check gate: a turn without new work is never checked" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    // A pristine run: no tool call at all.
    {
        const done = try endTurn(a, "done", "just an answer");
        defer a.free(done);
        const responses = [_][]const u8{done};
        var run = try runGate(a, root, .{ .gate = .{ .command = CHECK, .mode = .enforce } }, &responses);
        defer run.deinit(a);
        try run.expectMarkers(&.{0});
        try std.testing.expect(!try fileExists(a, root, "check-runs.log"));
        try std.testing.expectEqual(@as(u8, 0), run.record.checks);
        try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.not_run, run.record.final_verdict);
    }
    // After a continuation the model stops without changing anything: the
    // run ends on the last verdict instead of re-running the same check.
    {
        const wrong = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
        defer a.free(wrong);
        const done_1 = try endTurn(a, "done_1", "done");
        defer a.free(done_1);
        const done_2 = try endTurn(a, "done_2", "I cannot fix this");
        defer a.free(done_2);
        const responses = [_][]const u8{ wrong, done_1, done_2 };
        var run = try runGate(a, root, .{ .gate = .{ .command = CHECK, .mode = .enforce } }, &responses);
        defer run.deinit(a);
        try run.expectMarkers(&.{ 0, 0, 1 });
        try std.testing.expectEqual(@as(u8, 1), run.record.checks);
        try std.testing.expectEqual(@as(u8, 1), run.record.continuations);
        try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.failed, run.record.final_verdict);
    }
}

test "L2 check gate: a refused file write is no new work" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    // result.txt exists but was never read in this run, so Write refuses it
    // (must-read-first) and nothing on disk changes.
    const existing = try std.fmt.allocPrint(a, "{s}/result.txt", .{root});
    defer a.free(existing);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = existing, .data = "TOTAL=0\n" });
    const refused = try writeSse(a, "write_1", root, "result.txt", "TOTAL=42\n");
    defer a.free(refused);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ refused, done };
    var run = try runGate(a, root, .{ .gate = .{ .command = CHECK, .mode = .enforce }, .read_state = true }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expect(!try fileExists(a, root, "check-runs.log"));
    try std.testing.expectEqual(@as(u8, 0), run.record.checks);
    try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.not_run, run.record.final_verdict);
}

test "L2 check gate: editing the check makes the verdict tainted and ends the run" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    // The model rewrites the runner the pinned command executes.
    const rigged = try writeSse(a, "write_1", root, "check.sh", "exit 1\n");
    defer a.free(rigged);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ rigged, done };
    var run = try runGate(a, root, .{ .gate = .{ .command = "sh check.sh", .mode = .enforce } }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expectEqual(@as(u8, 1), run.record.checks);
    try std.testing.expectEqual(@as(u8, 0), run.record.continuations);
    try std.testing.expectEqual(cc.tools.tool_observation.CheckGateVerdict.tainted, run.record.final_verdict);
}

test "L2 check gate: a disabled gate never runs the check and never records" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const wrong = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(wrong);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ wrong, done };
    var run = try runGate(a, root, .{}, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expect(!try fileExists(a, root, "check-runs.log"));
    try std.testing.expectEqual(@as(usize, 0), run.record.records);
}

test "L2 Stop hook: a block continues the run with its reason and the next stop sees stop_hook_active" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell hook
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const hook = try std.fmt.allocPrint(
        a,
        "cd '{s}' && cat >> stop-stdin.log && echo >> stop-stdin.log && if [ -f done.txt ]; then exit 0; fi; " ++
            "printf '{{\"decision\":\"block\",\"reason\":\"done.txt is missing\"}}'",
        .{root},
    );
    defer a.free(hook);
    const cmds = [_][]const u8{hook};
    const entries = [_]hooks.HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const hookset = hooks.HookSet{ .pre_tool_use = &.{}, .stop = &entries, .allocator = a };
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const write = try writeSse(a, "write_1", root, "done.txt", "ok\n");
    defer a.free(write);
    const done_2 = try endTurn(a, "done_2", "now done");
    defer a.free(done_2);
    const responses = [_][]const u8{ done_1, write, done_2 };
    var run = try runGate(a, root, .{ .hookset = &hookset }, &responses);
    defer run.deinit(a);
    try run.expectStopMarkers(&.{ 0, 1, 1 });
    try std.testing.expect(std.mem.indexOf(u8, run.last_body.?, "done.txt is missing") != null);
    // Without an armed check gate there is no terminal record.
    try std.testing.expectEqual(@as(usize, 0), run.record.records);
    // The hook ran on both stops; only the second carries stop_hook_active.
    const log_path = try std.fmt.allocPrint(a, "{s}/stop-stdin.log", .{root});
    defer a.free(log_path);
    const log_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, a, .limited(1 << 16));
    defer a.free(log_bytes);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log_bytes, "\n"), '\n');
    const first = lines.next().?;
    const second = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"stop_hook_active\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"stop_hook_active\":true") != null);
}

test "L2 Stop hook: an always-blocking hook is bounded by the host" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell hook
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const cmds = [_][]const u8{"cat >/dev/null; echo 'never satisfied' >&2; exit 2"};
    const entries = [_]hooks.HookEntry{.{ .matcher = "*", .commands = &cmds }};
    const hookset = hooks.HookSet{ .pre_tool_use = &.{}, .stop = &entries, .allocator = a };
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const limit = gate_mod.MAX_STOP_HOOK_BLOCKS;
    var responses: [limit + 1][]const u8 = undefined;
    for (&responses) |*slot| slot.* = done;
    // The host-check record counts the blocks when the gate is armed.
    var run = try runGate(a, root, .{
        .hookset = &hookset,
        .gate = .{ .command = CHECK, .mode = .observe },
    }, &responses);
    defer run.deinit(a);
    try run.expectStopMarkers(&.{ 0, 1, 2, 3, 4, 5 });
    try std.testing.expect(std.mem.indexOf(u8, run.last_body.?, "never satisfied") != null);
    try std.testing.expectEqual(limit, run.record.stop_hook_blocks);
    // No file changed, so the check never ran.
    try std.testing.expectEqual(@as(u8, 0), run.record.checks);
}
