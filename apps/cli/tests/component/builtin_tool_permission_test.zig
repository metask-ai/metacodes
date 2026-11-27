const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

const ui_request = cc.ui_request;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const MARKER = "monitor-ran";

fn toolUseSse(a: std.mem.Allocator, id: []const u8, name: []const u8, escaped_input: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_",
        id,
        "\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n",
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"",
        id,
        "\",\"name\":\"",
        name,
        "\",\"input\":{}}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"",
        escaped_input,
        "\"}}\n\n",
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n",
        "data: {\"type\":\"message_stop\"}\n\n",
    });
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

const Home = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [4]EnvGuard,

    fn init(self: *Home, settings: ?[]const u8) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..len];
        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes");
        if (settings) |json| {
            try self.tmp.dir.createDirPath(std.testing.io, ".claude");
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".claude/settings.json", .data = json });
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

    fn markerPath(self: *const Home, buf: []u8) ![:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ self.root, MARKER });
    }

    fn commandRan(self: *const Home) !bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        return pfs.exists((try self.markerPath(&buf)).ptr);
    }

    fn waitForCommand(self: *const Home) !bool {
        var waited_ms: u32 = 0;
        while (waited_ms < 5000) : (waited_ms += 20) {
            if (try self.commandRan()) return true;
            cc.util_time.sleepMs(20);
        }
        return self.commandRan();
    }
};

const Host = struct {
    home: *const Home,
    answers: []const ui_request.PermissionChoice,
    asked: usize = 0,
    asked_for: [4][32]u8 = undefined,
    asked_for_len: [4]usize = .{ 0, 0, 0, 0 },
    ran_before_answer: bool = false,

    fn request(
        raw: *anyopaque,
        _: ui_request.SessionId,
        _: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *Host = @ptrCast(@alignCast(raw));
        if (req.* != .permission) return .unavailable;
        const index = self.asked;
        self.asked += 1;
        if (index < self.asked_for.len) {
            const tool = req.permission.tool;
            self.asked_for_len[index] = @min(tool.len, self.asked_for[index].len);
            @memcpy(self.asked_for[index][0..self.asked_for_len[index]], tool[0..self.asked_for_len[index]]);
        }
        self.ran_before_answer = self.ran_before_answer or try self.home.commandRan();
        out.* = .{ .permission = if (index < self.answers.len) self.answers[index] else .deny_once };
        return .answered;
    }

    fn requester(self: *Host) ui_request.UiRequester {
        return .{ .ctx = @ptrCast(self), .requestFn = request };
    }

    fn askedFor(self: *const Host, index: usize) []const u8 {
        if (index >= self.asked_for.len) return "";
        return self.asked_for[index][0..self.asked_for_len[index]];
    }
};

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
        self.io_rt = @import("platform").signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Session) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
    }

    fn turn(self: *Session, host: *Host) !cc.agent_loop.StopReason {
        const app = self.app;
        try app.conversation.appendText(.user, "carry on with the task");
        var options = cc.session_service.buildRunOptions(app, null);
        options.max_turns = 5;
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

const MonitorCase = struct {
    mode: [*:0]const u8,
    answer: ui_request.PermissionChoice = .deny_once,
    asks: bool,
    runs: bool,
    refusal: ?[]const u8 = null,
    command: []const u8 = "touch <marker>",
    settings: ?[]const u8 = null,
};

const DECLINED = "user declined 'Monitor' via prompt";
const DENIED_BY_MODE = "tool 'Monitor' denied by permission rule or permission mode";
const ALLOW_MONITOR = "{\"permissions\":{\"allow\":[\"Monitor\"]}}";
const READS_KEYCHAIN = ": security find-generic-password -s none -w; touch <marker>";

fn monitorJobs(app: *cc.app_module.App) usize {
    const registry = if (app.jobs) |*jobs| jobs else return 0;
    _ = registry.mu.lock();
    defer _ = registry.mu.unlock();
    return registry.jobs.items.len;
}

fn expectMonitorCase(case: MonitorCase) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var home: Home = undefined;
    try home.init(case.settings);
    defer home.deinit();

    var marker_buf: [std.fs.max_path_bytes]u8 = undefined;
    const marker = try home.markerPath(&marker_buf);
    const command = try std.mem.replaceOwned(u8, a, case.command, "<marker>", marker);
    defer a.free(command);
    const input = try std.fmt.allocPrint(a, "{{\\\"command\\\":\\\"{s}\\\",\\\"description\\\":\\\"x\\\"}}", .{command});
    defer a.free(input);
    const monitor_sse = try toolUseSse(a, "tu_monitor", "Monitor", input);
    defer a.free(monitor_sse);

    const bodies = [_][]const u8{ monitor_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, case.mode);
    defer session.deinit();
    if (session.app.sandboxPtr()) |sandbox| try std.testing.expect(!sandbox.enabled);

    const answers = [_]ui_request.PermissionChoice{case.answer};
    var host = Host{ .home = &home, .answers = &answers };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, try session.turn(&host));
    const ran = if (case.runs) try home.waitForCommand() else try home.commandRan();
    const jobs = monitorJobs(session.app);
    errdefer std.debug.print("mode={s} answer={s}: asked {d} time(s), command ran={}, jobs={d}\n", .{
        case.mode,
        @tagName(case.answer),
        host.asked,
        ran,
        jobs,
    });

    try std.testing.expectEqual(@as(usize, if (case.asks) 1 else 0), host.asked);
    if (case.asks) {
        try std.testing.expectEqualStrings("Monitor", host.askedFor(0));
        try std.testing.expect(!host.ran_before_answer);
    }
    try std.testing.expectEqual(case.runs, ran);
    if (!case.runs) try std.testing.expectEqual(@as(usize, 0), jobs);

    try std.testing.expect(server.requestCount() >= 2);
    const second = server.requestAt(1).?.body();
    if (case.refusal) |refusal| {
        try std.testing.expect(std.mem.indexOf(u8, second, refusal) != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, second, DECLINED) == null);
        try std.testing.expect(std.mem.indexOf(u8, second, DENIED_BY_MODE) == null);
    }
}

test "L2 default asks before Monitor starts a command, and deny_once leaves it unrun" {
    try expectMonitorCase(.{ .mode = "default", .answer = .deny_once, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 default asks before Monitor starts a command, and allow_once runs it" {
    try expectMonitorCase(.{ .mode = "default", .answer = .allow_once, .asks = true, .runs = true });
}

test "L2 acceptEdits asks before Monitor starts a command" {
    try expectMonitorCase(.{ .mode = "acceptEdits", .answer = .deny_once, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 auto asks before Monitor starts a command" {
    try expectMonitorCase(.{ .mode = "auto", .answer = .deny_once, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 dontAsk denies Monitor without asking" {
    try expectMonitorCase(.{ .mode = "dontAsk", .asks = false, .runs = false, .refusal = DENIED_BY_MODE });
}

test "L2 bypassPermissions runs Monitor without asking" {
    try expectMonitorCase(.{ .mode = "bypassPermissions", .asks = false, .runs = true });
}

test "L2 an allow rule for Monitor still asks before a command that reads a credential store" {
    try expectMonitorCase(.{ .mode = "default", .settings = ALLOW_MONITOR, .command = READS_KEYCHAIN, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 bypassPermissions still asks before a Monitor command that reads a credential store" {
    try expectMonitorCase(.{ .mode = "bypassPermissions", .command = READS_KEYCHAIN, .asks = true, .runs = false, .refusal = DECLINED });
}

test "L2 an allow rule for Monitor runs a command that reads no credential store without asking" {
    try expectMonitorCase(.{ .mode = "default", .settings = ALLOW_MONITOR, .asks = false, .runs = true });
}

const WorktreeCase = struct {
    mode: [*:0]const u8,
    then_exit: bool,
    answers: []const ui_request.PermissionChoice = &.{},
    asked: []const []const u8,
    root_moved: bool,
};

fn expectWorktreeCase(case: WorktreeCase) !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var home: Home = undefined;
    try home.init(null);
    defer home.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const process_cwd = try a.dupeZ(u8, pfs.getCwd(&cwd_buf) orelse return error.NoCwd);
    defer a.free(process_cwd);
    defer _ = pfs.chdir(process_cwd.ptr);

    try home.tmp.dir.createDirPath(std.testing.io, "elsewhere");
    const elsewhere = try std.fmt.allocPrint(a, "{s}/elsewhere", .{home.root});
    defer a.free(elsewhere);
    const enter_input = try std.fmt.allocPrint(a, "{{\\\"path\\\":\\\"{s}\\\"}}", .{elsewhere});
    defer a.free(enter_input);
    const enter_sse = try toolUseSse(a, "tu_enter", "EnterWorktree", enter_input);
    defer a.free(enter_sse);
    const exit_sse = try toolUseSse(a, "tu_exit", "ExitWorktree", "{\\\"action\\\":\\\"keep\\\"}");
    defer a.free(exit_sse);

    const with_exit = [_][]const u8{ enter_sse, exit_sse, FINAL_SSE };
    const enter_only = [_][]const u8{ enter_sse, FINAL_SSE };
    const bodies: []const []const u8 = if (case.then_exit) &with_exit else &enter_only;
    var server = try harness.MockServer.startCassette(bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, case.mode);
    defer session.deinit();
    const original_root = try a.dupe(u8, session.app.cwdAbs());
    defer a.free(original_root);

    var host = Host{ .home = &home, .answers = case.answers };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, try session.turn(&host));
    const root = session.app.cwdAbs();
    errdefer std.debug.print("mode={s} then_exit={}: asked {d} time(s) [{s}] [{s}], working root {s}\n", .{
        case.mode,
        case.then_exit,
        host.asked,
        host.askedFor(0),
        host.askedFor(1),
        root,
    });

    try std.testing.expectEqual(case.asked.len, host.asked);
    for (case.asked, 0..) |name, index| try std.testing.expectEqualStrings(name, host.askedFor(index));
    if (case.root_moved) {
        try std.testing.expectEqualStrings(elsewhere, root);
    } else {
        try std.testing.expectEqualStrings(original_root, root);
    }
}

test "L2 default asks before EnterWorktree moves the working root, and deny_once leaves it in place" {
    try expectWorktreeCase(.{
        .mode = "default",
        .then_exit = false,
        .answers = &.{.deny_once},
        .asked = &.{"EnterWorktree"},
        .root_moved = false,
    });
}

test "L2 default asks before EnterWorktree and before ExitWorktree" {
    try expectWorktreeCase(.{
        .mode = "default",
        .then_exit = true,
        .answers = &.{ .allow_once, .deny_once },
        .asked = &.{ "EnterWorktree", "ExitWorktree" },
        .root_moved = true,
    });
}

test "L2 acceptEdits and auto ask before EnterWorktree moves the working root" {
    try expectWorktreeCase(.{
        .mode = "acceptEdits",
        .then_exit = false,
        .answers = &.{.deny_once},
        .asked = &.{"EnterWorktree"},
        .root_moved = false,
    });
    try expectWorktreeCase(.{
        .mode = "auto",
        .then_exit = false,
        .answers = &.{.deny_once},
        .asked = &.{"EnterWorktree"},
        .root_moved = false,
    });
}

test "L2 bypassPermissions moves the working root with EnterWorktree and back with ExitWorktree without asking" {
    try expectWorktreeCase(.{
        .mode = "bypassPermissions",
        .then_exit = false,
        .asked = &.{},
        .root_moved = true,
    });
    try expectWorktreeCase(.{
        .mode = "bypassPermissions",
        .then_exit = true,
        .asked = &.{},
        .root_moved = false,
    });
}
