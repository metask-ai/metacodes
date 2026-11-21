const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const testing = std.testing;
const MOCK_MCP = "zig-out/bin/mock_mcp_server";

const REPLY_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ORIGINAL_CONFIG =
    \\{"jev":{"url":"https://jev.example.test"},"mcp_servers":[{"name":"legacy","command":["/nonexistent/legacy-mcp"]}],"theme":"dark"}
;

const Home = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,
    state_root: []const u8,
    config_path: []const u8,
    bin: []const u8,

    fn init(self: *Home) !bool {
        if (builtin.os.tag == .windows) return false;
        const raw = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return false;
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.bin = try a.dupe(u8, std.mem.span(raw));
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(testing.io, &buffer);
        self.root = try a.dupe(u8, buffer[0..len]);
        self.state_root = try std.fs.path.join(a, &.{ self.root, ".metacodes" });
        self.config_path = try std.fs.path.join(a, &.{ self.state_root, "config.json" });
        try self.tmp.dir.createDirPath(testing.io, ".metacodes");
        return true;
    }

    fn deinit(self: *Home) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn write(self: *Home, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn config(self: *Home) ![]const u8 {
        const a = self.arena_state.allocator();
        return self.tmp.dir.readFileAlloc(testing.io, ".metacodes/config.json", a, .limited(1 << 20));
    }

    fn run(self: *Home, args: []const []const u8) !cc.tools_common.SpawnOut {
        const a = self.arena_state.allocator();
        const script = "export HOME=\"$1\" METACODES_HOME=\"$2\" METACODES_NO_PROBE=1 METACODES_KG_AUTOSTART=0; cd \"$1\" || exit 99; shift 2; exec \"$@\"";
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        for ([_][]const u8{ "/bin/sh", "-c", script, "sh", self.root, self.state_root, self.bin, "mcp" }) |arg|
            try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        return cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 30_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, null);
    }

    fn expectRun(self: *Home, args: []const []const u8, code: i32, stdout_has: []const []const u8, stderr_has: []const []const u8) !cc.tools_common.SpawnOut {
        const out = try self.run(args);
        errdefer std.debug.print("metacodes mcp {s}…: exit {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ args[0], out.exit_code, out.stdout, out.stderr });
        try testing.expectEqual(code, out.exit_code);
        for (stdout_has) |needle| try testing.expect(std.mem.indexOf(u8, out.stdout, needle) != null);
        for (stderr_has) |needle| try testing.expect(std.mem.indexOf(u8, out.stderr, needle) != null);
        return out;
    }
};

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

fn fileMode(path: []const u8) !u32 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintSentinel(&buffer, "{s}", .{path}, 0);
    return (pfs.statMode(path_z.ptr, false) orelse return error.StatFailed) & 0o777;
}

test "L2 mcp add writes a stdio server a new session connects; every other key survives; 0600; a known name needs --force" {
    var home: Home = undefined;
    if (!try home.init()) return error.SkipZigTest;
    defer home.deinit();
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = home.arena_state.allocator();
    try home.write(".metacodes/config.json", ORIGINAL_CONFIG);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const mock = try std.fs.path.join(a, &.{ pfs.getCwd(&cwd_buffer) orelse return error.NoCwd, MOCK_MCP });

    const added = try home.expectRun(&.{ "add", "gate", "--", mock, "--flag" }, 0, &.{
        "Added MCP server 'gate' (stdio: ",
        home.config_path,
        "Checked: connected, ",
        "in a running session, run /mcp reconnect gate",
    }, &.{"Checking 'gate'"});
    try testing.expect(std.mem.indexOf(u8, added.stdout, "mcp login") == null);
    try testing.expectEqual(@as(u32, 0o600), try fileMode(home.config_path));

    const written = try home.config();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, written, .{});
    const root = parsed.object;
    try testing.expectEqualStrings("https://jev.example.test", root.get("jev").?.object.get("url").?.string);
    try testing.expectEqualStrings("legacy", root.get("mcp_servers").?.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("dark", root.get("theme").?.string);
    const gate = root.get("mcpServers").?.object.get("gate").?.object;
    try testing.expectEqualStrings("stdio", gate.get("type").?.string);
    try testing.expectEqualStrings(mock, gate.get("command").?.string);
    try testing.expectEqualStrings("--flag", gate.get("args").?.array.items[0].string);

    _ = try home.expectRun(&.{ "add", "gate", "--", "/bin/true" }, 1, &.{}, &.{ "already configured", "--force" });
    try testing.expectEqualStrings(written, try home.config());
    _ = try home.expectRun(&.{ "add", "legacy", "--", "/bin/true" }, 1, &.{}, &.{"legacy \"mcp_servers\" array"});

    var guards = [_]EnvGuard{
        try EnvGuard.set("HOME", (try a.dupeZ(u8, home.root)).ptr),
        try EnvGuard.set("METACODES_HOME", (try a.dupeZ(u8, home.state_root)).ptr),
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        try EnvGuard.set("CODEX_HOME", null),
    };
    defer for (&guards) |*guard| guard.restore();
    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    var session_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer session_arena.deinit();
    const sa = session_arena.allocator();
    const config = cc.parseArgsForTest(&.{ "metacodes", "--permission", "bypassPermissions", "--base-url", (try sa.dupeZ(u8, url)).ptr }, sa);
    try testing.expect(config.parse_error == null);
    var io_rt = @import("platform").signal.threadedIo(sa, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(sa, io_rt.io(), config, "test-key");
    defer app.deinit();
    const connected = for (app.mcp_report.servers) |server| {
        if (std.mem.eql(u8, server.name, "gate")) break server;
    } else return error.GateNotReported;
    try testing.expectEqual(.connected, connected.state);
    try testing.expectEqual(@as(u8, 0), try cc.repl_headless.run(app, sa, "hello", null, false, null));
    try testing.expect(std.mem.indexOf(u8, srv.lastRequest().?.body(), "mcp__gate__echo") != null);

    _ = try home.expectRun(&.{ "add", "gate", "--force", "--env", "MODE=x", "--", "/bin/true" }, 0, &.{ "Replaced MCP server 'gate'", "Checked: could not connect: " }, &.{});
    const replaced = try std.json.parseFromSliceLeaky(std.json.Value, a, try home.config(), .{});
    try testing.expectEqualStrings("x", replaced.object.get("mcpServers").?.object.get("gate").?.object.get("env").?.object.get("MODE").?.string);
}

test "L2 mcp add --url names the login step; mcp list says 'not logged in'; mcp remove forgets the entry and its login" {
    var home: Home = undefined;
    if (!try home.init()) return error.SkipZigTest;
    defer home.deinit();
    const a = home.arena_state.allocator();
    try home.write(".metacodes/config.json", ORIGINAL_CONFIG);
    const web_url = "https://mcp.example.test/mcp";

    _ = try home.expectRun(&.{ "add", "web", "--no-check", "--url", web_url, "--header", "X-Team=core" }, 0, &.{
        "Added MCP server 'web' (http https://mcp.example.test/mcp)",
        "If the server requires authorization, log in next: metacodes mcp login web",
        "/mcp reconnect web",
    }, &.{});
    const authd = try home.expectRun(&.{ "add", "authd", "--no-check", "--type", "sse", "--url", "https://a.example.test/sse", "-H", "Authorization: Bearer ${AUTHD_TOKEN}" }, 0, &.{ "(sse https://a.example.test/sse)", "Note: environment variable AUTHD_TOKEN is not set" }, &.{});
    try testing.expect(std.mem.indexOf(u8, authd.stdout, "mcp login") == null);
    const written = try std.json.parseFromSliceLeaky(std.json.Value, a, try home.config(), .{});
    const servers = written.object.get("mcpServers").?.object;
    try testing.expectEqualStrings("http", servers.get("web").?.object.get("type").?.string);
    try testing.expectEqualStrings("core", servers.get("web").?.object.get("headers").?.object.get("X-Team").?.string);
    try testing.expectEqualStrings("Bearer ${AUTHD_TOKEN}", servers.get("authd").?.object.get("headers").?.object.get("Authorization").?.string);

    const configured_in = try std.fmt.allocPrint(a, "    configured in {s}\n", .{home.config_path});
    const listed = try home.expectRun(&.{ "list", "--no-check" }, 0, &.{ "web  http  https://mcp.example.test/mcp  auth: not logged in (if the server requires it: metacodes mcp login web)", configured_in }, &.{});
    try testing.expect(std.mem.indexOf(u8, listed.stdout, "auth: none") == null);

    const login_path = try cc.mcp_oauth.storePath(a, home.state_root, "web", web_url);
    try cc.mcp_oauth.saveRecord(testing.allocator, login_path, .{
        .server = "web",
        .url = web_url,
        .resource = web_url,
        .issuer = "https://as.example.test",
        .token_endpoint = "https://as.example.test/token",
        .client_id = "c",
        .access_token = "at",
    });
    _ = try home.expectRun(&.{ "list", "--no-check" }, 0, &.{"auth: OAuth (https://as.example.test)"}, &.{});

    _ = try home.expectRun(&.{ "remove", "web" }, 0, &.{
        "Removed MCP server 'web' from ",
        "Its stored OAuth login is removed too.",
        "a running session keeps it until it ends",
    }, &.{});
    try testing.expect(!pfs.exists(try a.dupeZ(u8, login_path)));
    const after = try std.json.parseFromSliceLeaky(std.json.Value, a, try home.config(), .{});
    try testing.expect(!after.object.get("mcpServers").?.object.contains("web"));
    try testing.expect(after.object.get("mcpServers").?.object.contains("authd"));
    try testing.expectEqualStrings("https://jev.example.test", after.object.get("jev").?.object.get("url").?.string);
    try testing.expectEqual(@as(usize, 1), after.object.get("mcp_servers").?.array.items.len);

    _ = try home.expectRun(&.{ "remove", "web" }, 1, &.{}, &.{"no MCP server named 'web'"});
    _ = try home.expectRun(&.{ "remove", "legacy" }, 1, &.{}, &.{ "legacy \"mcp_servers\" array", "by hand" });
}

test "L2 a name another program configures needs --force to shadow; removing the shadow says the other one applies again" {
    var home: Home = undefined;
    if (!try home.init()) return error.SkipZigTest;
    defer home.deinit();
    try home.write(".claude.json", "{\"mcpServers\":{\"shared\":{\"type\":\"http\",\"url\":\"https://claude.example.test/mcp\"}}}");

    _ = try home.expectRun(&.{ "add", "shared", "--no-check", "--url", "https://mine.example.test/mcp" }, 1, &.{}, &.{ ".claude.json", "--force" });
    try testing.expect(!pfs.exists(try home.arena_state.allocator().dupeZ(u8, home.config_path)));
    _ = try home.expectRun(&.{ "add", "shared", "--force", "--no-check", "--url", "https://mine.example.test/mcp" }, 0, &.{ "Added MCP server 'shared'", "It takes precedence over 'shared' in", ".claude.json" }, &.{});
    _ = try home.expectRun(&.{ "list", "--no-check" }, 0, &.{"https://mine.example.test/mcp"}, &.{});
    _ = try home.expectRun(&.{ "remove", "shared" }, 0, &.{ "Removed MCP server 'shared'", "'shared' is still configured in", ".claude.json" }, &.{});
    _ = try home.expectRun(&.{ "remove", "shared" }, 1, &.{}, &.{ "which metacodes does not edit", "\"enabled\": false" });
}

test "L2 mcp usage errors exit 2 and say why; --help documents add" {
    var home: Home = undefined;
    if (!try home.init()) return error.SkipZigTest;
    defer home.deinit();
    _ = try home.expectRun(&.{"add"}, 2, &.{}, &.{ "missing the server name", "usage: metacodes mcp add" });
    _ = try home.expectRun(&.{ "add", "suno", "https://mcp.example.test/mcp", "https://other.example.test/mcp" }, 2, &.{}, &.{"unexpected argument"});
    _ = try home.expectRun(&.{ "add", "-s", "project", "suno", "https://mcp.example.test/mcp" }, 2, &.{}, &.{".mcp.json"});
    _ = try home.expectRun(&.{ "add-json", "suno", "{\"type\":\"http\"}" }, 2, &.{}, &.{ "no session could use this entry", "no url" });
    _ = try home.expectRun(&.{ "remove", "a", "b" }, 2, &.{}, &.{"takes one server name"});
    _ = try home.expectRun(&.{"--help"}, 0, &.{ "metacodes mcp add <name> <url>", "metacodes mcp add-json <name>", "/mcp reconnect <name>" }, &.{});
    _ = try home.expectRun(&.{ "add", "--help" }, 0, &.{"metacodes mcp remove <name>"}, &.{});
    try testing.expect(!pfs.exists(try home.arena_state.allocator().dupeZ(u8, home.config_path)));
}

fn startHttpMock(child: *@import("platform").process.PipeChild) ?u16 {
    const MOCK_HTTP = "tests/_harness/mock_mcp_http_server.py";
    if (std.c.access(MOCK_HTTP, 1) != 0) return null;
    const argv = [_]?[*:0]const u8{ MOCK_HTTP, null };
    child.* = @import("platform").process.spawnPipes(&argv, true, null) catch return null;
    var buffer: [16]u8 = undefined;
    var length: usize = 0;
    while (length < buffer.len) {
        var byte: [1]u8 = undefined;
        if (!child.pollReadable(5000) or child.read(&byte) != 1 or byte[0] == '\n') break;
        buffer[length] = byte[0];
        length += 1;
    }
    return std.fmt.parseInt(u16, buffer[0..length], 10) catch null;
}

test "L2 mcp add checks the server: a 401 names the login command, a live one its tools; mcp list shows each one's state and the configuration's problems" {
    var home: Home = undefined;
    if (!try home.init()) return error.SkipZigTest;
    defer home.deinit();
    const a = home.arena_state.allocator();
    var child: @import("platform").process.PipeChild = undefined;
    const port = startHttpMock(&child) orelse return error.SkipZigTest;
    defer {
        child.closeStdin();
        child.closeStdout();
        child.terminate();
    }
    const locked_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/auth", .{port});
    const live_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/classic", .{port});

    _ = try home.expectRun(&.{ "add", "--transport", "http", "locked", locked_url }, 0, &.{
        "Added MCP server 'locked' (http ",
        "Checked: the server requires authorization (401/403); log in: metacodes mcp login locked.",
    }, &.{});
    const live_json = try std.fmt.allocPrint(a, "{{\"type\":\"http\",\"url\":\"{s}\",\"aFieldNoVersionReads\":1}}", .{live_url});
    _ = try home.expectRun(&.{ "add-json", "live", live_json }, 0, &.{
        "Added MCP server 'live' (http ",
        "Checked: connected, ",
    }, &.{});
    const written = try home.config();
    const broken = try std.mem.replaceOwned(u8, a, written, "\"mcpServers\": {", "\"mcpServers\": {\"broken\": {\"type\": \"http\"},");
    try testing.expect(!std.mem.eql(u8, broken, written));
    try home.write(".metacodes/config.json", broken);

    const listed = try home.expectRun(&.{"list"}, 0, &.{
        "    status: the server requires authorization (401/403); log in: metacodes mcp login locked\n",
        "    status: connected, ",
        "/ broken: http server has no url",
    }, &.{"Checking 2 MCP servers"});
    try testing.expect(std.mem.indexOf(u8, try home.config(), "aFieldNoVersionReads") != null);
    _ = listed;
}
