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
    tier1: u32 = 0,
    tier2: u32 = 0,
    redundant: u32 = 255,
    closure_tier: u8 = 255,
    reopened: u32 = 0,
    known_failing: bool = false,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .verification_final_gate => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.mutations_occurred = record.mutations_occurred;
                self.obligation_met = record.obligation_met;
                self.nudges = record.nudges;
                self.tier1 = record.tier1_verifications;
                self.tier2 = record.tier2_verifications;
                self.redundant = record.redundant_verifications;
                self.closure_tier = record.final_closure_tier;
                self.reopened = record.reopened_after_verification;
                self.known_failing = record.known_failing;
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
    caution_request: ?[]u8,
    record: GateRecordSink,

    fn deinit(self: *GateRun, allocator: std.mem.Allocator) void {
        if (self.nudge_request) |bytes| allocator.free(bytes);
        if (self.caution_request) |bytes| allocator.free(bytes);
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
    var caution_request: ?[]u8 = null;
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (nudge_request == null and
            std.mem.indexOf(u8, request.body(), "[verification obligation]") != null)
        {
            nudge_request = try allocator.dupe(u8, request.body());
        }
        if (caution_request == null and
            std.mem.indexOf(u8, request.body(), "[verification freshness]") != null)
        {
            caution_request = try allocator.dupe(u8, request.body());
        }
    }
    return .{
        .requests = server.requestCount(),
        .nudge_request = nudge_request,
        .caution_request = caution_request,
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

test "L2 a mid-stream provider failure retries the same turn instead of dying" {
    // One transient stream drop destroyed an entire paired evaluation arm's
    // evidence twice in one day. The stream-error path fully discards the
    // partial turn, so a bounded re-issue of the identical request is
    // semantically clean. Headless enables 2 retries; default stays 0.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const write = try writeSse(a, root);
    defer a.free(write);
    // Response #1 (index 1) is cut mid-body; the retry replays it complete.
    var server = try harness.MockServer.startCassetteMidStreamCut(
        &.{ write, END_TURN, END_TURN },
        1,
    );
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
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .system_prompt = "STABLE-PREFIX",
            .max_stream_turn_retries = 2,
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        a,
    );
    // Turn 1: Write. Turn 2: cut mid-stream → retried → complete END_TURN.
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
}

test "L2 zero-retry default preserves the api_error surface" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const write = try writeSse(a, root);
    defer a.free(write);
    var server = try harness.MockServer.startCassetteMidStreamCut(
        &.{ write, END_TURN, END_TURN },
        1,
    );
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
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 8,
            .system_prompt = "STABLE-PREFIX",
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
}

fn probeCommand(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    // A validating computation that is not a canonical test runner: it
    // consumes its argument and exits 0. Mirrors the inline-probe /
    // pipeline-re-run idioms observed in real trials.
    const path = try std.fmt.allocPrint(allocator, "{s}/check", .{root});
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "#!/bin/sh\ntest -f \"$1\"\n",
    });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o700) != 0) return error.SkipZigTest;
    return allocator.dupe(u8, path);
}

fn redCommand(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    // Canonical test-runner shape (basename pytest) that always fails.
    const dir = try std.fmt.allocPrint(allocator, "{s}/red", .{root});
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(std.testing.io, dir) catch {};
    const path = try std.fmt.allocPrint(allocator, "{s}/pytest", .{dir});
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = "#!/bin/sh\nprintf '1 failed in 0.01s\\n'\nexit 1\n",
    });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o700) != 0) return error.SkipZigTest;
    return allocator.dupe(u8, path);
}

test "L2 tier-2 validating re-observation satisfies the gate" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const probe = try probeCommand(a, root);
    defer a.free(probe);
    const write = try writeSse(a, root);
    defer a.free(write);
    const probe_cmd = try std.fmt.allocPrint(a, "{s} {s}/patched.zig", .{ probe, root });
    defer a.free(probe_cmd);
    const bash = try bashSse(a, probe_cmd);
    defer a.free(bash);
    // write → premature final (nudged) → tier-2 probe → final.
    var run = try runGate(a, root, true, &.{ write, END_TURN, bash, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), run.requests);
    try std.testing.expect(run.record.obligation_met);
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
    try std.testing.expectEqual(@as(u32, 0), run.record.tier1);
    try std.testing.expectEqual(@as(u32, 1), run.record.tier2);
}

test "L2 known-failing state selects the honest-report nudge variant" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const red = try redCommand(a, root);
    defer a.free(red);
    const write = try writeSse(a, root);
    defer a.free(write);
    const bash = try bashSse(a, red);
    defer a.free(bash);
    // write → failing verification attempt → premature final (nudged with the
    // negative-evidence variant) → stubborn finals until nudges exhaust.
    var run = try runGate(a, root, true, &.{ write, bash, END_TURN, END_TURN, END_TURN });
    defer run.deinit(a);
    try std.testing.expect(run.record.known_failing);
    try std.testing.expect(!run.record.obligation_met);
    try std.testing.expect(run.nudge_request != null);
    try std.testing.expect(
        std.mem.indexOf(u8, run.nudge_request.?, "state the failing status") != null,
    );
}

test "L2 churn after a verified state injects one freshness caution and counts the reopen" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const command = try greenCommand(a, root);
    defer a.free(command);
    const write = try writeSse(a, root);
    defer a.free(write);
    // Identical content would re-observe as unchanged; churn needs a real
    // second mutation.
    const rewrite_input = try std.fmt.allocPrint(
        a,
        "{{\"file_path\":\"{s}/patched.zig\",\"content\":\"test \\\"two\\\" {{}}\\n\"}}",
        .{root},
    );
    defer a.free(rewrite_input);
    const rewrite = try toolSse(a, "write_2", "Write", rewrite_input);
    defer a.free(rewrite);
    const bash = try bashSse(a, command);
    defer a.free(bash);
    // write → verify → write again (churn: caution) → verify → final.
    var run = try runGate(a, root, true, &.{ write, bash, rewrite, bash, END_TURN });
    defer run.deinit(a);
    try std.testing.expect(run.record.obligation_met);
    try std.testing.expectEqual(@as(u32, 1), run.record.reopened);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
    try std.testing.expect(run.caution_request != null);
}

// ── PO-V2 M2:测试弱化候选信号(observe-only)────────────────────────────
// fstack-r2 两起同向事件:失败自测后把断言改弱迁就代码/自己输出。信号 =
// 失败验证之后、对测试分类文件的已实现编辑;只发候选事件,不判定不拦截。

const WeakeningSink = struct {
    candidates: usize = 0,
    hot: usize = 0, // assert_tokens_touched && last_verification_failed
    last_failed_flags: [8]bool = undefined,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .test_weakening_candidate => |record| {
                if (self.candidates < self.last_failed_flags.len)
                    self.last_failed_flags[self.candidates] = record.last_verification_failed;
                self.candidates += 1;
                if (record.assert_tokens_touched and record.last_verification_failed)
                    self.hot += 1;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

test "L2 a test-file edit after a failed verification emits a hot weakening candidate" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const tests_dir = try std.fmt.allocPrint(a, "{s}/tests", .{root});
    defer a.free(tests_dir);
    try cc.util_fs.mkdirParents(tests_dir);

    const test_path = try std.fmt.allocPrint(a, "{s}/tests/test_sample.py", .{root});
    defer a.free(test_path);
    const write_input = try std.fmt.allocPrint(
        a,
        "{{\"file_path\":\"{s}\",\"content\":\"def test_a():\\n    assert 1 == 1\\n\"}}",
        .{test_path},
    );
    defer a.free(write_input);
    const write_test = try toolSse(a, "w1", "Write", write_input);
    defer a.free(write_test);
    const fail_verify = try bashSse(a, "pytest");
    defer a.free(fail_verify);
    const weaken_input = try std.fmt.allocPrint(
        a,
        "{{\"file_path\":\"{s}\",\"content\":\"def test_a():\\n    assert True\\n\"}}",
        .{test_path},
    );
    defer a.free(weaken_input);
    const weaken = try toolSse(a, "w2", "Write", weaken_input);
    defer a.free(weaken);

    var server = try harness.MockServer.startCassette(
        &.{ write_test, fail_verify, weaken, END_TURN },
        0,
    );
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
    var record = WeakeningSink{};
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
    // 两次测试文件写:第一次在任何验证之前(last_failed=false),第二次在
    // 失败的 pytest 之后(last_failed=true 且触碰 assert → hot)。
    try std.testing.expectEqual(@as(usize, 2), record.candidates);
    try std.testing.expectEqual(@as(usize, 1), record.hot);
    try std.testing.expect(!record.last_failed_flags[0]);
    try std.testing.expect(record.last_failed_flags[1]);
}


// PO-V2 M4(observe 传感器):义务闭合后的再验证 = "绿灯重跑"计数;
// 闭合证据级记录最终一次闭合靠的层(1=tier1 测试命令)。
// fstack-r2 实测:freshness nudge 三次触发全部只产生已绿检查的重跑,
// 现行事件对此不可见——本传感器让它可见(只计数,不判定)。
test "L2 a green rerun after closure counts as redundant and closure tier is recorded" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const command = try greenCommand(a, root);
    defer a.free(command);
    const write = try writeSse(a, root);
    defer a.free(write);
    const bash_close = try bashSse(a, command);
    defer a.free(bash_close);
    const rerun_input = try std.fmt.allocPrint(a, "{{\"command\":\"{s}\"}}", .{command});
    defer a.free(rerun_input);
    const bash_rerun = try toolSse(a, "test_2", "Bash", rerun_input);
    defer a.free(bash_rerun);
    // write → green close(tier1) → green rerun(redundant) → final.
    var run = try runGate(a, root, true, &.{ write, bash_close, bash_rerun, END_TURN });
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.obligation_met);
    try std.testing.expectEqual(@as(u32, 2), run.record.tier1);
    try std.testing.expectEqual(@as(u32, 1), run.record.redundant);
    try std.testing.expectEqual(@as(u8, 1), run.record.closure_tier);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
}
