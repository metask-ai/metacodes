//! L2 for #484: a session with no usable model is its own state, not an
//! empty key.
//!
//! In process, on a real `App` built unbound (what `main` builds for the
//! interactive TUI when no credential resolves), pointed at a MockServer with
//! the startup `/v1/models` probe on:
//! - init sends nothing and opens no session directory;
//! - the banner line says it is not set; the reminder names this state
//!   root's `.env` and the provider keys the environment holds, by name;
//! - a request that reaches the transport anyway is refused before it is
//!   sent;
//! - choosing a route that has a key in `/model` with the durable scope binds
//!   the session, opens its directory, and is what the next plain start
//!   resolves to.
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`): without a credential the
//! uses nobody watches — `-p`, `serve`, `--web`, a REPL fed by a pipe — still
//! stop at once, non-zero, with the sign-in hint and no request; so does an
//! incomplete Metask sign-in under `-p`.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const testing = std.testing;
const App = cc.app_module.App;

const PLACEHOLDER = "sk-placeholder-never-sent";

/// Sets (or unsets, with null) one variable and puts the old value back.
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
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

/// Every built-in provider's key variable and what chooses a provider: the
/// developer's environment must decide nothing here.
const cleared = [_][*:0]const u8{
    "METASK_API_KEY",     "OPENAI_API_KEY",           "GEMINI_API_KEY",        "GOOGLE_API_KEY",
    "ZAI_API_KEY",        "GLM_API_KEY",              "Z_AI_API_KEY",          "DEEPSEEK_API_KEY",
    "KIMI_API_KEY",       "MOONSHOT_API_KEY",         "KIMI_CODE_API_KEY",     "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY",    "AWS_BEARER_TOKEN_BEDROCK", "METACODES_PROVIDER",    "METACODES_MODEL",
    "METACODES_BASE_URL", "METASK_GATEWAY_URL",       "METACODES_CONFIG_FILE", "METACODES_AUTH_FILE",
};

/// A scratch state root, working directory and home; the environment cleared
/// of keys, the probe left on, no TinyKG start, no advisor.
const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    state: []const u8,
    work: []const u8,
    home: []const u8,
    guards: [cleared.len + 6]EnvGuard = undefined,
    count: usize = 0,

    fn init(self: *Case) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.count = 0;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ root, "state" });
        self.work = try std.fs.path.join(a, &.{ root, "work" });
        self.home = try std.fs.path.join(a, &.{ root, "home" });
    }

    /// The in-process environment: no key, HOME and the state root here.
    fn enter(self: *Case) !void {
        const a = self.arena_state.allocator();
        for (cleared) |name| try self.guard(name, null);
        try self.guard("HOME", (try a.dupeZ(u8, self.home)).ptr);
        // `main`'s stored-default reader resolves the state root itself.
        try self.guard("METACODES_HOME", (try a.dupeZ(u8, self.state)).ptr);
        // The probe stays on: an unbound start must not run it.
        try self.guard("METACODES_NO_PROBE", null);
        try self.guard("METACODES_KG_AUTOSTART", "0");
        try self.guard("METACODES_JEV_URL", "off");
    }

    fn guard(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        self.guards[self.count] = try EnvGuard.set(name, value);
        self.count += 1;
    }

    fn deinit(self: *Case) void {
        while (self.count > 0) {
            self.count -= 1;
            self.guards[self.count].restore();
        }
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Session directories under `<state>/projects/<project>/` (anything but
    /// the project's memory directory).
    fn sessionDirectories(self: *Case) !usize {
        const a = self.arena();
        const projects = try std.fs.path.join(a, &.{ self.state, "projects" });
        var dir = std.Io.Dir.openDirAbsolute(testing.io, projects, .{ .iterate = true }) catch return 0;
        defer dir.close(testing.io);
        var found: usize = 0;
        var it = dir.iterate();
        while (try it.next(testing.io)) |project| {
            var sub = try dir.openDir(testing.io, project.name, .{ .iterate = true });
            defer sub.close(testing.io);
            var entries = sub.iterate();
            while (try entries.next(testing.io)) |entry| {
                if (!std.mem.eql(u8, entry.name, "memory")) found += 1;
            }
        }
        return found;
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find `{s}` in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("`{s}` must not appear in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

/// The App `main` builds for the TUI when no credential resolves.
fn unboundApp(case: *Case, io: std.Io, base_url: []const u8) !*App {
    return unboundAppWithKey(case, io, base_url, "");
}

/// `unboundApp` handed `key` anyway: what the unbound state itself, not the
/// empty key, keeps from being sent.
fn unboundAppWithKey(case: *Case, io: std.Io, base_url: []const u8, key: []const u8) !*App {
    const a = case.arena();
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", (try a.dupeZ(u8, base_url)).ptr }, a);
    try testing.expect(config.parse_error == null);
    config.state_root = case.state;
    return App.initWithOptions(testing.allocator, io, config, key, .{
        .models_cache = true,
        .route_state = .{ .unbound = .nothing_configured },
    });
}

test "unbound: init sends nothing, opens no session directory, and the banner says not set (#484)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    try case.guard("DEEPSEEK_API_KEY", PLACEHOLDER);
    var server = try harness.MockServer.startRepeatingStatus("{\"data\":[]}", "HTTP/1.1 200 OK", "");
    defer server.stop();
    const a = case.arena();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try unboundApp(&case, io_runtime.io(), try server.urlOwned(a));
    defer app.deinit();

    // No `/v1/models` probe, no key list, nothing else.
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try testing.expect(app.sessionDir() == null);
    try testing.expectEqual(@as(usize, 0), try case.sessionDirectories());
    try testing.expect(app.unbound().? == .nothing_configured);
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("not set — /login, or configure .env", app.bannerModelLine(&line_buf));

    // The reminder: this state root's .env (no template is there), the shell
    // key by name only, the guide.
    var reminder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reminder.deinit();
    try app.writeUnboundReminder(&reminder.writer);
    const env_path = try std.fs.path.join(a, &.{ case.state, ".env" });
    try expectContains(reminder.written(), "No model is set up.\n  Sign in to Metask:            /login\n");
    try expectContains(reminder.written(), try std.fmt.allocPrint(a, "  Or use your own provider key: edit {s}, then restart\n", .{env_path}));
    try expectContains(reminder.written(), "  Or use a key in your shell:   /model (DEEPSEEK_API_KEY)\n");
    try expectContains(reminder.written(), "https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md");
    try expectAbsent(reminder.written(), PLACEHOLDER);
    try expectAbsent(reminder.written(), "template");

    // A request that got past the REPL would still not leave: the session
    // holds no key, and the transport refuses an empty one before it sends.
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    try testing.expectError(error.InvalidCredential, app.provider().sendStream(&messages, null, null, null, null, null, ""));
    try testing.expectEqual(@as(usize, 0), server.requestCount());

    // `/clear` starts a new session: still no directory while unbound.
    app.clearConversation();
    try testing.expect(app.sessionDir() == null);
    try testing.expectEqual(@as(usize, 0), try case.sessionDirectories());

    // The state, not the empty key, is what keeps init quiet: handed a key,
    // an unbound App still neither probes nor records a key route.
    const keyed = try unboundAppWithKey(&case, io_runtime.io(), try server.urlOwned(a), "sk-unbound-but-keyed");
    defer keyed.deinit();
    try testing.expectEqual(@as(usize, 0), server.requestCount());
    try testing.expect(keyed.metask_key_route == null);
    try testing.expect(keyed.sessionDir() == null);
}

test "unbound: the template is named when an install wrote it (#484)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    try case.tmp.dir.writeFile(testing.io, .{ .sub_path = "state/.env.example", .data = "# template\n" });
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try unboundApp(&case, io_runtime.io(), "http://127.0.0.1:9/v1/messages");
    defer app.deinit();
    var reminder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reminder.deinit();
    try app.writeUnboundReminder(&reminder.writer);
    try expectContains(reminder.written(), ".env (template: .env.example), then restart\n");
    try expectAbsent(reminder.written(), "in your shell");
}

test "unbound: a durable /model choice binds the session, opens its directory, and is the next start's default (#484)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    try case.guard("DEEPSEEK_API_KEY", PLACEHOLDER);
    var server = try harness.MockServer.startRepeatingStatus("{\"data\":[]}", "HTTP/1.1 200 OK", "");
    defer server.stop();
    const a = case.arena();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try unboundApp(&case, io_runtime.io(), try server.urlOwned(a));
    defer app.deinit();

    // `/model` → DeepSeek → "every future session" (the picker's commit).
    const host = try app.providerHost();
    const offer = for (host.kernel.catalogSnapshot().items()) |*candidate| {
        if (candidate.provider_id.eqlText("deepseek") and std.mem.eql(u8, candidate.request_model_id, "deepseek-v4-pro")) break candidate;
    } else return error.OfferMissing;
    const outcome = try app.commitModelSelection(.{
        .offer_id = offer.offer_id,
        .offer_revision = offer.offer_revision,
        .controls = .{},
        .scope = .global,
    });
    try testing.expect(outcome == .committed);

    // Bound, with the key from the shell; the session has its directory now.
    try testing.expect(app.unbound() == null);
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("deepseek-v4-pro · from shell", app.bannerModelLine(&line_buf));
    const dir = app.sessionDir() orelse return error.NoSessionDirectory;
    try std.Io.Dir.cwd().access(testing.io, dir, .{});
    try testing.expectEqual(@as(usize, 1), try case.sessionDirectories());
    // Binding sends nothing either.
    try testing.expectEqual(@as(usize, 0), server.requestCount());

    // The next plain start resolves the stored default to DeepSeek.
    var next = cc.parseArgsForTest(&.{"metacodes"}, a);
    next.state_root = case.state;
    try testing.expect(cc.applyPersistedGlobalSelection(&next, a));
    try testing.expectEqualStrings("deepseek", next.resolved_provider_id orelse "");
    try testing.expectEqualStrings("deepseek-v4-pro", next.model);
}

// ── through the real CLI ─────────────────────────────────────────────────────

const Run = struct {
    exit_code: i32,
    stderr: []const u8,
};

/// `metacodes --state-dir <state> args…` in `work` with only `env` (and a
/// home, a PATH, no TinyKG start, no advisor) set. Its stdin is not a
/// terminal.
fn runCli(case: *Case, cli: []const u8, env: []const []const u8, args: []const []const u8) !Run {
    const a = case.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const base = [_][]const u8{
        "/usr/bin/env",
        try std.fmt.allocPrint(a, "HOME={s}", .{case.home}),
        "PATH=/usr/bin:/bin",
        "METACODES_KG_AUTOSTART=0",
        "METACODES_JEV_URL=off",
    };
    for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
    for ([_][]const u8{ cli, "--state-dir", case.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(
        argv.items,
        a,
        null,
        60_000,
        null,
        cc.tools_common.MAX_SPAWN_CAPTURE_BYTES,
        case.work,
    );
    return .{ .exit_code = out.exit_code, .stderr = out.stderr };
}

test "unbound: without a credential -p, serve, --web and a piped REPL stop at once, non-zero, sending nothing (#484)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    const cli = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
    var server = try harness.MockServer.startRepeatingStatus("{\"data\":[]}", "HTTP/1.1 200 OK", "");
    defer server.stop();
    const url = try server.urlOwned(a);
    const base_url = try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{url[0 .. url.len - "/v1/messages".len]});

    const uses = [_][]const []const u8{
        &.{ "-p", "hi" },
        &.{ "serve", "0" },
        &.{ "--web", "0" },
        // No `-p`, but nobody at a terminal either: not the TUI.
        &.{},
    };
    for (uses) |args| {
        const run = try runCli(&case, cli, &.{base_url}, args);
        errdefer std.debug.print("args {any}: exit {d}; stderr:\n{s}\n", .{ args, run.exit_code, run.stderr });
        try testing.expect(run.exit_code != 0);
        try expectContains(run.stderr, "Authentication required.");
        try expectContains(run.stderr, "No token value was printed.");
    }
    try testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "unbound: an incomplete Metask sign-in still stops -p (#484)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    const cli = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
    var server = try harness.MockServer.startRepeatingStatus("{\"data\":[]}", "HTTP/1.1 200 OK", "");
    defer server.stop();
    const url = try server.urlOwned(a);
    const base_url = try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{url[0 .. url.len - "/v1/messages".len]});
    const auth = try std.fmt.allocPrint(a,
        \\{{"oauth":{{"access_token":"at-incomplete","refresh_token":"rt-incomplete","token_type":"Bearer","expires_at":{d}}}}}
    , .{cc.util_time.nowUnix() + 86_400});
    try case.tmp.dir.writeFile(testing.io, .{ .sub_path = "state/auth.json", .data = auth });
    const auth_path = try std.fs.path.joinZ(a, &.{ case.state, "auth.json" });
    _ = @import("platform").fs.chmod(auth_path.ptr, 0o600);

    const run = try runCli(&case, cli, &.{base_url}, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expect(run.exit_code != 0);
    try expectContains(run.stderr, "Metask login is incomplete.");
    try expectAbsent(run.stderr, "at-incomplete");
    try testing.expectEqual(@as(usize, 0), server.requestCount());
}
