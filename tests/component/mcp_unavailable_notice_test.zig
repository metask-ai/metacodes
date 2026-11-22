const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const process = @import("platform").process;

const MOCK_HTTP = "tests/_harness/mock_mcp_http_server.py";

fn toolUseSse(comptime id: []const u8, comptime name: []const u8, comptime partial_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_" ++ id ++ "\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ partial_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const SEARCH_SSE = toolUseSse("tu_search", "ToolSearch", "{\\\"query\\\":\\\"locked\\\"}");
const CALL_SSE = toolUseSse("tu_call", "mcp__locked__generate", "{}");
const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const NAMED = "'locked' (the server requires authorization";
const REMEDY = "metacodes mcp login locked";

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

fn startHttpMock(child: *process.PipeChild) !?u16 {
    const argv = [_]?[*:0]const u8{ MOCK_HTTP, null };
    child.* = process.spawnPipes(&argv, true, null) catch return null;
    var port_buffer: [16]u8 = undefined;
    var length: usize = 0;
    while (length < port_buffer.len) {
        var byte: [1]u8 = undefined;
        if (!child.pollReadable(5000) or child.read(&byte) != 1 or byte[0] == '\n') break;
        port_buffer[length] = byte[0];
        length += 1;
    }
    return std.fmt.parseInt(u16, port_buffer[0..length], 10) catch null;
}

fn lastToolResult(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    const messages = parsed.object.get("messages").?.array.items;
    const content = messages[messages.len - 1].object.get("content").?.array.items;
    for (content) |block| {
        if (!std.mem.eql(u8, block.object.get("type").?.string, "tool_result")) continue;
        const result = block.object.get("content").?;
        if (result == .string) return result.string;
        var joined: std.ArrayList(u8) = .empty;
        for (result.array.items) |part| if (part.object.get("text")) |text| try joined.appendSlice(a, text.string);
        return joined.items;
    }
    return error.NoToolResult;
}

test "L2 a configured MCP server that answered 401 is named, with its remedy, by ToolSearch and by a call to its tool" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.access(MOCK_HTTP, 1) != 0) return error.SkipZigTest;
    const a = std.testing.allocator;

    var child: process.PipeChild = undefined;
    const port = (try startHttpMock(&child)) orelse return error.SkipZigTest;
    defer {
        child.closeStdin();
        child.closeStdout();
        child.terminate();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try tmp.dir.createDirPath(std.testing.io, ".metacodes");
    const config = try std.fmt.allocPrint(a, "{{\"mcpServers\":{{\"locked\":{{\"type\":\"http\",\"url\":\"http://127.0.0.1:{d}/auth\"}}}}}}", .{port});
    defer a.free(config);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });

    const home_z = try a.dupeZ(u8, root);
    defer a.free(home_z);
    var guards = [_]EnvGuard{
        try EnvGuard.set("HOME", home_z.ptr),
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        try EnvGuard.set("CODEX_HOME", null),
    };
    defer {
        var i = guards.len;
        while (i > 0) {
            i -= 1;
            guards[i].restore();
        }
    }

    const bodies = [_][]const u8{ SEARCH_SSE, CALL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const url_z = try aa.dupeZ(u8, url);
    const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", url_z.ptr, "--model", "test-model" };
    const parsed = cc.parseArgsForTest(&argv, aa);
    try std.testing.expect(parsed.parse_error == null);
    var io_rt = @import("platform").signal.threadedIo(aa, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(aa, io_rt.io(), parsed, "test-key");
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 1), app.mcp_unavailable.len);
    try std.testing.expectEqualStrings("locked", app.mcp_unavailable[0].name);

    try app.conversation.appendText(.user, "make a song with locked");
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 4;
    var render = cc.writer_backend.WriterBackend.initNull();
    const backend = render.backend();
    const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    const after_search = try lastToolResult(aa, server.requestAt(1).?.body());
    try std.testing.expect(std.mem.indexOf(u8, after_search, "No deferred tool matched query") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_search, NAMED) != null);
    try std.testing.expect(std.mem.indexOf(u8, after_search, REMEDY) != null);
    const after_call = try lastToolResult(aa, server.requestAt(2).?.body());
    try std.testing.expect(std.mem.indexOf(u8, after_call, "Tool 'mcp__locked__generate' does not exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_call, NAMED) != null);
    try std.testing.expect(std.mem.indexOf(u8, after_call, REMEDY) != null);
}

fn startupApp(aa: std.mem.Allocator, io: std.Io) !*cc.app_module.App {
    const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", "http://127.0.0.1:1/v1/messages", "--model", "test-model" };
    const parsed = cc.parseArgsForTest(&argv, aa);
    try std.testing.expect(parsed.parse_error == null);
    return cc.app_module.App.init(aa, io, parsed, "test-key");
}

test "L2 a server in ~/.metacode/config.toml starts with the session, is reported by headless, and mcpImport.metacode=false leaves it out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.access(MOCK_HTTP, 1) != 0) return error.SkipZigTest;
    const a = std.testing.allocator;

    var child: process.PipeChild = undefined;
    const port = (try startHttpMock(&child)) orelse return error.SkipZigTest;
    defer {
        child.closeStdin();
        child.closeStdout();
        child.terminate();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try tmp.dir.createDirPath(std.testing.io, ".metacode");
    try tmp.dir.createDirPath(std.testing.io, ".metacodes");
    const toml = try std.fmt.allocPrint(a, "[mcp_servers.locked]\nurl = \"http://127.0.0.1:{d}/auth\"\n", .{port});
    defer a.free(toml);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacode/config.toml", .data = toml });

    const home_z = try a.dupeZ(u8, root);
    defer a.free(home_z);
    var guards = [_]EnvGuard{
        try EnvGuard.set("HOME", home_z.ptr),
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        try EnvGuard.set("CODEX_HOME", null),
    };
    defer {
        var i = guards.len;
        while (i > 0) {
            i -= 1;
            guards[i].restore();
        }
    }

    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var io_rt = @import("platform").signal.threadedIo(aa, .{});
        defer io_rt.deinit();
        const app = try startupApp(aa, io_rt.io());
        defer app.deinit();

        try std.testing.expectEqual(@as(usize, 1), app.mcp_report.servers.len);
        const status = app.mcp_report.servers[0];
        try std.testing.expectEqualStrings("locked", status.name);
        try std.testing.expectEqual(cc.mcp_config.Origin.metacode_user, status.origin);
        try std.testing.expectEqual(.needs_auth, status.state);

        const notice = (try cc.repl_headless.mcpUnavailableNotice(a, app.mcp_unavailable)).?;
        defer a.free(notice);
        try std.testing.expect(std.mem.startsWith(u8, notice, "warning: MCP server 'locked' did not connect: the server requires authorization"));
        try std.testing.expect(std.mem.indexOf(u8, notice, REMEDY) != null);

        var usage: cc.app_module.UsageTotals = .{};
        const line = try cc.repl_headless.buildResultLine(a, "done", "final", null, null, app.mcp_unavailable, .{ .stop_reason = .end_turn, .turns = 1, .tool_calls = 0 }, &usage, "m");
        defer a.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, line, "\n"), .{});
        defer parsed.deinit();
        const servers = parsed.value.object.get("mcp_unavailable").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), servers.len);
        try std.testing.expectEqualStrings("locked", servers[0].object.get("name").?.string);
        try std.testing.expect(std.mem.indexOf(u8, servers[0].object.get("detail").?.string, REMEDY) != null);
    }

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = "{\"mcpImport\":{\"metacode\":false}}" });
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var io_rt = @import("platform").signal.threadedIo(aa, .{});
        defer io_rt.deinit();
        const app = try startupApp(aa, io_rt.io());
        defer app.deinit();
        try std.testing.expectEqual(@as(usize, 0), app.mcp_report.servers.len);
        try std.testing.expectEqual(@as(usize, 0), app.mcp_unavailable.len);
        try std.testing.expect((try cc.repl_headless.mcpUnavailableNotice(a, app.mcp_unavailable)) == null);
    }
}

const SEARCH_FRESH_SSE = toolUseSse("tu_search", "ToolSearch", "{\\\"query\\\":\\\"fresh\\\"}");
const CALL_FRESH_SSE = toolUseSse("tu_call", "mcp__fresh__generate", "{}");
const NOT_LOADED = "'fresh' (added during this session inside the working directories; `/mcp reconnect fresh` connects it);";

fn runSearchAndCall(app: *cc.app_module.App, prompt: []const u8) !void {
    try app.conversation.appendText(.user, prompt);
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 4;
    var render = cc.writer_backend.WriterBackend.initNull();
    const backend = render.backend();
    const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
}

test "L2 a server added inside the working directories after the session started is named, with how to load it, before the next request, by ToolSearch and by a call to its tool" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try tmp.dir.createDirPath(std.testing.io, ".metacodes");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = "{}" });

    const home_z = try a.dupeZ(u8, root);
    defer a.free(home_z);
    var guards = [_]EnvGuard{
        try EnvGuard.set("HOME", home_z.ptr),
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        try EnvGuard.set("CODEX_HOME", null),
    };
    defer {
        var i = guards.len;
        while (i > 0) {
            i -= 1;
            guards[i].restore();
        }
    }

    const bodies = [_][]const u8{ SEARCH_FRESH_SSE, CALL_FRESH_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const url_z = try aa.dupeZ(u8, url);
    const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", url_z.ptr, "--model", "test-model" };
    const parsed = cc.parseArgsForTest(&argv, aa);
    try std.testing.expect(parsed.parse_error == null);
    var io_rt = @import("platform").signal.threadedIo(aa, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(aa, io_rt.io(), parsed, "test-key");
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 0), app.mcp_report.servers.len);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = "{\"mcpServers\":{\"fresh\":{\"type\":\"http\",\"url\":\"http://127.0.0.1:9/mcp\"}}}" });
    try runSearchAndCall(app, "make a song with fresh");

    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    const first = server.requestAt(0).?.body();
    try std.testing.expect(std.mem.indexOf(u8, first, "'fresh' was added in ") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "inside this session's working directories, so it was not connected automatically; the user loads it with `/mcp reconnect fresh`.") != null);
    const after_search = try lastToolResult(aa, server.requestAt(1).?.body());
    try std.testing.expect(std.mem.indexOf(u8, after_search, "No deferred tool matched query") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_search, NOT_LOADED) != null);
    const after_call = try lastToolResult(aa, server.requestAt(2).?.body());
    try std.testing.expect(std.mem.indexOf(u8, after_call, "Tool 'mcp__fresh__generate' does not exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_call, NOT_LOADED) != null);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_sessions.items.len);
}

test "L2 a stored login that the server does not accept leaves it needing authorization, said before the next request and by ToolSearch" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.access(MOCK_HTTP, 1) != 0) return error.SkipZigTest;
    const a = std.testing.allocator;

    var child: process.PipeChild = undefined;
    const port = (try startHttpMock(&child)) orelse return error.SkipZigTest;
    defer {
        child.closeStdin();
        child.closeStdout();
        child.terminate();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    try tmp.dir.createDirPath(std.testing.io, ".metacodes/mcp-oauth");
    const server_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/auth", .{port});
    defer a.free(server_url);
    const config = try std.fmt.allocPrint(a, "{{\"mcpServers\":{{\"locked\":{{\"type\":\"http\",\"url\":\"{s}\"}}}}}}", .{server_url});
    defer a.free(config);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });

    const home_z = try a.dupeZ(u8, root);
    defer a.free(home_z);
    var guards = [_]EnvGuard{
        try EnvGuard.set("HOME", home_z.ptr),
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
        try EnvGuard.set("CODEX_HOME", null),
    };
    defer {
        var i = guards.len;
        while (i > 0) {
            i -= 1;
            guards[i].restore();
        }
    }

    const bodies = [_][]const u8{ SEARCH_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const url_z = try aa.dupeZ(u8, url);
    const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", url_z.ptr, "--model", "test-model" };
    const parsed = cc.parseArgsForTest(&argv, aa);
    try std.testing.expect(parsed.parse_error == null);
    var io_rt = @import("platform").signal.threadedIo(aa, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(aa, io_rt.io(), parsed, "test-key");
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), app.mcp_unavailable.len);

    const state_root = try std.fs.path.join(aa, &.{ root, ".metacodes" });
    const login_path = try cc.mcp_oauth.storePath(aa, state_root, "locked", server_url);
    const relative = login_path[root.len + 1 ..];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = relative, .data = "{}" });
    try runSearchAndCall(app, "make a song with locked");

    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, server.requestAt(0).?.body(), "'locked' needs authorization: the user runs `metacodes mcp login locked`") != null);
    const after_search = try lastToolResult(aa, server.requestAt(1).?.body());
    try std.testing.expect(std.mem.indexOf(u8, after_search, NAMED) != null);
    try std.testing.expect(std.mem.indexOf(u8, after_search, REMEDY) != null);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_unavailable.len);

    const unrelated = try std.fmt.allocPrint(a, "{{\"mcpServers\":{{\"locked\":{{\"type\":\"http\",\"url\":\"{s}\"}},\"off\":{{\"command\":\"x\",\"enabled\":false}}}}}}", .{server_url});
    defer a.free(unrelated);
    @import("platform").sync.sleepMs(1100);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = unrelated });
    try app.conversation.appendText(.user, "again");
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 2;
    var render = cc.writer_backend.WriterBackend.initNull();
    const backend = render.backend();
    _ = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try std.testing.expectEqual(@as(usize, 1), app.mcp_report.disabled.len);
    try std.testing.expectEqualStrings("off", app.mcp_report.disabled[0]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, server.requestAt(2).?.body(), "'locked' needs authorization"));
}
