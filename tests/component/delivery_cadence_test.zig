//! L2: the delivery-cadence obligation. A run that keeps making exploration
//! calls (read-only tools, read-only Bash) without creating or changing any
//! file receives a bounded nudge at the turn boundary once per threshold; a
//! run that mutates early is never nudged; observe mode records the same
//! crossings without touching the conversation; a disabled gate leaves no
//! record. Task-agnostic process rule — these tests carry no benchmark
//! content. Formal model: control-plane/lean/MetaCodesControl/DeliveryCadence.lean.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const cadence = cc.delivery_cadence;

const END_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

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

const RecordSink = struct {
    records: usize = 0,
    enforced: bool = false,
    exploration_calls: u32 = 0,
    mutations_occurred: bool = false,
    levels_reached: u8 = 255,
    nudges: u8 = 255,
    max_nudges: u8 = 0,
    first_threshold: u32 = 0,
    second_threshold: u32 = 0,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .delivery_cadence => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.exploration_calls = record.exploration_calls;
                self.mutations_occurred = record.mutations_occurred;
                self.levels_reached = record.levels_reached;
                self.nudges = record.nudges;
                self.max_nudges = record.max_nudges;
                self.first_threshold = record.first_threshold;
                self.second_threshold = record.second_threshold;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const Mode = enum { off, enforced, observe };

const MAX_REQUESTS = 8;

const CadenceRun = struct {
    requests: usize,
    /// Marker occurrences per request body (0-based). An injected nudge stays
    /// in the conversation, so every later request carries it too: the count
    /// on request N is the number of nudges injected before request N.
    markers: [MAX_REQUESTS]usize = [_]usize{0} ** MAX_REQUESTS,
    first_nudge_body: ?[]u8 = null,
    second_nudge_body: ?[]u8 = null,
    record: RecordSink,

    fn deinit(self: *CadenceRun, allocator: std.mem.Allocator) void {
        if (self.first_nudge_body) |bytes| allocator.free(bytes);
        if (self.second_nudge_body) |bytes| allocator.free(bytes);
    }

    fn expectMarkers(self: *const CadenceRun, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| {
            try std.testing.expectEqual(count, self.markers[index]);
        }
    }
};

fn runCadence(
    allocator: std.mem.Allocator,
    root: []const u8,
    mode: Mode,
    responses: []const []const u8,
) !CadenceRun {
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
    try conversation.appendText(.user, "investigate the repository");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = RecordSink{};
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 12,
            .system_prompt = "STABLE-PREFIX",
            .delivery_cadence = mode == .enforced,
            .delivery_cadence_observe = mode == .observe,
            // Non-default thresholds prove the option is wired, not defaulted.
            .delivery_cadence_thresholds = .{ .first = 2, .second = 4 },
            .tool_observer = record.sink(),
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    var out = CadenceRun{ .requests = server.requestCount(), .record = record };
    var index: usize = 0;
    var seen: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        const count = std.mem.count(u8, request.body(), cadence.MARKER);
        if (index < MAX_REQUESTS) out.markers[index] = count;
        // The first request whose count grows carries the newly injected nudge.
        if (count > seen) {
            if (out.first_nudge_body == null) {
                out.first_nudge_body = try allocator.dupe(u8, request.body());
            } else if (out.second_nudge_body == null) {
                out.second_nudge_body = try allocator.dupe(u8, request.body());
            }
            seen = count;
        }
    }
    return out;
}

fn fixturePath(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/fixture.txt", .{root});
    errdefer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "alpha\nbeta\n" });
    return path;
}

fn readSse(allocator: std.mem.Allocator, id: []const u8, path: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\"}}", .{path});
    defer allocator.free(input);
    return toolSse(allocator, id, "Read", input);
}

fn writeSse(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/draft.md", .{root});
    defer allocator.free(path);
    const input = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"content\":\"first draft\\n\"}}", .{path});
    defer allocator.free(input);
    return toolSse(allocator, "write_1", "Write", input);
}

fn bashSse(allocator: std.mem.Allocator, id: []const u8, command: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}", .{command});
    defer allocator.free(input);
    return toolSse(allocator, id, "Bash", input);
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

test "L2 delivery cadence: exploration without a deliverable is nudged once per threshold at the turn boundary" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const fixture = try fixturePath(a, root);
    defer a.free(fixture);
    const reads = [_][]u8{
        try readSse(a, "read_1", fixture),
        try readSse(a, "read_2", fixture),
        try readSse(a, "read_3", fixture),
        try readSse(a, "read_4", fixture),
    };
    defer for (reads) |sse| a.free(sse);
    const responses = [_][]const u8{ reads[0], reads[1], reads[2], reads[3], END_TURN };
    var run = try runCadence(a, root, .enforced, &responses);
    defer run.deinit(a);
    // Thresholds 2/4: the first request stays byte-identical (cache prefix),
    // the nudges ride requests 3 and 5 — the boundaries after calls 2 and 4 —
    // and each one stays in the history of every later request.
    try run.expectMarkers(&.{ 0, 0, 1, 1, 2 });
    try std.testing.expect(std.mem.indexOf(u8, run.first_nudge_body.?, "You have made 2 tool calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.second_nudge_body.?, "4 tool calls in this run and still") != null);
    // Terminal record: enforced, both crossings, both injections, no mutation.
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.enforced);
    try std.testing.expectEqual(@as(u32, 4), run.record.exploration_calls);
    try std.testing.expect(!run.record.mutations_occurred);
    try std.testing.expectEqual(@as(u8, 2), run.record.levels_reached);
    try std.testing.expectEqual(@as(u8, 2), run.record.nudges);
    try std.testing.expectEqual(cadence.MAX_CADENCE_NUDGES, run.record.max_nudges);
    try std.testing.expectEqual(@as(u32, 2), run.record.first_threshold);
    try std.testing.expectEqual(@as(u32, 4), run.record.second_threshold);
}

test "L2 delivery cadence: an early file write disarms the gate for the rest of the run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const fixture = try fixturePath(a, root);
    defer a.free(fixture);
    const read_1 = try readSse(a, "read_1", fixture);
    defer a.free(read_1);
    const write = try writeSse(a, root);
    defer a.free(write);
    const read_2 = try readSse(a, "read_2", fixture);
    defer a.free(read_2);
    const read_3 = try readSse(a, "read_3", fixture);
    defer a.free(read_3);
    const read_4 = try readSse(a, "read_4", fixture);
    defer a.free(read_4);
    const responses = [_][]const u8{ read_1, write, read_2, read_3, read_4, END_TURN };
    var run = try runCadence(a, root, .enforced, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.mutations_occurred);
    // Only the exploration before the mutation is counted.
    try std.testing.expectEqual(@as(u32, 1), run.record.exploration_calls);
    try std.testing.expectEqual(@as(u8, 0), run.record.levels_reached);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
}

test "L2 delivery cadence: observe-only records the crossings and never touches the conversation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const fixture = try fixturePath(a, root);
    defer a.free(fixture);
    const reads = [_][]u8{
        try readSse(a, "read_1", fixture),
        try readSse(a, "read_2", fixture),
        try readSse(a, "read_3", fixture),
        try readSse(a, "read_4", fixture),
    };
    defer for (reads) |sse| a.free(sse);
    const responses = [_][]const u8{ reads[0], reads[1], reads[2], reads[3], END_TURN };
    var run = try runCadence(a, root, .observe, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(!run.record.enforced);
    try std.testing.expectEqual(@as(u32, 4), run.record.exploration_calls);
    try std.testing.expectEqual(@as(u8, 2), run.record.levels_reached);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
}

test "L2 delivery cadence: disabled gate never nudges and never records" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    const fixture = try fixturePath(a, root);
    defer a.free(fixture);
    const reads = [_][]u8{
        try readSse(a, "read_1", fixture),
        try readSse(a, "read_2", fixture),
        try readSse(a, "read_3", fixture),
        try readSse(a, "read_4", fixture),
    };
    defer for (reads) |sse| a.free(sse);
    const responses = [_][]const u8{ reads[0], reads[1], reads[2], reads[3], END_TURN };
    var run = try runCadence(a, root, .off, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), run.record.records);
}

test "L2 delivery cadence: read-only bash counts as exploration and a mutating bash command disarms" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    // Two read-only commands cross the first threshold (2) → one nudge.
    {
        const ls_1 = try bashSse(a, "bash_1", "ls");
        defer a.free(ls_1);
        const ls_2 = try bashSse(a, "bash_2", "ls 2>&1");
        defer a.free(ls_2);
        const responses = [_][]const u8{ ls_1, ls_2, END_TURN };
        var run = try runCadence(a, root, .enforced, &responses);
        defer run.deinit(a);
        try run.expectMarkers(&.{ 0, 0, 1 });
        try std.testing.expectEqual(@as(u32, 2), run.record.exploration_calls);
        try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
    }
    // A mutating command in the second call disarms: no nudge, mutation recorded.
    {
        const ls_1 = try bashSse(a, "bash_1", "ls");
        defer a.free(ls_1);
        const mkdir = try bashSse(a, "bash_2", "mkdir -p out");
        defer a.free(mkdir);
        const ls_2 = try bashSse(a, "bash_3", "ls");
        defer a.free(ls_2);
        const ls_3 = try bashSse(a, "bash_4", "ls");
        defer a.free(ls_3);
        const responses = [_][]const u8{ ls_1, mkdir, ls_2, ls_3, END_TURN };
        var run = try runCadence(a, root, .enforced, &responses);
        defer run.deinit(a);
        try run.expectMarkers(&.{ 0, 0, 0, 0, 0 });
        try std.testing.expect(run.record.mutations_occurred);
        try std.testing.expectEqual(@as(u32, 1), run.record.exploration_calls);
        try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
    }
}
