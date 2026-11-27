const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const region_harness = @import("region_harness.zig");

const gpa = std.testing.allocator;

const message_start = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";

fn thinkingOpen(comptime index: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_start\",\"index\":" ++ index ++ ",\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n";
}

fn thinkingDelta(comptime index: []const u8, comptime body: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_delta\",\"index\":" ++ index ++ ",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"" ++ body ++ "\"}}\n\n";
}

fn blockStop(comptime index: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_stop\",\"index\":" ++ index ++ "}\n\n";
}

fn thinking(comptime index: []const u8, comptime body: []const u8) []const u8 {
    return thinkingOpen(index) ++ thinkingDelta(index, body) ++ blockStop(index);
}

fn answerText(comptime index: []const u8, comptime body: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_start\",\"index\":" ++ index ++ ",\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":" ++ index ++ ",\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ body ++ "\"}}\n\n" ++
        blockStop(index);
}

fn readCall(comptime index: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_start\",\"index\":" ++ index ++ ",\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":" ++ index ++ ",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"file_path\\\":\\\"/definitely/not/there.txt\\\"}\"}}\n\n" ++
        blockStop(index);
}

fn finish(comptime stop_reason: []const u8) []const u8 {
    return "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"" ++ stop_reason ++ "\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try gpa.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            gpa.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    guards: [4]EnvGuard,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,
    server: *harness.MockServer,

    fn init(self: *Fixture, bodies: []const []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        const home_z = try gpa.dupeZ(u8, self.root_buffer[0..len]);
        defer gpa.free(home_z);
        self.guards = .{
            try EnvGuard.set("HOME", home_z.ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
            try EnvGuard.set("CODEX_HOME", null),
        };
        errdefer self.restoreEnv();

        self.server = try harness.MockServer.startCassette(bodies, 0);
        errdefer self.server.stop();
        const url = try self.server.urlOwned(gpa);
        defer gpa.free(url);

        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const url_z = try a.dupeZ(u8, url);
        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", url_z.ptr, "--model", "test-model" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        self.io_rt = @import("platform").signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn restoreEnv(self: *Fixture) void {
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
        self.server.stop();
        self.restoreEnv();
        self.tmp.cleanup();
    }

    fn drawnTurn(self: *Fixture, requests: usize) ![]u8 {
        const app = self.app;
        const t = try region_harness.Term.create(gpa, .{ .rows = 40, .cols = 100 });
        defer t.destroy();
        t.region.enterGenerating(app, null);
        var tui = cc.tui_backend.TuiBackend.init(&t.region);
        tui.theme = &t.region.theme;
        tui.alloc = gpa;
        tui.colorize = true;
        tui.show_retry = true;
        const backend = tui.backend();
        try app.conversation.appendText(.user, "go");
        var options = cc.session_service.buildRunOptions(app, null);
        options.max_turns = 3;
        const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
        t.region.leaveGenerating(app);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        try std.testing.expectEqual(requests, self.server.requestCount());
        return t.transcriptAlloc(.{});
    }
};

fn rowsStartingWith(screen: []const u8, start: []const u8, out: []usize) []usize {
    var n: usize = 0;
    var offset: usize = 0;
    var rows = std.mem.splitScalar(u8, screen, '\n');
    while (rows.next()) |row| {
        if (std.mem.startsWith(u8, row, start) and n < out.len) {
            out[n] = offset;
            n += 1;
        }
        offset += row.len + 1;
    }
    return out[0..n];
}

fn expectLine(screen: []const u8, line: []const u8) !usize {
    var offset: usize = 0;
    var rows = std.mem.splitScalar(u8, screen, '\n');
    while (rows.next()) |row| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, row, " "), line)) return offset;
        offset += row.len + 1;
    }
    std.debug.print("no row equal to {s}\nscreen:\n{s}\n", .{ line, screen });
    return error.TestExpectedEqual;
}

fn expectAbsent(screen: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, screen, needle) == null) return;
    std.debug.print("{s} should not be on the screen:\n{s}\n", .{ needle, screen });
    return error.TestUnexpectedResult;
}

const summary_start = "✻ Thought for ";

test "L2 thinking before the answer leaves one summary line in the scrollback, not the thinking" {
    const body = comptime message_start ++ thinking("0", "I should read the parser first.\\nThe tail is cut short.") ++ answerText("1", "The bug is fixed.") ++ finish("end_turn");
    var fx: Fixture = undefined;
    try fx.init(&.{body});
    defer fx.deinit();
    const screen = try fx.drawnTurn(1);
    defer gpa.free(screen);

    var found: [4]usize = undefined;
    const summaries = rowsStartingWith(screen, summary_start, &found);
    try std.testing.expectEqual(@as(usize, 1), summaries.len);
    const answer = try expectLine(screen, "⏺ The bug is fixed.");
    try std.testing.expect(summaries[0] < answer);
    try expectAbsent(screen, "read the parser first");
    try expectAbsent(screen, "The tail is cut short");
}

test "L2 thinking, a tool call, then thinking again: each thinking leaves its own summary line, in order" {
    const first = comptime message_start ++ thinking("0", "look before touching") ++ readCall("1") ++ finish("tool_use");
    const second = comptime message_start ++ thinking("0", "now the second look") ++ answerText("1", "All done.") ++ finish("end_turn");
    var fx: Fixture = undefined;
    try fx.init(&.{ first, second });
    defer fx.deinit();
    const screen = try fx.drawnTurn(2);
    defer gpa.free(screen);

    var found: [4]usize = undefined;
    const summaries = rowsStartingWith(screen, summary_start, &found);
    try std.testing.expectEqual(@as(usize, 2), summaries.len);
    const tool = std.mem.indexOfPos(u8, screen, summaries[0], "Read") orelse return error.TestExpectedEqual;
    const answer = try expectLine(screen, "⏺ All done.");
    try std.testing.expect(summaries[0] < tool and tool < summaries[1] and summaries[1] < answer);
    try expectAbsent(screen, "look before touching");
    try expectAbsent(screen, "the second look");
}

test "L2 a reply that only thinks still leaves its summary line" {
    const body = comptime message_start ++ thinking("0", "nothing to say yet") ++ finish("end_turn");
    var fx: Fixture = undefined;
    try fx.init(&.{body});
    defer fx.deinit();
    const screen = try fx.drawnTurn(1);
    defer gpa.free(screen);

    var found: [4]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), rowsStartingWith(screen, summary_start, &found).len);
    try expectAbsent(screen, "nothing to say yet");
}

test "L2 a reply that breaks off while thinking: its summary, the discarded notice, then the re-issue's summary and answer" {
    const broken = comptime message_start ++ thinkingOpen("0") ++ thinkingDelta("0", "halfway through a thought") ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"boom\"}}\n\n";
    const good = comptime message_start ++ thinking("0", "a whole thought") ++ answerText("1", "clean answer") ++ finish("end_turn");
    var fx: Fixture = undefined;
    try fx.init(&.{ broken, good });
    defer fx.deinit();
    const screen = try fx.drawnTurn(2);
    defer gpa.free(screen);

    var found: [4]usize = undefined;
    const summaries = rowsStartingWith(screen, summary_start, &found);
    try std.testing.expectEqual(@as(usize, 2), summaries.len);
    const notice = std.mem.indexOf(u8, screen, "The reply above broke off") orelse return error.TestExpectedEqual;
    const answer = try expectLine(screen, "⏺ clean answer");
    try std.testing.expect(summaries[0] < notice and notice < summaries[1] and summaries[1] < answer);
    try expectAbsent(screen, "halfway through a thought");
    try expectAbsent(screen, "a whole thought");
}

test "live thinking shows its last three rows above the spinner, then becomes one dim line with its seconds" {
    const fx = try region_harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 60 });
    defer t.destroy();
    t.region.enterGenerating(fx.app, null);
    t.region.writeGenThinking("first line of the thought\nsecond line\n", 10_000);
    t.region.writeGenThinking("third line\nfourth line", 11_000);

    const live = try t.transcriptAlloc(.{});
    defer gpa.free(live);
    const top = try expectLine(live, "✻ second line");
    _ = try expectLine(live, "  third line");
    _ = try expectLine(live, "  fourth line");
    try expectAbsent(live, "first line of the thought");
    try std.testing.expect(top < (std.mem.indexOf(u8, live, "❯") orelse return error.TestExpectedEqual));

    t.region.endGenThinking(15_400);
    t.region.endGenThinking(16_000);
    t.region.leaveGenerating(fx.app);
    const after = try t.transcriptAlloc(.{});
    defer gpa.free(after);
    _ = try expectLine(after, "✻ Thought for 5s");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "Thought for"));
    try expectAbsent(after, "fourth line");
    const dim_line = try std.fmt.allocPrint(gpa, "{s}✻ Thought for 5s{s}", .{ t.region.theme.dim, t.region.theme.reset });
    defer gpa.free(dim_line);
    try std.testing.expect(std.mem.indexOf(u8, t.written(), dim_line) != null);
}

test "a reply that ends while still thinking leaves its summary when the reply is over" {
    const fx = try region_harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 60 });
    defer t.destroy();
    t.region.enterGenerating(fx.app, null);
    t.region.writeGenThinking("still going", 0);
    t.region.leaveGenerating(fx.app);
    const after = try t.transcriptAlloc(.{});
    defer gpa.free(after);
    var found: [4]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), rowsStartingWith(after, summary_start, &found).len);
    try expectAbsent(after, "still going");
}

test "a resumed session replays its thinking as one summary line without seconds, and keeps the answer" {
    const fx = try region_harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 60 });
    defer t.destroy();
    var conv = cc.conversation.Conversation.init(gpa);
    defer conv.deinit();
    try conv.appendText(.user, "fix it");
    const blocks = try gpa.alloc(cc.message.Block, 2);
    blocks[0] = .{ .thinking = try gpa.dupe(u8, "the private reasoning") };
    blocks[1] = .{ .text = try gpa.dupe(u8, "Fixed it.") };
    try conv.append(.{ .role = .assistant, .blocks = blocks });

    try cc.repl_replay.replay(gpa, .{ .region = &t.region, .theme = &t.region.theme, .verbose = false }, &conv);
    const screen = try t.transcriptAlloc(.{});
    defer gpa.free(screen);
    const summary = try expectLine(screen, "✻ Thought");
    const answer = try expectLine(screen, "⏺ Fixed it.");
    try std.testing.expect(summary < answer);
    try expectAbsent(screen, "the private reasoning");
}
