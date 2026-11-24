const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn commentedWriteSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var input: std.Io.Writer.Allocating = .init(allocator);
    defer input.deinit();
    try input.writer.writeAll("{\"file_path\":");
    try std.json.Stringify.encodeJsonString(path, .{}, &input.writer);
    try input.writer.writeAll(",\"content\":\"x = 1  # set x\\n\"}");
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(input.written(), .{}, &escaped.writer);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{escaped.written()},
    );
}

fn chdirTo(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (pfs.chdir(z.ptr) != 0) return error.ChdirFailed;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    codex_guard: EnvGuard,
    probe_guard: EnvGuard,
    autostart_guard: EnvGuard,
    server: *harness.MockServer,
    previous_cwd: []u8,
    target: [:0]const u8,
    responses: [2][]const u8,
    app: *cc.app_module.App,

    fn setup(self: *Fixture) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);

        self.arena = std.heap.ArenaAllocator.init(a);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        const root = try allocator.dupe(u8, root_buffer[0..len]);
        const home = try std.fs.path.join(allocator, &.{ root, "home" });
        const repo = try std.fs.path.join(allocator, &.{ root, "repo" });
        self.target = try std.fs.path.joinZ(allocator, &.{ repo, "new.py" });
        try self.tmp.dir.createDirPath(std.testing.io, "repo/.git");
        try self.tmp.dir.createDirPath(std.testing.io, "home/.claude/skills/forkwriter");
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "home/.claude/skills/forkwriter/SKILL.md",
            .data = "---\nname: forkwriter\ndescription: writes one file\ncontext: fork\n---\nWrite the file.\n",
        });

        self.home_guard = try EnvGuard.set(a, "HOME", (try allocator.dupeZ(u8, home)).ptr);
        errdefer self.home_guard.restore();
        self.codex_guard = try EnvGuard.set(a, "CODEX_HOME", (try std.fs.path.joinZ(allocator, &.{ home, ".codex" })).ptr);
        errdefer self.codex_guard.restore();
        self.probe_guard = try EnvGuard.set(a, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();
        self.autostart_guard = try EnvGuard.set(a, "METACODES_KG_AUTOSTART", "0");
        errdefer self.autostart_guard.restore();

        self.responses = .{ try commentedWriteSse(allocator, self.target), FINAL_SSE };
        self.server = try harness.MockServer.startCassette(&self.responses, 0);
        errdefer self.server.stop();
        const url_z = try allocator.dupeZ(u8, try self.server.urlOwned(allocator));
        const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", "test-model", "--permission", "bypassPermissions", "--preview" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        self.previous_cwd = try cc.util_fs.getCwd(a);
        errdefer a.free(self.previous_cwd);
        try chdirTo(repo);
        errdefer chdirTo(self.previous_cwd) catch {};

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        chdirTo(self.previous_cwd) catch {};
        std.testing.allocator.free(self.previous_cwd);
        self.server.stop();
        self.autostart_guard.restore();
        self.probe_guard.restore();
        self.codex_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn expectWriteRefused(self: *Fixture) !void {
        try std.testing.expectEqual(@as(usize, 2), self.server.requestCount());
        const first = (self.server.requestAt(0) orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, first, cc.system_prompt.COMMENT_GUIDANCE) != null);
        const followup = (self.server.requestAt(1) orelse return error.NoRequestCaptured).body();
        try std.testing.expect(std.mem.indexOf(u8, followup, "adds a code comment") != null);
        try std.testing.expect(!pfs.exists(self.target.ptr));
    }
};

test "L2 comment preview: a /name fork Skill's Write refuses a new comment" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    try std.testing.expectEqual(
        cc.skills_cli_adapter.SlashDisposition.handled,
        try cc.skills_cli_adapter.handleSlash(fx.app, std.testing.allocator, "forkwriter"),
    );
    try fx.expectWriteRefused();
}

test "L2 comment preview: a process teammate's Write refuses a new comment" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const session = cc.session_id.gen();
    var sw = cc.swarm_context.SwarmContext{ .allocator = a, .session = session, .state_root = fx.app.stateRoot(), .self_name = "worker", .team_sanitized = try a.dupe(u8, "proj") };
    defer sw.deinit();
    try fx.app.conversation.appendText(.user, "write new.py");
    var sink = cc.writer_backend.WriterBackend.initNull();
    const backend = sink.backend();
    const options = cc.TeammateHost.loopOptions(fx.app, &sw, session, cc.session_id.gen(), "worker@proj");
    const result = try cc.agent_loop.run(&fx.app.conversation, fx.app.provider(), fx.app.tool_defs, &fx.app.permission_ctx, options, &backend, fx.app.allocator);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try fx.expectWriteRefused();
}
