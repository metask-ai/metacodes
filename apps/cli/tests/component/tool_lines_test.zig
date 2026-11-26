const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const region_harness = @import("region_harness.zig");

const gpa = std.testing.allocator;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"all done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn toolUseSse(a: std.mem.Allocator, name: []const u8, input_json: []const u8) ![]u8 {
    const partial = try std.json.Stringify.valueAlloc(a, input_json, .{});
    defer a.free(partial);
    return std.fmt.allocPrint(
        a,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_line\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ name, partial },
    );
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
    root: []const u8,
    guards: [4]EnvGuard,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,
    server: *harness.MockServer,

    fn init(self: *Fixture, bodies: []const []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..len];
        const home_z = try gpa.dupeZ(u8, self.root);
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

    fn path(self: *const Fixture, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.root, name });
    }

    fn drawnTurn(self: *Fixture) ![]u8 {
        const app = self.app;
        const t = try region_harness.Term.create(gpa, .{ .rows = 30, .cols = 110 });
        defer t.destroy();
        t.region.enterGenerating(app, null);
        var tui = cc.tui_backend.TuiBackend.init(&t.region);
        tui.theme = &t.region.theme;
        tui.alloc = gpa;
        const backend = tui.backend();
        try app.conversation.appendText(.user, "go");
        var options = cc.session_service.buildRunOptions(app, null);
        options.max_turns = 3;
        const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
        t.region.leaveGenerating(app);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), self.server.requestCount());
        return t.transcriptAlloc(.{});
    }
};

fn expectLine(screen: []const u8, line: []const u8) !void {
    var rows = std.mem.splitScalar(u8, screen, '\n');
    while (rows.next()) |row| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, row, " "), line)) return;
    }
    std.debug.print("no row equal to {s}\nscreen:\n{s}\n", .{ line, screen });
    return error.TestExpectedEqual;
}

fn expectRowContaining(screen: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, screen, needle) != null) return;
    std.debug.print("no row containing {s}\nscreen:\n{s}\n", .{ needle, screen });
    return error.TestExpectedEqual;
}

test "L2 an ApplyPatch call reaches the TUI as a tool line naming the file, then the counts and the diff" {
    var tmp_probe = std.testing.tmpDir(.{});
    var probe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const probe_len = try tmp_probe.dir.realPath(std.testing.io, &probe_buffer);
    const target = try std.fmt.allocPrint(gpa, "{s}/notes.txt", .{probe_buffer[0..probe_len]});
    defer gpa.free(target);
    defer tmp_probe.cleanup();

    const patch = try std.fmt.allocPrint(gpa, "*** Begin Patch\n*** Add File: {s}\n+hello from the patch\n*** End Patch", .{target});
    defer gpa.free(patch);
    const input = try std.json.Stringify.valueAlloc(gpa, .{ .patch = patch }, .{});
    defer gpa.free(input);
    const call = try toolUseSse(gpa, "ApplyPatch", input);
    defer gpa.free(call);
    const bodies = [_][]const u8{ call, FINAL_SSE };

    var fx: Fixture = undefined;
    try fx.init(&bodies);
    defer fx.deinit();
    const screen = try fx.drawnTurn();
    defer gpa.free(screen);

    const written = try tmp_probe.dir.readFileAlloc(std.testing.io, "notes.txt", gpa, .limited(1 << 16));
    defer gpa.free(written);
    try std.testing.expectEqualStrings("hello from the patch\n", written);

    try expectLine(screen, "⏺ ApplyPatch(notes.txt)");
    try expectLine(screen, "  ⎿  Applied patch: 1 added, 0 modified, 0 deleted");
    try expectRowContaining(screen, "hello from the patch");
    try std.testing.expect(std.mem.indexOf(u8, screen, "gitDiff") == null);
    const tool_row = std.mem.indexOf(u8, screen, "⏺ ApplyPatch").?;
    const reply_row = std.mem.indexOf(u8, screen, "all done") orelse return error.TestExpectedEqual;
    try std.testing.expect(tool_row < reply_row);
}
