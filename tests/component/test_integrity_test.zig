//! L2: the test integrity obligation. Tests that existed when the run started
//! are compared with the end state at end-of-turn boundaries; enforce mode
//! sends one message when the model stops with them rewritten, deleted or
//! disabled (restore them, or quote the request), observe mode only records,
//! and either way the end state reaches the caller's report. Appending tests,
//! the model's own new tests and the user's earlier edits never count. The
//! sensor reads the workspace, so a Bash rewrite and a commit are seen too.
//! Composed with the host check gate, the message comes first and the check
//! then judges the restored tests. Task-agnostic process rules — these tests
//! carry no benchmark content. Formal model:
//! control-plane/lean/MetaCodesControl/TestIntegrity.lean.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const ti = cc.test_integrity;
const gate_mod = cc.check_gate;
const Obs = cc.tools.tool_observation;

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

fn bashSse(allocator: std.mem.Allocator, id: []const u8, command: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"command\":");
    try std.json.Stringify.encodeJsonString(command, .{}, &aw.writer);
    try aw.writer.writeByte('}');
    const input = try aw.toOwnedSlice();
    defer allocator.free(input);
    return toolSse(allocator, id, "Bash", input);
}

const RecordSink = struct {
    records: usize = 0,
    enforced: bool = false,
    coverage: Obs.TestIntegrityCoverage = .git_failed,
    scans: u32 = 0,
    nudges: u8 = 255,
    outcome: Obs.TestIntegrityOutcome = .clean,
    files_weakened: u32 = 999,
    files_weakened_peak: u32 = 999,
    removed_lines: u32 = 999,
    check_records: usize = 0,
    check_checks: u8 = 255,
    check_continuations: u8 = 255,
    check_final: Obs.CheckGateVerdict = .not_run,

    fn emit(raw: *anyopaque, event: Obs.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .test_integrity => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.coverage = record.coverage;
                self.scans = record.scans;
                self.nudges = record.nudges;
                self.outcome = record.outcome;
                self.files_weakened = record.files_weakened;
                self.files_weakened_peak = record.files_weakened_peak;
                self.removed_lines = record.removed_lines;
            },
            .check_gate => |record| {
                self.check_records += 1;
                self.check_checks = record.checks;
                self.check_continuations = record.continuations;
                self.check_final = record.final_verdict;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) Obs.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const MAX_REQUESTS = 10;

const Run = struct {
    requests: usize,
    /// Marker occurrences per request body. An injected message stays in the
    /// conversation, so request N carries every one injected before it.
    markers: [MAX_REQUESTS]usize = [_]usize{0} ** MAX_REQUESTS,
    check_markers: [MAX_REQUESTS]usize = [_]usize{0} ** MAX_REQUESTS,
    last_body: ?[]u8 = null,
    record: RecordSink,
    report: ti.Report,

    fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        if (self.last_body) |bytes| allocator.free(bytes);
        self.report.deinit();
    }

    fn expectMarkers(self: *const Run, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| try std.testing.expectEqual(count, self.markers[index]);
    }

    fn expectCheckMarkers(self: *const Run, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| try std.testing.expectEqual(count, self.check_markers[index]);
    }
};

const RunConfig = struct {
    mode: ?ti.Mode = null,
    gate: ?gate_mod.Options = null,
};

fn runIntegrity(
    allocator: std.mem.Allocator,
    root: []const u8,
    config: RunConfig,
    responses: []const []const u8,
) !Run {
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
    try conversation.appendText(.user, "make the change");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var record = RecordSink{};
    var report = ti.Report.init(allocator);
    errdefer report.deinit();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 16,
            .system_prompt = "STABLE-PREFIX",
            .check_gate = config.gate,
            .test_integrity = if (config.mode) |mode| .{ .mode = mode, .report = &report } else null,
            .tool_observer = record.sink(),
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    var out = Run{ .requests = server.requestCount(), .record = record, .report = report };
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (index < MAX_REQUESTS) {
            out.markers[index] = std.mem.count(u8, request.body(), ti.MARKER);
            out.check_markers[index] = std.mem.count(u8, request.body(), gate_mod.MARKER);
        }
        if (server.requestAt(index + 1) == null) out.last_body = try allocator.dupe(u8, request.body());
    }
    return out;
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

fn writeFile(allocator: std.mem.Allocator, root: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

fn runGit(a: std.mem.Allocator, cwd: []const u8, args: []const []const u8) bool {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |item| if (item) |z| a.free(std.mem.span(z));
        argv.deinit(a);
    }
    argv.append(a, (a.dupeZ(u8, "/usr/bin/env") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, "git") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, "-C") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, cwd) catch return false).ptr) catch return false;
    for (args) |arg| argv.append(a, (a.dupeZ(u8, arg) catch return false).ptr) catch return false;
    argv.append(a, null) catch return false;
    const out = cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 15_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, null) catch return false;
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    return out.exit_code == 0;
}

const CALC = "def add(a, b):\n    return a + b\n";
const TEST_CALC = "from calc import add\n\n\ndef test_add():\n    assert add(1, 2) == 3\n";
const TEST_CALC_RIGGED = "from calc import add\n\n\ndef test_add():\n    assert add(1, 2) == 4\n";
const TEST_CALC_APPENDED = TEST_CALC ++ "\n\ndef test_add_negative():\n    assert add(-1, -2) == -3\n";

/// A repository whose HEAD holds `calc.py` and `tests/test_calc.py`.
fn seedRepo(a: std.mem.Allocator, root: []const u8) !void {
    try writeFile(a, root, "calc.py", CALC);
    try writeFile(a, root, "tests/test_calc.py", TEST_CALC);
    if (!runGit(a, root, &.{ "init", "-q" })) return error.SkipZigTest;
    _ = runGit(a, root, &.{ "config", "user.email", "test@metacodes.local" });
    _ = runGit(a, root, &.{ "config", "user.name", "metacodes-test" });
    _ = runGit(a, root, &.{ "add", "-A" });
    if (!runGit(a, root, &.{ "commit", "-q", "-m", "seed" })) return error.SkipZigTest;
}

fn countObjects(a: std.mem.Allocator, root: []const u8) !usize {
    const objects = try std.fmt.allocPrint(a, "{s}/.git/objects", .{root});
    defer a.free(objects);
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, objects, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

test "L2 test integrity: a rewritten assertion earns one message, and restoring it ends the run clean" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX git fixture
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const objects_before = try countObjects(a, root);
    const rigged = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_RIGGED);
    defer a.free(rigged);
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const restore = try writeSse(a, "write_2", root, "tests/test_calc.py", TEST_CALC);
    defer a.free(restore);
    const done_2 = try endTurn(a, "done_2", "restored");
    defer a.free(done_2);
    const responses = [_][]const u8{ rigged, done_1, restore, done_2 };
    var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
    defer run.deinit(a);
    // The message rides request 3 and stays in the history.
    try run.expectMarkers(&.{ 0, 0, 1, 1 });
    const body = run.last_body.?;
    try std.testing.expect(std.mem.indexOf(u8, body, "tests/test_calc.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "- assert add(1, 2) == 3") != null); // the removed line
    try std.testing.expectEqual(@as(usize, 1), run.record.records);
    try std.testing.expect(run.record.enforced);
    try std.testing.expectEqual(Obs.TestIntegrityCoverage.git, run.record.coverage);
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.restored, run.record.outcome);
    try std.testing.expectEqual(@as(u32, 0), run.record.files_weakened);
    try std.testing.expectEqual(@as(u32, 1), run.record.files_weakened_peak);
    try std.testing.expectEqual(@as(u32, 2), run.record.scans);
    // The user-facing report is filled and has nothing left to say.
    try std.testing.expect(run.report.filled);
    try std.testing.expectEqual(ti.Outcome.restored, run.report.outcome);
    try std.testing.expect((try run.report.renderNotice(a)) == null);
    // The sensor never writes to the repository.
    try std.testing.expectEqual(objects_before, try countObjects(a, root));
}

test "L2 test integrity: appending tests to an existing file is not weakening" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const appended = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_APPENDED);
    defer a.free(appended);
    const done = try endTurn(a, "done", "added a test");
    defer a.free(done);
    const responses = [_][]const u8{ appended, done };
    var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.clean, run.record.outcome);
    try std.testing.expectEqual(@as(u32, 0), run.record.files_weakened_peak);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
}

test "L2 test integrity: the model's own new test file is never counted" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const created = try writeSse(a, "write_1", root, "tests/test_new.py", "def test_x():\n    assert 1 == 1\n");
    defer a.free(created);
    const rewritten = try writeSse(a, "write_2", root, "tests/test_new.py", "def test_x():\n    assert 2 == 2\n");
    defer a.free(rewritten);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ created, rewritten, done };
    var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0, 0 });
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.clean, run.record.outcome);
}

test "L2 test integrity: a Bash rewrite that is committed is still seen, and a cited answer is kept_cited" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const rewrite = try bashSse(a, "bash_1", "printf 'from calc import add\\n\\n\\ndef test_add():\\n    assert add(1, 2) == 4\\n' > tests/test_calc.py && " ++
        "git -c user.email=t@t -c user.name=t commit -qam rigged");
    defer a.free(rewrite);
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const done_2 = try endTurn(a, "done_2", "The request asks for this: tests/test_calc.py now expects 4.");
    defer a.free(done_2);
    const responses = [_][]const u8{ rewrite, done_1, done_2 };
    var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0, 1 });
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.kept_cited, run.record.outcome);
    try std.testing.expectEqual(@as(u32, 1), run.record.files_weakened);
    // The user still hears about it from the host.
    const notice = (try run.report.renderNotice(a)).?;
    defer a.free(notice);
    try std.testing.expect(std.mem.indexOf(u8, notice, "tests/test_calc.py") != null);
}

test "L2 test integrity: after the one message a second stop finishes; an answer that names nothing is kept_silent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const rigged = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_RIGGED);
    defer a.free(rigged);
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const done_2 = try endTurn(a, "done_2", "still done");
    defer a.free(done_2);
    const responses = [_][]const u8{ rigged, done_1, done_2 };
    var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0, 1 });
    try std.testing.expectEqual(@as(u8, 1), run.record.nudges);
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.kept_silent, run.record.outcome);
}

test "L2 test integrity: the user's uncommitted test edits are the baseline, not the model's" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    // The user changed the test before the run (not committed).
    try writeFile(a, root, "tests/test_calc.py", TEST_CALC_APPENDED);
    {
        // The run leaves the user's edit alone: nothing to report.
        const code = try writeSse(a, "write_1", root, "calc.py", CALC ++ "\n\ndef sub(a, b):\n    return a - b\n");
        defer a.free(code);
        const done = try endTurn(a, "done", "done");
        defer a.free(done);
        const responses = [_][]const u8{ code, done };
        var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
        defer run.deinit(a);
        try run.expectMarkers(&.{ 0, 0 });
        try std.testing.expectEqual(Obs.TestIntegrityOutcome.clean, run.record.outcome);
    }
    {
        // The run removes the test the user just added: that is weakening.
        const rigged = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC);
        defer a.free(rigged);
        const done = try endTurn(a, "done", "done");
        defer a.free(done);
        const restore = try writeSse(a, "write_2", root, "tests/test_calc.py", TEST_CALC_APPENDED);
        defer a.free(restore);
        const done_2 = try endTurn(a, "done_2", "restored");
        defer a.free(done_2);
        const responses = [_][]const u8{ rigged, done, restore, done_2 };
        var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
        defer run.deinit(a);
        try run.expectMarkers(&.{ 0, 0, 1, 1 });
        try std.testing.expect(std.mem.indexOf(u8, run.last_body.?, "- assert add(-1, -2) == -3") != null);
        try std.testing.expectEqual(Obs.TestIntegrityOutcome.restored, run.record.outcome);
    }
}

test "L2 test integrity: observe mode never messages but reports the end state" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const deleted = try bashSse(a, "bash_1", "rm tests/test_calc.py");
    defer a.free(deleted);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ deleted, done };
    var run = try runIntegrity(a, root, .{ .mode = .observe }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expect(!run.record.enforced);
    try std.testing.expectEqual(@as(u8, 0), run.record.nudges);
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.observed, run.record.outcome);
    try std.testing.expectEqual(@as(usize, 1), run.report.files.items.len);
    try std.testing.expectEqual(ti.FileKind.deleted, run.report.files.items[0].kind);
}

/// Pinned check: passes only when result.txt matches the expectation file;
/// every run leaves a mark.
const CHECK = "echo run >> check-runs.log; cmp -s result.txt tests/test_expect.txt";

test "L2 test integrity: weakened tests are messaged before the check runs, and the check then judges the restored tests" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try writeFile(a, root, "tests/test_expect.txt", "TOTAL=42\n");
    if (!runGit(a, root, &.{ "init", "-q" })) return error.SkipZigTest;
    _ = runGit(a, root, &.{ "config", "user.email", "test@metacodes.local" });
    _ = runGit(a, root, &.{ "config", "user.name", "metacodes-test" });
    _ = runGit(a, root, &.{ "add", "-A" });
    if (!runGit(a, root, &.{ "commit", "-q", "-m", "seed" })) return error.SkipZigTest;
    const wrong = try writeSse(a, "write_1", root, "result.txt", "TOTAL=41\n");
    defer a.free(wrong);
    const rigged = try writeSse(a, "write_2", root, "tests/test_expect.txt", "TOTAL=41\n");
    defer a.free(rigged);
    const done_1 = try endTurn(a, "done_1", "done");
    defer a.free(done_1);
    const restore = try writeSse(a, "write_3", root, "tests/test_expect.txt", "TOTAL=42\n");
    defer a.free(restore);
    const done_2 = try endTurn(a, "done_2", "restored");
    defer a.free(done_2);
    const right = try writeSse(a, "write_4", root, "result.txt", "TOTAL=42\n");
    defer a.free(right);
    const done_3 = try endTurn(a, "done_3", "fixed");
    defer a.free(done_3);
    const responses = [_][]const u8{ wrong, rigged, done_1, restore, done_2, right, done_3 };
    var run = try runIntegrity(a, root, .{
        .mode = .enforce,
        .gate = .{ .command = CHECK, .mode = .enforce, .max_continuations = 3 },
    }, &responses);
    defer run.deinit(a);
    // Boundary 1: integrity message, no check. Boundary 2: restored tests,
    // the check fails and continues. Boundary 3: the check passes.
    try run.expectMarkers(&.{ 0, 0, 0, 1, 1, 1, 1 });
    try run.expectCheckMarkers(&.{ 0, 0, 0, 0, 0, 1, 1 });
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.restored, run.record.outcome);
    try std.testing.expectEqual(@as(usize, 1), run.record.check_records);
    try std.testing.expectEqual(@as(u8, 2), run.record.check_checks);
    try std.testing.expectEqual(@as(u8, 1), run.record.check_continuations);
    try std.testing.expectEqual(Obs.CheckGateVerdict.passed, run.record.check_final);
}

test "L2 check gate: a pass after only appending tests is not tainted" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const appended = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_APPENDED);
    defer a.free(appended);
    const done = try endTurn(a, "done", "added a test");
    defer a.free(done);
    const responses = [_][]const u8{ appended, done };
    // The check gate alone: the sensor still runs for its taint rule.
    var run = try runIntegrity(a, root, .{ .gate = .{ .command = "true", .mode = .enforce } }, &responses);
    defer run.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), run.record.records);
    try std.testing.expectEqual(Obs.CheckGateVerdict.passed, run.record.check_final);
    // The same run with a rewritten assertion is tainted.
    const rigged = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_RIGGED);
    defer a.free(rigged);
    const responses_2 = [_][]const u8{ rigged, done };
    var tainted = try runIntegrity(a, root, .{ .gate = .{ .command = "true", .mode = .enforce } }, &responses_2);
    defer tainted.deinit(a);
    try std.testing.expectEqual(Obs.CheckGateVerdict.tainted, tainted.record.check_final);
}

test "L2 test integrity: outside a git repository the sensor has no baseline and never messages" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    // std.testing.tmpDir lives inside this repository's .zig-cache, where git
    // would find the enclosing checkout; use the system temp directory.
    const root = try std.fmt.allocPrint(a, "{s}/metacodes-ti-nogit-{d}", .{ @import("platform").paths.tempDir(), @import("platform").process.currentPid() });
    defer a.free(root);
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try writeFile(a, root, "tests/test_calc.py", TEST_CALC);
    const rigged = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_RIGGED);
    defer a.free(rigged);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ rigged, done };
    var run = try runIntegrity(a, root, .{ .mode = .enforce }, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expectEqual(Obs.TestIntegrityCoverage.no_git, run.record.coverage);
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.clean, run.record.outcome);
    try std.testing.expect((try run.report.renderNotice(a)) == null);
}

test "L2 test integrity: a disabled obligation never records or reports" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    const rigged = try writeSse(a, "write_1", root, "tests/test_calc.py", TEST_CALC_RIGGED);
    defer a.free(rigged);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ rigged, done };
    var run = try runIntegrity(a, root, .{}, &responses);
    defer run.deinit(a);
    try run.expectMarkers(&.{ 0, 0 });
    try std.testing.expectEqual(@as(usize, 0), run.record.records);
    try std.testing.expect(!run.report.filled);
}

test "L2 check gate: a test file created by Bash and then edited is the model's own, not unverified" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shell check
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try seedRepo(a, root);
    // Bash creates the file, so the file tool's first record of it is a modification.
    const created = try bashSse(a, "bash_1", "printf 'def test_sub():\\n    assert 1 == 1\\n' > tests/test_sub.py");
    defer a.free(created);
    const edited = try writeSse(a, "write_1", root, "tests/test_sub.py", "def test_sub():\n    assert 2 - 1 == 1\n");
    defer a.free(edited);
    const done = try endTurn(a, "done", "done");
    defer a.free(done);
    const responses = [_][]const u8{ created, edited, done };
    var run = try runIntegrity(a, root, .{ .mode = .observe, .gate = .{ .command = "true", .mode = .enforce } }, &responses);
    defer run.deinit(a);
    try std.testing.expectEqual(Obs.CheckGateVerdict.passed, run.record.check_final);
    try std.testing.expectEqual(Obs.TestIntegrityOutcome.clean, run.record.outcome);
}
