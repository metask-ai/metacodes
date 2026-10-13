//! L2: EnterWorktree / ExitWorktree move the session's working root, not just
//! the process cwd.
//!
//! Before: EnterWorktree chdir'ed the process and recorded the entry, but the
//! session root (`App.cwd_abs`) stayed put. Every tool that works from it -
//! Bash's child cwd first of all - kept running in the original checkout for
//! the rest of the Run and every later one, while file tools resolving
//! relative paths followed the process cwd: two trees at once. The worktree
//! stack itself was kept in the per-call arena of the EnterWorktree call, so
//! ExitWorktree read freed memory.
//!
//! What is locked here, against the real App, agent loop, tools and a mock
//! provider over a real git repository:
//!   - a later tool call in the same Run, the next Run's options and system
//!     prompt, and Bash all follow EnterWorktree; ExitWorktree brings them back;
//!   - in one response `[EnterWorktree, Bash]`, Bash is not run ahead of
//!     EnterWorktree by the streaming prefetch;
//!   - the stack survives the call that pushed it (the App runs on the testing
//!     allocator, as the product's on `init.gpa`, so a per-call arena's memory
//!     is really freed, and poisoned, once the call returns).
//!
//! Cross-module: app + session_service + agent_loop + tool_exec + tools/worktree
//! + tools/bash. chdir is process-wide: each test restores the process cwd.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;

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

const Call = struct { name: []const u8, input: []const u8 };

/// One assistant message with a tool_use per call, ids `tu_<first_id + i>`.
fn toolUseMessage(a: std.mem.Allocator, first_id: usize, calls: []const Call) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tools\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    for (calls, 0..) |call, i| {
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_{d}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n", .{ i, first_id + i, call.name });
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{f}}}}}\n\n", .{ i, std.json.fmt(call.input, .{}) });
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{i});
    }
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// Every tool_result the loop emits, keyed by tool_use id.
const ToolResults = struct {
    allocator: std.mem.Allocator,
    ids: std.ArrayList([]u8) = .empty,
    contents: std.ArrayList([]u8) = .empty,

    fn deinit(self: *ToolResults) void {
        for (self.ids.items) |id| self.allocator.free(id);
        for (self.contents.items) |content| self.allocator.free(content);
        self.ids.deinit(self.allocator);
        self.contents.deinit(self.allocator);
    }

    fn backend(self: *ToolResults) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
        const self: *ToolResults = @ptrCast(@alignCast(raw));
        switch (event) {
            .tool_result => |result| {
                if (result.content.len == 0) return; // the empty pre-announcement
                const id = self.allocator.dupe(u8, result.id) catch return;
                const content = self.allocator.dupe(u8, result.content) catch {
                    self.allocator.free(id);
                    return;
                };
                self.ids.append(self.allocator, id) catch {
                    self.allocator.free(id);
                    self.allocator.free(content);
                    return;
                };
                self.contents.append(self.allocator, content) catch {
                    self.allocator.free(self.ids.pop().?);
                    self.allocator.free(content);
                };
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn get(self: *const ToolResults, index: usize) ![]const u8 {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "tu_{d}", .{index});
        var found: ?[]const u8 = null;
        for (self.ids.items, self.contents.items) |seen, content| {
            if (std.mem.eql(u8, seen, id)) found = content;
        }
        return found orelse error.MissingToolResult;
    }
};

fn runGit(a: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |item| if (item) |z| a.free(std.mem.span(z));
        argv.deinit(a);
    }
    for ([_][]const u8{ "/usr/bin/env", "git", "-C", cwd }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 30_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) {
        std.debug.print("git {s} failed: {s}\n", .{ args[0], out.stderr });
        return error.GitFailed;
    }
}

fn chdirZ(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (std.c.chdir(z.ptr) != 0) return error.ChdirFailed;
}

/// A real App started inside a fresh git repository, its provider a mock
/// server playing `responses` in order. `setup` must run on the caller's
/// final address (the arena and io runtime are captured by pointer).
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    probe_guard: EnvGuard,
    autostart_guard: EnvGuard,
    server: *harness.MockServer,
    previous_cwd: []u8,
    app: *cc.app_module.App,
    /// The repository's physical path.
    repo: []const u8,

    fn setup(self: *Fixture, responses: []const []const u8) !void {
        return self.setupWith(responses, null);
    }

    /// `user_settings`: written to `<HOME>/.claude/settings.json` before the App starts.
    fn setupWith(self: *Fixture, responses: []const []const u8, user_settings: ?[]const u8) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);

        self.arena = std.heap.ArenaAllocator.init(a);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        const root = try allocator.dupe(u8, root_buffer[0..len]);
        self.repo = try std.fmt.allocPrint(allocator, "{s}/repo", .{root});
        try self.tmp.dir.createDirPath(std.testing.io, "repo");
        try runGit(a, self.repo, &.{ "init", "-q" });
        try runGit(a, self.repo, &.{ "config", "user.email", "test@metacodes.local" });
        try runGit(a, self.repo, &.{ "config", "user.name", "metacodes-test" });
        try runGit(a, self.repo, &.{ "commit", "-q", "--allow-empty", "-m", "seed" });

        if (user_settings) |settings| {
            try self.tmp.dir.createDirPath(std.testing.io, ".claude");
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".claude/settings.json", .data = settings });
        }
        const home_z = try allocator.dupeZ(u8, root);
        self.home_guard = try EnvGuard.set(a, "HOME", home_z.ptr);
        errdefer self.home_guard.restore();
        self.probe_guard = try EnvGuard.set(a, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();
        self.autostart_guard = try EnvGuard.set(a, "METACODES_KG_AUTOSTART", "0");
        errdefer self.autostart_guard.restore();

        self.server = try harness.MockServer.startCassette(responses, 0);
        errdefer self.server.stop();
        const url_z = try allocator.dupeZ(u8, try self.server.urlOwned(allocator));
        const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", "test-model", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        // The App snapshots the process cwd as its session root.
        self.previous_cwd = try cc.util_fs.getCwd(a);
        errdefer a.free(self.previous_cwd);
        try chdirZ(self.repo);
        errdefer chdirZ(self.previous_cwd) catch {};

        self.io_rt = std.Io.Threaded.init(allocator, .{});
        errdefer self.io_rt.deinit();
        // The general-purpose allocator, as the product's `init.gpa`: memory a
        // per-call arena hands back is really freed (and poisoned) here.
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
        try std.testing.expectEqualStrings(self.repo, self.app.cwdAbs());
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        chdirZ(self.previous_cwd) catch {};
        std.testing.allocator.free(self.previous_cwd);
        self.server.stop();
        self.autostart_guard.restore();
        self.probe_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// One Run with the options the product assembles for the main session.
    fn run(self: *Fixture, results: *ToolResults, prompt: []const u8) !void {
        try self.app.conversation.appendText(.user, prompt);
        var jobs = try cc.job_registry.JobRegistry.init(std.testing.allocator);
        defer jobs.deinit();
        var options = cc.session_service.buildRunOptions(self.app, null);
        options.max_turns = 8;
        options.emit_tool_cards = true;
        options.jobs = &jobs;
        const backend = results.backend();
        const result = try cc.agent_loop.run(&self.app.conversation, self.app.provider(), self.app.tool_defs, &self.app.permission_ctx, options, &backend, self.app.allocator);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find\n  {s}\nin\n  {s}\n", .{ needle, haystack });
        return error.TestExpectedSubstring;
    }
}

test "L2 worktree: a later call, the next Run and Bash follow EnterWorktree; ExitWorktree brings them back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX git fixture
    const a = std.testing.allocator;
    const pwd = "{\"command\":\"pwd -P\"}";
    const enter = try toolUseMessage(a, 0, &.{.{ .name = "EnterWorktree", .input = "{\"name\":\"wt-one\"}" }});
    defer a.free(enter);
    const bash_1 = try toolUseMessage(a, 1, &.{.{ .name = "Bash", .input = pwd }});
    defer a.free(bash_1);
    const bash_2 = try toolUseMessage(a, 2, &.{.{ .name = "Bash", .input = pwd }});
    defer a.free(bash_2);
    const exit = try toolUseMessage(a, 3, &.{.{ .name = "ExitWorktree", .input = "{\"action\":\"keep\"}" }});
    defer a.free(exit);
    const bash_4 = try toolUseMessage(a, 4, &.{.{ .name = "Bash", .input = pwd }});
    defer a.free(bash_4);
    const responses = [_][]const u8{ enter, bash_1, FINAL_SSE, bash_2, exit, bash_4, FINAL_SSE };

    var fx: Fixture = undefined;
    try fx.setup(&responses);
    defer fx.deinit();
    var results = ToolResults{ .allocator = a };
    defer results.deinit();
    const worktree = try std.fmt.allocPrint(a, "{s}/.metacodes/worktrees/wt-one", .{fx.repo});
    defer a.free(worktree);

    // Run 1: enter, then a later tool call in the same Run.
    try fx.run(&results, "work in a worktree");
    try expectContains(try results.get(0), "\"entered\":true");
    try expectContains(try results.get(1), worktree);
    try std.testing.expectEqualStrings(worktree, fx.app.cwdAbs());
    try std.testing.expectEqualStrings(worktree, fx.app.permission_ctx.match_ctx.cwd);

    // Run 2: assembled from the App, it starts in the worktree.
    const next = cc.session_service.buildRunOptions(fx.app, null);
    try std.testing.expectEqualStrings(worktree, next.cwd_abs);
    try expectContains(next.system_prompt.?, worktree);
    try fx.run(&results, "still there?");
    try expectContains(try results.get(2), worktree);
    try expectContains(try results.get(3), "\"removed\":false");
    try expectContains(try results.get(3), fx.repo);
    const back = try results.get(4);
    try expectContains(back, fx.repo);
    try std.testing.expect(std.mem.indexOf(u8, back, ".metacodes/worktrees") == null);
    try std.testing.expectEqualStrings(fx.repo, fx.app.cwdAbs());
    try std.testing.expectEqualStrings(fx.repo, fx.app.permission_ctx.match_ctx.cwd);
    const process_cwd = try cc.util_fs.getCwd(a);
    defer a.free(process_cwd);
    try std.testing.expectEqualStrings(fx.repo, process_cwd);
}

test "L2 worktree: Bash after EnterWorktree in the same response is not run ahead of it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX git fixture
    const a = std.testing.allocator;
    const both = try toolUseMessage(a, 0, &.{
        .{ .name = "EnterWorktree", .input = "{\"name\":\"wt-two\"}" },
        .{ .name = "Bash", .input = "{\"command\":\"pwd -P\"}" },
    });
    defer a.free(both);
    const remove = try toolUseMessage(a, 2, &.{.{ .name = "ExitWorktree", .input = "{\"action\":\"remove\",\"discard_changes\":true}" }});
    defer a.free(remove);
    const responses = [_][]const u8{ both, remove, FINAL_SSE };

    var fx: Fixture = undefined;
    try fx.setup(&responses);
    defer fx.deinit();
    var results = ToolResults{ .allocator = a };
    defer results.deinit();
    const worktree = try std.fmt.allocPrint(a, "{s}/.metacodes/worktrees/wt-two", .{fx.repo});
    defer a.free(worktree);

    try fx.run(&results, "enter and look around");
    try expectContains(try results.get(0), "\"entered\":true");
    try expectContains(try results.get(1), worktree);
    try expectContains(try results.get(2), "\"removed\":true");
    try std.testing.expectEqualStrings(fx.repo, fx.app.cwdAbs());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, worktree, .{}));
}

test "L2 worktree: with the sandbox on, Bash can commit in the worktree" {
    // Seatbelt; the fixture lives under .zig-cache/tmp, outside the temp
    // directories every sandboxed command may write.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    const commit = "{\"command\":\"git -c user.email=t@t -c user.name=t commit -q --allow-empty -m from-worktree && git log -1 --format=%s\"}";
    const enter = try toolUseMessage(a, 0, &.{.{ .name = "EnterWorktree", .input = "{\"name\":\"wt-sandbox\"}" }});
    defer a.free(enter);
    const bash = try toolUseMessage(a, 1, &.{.{ .name = "Bash", .input = commit }});
    defer a.free(bash);
    const leave = try toolUseMessage(a, 2, &.{.{ .name = "ExitWorktree", .input = "{\"action\":\"keep\"}" }});
    defer a.free(leave);
    const responses = [_][]const u8{ enter, bash, leave, FINAL_SSE };

    var fx: Fixture = undefined;
    try fx.setupWith(&responses, "{\"sandbox\":{\"enabled\":true}}");
    defer fx.deinit();
    if (fx.app.sandboxPtr() == null or !fx.app.sandboxPtr().?.enabled) return error.SandboxSettingNotLoaded;
    var results = ToolResults{ .allocator = a };
    defer results.deinit();

    try fx.run(&results, "commit in a worktree");
    try expectContains(try results.get(0), "\"entered\":true");
    const committed = try results.get(1);
    try expectContains(committed, "from-worktree");
    try expectContains(committed, "\"exit_code\":0");
}
