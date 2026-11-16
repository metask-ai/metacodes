//! L2 (#473): on an App host an MCP tool asks before it runs, mode by mode, as
//! it does on AgentCore.
//!
//! A real App (`App.init`, with the `.app_init` MCP join that `-p`, `--web`
//! and `serve` start with) connects the stdio mock server named in the user's
//! `config.json` and registers its tools through `registry_bridge`. Each case
//! runs one turn on the Run options the TUI, web and serve hosts assemble
//! (`session_service.buildRunOptions`), with a scripted host in place of their
//! dialog, against a loopback provider whose first answer calls
//! `mcp__plc__echo`, a tool with no annotations. A shell loop in front of the
//! server appends each line it is sent to a log before passing it on, so the
//! test reads what the server received: whether a `tools/call` reached it, and
//! whether one had when the host was asked.
//!
//! Expected, as AgentCore decides a tool that is not a built-in
//! (`external_fallback` in `agentcore/abi_v1.zig`;
//! doc/AGENTCORE_BINARY_ABI.md, the permission order, step 8): `default`,
//! `acceptEdits` and `auto` ask; `dontAsk` denies without asking;
//! `bypassPermissions` runs it; an allow rule (`mcp__plc`, `mcp__plc__*`,
//! `mcp__plc__echo`) runs it without asking. Controls on the same App: the
//! built-in `Read` runs without asking in `default`, and `Grep`, `Glob` and the
//! Skill tool are still allowed there.
//!
//! Cross-module: app + mcp config, client and registry_bridge (a stdio child) +
//! session_service + agent_loop + permission (decision, settings, prompt).

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const ui_request = cc.ui_request;

const MOCK_MCP = "zig-out/bin/mock_mcp_server";
/// The mock lists `echo` with no annotations; registered under server `plc`.
const MCP_TOOL = "mcp__plc__echo";
/// What the model asks the server to echo.
const MESSAGE = "set line 3 to 900 rpm";

fn toolUseSse(comptime id: []const u8, comptime name: []const u8, comptime partial_json: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ partial_json ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const MCP_SSE = toolUseSse("tu_mcp", MCP_TOOL, "{\\\"message\\\":\\\"" ++ MESSAGE ++ "\\\"}");

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Stands in front of the server: appends every line the client sends to the
/// log (`$1`) before it hands the line to the server (`$2`), so a line is in
/// the log by the time the server can answer it.
const WIRE_LOGGER =
    \\while IFS= read -r line; do
    \\  printf '%s\n' "$line" >> "$1"
    \\  printf '%s\n' "$line"
    \\done | "$2"
    \\
;

/// The tool_result texts the model reads when the call did not run.
const DENIED_BY_MODE = "tool '" ++ MCP_TOOL ++ "' denied by permission rule or permission mode";
const DECLINED = "user declined '" ++ MCP_TOOL ++ "' via prompt";

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

/// A temporary HOME as a user sets it up: `~/.metacodes/config.json` names the
/// `plc` server (the mock behind `WIRE_LOGGER`, which logs to `plc-wire.log`),
/// `~/.claude/settings.json` holds the case's allow rule, and one personal
/// Skill makes the App register the Skill tool. Initialized in place: the
/// guards restore the environment in `deinit`.
const Home = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [4]EnvGuard,

    fn init(self: *Home, allow_rule: ?[]const u8) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..len];

        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes");
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plc-wire.sh", .data = WIRE_LOGGER });
        const config = try std.fmt.allocPrint(
            a,
            "{{\"mcpServers\":{{\"plc\":{{\"command\":\"/bin/sh\",\"args\":[\"{s}/plc-wire.sh\",\"{s}/plc-wire.log\",\"{s}/{s}\"]}}}}}}",
            .{ self.root, self.root, cwd, MOCK_MCP },
        );
        defer a.free(config);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });

        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes/skills/linecheck");
        try self.tmp.dir.writeFile(std.testing.io, .{
            .sub_path = ".metacodes/skills/linecheck/SKILL.md",
            .data = "---\nname: linecheck\ndescription: Report the state of a production line.\n---\nReport the state of the line.\n",
        });

        if (allow_rule) |rule| {
            try self.tmp.dir.createDirPath(std.testing.io, ".claude");
            const settings = try std.fmt.allocPrint(a, "{{\"permissions\":{{\"allow\":[\"{s}\"]}}}}", .{rule});
            defer a.free(settings);
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".claude/settings.json", .data = settings });
        }

        const home_z = try a.dupeZ(u8, self.root);
        defer a.free(home_z);
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

    /// `tools/call` requests the server has received so far.
    fn toolCalls(self: *const Home) !usize {
        const a = std.testing.allocator;
        const wire = self.tmp.dir.readFileAlloc(std.testing.io, "plc-wire.log", a, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer a.free(wire);
        return std.mem.count(u8, wire, "\"tools/call\"");
    }
};

/// The host's dialog: counts the permission requests it is shown, notes how
/// many `tools/call` the server had received when it was asked, and answers.
const Host = struct {
    home: *const Home,
    answer: ui_request.PermissionChoice,
    asked: usize = 0,
    asked_for: [64]u8 = undefined,
    asked_for_len: usize = 0,
    calls_when_asked: usize = 0,

    fn request(
        raw: *anyopaque,
        _: ui_request.SessionId,
        _: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (req.* != .permission) return .unavailable;
        self.asked += 1;
        const tool = req.permission.tool;
        self.asked_for_len = @min(tool.len, self.asked_for.len);
        @memcpy(self.asked_for[0..self.asked_for_len], tool[0..self.asked_for_len]);
        self.calls_when_asked += try self.home.toolCalls();
        out.* = .{ .permission = self.answer };
        return .answered;
    }

    fn requester(self: *Host) ui_request.UiRequester {
        return .{ .ctx = @ptrCast(self), .requestFn = request };
    }

    fn askedFor(self: *const Host) []const u8 {
        return self.asked_for[0..self.asked_for_len];
    }
};

/// An App as main.zig builds it for a non-interactive host, in permission
/// `mode`, against `base_url`. Arena-backed like the other App fixtures.
const Session = struct {
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,

    fn init(self: *Session, base_url: []const u8, mode: [*:0]const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const url = try a.dupeZ(u8, base_url);
        const argv = [_][*:0]const u8{ "metacodes", "--permission", mode, "--base-url", url.ptr, "--model", "test-model" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        try std.testing.expectEqual(cc.types_mod.McpConnect.app_init, config.mcp_connect);
        self.io_rt = @import("platform").signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Session) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
    }

    /// One turn on the canonical host Run options with `host` answering
    /// permission requests, as `--web` and `serve` attach their dialog.
    fn turn(self: *Session, host: *Host) !cc.agent_loop.StopReason {
        const app = self.app;
        try app.conversation.appendText(.user, "set the conveyor speed");
        var options = cc.session_service.buildRunOptions(app, null);
        options.max_turns = 3;
        options.ui_requester = host.requester();
        app.permission_ctx.ui_requester = host.requester();
        defer app.permission_ctx.ui_requester = null;
        var render = cc.writer_backend.WriterBackend.initNull();
        const backend = render.backend();
        const result = try cc.agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            options,
            &backend,
            app.allocator,
        );
        return result.stop_reason;
    }
};

const Case = struct {
    mode: [*:0]const u8,
    allow_rule: ?[]const u8 = null,
    /// The host's answer, when it is asked.
    answer: ui_request.PermissionChoice = .allow_once,
    asks: bool,
    runs: bool,
    /// The tool_result the model reads when the call did not run.
    refusal: ?[]const u8 = null,
};

fn expectCase(case: Case) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the /bin/sh logger
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var home: Home = undefined;
    try home.init(case.allow_rule);
    defer home.deinit();

    const bodies = [_][]const u8{ MCP_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var session: Session = undefined;
    try session.init(url, case.mode);
    defer session.deinit();
    const app = session.app;

    // The server's tool went through registry_bridge, as every App host registers it.
    const entry = app.dyn_registry.find(MCP_TOOL) orelse return error.McpToolNotRegistered;
    try std.testing.expectEqualStrings("plc", entry.mcp_server.?);

    var host = Host{ .home = &home, .answer = case.answer };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, try session.turn(&host));
    errdefer std.debug.print("mode={s} allow={s}: asked {d} time(s), server saw {d} tools/call\n", .{
        case.mode,
        case.allow_rule orelse "-",
        host.asked,
        home.toolCalls() catch 0,
    });

    try std.testing.expectEqual(@as(usize, if (case.asks) 1 else 0), host.asked);
    if (case.asks) {
        try std.testing.expectEqualStrings(MCP_TOOL, host.askedFor());
        // Nothing reached the server before the answer.
        try std.testing.expectEqual(@as(usize, 0), host.calls_when_asked);
    }
    try std.testing.expectEqual(@as(usize, if (case.runs) 1 else 0), try home.toolCalls());

    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const second = server.requestAt(1).?.body();
    if (case.refusal) |refusal| {
        try std.testing.expect(std.mem.indexOf(u8, second, refusal) != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, second, DENIED_BY_MODE) == null);
        try std.testing.expect(std.mem.indexOf(u8, second, DECLINED) == null);
    }
}

test "L2 #473 default asks before an MCP tool runs: allow_once runs it, deny_once does not" {
    try expectCase(.{ .mode = "default", .answer = .allow_once, .asks = true, .runs = true });
    try expectCase(.{ .mode = "default", .answer = .deny_once, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 #473 acceptEdits and auto ask before an MCP tool runs" {
    try expectCase(.{ .mode = "acceptEdits", .asks = true, .runs = true });
    try expectCase(.{ .mode = "auto", .asks = true, .runs = true });
    try expectCase(.{ .mode = "auto", .answer = .deny_once, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 #473 dontAsk denies an MCP tool without asking; bypassPermissions runs it without asking" {
    try expectCase(.{ .mode = "dontAsk", .asks = false, .runs = false, .refusal = DENIED_BY_MODE });
    try expectCase(.{ .mode = "bypassPermissions", .asks = false, .runs = true });
}

test "L2 #473 an allow rule for the server or the tool runs an MCP tool without asking" {
    try expectCase(.{ .mode = "default", .allow_rule = "mcp__plc", .asks = false, .runs = true });
    try expectCase(.{ .mode = "default", .allow_rule = "mcp__plc__*", .asks = false, .runs = true });
    try expectCase(.{ .mode = "default", .allow_rule = "mcp__plc__echo", .asks = false, .runs = true });
    // A rule for another server does not reach this one.
    try expectCase(.{ .mode = "default", .allow_rule = "mcp__other", .asks = true, .runs = true });
}

test "L2 #473 on the same App, Read runs without asking in default; Grep, Glob and the Skill tool are still allowed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // the /bin/sh logger
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var home: Home = undefined;
    try home.init(null);
    defer home.deinit();
    try home.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "line3.txt", .data = "line 3 runs at 600 rpm\n" });
    const target = try std.fmt.allocPrint(a, "{s}/line3.txt", .{home.root});
    defer a.free(target);
    const read_json = try std.fmt.allocPrint(a, "{{\\\"file_path\\\":\\\"{s}\\\"}}", .{target});
    defer a.free(read_json);
    const read_sse = try std.mem.concat(a, u8, &.{
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{}}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"",
        read_json,
        "\"}}\n\n",
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n",
        "data: {\"type\":\"message_stop\"}\n\n",
    });
    defer a.free(read_sse);

    const bodies = [_][]const u8{ read_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, "default");
    defer session.deinit();
    const app = session.app;

    var host = Host{ .home = &home, .answer = .deny_once };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, try session.turn(&host));
    try std.testing.expectEqual(@as(usize, 0), host.asked);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, server.requestAt(1).?.body(), "600 rpm") != null);

    // What the permission pass computes for a call on this App (agent_loop:
    // the registry's class, else the name fallback), for the other read
    // built-ins and the Skill tool. A default-mode allow is "no prompt".
    try std.testing.expect(app.dyn_registry.find("Skill") != null);
    const calls = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "Grep", .args = "{\"pattern\":\"rpm\"}" },
        .{ .name = "Glob", .args = "{\"pattern\":\"*.txt\"}" },
        .{ .name = "Skill", .args = "{\"skill\":\"linecheck\"}" },
    };
    for (calls) |call| {
        try std.testing.expect(app.dyn_registry.category(call.name) == null);
        try std.testing.expectEqual(
            cc.permission.PermissionResult.allow,
            cc.permission.checkPermissionClassified(&app.permission_ctx, call.name, call.args, app.dyn_registry.category(call.name)),
        );
    }
    // The same pass on the MCP tool asks.
    try std.testing.expectEqual(
        cc.permission.PermissionResult.ask,
        cc.permission.checkPermissionClassified(&app.permission_ctx, MCP_TOOL, "{\"message\":\"x\"}", app.dyn_registry.category(MCP_TOOL)),
    );
}
