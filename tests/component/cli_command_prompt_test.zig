const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const testing = std.testing;
const ppaths = @import("platform").paths;

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            testing.allocator.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

const REPLY_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    exe: []const u8,
    dev: []const u8,
    state: []const u8,
    work: []const u8,
    home: []const u8,

    fn init(self: *Case) !void {
        const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "work", "home", "bin" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ root, "state" });
        self.work = try std.fs.path.join(a, &.{ root, "work" });
        self.home = try std.fs.path.join(a, &.{ root, "home" });
        self.exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
        try self.tmp.dir.symLink(testing.io, self.exe, "bin/metacodes-dev", .{});
        self.dev = try std.fs.path.join(a, &.{ root, "bin/metacodes-dev" });
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn systemPromptOfRun(self: *Case, command: []const u8) ![]const u8 {
        const a = self.arena_state.allocator();
        var server = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        const args = [_][]const u8{
            "/usr/bin/env",
            try std.fmt.allocPrint(a, "HOME={s}", .{self.home}),
            "PATH=/usr/bin:/bin",
            "METACODES_KG_AUTOSTART=0",
            "METACODES_JEV_URL=off",
            "METACODES_NO_PROBE=1",
            "METASK_API_KEY=sk-placeholder-metask-key",
            try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{url}),
            command,
            "--state-dir",
            self.state,
            "-p",
            "hi",
        };
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, self.work);
        errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
        try testing.expectEqual(@as(i32, 0), out.exit_code);
        try testing.expectEqual(@as(usize, 1), server.requestCount());
        const body = try a.dupe(u8, server.lastRequest().?.body());
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const system = parsed.object.get("system") orelse return error.NoSystemPrompt;
        return switch (system) {
            .string => |text| text,
            .array => |blocks| blk: {
                var joined: std.ArrayList(u8) = .empty;
                for (blocks.items) |block| if (block.object.get("text")) |text| try joined.appendSlice(a, text.string);
                break :blk joined.items;
            },
            else => error.NoSystemPrompt,
        };
    }
};

fn expectNamesCommand(prompt: []const u8, comptime command: []const u8) !void {
    errdefer std.debug.print("system prompt:\n{s}\n", .{prompt});
    try testing.expect(std.mem.indexOf(u8, prompt, "Your command is `" ++ command ++ "`: use it for anything about yourself (`" ++ command ++ " --help`).") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "`metacode` and other programs with similar names are different products.") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "`" ++ command ++ " mcp add <name> <url>`") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "`" ++ command ++ " mcp login <name>`") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "`/mcp reconnect <name>`") != null);
}

test "L2 the CLI's system prompt names the command that started it, and how MCP servers are added, logged in to and loaded" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();

    try expectNamesCommand(try case.systemPromptOfRun(case.dev), "metacodes-dev");
    const plain = try case.systemPromptOfRun(case.exe);
    try expectNamesCommand(plain, "metacodes");
    try testing.expect(std.mem.indexOf(u8, plain, "metacodes-dev") == null);
}

test "L2 an App built without the CLI's command name gets no command lines in its system prompt" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var guards = [_]EnvGuard{
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
    };
    defer {
        var i = guards.len;
        while (i > 0) {
            i -= 1;
            guards[i].restore();
        }
    }
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", "http://127.0.0.1:1/v1/messages", "--model", "test-model" };
    var parsed = cc.parseArgsForTest(&argv, aa);
    try testing.expect(parsed.parse_error == null);
    parsed.mcp_connect = .disabled;
    var io_rt = @import("platform").signal.threadedIo(aa, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(aa, io_rt.io(), parsed, "test-key");
    defer app.deinit();
    const prompt = app.system_prompt orelse return error.NoSystemPrompt;
    try testing.expect(std.mem.indexOf(u8, prompt, "MetaCode is a local, single-binary CLI agent") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Your command is") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "mcp add <name>") == null);
}
