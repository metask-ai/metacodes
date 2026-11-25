const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;
const psync = @import("platform").sync;

const MOCK_MCP = "zig-out/bin/mock_mcp_server";
const GROW_MCP = "tests/_harness/mock_mcp_grow_server.py";

fn textSse(comptime text: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const FINAL_SSE = textSse("done");

fn toolUseSse(a: std.mem.Allocator, id: []const u8, name: []const u8, input_json: []const u8) ![]u8 {
    const partial = try std.json.Stringify.valueAlloc(a, input_json, .{});
    defer a.free(partial);
    return std.fmt.allocPrint(
        a,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, name, partial },
    );
}

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

var workspace_serial: std.atomic.Value(u32) = .init(0);

const Workspace = struct {
    dir: std.Io.Dir,
    created_buffer: [std.fs.max_path_bytes]u8,
    created: []const u8,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [4]EnvGuard,

    fn init(self: *Workspace) !void {
        const io = std.testing.io;
        self.created = try std.fmt.bufPrint(&self.created_buffer, "{s}/metacodes-hotplug-{d}-{d}", .{
            std.mem.trimEnd(u8, ppaths.tempDir(), "/"),
            std.c.getpid(),
            workspace_serial.fetchAdd(1, .monotonic),
        });
        try std.Io.Dir.createDirAbsolute(io, self.created, .default_dir);
        errdefer std.Io.Dir.cwd().deleteTree(io, self.created) catch {};
        self.dir = try std.Io.Dir.openDirAbsolute(io, self.created, .{});
        errdefer self.dir.close(io);
        const len = try self.dir.realPath(io, &self.root_buffer);
        self.root = self.root_buffer[0..len];
        try self.dir.createDirPath(io, ".metacodes");
        const home_z = try std.testing.allocator.dupeZ(u8, self.root);
        defer std.testing.allocator.free(home_z);
        self.guards = .{
            try EnvGuard.set("HOME", home_z.ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
            try EnvGuard.set("CODEX_HOME", null),
        };
    }

    fn deinit(self: *Workspace) void {
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.dir.close(std.testing.io);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.created) catch {};
    }

    fn writeFile(self: *Workspace, sub_path: []const u8, data: []const u8) !void {
        try self.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn servers(self: *Workspace, a: std.mem.Allocator, servers_json: []const u8) ![]u8 {
        _ = self;
        return std.fmt.allocPrint(a, "{{\"mcpServers\":{s}}}", .{servers_json});
    }

    fn writeConfig(self: *Workspace, servers_json: []const u8) !void {
        const a = std.testing.allocator;
        const config = try self.servers(a, servers_json);
        defer a.free(config);
        try self.writeFile(".metacodes/config.json", config);
    }

    fn readPid(self: *Workspace) ?i32 {
        var buffer: [32]u8 = undefined;
        const bytes = self.dir.readFile(std.testing.io, "server.pid", &buffer) catch return null;
        return std.fmt.parseInt(i32, std.mem.trim(u8, bytes, " \n"), 10) catch null;
    }
};

fn mockEntry(a: std.mem.Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
    return std.fmt.allocPrint(a, "\"{s}\":{{\"command\":\"{s}/{s}\",\"args\":{s}}}", .{ name, cwd, MOCK_MCP, args_json });
}

fn growEntry(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
    return std.fmt.allocPrint(a, "\"{s}\":{{\"command\":\"{s}/{s}\"}}", .{ name, cwd, GROW_MCP });
}

fn pidEntry(a: std.mem.Allocator, ws: *const Workspace, name: []const u8) ![]u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
    return std.fmt.allocPrint(
        a,
        "\"{s}\":{{\"command\":\"/bin/sh\",\"args\":[\"-c\",\"echo $$ > '{s}/server.pid'; exec '{s}/{s}'\"]}}",
        .{ name, ws.root, cwd, MOCK_MCP },
    );
}

const Session = struct {
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,

    fn init(self: *Session, base_url: []const u8, extra: []const [*:0]const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const url = try a.dupeZ(u8, base_url);
        var argv: std.ArrayList([*:0]const u8) = .empty;
        try argv.appendSlice(a, &.{ "metacodes", "--permission", "bypassPermissions", "--base-url", url.ptr, "--model", "test-model" });
        try argv.appendSlice(a, extra);
        const config = cc.parseArgsForTest(argv.items, a);
        try std.testing.expect(config.parse_error == null);
        self.io_rt = @import("platform").signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Session) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
    }

    fn run(self: *Session, prompt: []const u8) !void {
        const app = self.app;
        try app.conversation.appendText(.user, prompt);
        var options = cc.session_service.buildRunOptions(app, null);
        options.max_turns = 6;
        var render = cc.writer_backend.WriterBackend.initNull();
        const backend = render.backend();
        const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    }

    fn repl(self: *Session, ws: *Workspace, text: []const u8) !void {
        const a = self.arena.allocator();
        const input_path = try std.fmt.allocPrintSentinel(a, "{s}/repl-input", .{ws.root}, 0);
        {
            const fd = pfs.open(input_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
            if (fd < 0) return error.InputFile;
            defer _ = pfs.close(fd);
            if (pfs.write(fd, text) != @as(isize, @intCast(text.len))) return error.InputFile;
        }
        const fd = pfs.open(input_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (fd < 0) return error.InputFile;
        defer _ = pfs.close(fd);
        try cc.repl_loop.run(self.app, a, .{ .input_fd = fd });
    }
};

fn prefix(a: std.mem.Allocator, body: []const u8) ![2][]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    var out: [2][]u8 = undefined;
    for ([_][]const u8{ "system", "tools" }, 0..) |key, i| {
        const value = parsed.value.object.get(key) orelse return error.MissingField;
        out[i] = try std.json.Stringify.valueAlloc(a, value, .{});
    }
    return out;
}

fn expectSamePrefix(a: std.mem.Allocator, before_body: []const u8, after_body: []const u8) !void {
    const before = try prefix(a, before_body);
    defer for (before) |part| a.free(part);
    const after = try prefix(a, after_body);
    defer for (after) |part| a.free(part);
    for (before, after) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

fn toolNames(a: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const tools = parsed.value.object.get("tools") orelse return out.toOwnedSlice(a);
    for (tools.array.items) |tool| {
        try out.appendSlice(a, tool.object.get("name").?.string);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

fn lastToolResult(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const messages = parsed.object.get("messages").?.array.items;
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const content = messages[index].object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |block| {
            if (!std.mem.eql(u8, block.object.get("type").?.string, "tool_result")) continue;
            const result = block.object.get("content").?;
            if (result == .string) return result.string;
            var joined: std.ArrayList(u8) = .empty;
            for (result.array.items) |part| if (part.object.get("text")) |text| try joined.appendSlice(a, text.string);
            return joined.items;
        }
    }
    return error.NoToolResult;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn liveTools(app: *cc.app_module.App, prefix_name: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (app.dyn_registry.entryAt(index)) |entry| : (index += 1) {
        if (entry.isLive() and std.mem.startsWith(u8, entry.name, prefix_name)) count += 1;
    }
    return count;
}

fn liveTool(app: *cc.app_module.App, name: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (app.dyn_registry.entryAt(index)) |entry| : (index += 1) {
        if (entry.isLive() and std.mem.eql(u8, entry.name, name)) count += 1;
    }
    return count;
}

fn waitSettled(app: *cc.app_module.App) !void {
    var waited: usize = 0;
    while (!app.mcpStartupSettled() and waited < 1000) : (waited += 1) psync.sleepMs(10);
    try std.testing.expect(app.mcpStartupSettled());
    try app.publishMcpServers();
}

test "L2 a server added during a Run is connected before its next request: only history learns of it, then ToolSearch loads it and the call reaches it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{}");
    {
        const entry = try mockEntry(a, "hot", "[]");
        defer a.free(entry);
        const braced = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(braced);
        const next = try ws.servers(a, braced);
        defer a.free(next);
        try ws.writeFile("next.json", next);
    }
    const copy = try std.fmt.allocPrint(a, "{{\"command\":\"cp '{s}/next.json' '{s}/.metacodes/config.json'\"}}", .{ ws.root, ws.root });
    defer a.free(copy);
    const install = try toolUseSse(a, "tu_install", "Bash", copy);
    defer a.free(install);
    const search = try toolUseSse(a, "tu_search", "ToolSearch", "{\"query\":\"select:mcp__hot__echo\"}");
    defer a.free(search);
    const call = try toolUseSse(a, "tu_call", "mcp__hot__echo", "{\"message\":\"hot plugged\"}");
    defer a.free(call);

    var srv = try harness.MockServer.startCassette(&.{ install, search, call, FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, &.{});
    defer session.deinit();
    const app = session.app;
    try std.testing.expectEqual(@as(usize, 0), app.mcp_sessions.items.len);

    try session.run("install the hot server and use it");

    try std.testing.expectEqual(@as(usize, 4), srv.requestCount());
    const first = srv.requestAt(0).?.body();
    const second = srv.requestAt(1).?.body();
    try std.testing.expect(!contains(first, "mcp__hot__echo"));
    try expectSamePrefix(a, first, second);
    try std.testing.expect(contains(second, "MCP tools changed during this session."));
    try std.testing.expect(contains(second, "- mcp__hot__echo — echo back input"));
    try std.testing.expect(contains(second, "'hot' connected ("));

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const third = srv.requestAt(2).?.body();
    const loaded = try lastToolResult(arena.allocator(), third);
    try std.testing.expect(contains(loaded, "<function>"));
    try std.testing.expect(contains(loaded, "mcp__hot__echo"));
    const names = try toolNames(a, third);
    defer a.free(names);
    try std.testing.expect(contains(names, "mcp__hot__echo\n"));
    const answered = try lastToolResult(arena.allocator(), srv.requestAt(3).?.body());
    try std.testing.expect(contains(answered, "hot plugged"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, srv.requestAt(3).?.body(), "MCP tools changed during this session."));
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
}

test "L2 a server removed from the configuration is reported gone before the next request, its process is reaped, and a call to its tool fails" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    {
        const entry = try pidEntry(a, &ws, "gone");
        defer a.free(entry);
        const braced = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(braced);
        try ws.writeConfig(braced);
    }
    const call = try toolUseSse(a, "tu_call", "mcp__gone__echo", "{\"message\":\"x\"}");
    defer a.free(call);
    var srv = try harness.MockServer.startCassette(&.{ FINAL_SSE, call, FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, &.{});
    defer session.deinit();
    const app = session.app;
    try waitSettled(app);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
    const pid = ws.readPid() orelse return error.ServerNeverStarted;

    try session.run("hello");
    try ws.writeConfig("{}");
    try session.run("use it");

    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
    const before = srv.requestAt(0).?.body();
    const after = srv.requestAt(1).?.body();
    try expectSamePrefix(a, before, after);
    try std.testing.expect(!contains(before, "MCP tools changed during this session."));
    try std.testing.expect(contains(after, "are no longer available"));
    try std.testing.expect(contains(after, "- mcp__gone__echo\\n"));
    try std.testing.expect(contains(after, "'gone' was removed from the configuration"));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const failed = try lastToolResult(arena.allocator(), srv.requestAt(2).?.body());
    try std.testing.expect(contains(failed, "mcp__gone__echo"));
    try std.testing.expectEqual(@as(usize, 0), app.mcp_sessions.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_retired.items.len);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_report.servers.len);
    try std.testing.expectEqual(@as(usize, 0), liveTools(app, "mcp__gone__"));
    var waited: usize = 0;
    while (std.c.kill(pid, @enumFromInt(0)) == 0 and waited < 200) : (waited += 1) psync.sleepMs(10);
    try std.testing.expect(std.c.kill(pid, @enumFromInt(0)) != 0);
}

test "L2 a server that changes its tool list has the new list announced before the next request" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.access(GROW_MCP, 1) != 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    {
        const entry = try growEntry(a, "g");
        defer a.free(entry);
        const braced = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(braced);
        try ws.writeConfig(braced);
    }
    const search = try toolUseSse(a, "tu_search", "ToolSearch", "{\"query\":\"select:mcp__g__grow\"}");
    defer a.free(search);
    const call = try toolUseSse(a, "tu_grow", "mcp__g__grow", "{}");
    defer a.free(call);
    var srv = try harness.MockServer.startCassette(&.{ search, call, FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, &.{});
    defer session.deinit();
    const app = session.app;
    try waitSettled(app);
    try std.testing.expectEqual(@as(usize, 0), liveTool(app, "mcp__g__grown"));

    try session.run("grow it");

    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
    const called = srv.requestAt(1).?.body();
    const after = srv.requestAt(2).?.body();
    try std.testing.expect(!contains(called, "mcp__g__grown"));
    try expectSamePrefix(a, called, after);
    try std.testing.expect(contains(after, "- mcp__g__grown — appears after grow"));
    try std.testing.expect(contains(after, "'g' changed its tools."));
    try std.testing.expect(!contains(after, "are no longer available"));
    try std.testing.expectEqual(@as(usize, 1), liveTool(app, "mcp__g__grown"));
    try std.testing.expectEqual(@as(usize, 1), liveTool(app, "mcp__g__grow"));
    var echo_descriptions: usize = 0;
    for (app.tool_defs) |definition| {
        if (!std.mem.eql(u8, definition.name, "mcp__g__echo")) continue;
        echo_descriptions += 1;
        try std.testing.expectEqualStrings("echo back input, grown", definition.description);
        try std.testing.expect(!definition.retired);
    }
    try std.testing.expectEqual(@as(usize, 1), echo_descriptions);
}

test "L2 a server added inside the working directories waits for /mcp reconnect" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{}");
    var srv = try harness.MockServer.startCassette(&.{ FINAL_SSE, FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    const add_dir = try a.dupeZ(u8, ws.root);
    defer a.free(add_dir);
    try session.init(url, &.{ "--add-dir", add_dir.ptr });
    defer session.deinit();
    const app = session.app;
    {
        const entry = try mockEntry(a, "inside", "[]");
        defer a.free(entry);
        const braced = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(braced);
        try ws.writeConfig(braced);
    }

    try session.run("hello");

    const first = srv.requestAt(0).?.body();
    try std.testing.expect(contains(first, "inside this session's working directories, so it was not connected automatically"));
    try std.testing.expect(contains(first, "`/mcp reconnect inside`"));
    try std.testing.expect(!contains(first, "mcp__inside__echo"));
    try std.testing.expectEqual(@as(usize, 0), app.mcp_sessions.items.len);
    try std.testing.expectEqual(.not_loaded, app.mcp_report.servers[0].state);

    try session.repl(&ws, "/mcp reconnect inside\nhello again\n");

    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    const second = srv.lastRequest().?.body();
    try std.testing.expect(contains(second, "- mcp__inside__echo — echo back input"));
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
}

test "L2 servers come and go while an agent job runs, and /mcp reconnect is not refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{}");
    var srv = try harness.MockServer.startCassette(&.{FINAL_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, &.{});
    defer session.deinit();
    const app = session.app;
    const jobs = &(app.agent_jobs orelse return error.SkipZigTest);
    const job = jobs.registerForeground("general-purpose", "busy", "busy") orelse return error.SkipZigTest;
    defer jobs.finishForeground(job, 0, 0, .end_turn);
    {
        const entry = try mockEntry(a, "busy", "[]");
        defer a.free(entry);
        const braced = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(braced);
        try ws.writeConfig(braced);
    }

    try session.run("hello");
    try std.testing.expect(contains(srv.requestAt(0).?.body(), "- mcp__busy__echo — echo back input"));
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);

    const begun = try app.beginMcpReconnect(.{ .server = "busy" });
    try std.testing.expectEqual(@as(usize, 1), begun.connecting.len);
    try waitSettled(app);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_retired.items.len);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
}

test "L2 /mcp reconnect <name> also applies another server's changed entry" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    if (std.c.access(GROW_MCP, 1) != 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    const first = try mockEntry(a, "first", "[]");
    defer a.free(first);
    {
        const second = try mockEntry(a, "second", "[]");
        defer a.free(second);
        const braced = try std.fmt.allocPrint(a, "{{{s},{s}}}", .{ first, second });
        defer a.free(braced);
        try ws.writeConfig(braced);
    }
    var session: Session = undefined;
    try session.init("http://127.0.0.1:1/v1/messages", &.{});
    defer session.deinit();
    const app = session.app;
    try waitSettled(app);
    try std.testing.expectEqual(@as(usize, 0), liveTool(app, "mcp__second__grow"));
    {
        const second = try growEntry(a, "second");
        defer a.free(second);
        const braced = try std.fmt.allocPrint(a, "{{{s},{s}}}", .{ first, second });
        defer a.free(braced);
        try ws.writeConfig(braced);
    }

    const begun = try app.beginMcpReconnect(.{ .server = "first" });
    try std.testing.expectEqual(@as(usize, 1), begun.connecting.len);
    try waitSettled(app);
    try std.testing.expectEqual(@as(usize, 1), liveTool(app, "mcp__second__grow"));
    try std.testing.expectEqual(@as(usize, 1), liveTool(app, "mcp__first__echo"));
    try std.testing.expectEqual(@as(usize, 2), app.mcp_sessions.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.mcp_retired.items.len);
}
