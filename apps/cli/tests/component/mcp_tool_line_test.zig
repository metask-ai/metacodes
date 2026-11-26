const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;
const region_harness = @import("region_harness.zig");

const gpa = std.testing.allocator;

const MOCK_MCP = "zig-out/bin/mock_mcp_server";
const MCP_TOOL = "mcp__plc__echo";
const MESSAGE = "set line 3 to 900 rpm";

const MCP_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_mcp\",\"name\":\"" ++ MCP_TOOL ++ "\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"message\\\":\\\"" ++ MESSAGE ++ "\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"speed set\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const PAIR_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_one\",\"name\":\"" ++ MCP_TOOL ++ "\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"message\\\":\\\"first call\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_two\",\"name\":\"" ++ MCP_TOOL ++ "\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"message\\\":\\\"second call\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Server = enum { echo, failing, lone_surrogates };

const FAILING_SERVER =
    \\"$1" | sed -u '/"content":\[/s/]}}$/],"isError":true}}/'
    \\
;

const LONE_SURROGATE_SERVER =
    \\"$1" | sed -u 's/LONE-HIGH/\\ud83d/g; s/LONE-LOW/\\udc80/g'
    \\
;

fn toolUseSse(a: std.mem.Allocator, input_json: []const u8) ![]u8 {
    const partial = try std.json.Stringify.valueAlloc(a, input_json, .{});
    defer a.free(partial);
    return std.fmt.allocPrint(
        a,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_mcp\",\"name\":\"" ++ MCP_TOOL ++ "\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{partial},
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

const Home = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    guards: [4]EnvGuard,

    fn init(self: *Home, server: Server) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        const root = self.root_buffer[0..len];

        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes");
        const config = switch (server) {
            .echo => try std.fmt.allocPrint(gpa, "{{\"mcpServers\":{{\"plc\":{{\"command\":\"{s}/{s}\",\"args\":[]}}}}}}", .{ cwd, MOCK_MCP }),
            .lone_surrogates => blk: {
                try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plc-lone.sh", .data = LONE_SURROGATE_SERVER });
                break :blk try std.fmt.allocPrint(gpa, "{{\"mcpServers\":{{\"plc\":{{\"command\":\"/bin/sh\",\"args\":[\"{s}/plc-lone.sh\",\"{s}/{s}\"]}}}}}}", .{ root, cwd, MOCK_MCP });
            },
            .failing => blk: {
                try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plc-fail.sh", .data = FAILING_SERVER });
                break :blk try std.fmt.allocPrint(gpa, "{{\"mcpServers\":{{\"plc\":{{\"command\":\"/bin/sh\",\"args\":[\"{s}/plc-fail.sh\",\"{s}/{s}\"]}}}}}}", .{ root, cwd, MOCK_MCP });
            },
        };
        defer gpa.free(config);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });

        const home_z = try gpa.dupeZ(u8, root);
        defer gpa.free(home_z);
        self.guards = .{
            try EnvGuard.set("HOME", home_z.ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
            try EnvGuard.set("CODEX_HOME", null),
        };
    }

    fn deinit(self: *Home) void {
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.tmp.cleanup();
    }
};

const Session = struct {
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,

    fn init(self: *Session, base_url: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const url = try a.dupeZ(u8, base_url);
        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", url.ptr, "--model", "test-model" };
        const config = cc.parseArgsForTest(&argv, a);
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
};

fn expectLine(screen: []const u8, line: []const u8) !void {
    var rows = std.mem.splitScalar(u8, screen, '\n');
    while (rows.next()) |row| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, row, " "), line)) return;
    }
    std.debug.print("no row equal to {s}\nscreen:\n{s}\n", .{ line, screen });
    return error.TestExpectedEqual;
}

test "L2 an MCP tool call reaches the TUI as a tool line: the tool and its arguments, then what the server returned" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var home: Home = undefined;
    try home.init(.echo);
    defer home.deinit();

    const bodies = [_][]const u8{ MCP_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(gpa);
    defer gpa.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    _ = app.dyn_registry.find(MCP_TOOL) orelse return error.McpToolNotRegistered;

    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 100 });
    defer t.destroy();
    t.region.enterGenerating(app, null);
    var tui = cc.tui_backend.TuiBackend.init(&t.region);
    tui.theme = &t.region.theme;
    tui.alloc = gpa;
    const backend = tui.backend();

    try app.conversation.appendText(.user, "set the conveyor speed");
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 3;
    const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    t.region.leaveGenerating(app);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const second = server.requestAt(1).?.body();
    try std.testing.expect(std.mem.indexOf(u8, second, MESSAGE) != null);

    const screen = try t.transcriptAlloc(.{});
    defer gpa.free(screen);
    try expectLine(screen, "⏺ " ++ MCP_TOOL ++ "(message: \"" ++ MESSAGE ++ "\")");
    try expectLine(screen, "  ⎿  " ++ MESSAGE);
    try std.testing.expect(std.mem.indexOf(u8, screen, "\"content\"") == null);
    const tool_row = std.mem.indexOf(u8, screen, "⏺ " ++ MCP_TOOL).?;
    const reply_row = std.mem.indexOf(u8, screen, "speed set") orelse return error.TestExpectedEqual;
    try std.testing.expect(tool_row < reply_row);
}

fn expectRowsInOrder(screen: []const u8, rows: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, screen, '\n');
    var next: usize = 0;
    var previous_matched = false;
    while (lines.next()) |line| {
        if (next == rows.len) return;
        const row = std.mem.trimEnd(u8, line, " ");
        if (std.mem.eql(u8, row, rows[next])) {
            next += 1;
            previous_matched = true;
        } else if (previous_matched) break;
    }
    if (next == rows.len) return;
    std.debug.print("rows not found one after another, stopped before {s}\nscreen:\n{s}\n", .{ rows[next], screen });
    return error.TestExpectedEqual;
}

test "L2 two MCP calls in one reply each reach the TUI as their call line with their own result right under it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var home: Home = undefined;
    try home.init(.echo);
    defer home.deinit();

    const bodies = [_][]const u8{ PAIR_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(gpa);
    defer gpa.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    _ = app.dyn_registry.find(MCP_TOOL) orelse return error.McpToolNotRegistered;

    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 100 });
    defer t.destroy();
    t.region.enterGenerating(app, null);
    var tui = cc.tui_backend.TuiBackend.init(&t.region);
    tui.theme = &t.region.theme;
    tui.alloc = gpa;
    const backend = tui.backend();

    try app.conversation.appendText(.user, "echo two things");
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 3;
    const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    t.region.leaveGenerating(app);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());

    const screen = try t.transcriptAlloc(.{});
    defer gpa.free(screen);
    try expectRowsInOrder(screen, &.{
        "⏺ " ++ MCP_TOOL ++ "(message: \"first call\")",
        "  ⎿  first call",
        "⏺ " ++ MCP_TOOL ++ "(message: \"second call\")",
        "  ⎿  second call",
    });
}

fn toolResultContent(body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("messages").?.array.items) |message| {
        const content = message.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |block| {
            if (block != .object) continue;
            const kind = block.object.get("type") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, "tool_result")) continue;
            const inner = block.object.get("content") orelse continue;
            if (inner == .string) return gpa.dupe(u8, inner.string);
        }
    }
    return error.NoToolResult;
}

test "L2 an MCP result whose text holds half a surrogate pair reaches the model as text with U+FFFD, not as invalid JSON" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var home: Home = undefined;
    try home.init(.lone_surrogates);
    defer home.deinit();

    const call = try toolUseSse(gpa, "{\"message\":\"a LONE-HIGH b LONE-LOW c\"}");
    defer gpa.free(call);
    const bodies = [_][]const u8{ call, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(gpa);
    defer gpa.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    _ = app.dyn_registry.find(MCP_TOOL) orelse return error.McpToolNotRegistered;

    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 100 });
    defer t.destroy();
    t.region.enterGenerating(app, null);
    var tui = cc.tui_backend.TuiBackend.init(&t.region);
    tui.theme = &t.region.theme;
    tui.alloc = gpa;
    const backend = tui.backend();

    try app.conversation.appendText(.user, "echo it back");
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 3;
    const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    t.region.leaveGenerating(app);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const second = server.requestAt(1).?.body();
    const result_json = try toolResultContent(second);
    defer gpa.free(result_json);
    const result_value = try std.json.parseFromSlice(std.json.Value, gpa, result_json, .{});
    defer result_value.deinit();
    const blocks = result_value.value.object.get("content").?.array.items;
    try std.testing.expectEqualStrings("a \u{FFFD} b \u{FFFD} c", blocks[0].object.get("text").?.string);
    try std.testing.expect(std.mem.indexOf(u8, second, "invalid_json") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"is_error\":true") == null);

    const screen = try t.transcriptAlloc(.{});
    defer gpa.free(screen);
    try expectLine(screen, "  ⎿  a \u{FFFD} b \u{FFFD} c");
}

test "L2 an MCP call the server marks as failed shows its first line of text in the TUI, not the server's JSON" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var home: Home = undefined;
    try home.init(.failing);
    defer home.deinit();

    const call = try toolUseSse(gpa, "{\"message\":\"line 3 is locked\\ncall the operator\"}");
    defer gpa.free(call);
    const bodies = [_][]const u8{ call, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(gpa);
    defer gpa.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    _ = app.dyn_registry.find(MCP_TOOL) orelse return error.McpToolNotRegistered;

    const t = try region_harness.Term.create(gpa, .{ .rows = 24, .cols = 100 });
    defer t.destroy();
    t.region.enterGenerating(app, null);
    var tui = cc.tui_backend.TuiBackend.init(&t.region);
    tui.theme = &t.region.theme;
    tui.alloc = gpa;
    const backend = tui.backend();

    try app.conversation.appendText(.user, "set the conveyor speed");
    var options = cc.session_service.buildRunOptions(app, null);
    options.max_turns = 3;
    const result = try cc.agent_loop.run(&app.conversation, app.provider(), app.tool_defs, &app.permission_ctx, options, &backend, app.allocator);
    t.region.leaveGenerating(app);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const second = server.requestAt(1).?.body();
    try std.testing.expect(std.mem.indexOf(u8, second, "line 3 is locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"is_error\":true") != null);

    const screen = try t.transcriptAlloc(.{});
    defer gpa.free(screen);
    try expectLine(screen, "⏺ " ++ MCP_TOOL ++ "(message: \"line 3 is locked\\ncall the operator\")");
    try expectLine(screen, "  ⎿  line 3 is locked");
    var rows = std.mem.splitScalar(u8, screen, '\n');
    while (rows.next()) |row| {
        const text = std.mem.trim(u8, row, " ⎿");
        if (std.mem.eql(u8, text, "call the operator")) return error.TestExpectedEqual;
    }
    try std.testing.expect(std.mem.indexOf(u8, screen, "\"content\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "isError") == null);
}
