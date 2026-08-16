//! L2: the session-end verification obligation. A premature final answer
//! after an unverified mutation receives a bounded nudge with a recovery
//! protocol; a verified session finishes untouched; an exhausted budget
//! finishes honestly with obligation_unmet recorded. The obligation is a
//! task-agnostic process rule — these tests carry no benchmark content.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

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

const GateRecordSink = struct {
    records: usize = 0,
    enforced: bool = false,
    mutations_occurred: bool = false,
    obligation_met: bool = false,
    nudges: u8 = 255,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .verification_final_gate => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.mutations_occurred = record.mutations_occurred;
                self.obligation_met = record.obligation_met;
                self.nudges = record.nudges;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const GateRun = struct {
    requests: usize,
    nudge_request: ?[]u8,
    record: GateRecordSink,

    fn deinit(self: *GateRun, allocator: std.mem.Allocator) void {
        if (self.nudge_request) |bytes| allocator.free(bytes);
    }
};

fn greenCommand(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/pytest", .{root});
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "#!/bin/sh\nprintf '1 passed in 0.01s\\n'\n",
    });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o700) != 0) return error.SkipZigTest;
    return allocator.dupe(u8, path);
}

fn runGate(
    allocator: std.mem.Allocator,
    root: []const u8,
    enabled: bool,
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
    try conversation.appendText(.user, "repair the repository");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = GateRecordSink{};
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .system_prompt = "STABLE-PREFIX",
            .verification_final_gate = enabled,
            .tool_observer = record.sink(),
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    var nudge_request: ?[]u8 = null;
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (std.mem.indexOf(u8, request.body(), "[verification obligation]") != null) {
            nudge_request = try allocator.dupe(u8, request.body());
            break;
        }
    }
    return .{
        .requests = server.requestCount(),
        .nudge_request = nudge_request,
        .record = record,
    };
}

fn writeSse(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/patched.zig", .{root});
    defer allocator.free(path);
    const input = try std.fmt.allocPrint(
        allocator,
        "{{\"file_path\":\"{s}\",\"content\":\"test \\\"one\\\" {{}}\\n\"}}",
        .{path},
    );
    defer allocator.free(input);
    return toolSse(allocator, "write_1", "Write", input);
}

fn bashSse(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(allocator, "{{\"command\":\"{s}\"}}", .{command});
    defer allocator.free(input);
    return toolSse(allocator, "test_1", "Bash", input);
}

test "L2 unverified mutation nudges once and a green run then satisfies the obligation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const command = try greenCommand(a, root);
    defer a.free(command);
    const write = try writeSse(a, root);
    defer a.free(write);
    const bash = try bashSse(a, command);
    defer a.free(bash);
    // write → premature final (nudged) → green verification → final.
    var run = try runGate(a, root, true, &.{ write, END_TURN, bash, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), run.requests);
    try std.testing.expect(run.nudge_request != null);
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.enforced);
    try std.testing.expect(run.record.mutations_occurred);
    try std.testing.expect(run.record.obligation_met);
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
}

test "L2 a verified session finishes with zero nudges" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const command = try greenCommand(a, root);
    defer a.free(command);
    const write = try writeSse(a, root);
    defer a.free(write);
    const bash = try bashSse(a, command);
    defer a.free(bash);
    var run = try runGate(a, root, true, &.{ write, bash, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), run.requests);
    try std.testing.expect(run.nudge_request == null);
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.obligation_met);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
}

test "L2 exhausted nudges finish honestly with obligation_unmet recorded" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const write = try writeSse(a, root);
    defer a.free(write);
    // The model refuses to verify: write, then three premature finals.
    var run = try runGate(a, root, true, &.{ write, END_TURN, END_TURN, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), run.requests);
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.mutations_occurred);
    try std.testing.expect(!run.record.obligation_met);
    try std.testing.expectEqual(@as(u8, 2), run.record.nudges);
}

test "L2 disabled gate never nudges and never records" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const write = try writeSse(a, root);
    defer a.free(write);
    var run = try runGate(a, root, false, &.{ write, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), run.requests);
    try std.testing.expect(run.nudge_request == null);
    try std.testing.expectEqual(@as(usize, 0), run.record.records);
}

test "L2 observe-only records the outcome and never touches the conversation" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const write = try writeSse(a, root);
    defer a.free(write);
    var server = try harness.MockServer.startCassette(&.{ write, END_TURN }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "repair the repository");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = GateRecordSink{};
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .system_prompt = "STABLE-PREFIX",
            .verification_final_observe = true,
            .tool_observer = record.sink(),
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    // No nudge: the unverified final finished untouched in two requests.
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        try std.testing.expect(
            std.mem.indexOf(u8, request.body(), "[verification obligation]") == null,
        );
    }
    // But the outcome was recorded honestly, witnessed as not enforced.
    try std.testing.expectEqual(@as(usize, 1), record.records);
    try std.testing.expect(!record.enforced);
    try std.testing.expect(record.mutations_occurred);
    try std.testing.expect(!record.obligation_met);
    try std.testing.expectEqual(@as(u8, 0), record.nudges);
}
