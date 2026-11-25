//! L2 component test: where the System-One advisor comes from (#474).
//!
//! In process, on a real `App.init`: the built-in default reaches it exactly
//! when the host opts in (`Config.jev_builtin_default`, a library embedder's
//! choice), advises only `scoped_recall`, and config.json narrows, widens or
//! turns it off. The CLI's own decision (`jev.CLI_USES_BUILTIN_DEFAULT`) is no
//! opt-in: a CLI session with nothing configured has no advisor, and one that
//! names a service keeps it.
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`, started in an environment
//! that holds only what a case sets, so no `METACODES_JEV_*` unless it names
//! one): `metacodes doctor` of a fresh state root reports the advisor off and
//! reports a named one as before; and a Run with memories in TinyKG and no
//! advisor configured reaches the model provider and nothing else, while the
//! same Run with an advisor named does consult it, so the first proves
//! something.
//!
//! The build exports `METACODES_JEV_URL=off` to every step, so the in-process
//! cases clear the METACODES_JEV_* variables first and restore them afterwards.
//! No case names a real service: the advisors here are loopback mocks.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const tinykg_binary = @import("tinykg_binary");

const testing = std.testing;
const jev = cc.jev_runtime;

const END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
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

const jev_variables = [_][*:0]const u8{ jev.ENV_URL, jev.ENV_MODE, jev.ENV_TIMEOUT_MS, jev.ENV_MODEL, jev.ENV_DECISIONS };

/// Start an App over `state_root` with no METACODES_JEV_* set (but for
/// `env_url`, when given), and hand it to `check`. `config_json` is written to
/// `<state_root>/config.json` first.
fn withAppUrl(
    state_root: []const u8,
    config_json: ?[]const u8,
    builtin_default: bool,
    env_url: ?[*:0]const u8,
    comptime check: fn (app: *cc.app_module.App) anyerror!void,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try harness.MockServer.start(END_TURN_SSE, 0);
    defer server.stop();
    const url_z = try allocator.dupeZ(u8, try server.urlOwned(allocator));

    const config_path = try std.fs.path.join(allocator, &.{ state_root, "config.json" });
    if (config_json) |bytes| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = bytes });
    } else {
        std.Io.Dir.cwd().deleteFile(std.testing.io, config_path) catch {};
    }

    var guards: [jev_variables.len]EnvGuard = undefined;
    for (jev_variables, 0..) |name, index| guards[index] = try EnvGuard.set(allocator, name, null);
    defer for (&guards) |*guard| guard.restore();
    if (env_url) |value| ppaths.setEnv(jev.ENV_URL, value);
    const home_z = try allocator.dupeZ(u8, state_root);
    var home_guard = try EnvGuard.set(allocator, "HOME", home_z.ptr);
    defer home_guard.restore();
    var probe_guard = try EnvGuard.set(allocator, "METACODES_NO_PROBE", "1");
    defer probe_guard.restore();

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", url_z.ptr, "--model", "glm-5.2" };
    var config = cc.parseArgsForTest(&argv, allocator);
    try std.testing.expect(config.parse_error == null);
    config.state_root = state_root;
    config.jev_builtin_default = builtin_default;

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try cc.app_module.App.init(allocator, io_runtime.io(), config, "test-key");
    defer app.deinit();
    try check(app);
}

fn withApp(
    state_root: []const u8,
    config_json: ?[]const u8,
    builtin_default: bool,
    comptime check: fn (app: *cc.app_module.App) anyerror!void,
) !void {
    try withAppUrl(state_root, config_json, builtin_default, null, check);
}

fn expectBuiltinAdvisor(app: *cc.app_module.App) anyerror!void {
    const runtime = app.jev orelse return error.TestExpectedAdvisor;
    const expected_url = jev.BUILTIN_DEFAULT.url.? ++ "/v1/systemone";
    try std.testing.expectEqualStrings(expected_url, runtime.client.url);
    try std.testing.expectEqual(cc.jev_advisor.Mode.advisory, runtime.advisor.mode);
    try std.testing.expect(runtime.advisor.actuates());
    // Only the recall gate is advised; the other surfaces run as with no
    // advisor (the narrowing itself is proven in jev_memory_plane_test.zig).
    try std.testing.expect(runtime.advisor.advises(.scoped_recall));
    try std.testing.expect(!runtime.advisor.advises(.memory_relation));
    try std.testing.expect(!runtime.advisor.advises(.enumeration_intent));
}

fn expectBuiltinAdvisorAllSurfaces(app: *cc.app_module.App) anyerror!void {
    const runtime = app.jev orelse return error.TestExpectedAdvisor;
    const expected_url = jev.BUILTIN_DEFAULT.url.? ++ "/v1/systemone";
    try std.testing.expectEqualStrings(expected_url, runtime.client.url);
    try std.testing.expectEqual(cc.jev_advisor.Mode.advisory, runtime.advisor.mode);
    try std.testing.expect(runtime.advisor.surfaces.eql(.initFull()));
}

fn expectNoAdvisor(app: *cc.app_module.App) anyerror!void {
    try std.testing.expect(app.jev == null);
    try std.testing.expect(app.jevAdvisor() == null);
}

/// The advisor `http://127.0.0.1:9`, named by config.json or the environment
/// and nothing else: its own service starts from the plain defaults (shadow).
fn expectNamedAdvisor(app: *cc.app_module.App) anyerror!void {
    const runtime = app.jev orelse return error.TestExpectedAdvisor;
    try std.testing.expectEqualStrings("http://127.0.0.1:9/v1/systemone", runtime.client.url);
    try std.testing.expectEqual(cc.jev_advisor.Mode.shadow, runtime.advisor.mode);
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return buf[0..try tmp.dir.realPath(std.testing.io, buf)];
}

test "L2 jev default: a library host that opts in gets the built-in advisor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try withApp(root, null, true, expectBuiltinAdvisor);
    // A config.json about something else keeps the default.
    try withApp(root, "{\"mcp_servers\":{}}", true, expectBuiltinAdvisor);
}

test "L2 jev default: a host that does not opt in gets no advisor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try withApp(root, null, false, expectNoAdvisor);
}

test "L2 jev default: config.json overrides or turns off the built-in advisor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    try withApp(root, "{\"jev\":false}", true, expectNoAdvisor);
    try withApp(root, "{\"jev\":{\"url\":\"\"}}", true, expectNoAdvisor);
    try withApp(root, "{\"jev\":{\"url\":\"http://127.0.0.1:9\",\"mode\":\"shadow\"}}", true, expectNamedAdvisor);
    // `decisions` alone replaces the default's surface list and keeps its service.
    // The list still names the retired recall_evidence: it is skipped, and the
    // advisor keeps every surface that exists.
    try withApp(
        root,
        "{\"jev\":{\"decisions\":[\"scoped_recall\",\"recall_evidence\",\"memory_relation\",\"enumeration_intent\"]}}",
        true,
        expectBuiltinAdvisorAllSurfaces,
    );
}

test "L2 jev default: the CLI takes no built-in advisor, and a service it is told about works as before (#474)" {
    // What `main` hands the App and `doctor` resolves with.
    const cli = jev.CLI_USES_BUILTIN_DEFAULT;
    try testing.expect(!cli);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &buf);
    // Nothing configured, or config.json about something else: no advisor.
    try withApp(root, null, cli, expectNoAdvisor);
    try withApp(root, "{\"mcp_servers\":{}}", cli, expectNoAdvisor);
    // Tuning a service nobody named names none.
    try withApp(root, "{\"jev\":{\"mode\":\"advisory\",\"decisions\":[\"scoped_recall\"]}}", cli, expectNoAdvisor);
    // Named in config.json or in the environment: used, in shadow unless it says otherwise.
    try withApp(root, "{\"jev\":{\"url\":\"http://127.0.0.1:9\"}}", cli, expectNamedAdvisor);
    try withAppUrl(root, null, cli, "http://127.0.0.1:9", expectNamedAdvisor);
    // `"jev": false` and `off` still mean off, over whatever else names one.
    try withApp(root, "{\"jev\":false}", cli, expectNoAdvisor);
    try withAppUrl(root, "{\"jev\":{\"url\":\"http://127.0.0.1:9\"}}", cli, "off", expectNoAdvisor);
}

// ── Through the real CLI ────────────────────────────────────────────────────

const Run = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

/// One scratch install: a state root, a working directory and a home, all
/// empty, and the CLI to run there.
const CliCase = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    cli: []const u8,
    root: []const u8,
    state: []const u8,
    work: []const u8,
    home: []const u8,

    fn init(self: *CliCase) !void {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ self.root, "state" });
        self.work = try std.fs.path.join(a, &.{ self.root, "work" });
        self.home = try std.fs.path.join(a, &.{ self.root, "home" });
        self.cli = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
    }

    fn deinit(self: *CliCase) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *CliCase) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Writes `<root>/<sub_path>`.
    fn write(self: *CliCase, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    /// `metacodes --state-dir <state> args…` in `work`, with only `env` (and a
    /// home, a PATH, no TinyKG start, no model probe) set: the capture starts
    /// a POSIX child with an empty environment, so the build's own
    /// `METACODES_JEV_URL=off` does not reach it and no `METACODES_JEV_*`
    /// does unless `env` names one. This install has been told of no advisor.
    fn run(self: *CliCase, env: []const []const u8, args: []const []const u8) !Run {
        const a = self.arena();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        const base = [_][]const u8{
            "/usr/bin/env",
            try std.fmt.allocPrint(a, "HOME={s}", .{self.home}),
            "PATH=/usr/bin:/bin",
            "METACODES_KG_AUTOSTART=0",
            "METACODES_NO_PROBE=1",
        };
        for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
        for ([_][]const u8{ self.cli, "--state-dir", self.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        try argv.append(a, null);
        const out = try cc.tools_common.spawnCaptureWithStderrTimed(
            argv.items,
            a,
            null,
            60_000,
            null,
            cc.tools_common.MAX_SPAWN_CAPTURE_BYTES,
            self.work,
        );
        return .{ .exit_code = out.exit_code, .stdout = out.stdout, .stderr = out.stderr };
    }
};

/// The `jev_advisor` line of `metacodes doctor --plain`, which judges the
/// advisor as a CLI session would configure it without contacting anything.
fn expectDoctorJev(case: *CliCase, env: []const []const u8, want: []const u8) !void {
    const run = try case.run(env, &.{ "doctor", "--plain" });
    errdefer std.debug.print("env {any}: exit {d}; stdout:\n{s}\nstderr:\n{s}\n", .{ env, run.exit_code, run.stdout, run.stderr });
    var lines = std.mem.splitScalar(u8, run.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "jev_advisor ")) continue;
        try testing.expectEqualStrings(want, line);
        return;
    }
    return error.TestExpectedJevAdvisorLine;
}

test "L2 jev default: doctor of a fresh install reports the advisor off, and a named one as before (#474)" {
    var case: CliCase = undefined;
    try case.init();
    defer case.deinit();

    // Nothing configured: off. Before #474 this said
    // `jev_advisor advisory url=http://58.211.6.133:10420 source=default`.
    try expectDoctorJev(&case, &.{}, "jev_advisor off url=- source=none error=-");

    // Named in the environment: used (shadow, a service of one's own), or off.
    try expectDoctorJev(&case, &.{"METACODES_JEV_URL=http://127.0.0.1:9"}, "jev_advisor shadow url=http://127.0.0.1:9 source=env error=-");
    try expectDoctorJev(&case, &.{"METACODES_JEV_URL=off"}, "jev_advisor off url=- source=env error=-");

    // Named in config.json: used as written; `"jev": false` is off.
    try case.write("state/config.json", "{\"jev\":{\"url\":\"http://127.0.0.1:9\",\"mode\":\"advisory\",\"decisions\":[\"scoped_recall\"]}}");
    try expectDoctorJev(&case, &.{}, "jev_advisor advisory url=http://127.0.0.1:9 source=file error=-");
    try expectDoctorJev(&case, &.{"METACODES_JEV_URL=off"}, "jev_advisor off url=- source=file_and_env error=-");
    try case.write("state/config.json", "{\"jev\":false}");
    try expectDoctorJev(&case, &.{}, "jev_advisor off url=- source=file error=-");

    // A tuning that names no service names none.
    try case.write("state/config.json", "{\"jev\":{\"mode\":\"advisory\"}}");
    try expectDoctorJev(&case, &.{}, "jev_advisor off url=- source=file error=-");
}

/// Everything the TinyKG-backed Runs below share: a store seeded with three
/// memories in `domain`, the `.env` that gives the CLI a provider and a key,
/// and the log the CLI appends to.
const KgRun = struct {
    domain: []const u8,
    kg_bin: []const u8,
    store: []const u8,
    log_path: []const u8,
    query: []const u8,

    fn prepare(case: *CliCase) !KgRun {
        const a = case.arena();
        const kg_bin = tinykg_binary.find(a) orelse return error.SkipZigTest;
        const self: KgRun = .{
            .domain = "jev-default-l2",
            .kg_bin = kg_bin,
            .store = try std.fs.path.join(a, &.{ case.state, "jev-default.kg" }),
            .log_path = try std.fs.path.join(a, &.{ case.root, "run.log" }),
            .query = "How does the zorblax parser treat tab characters in indentation?",
        };
        {
            var kg = try cc.kg_client.KgClient.init(testing.allocator, .{
                .state_root = "/tmp",
                .domain = self.domain,
                .config_bin = self.kg_bin,
                .config_store = self.store,
                .env_bin = "",
                .env_store = "",
            });
            defer kg.deinit();
            kg.ensureReady();
            if (!kg.ready) return error.SkipZigTest;
            _ = try kg.remember(.observation, "zorblax parser rejects tab characters in indentation", "module", false);
            _ = try kg.remember(.observation, "zorblax parser converts tab characters in indentation to four spaces unless strict mode is on", "decision", false);
            _ = try kg.remember(.observation, "zorblax cache eviction uses LRU with 64 entries", "module", false);
        }
        try case.write("state/.env", "DEEPSEEK_API_KEY=sk-jev-default-l2\nMETACODES_PROVIDER=deepseek\nMETACODES_MODEL=deepseek-flash\n");
        return self;
    }

    /// `-p <query>` against `provider`, in TinyKG's exclusive-CLI mode over the
    /// seeded store, logging at info to `log_path`; `extra` adds environment.
    fn run(self: KgRun, case: *CliCase, provider: *harness.MockServer, extra: []const []const u8) !Run {
        const a = case.arena();
        const url = try provider.urlOwned(a);
        var env: std.ArrayList([]const u8) = .empty;
        for ([_][]const u8{
            try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{url[0 .. url.len - "/v1/messages".len]}),
            "METACODES_KG_TRANSPORT=cli-exclusive",
            try std.fmt.allocPrint(a, "METACODES_KG_BIN={s}", .{self.kg_bin}),
            try std.fmt.allocPrint(a, "METACODES_KG_STORE={s}", .{self.store}),
            try std.fmt.allocPrint(a, "METACODES_KG_DOMAIN={s}", .{self.domain}),
            "METACODES_LOG=*:info",
            try std.fmt.allocPrint(a, "METACODES_LOG_FILE={s}", .{self.log_path}),
        }) |assignment| try env.append(a, assignment);
        for (extra) |assignment| try env.append(a, assignment);
        return case.run(env.items, &.{ "-p", self.query });
    }

    fn log(self: KgRun, case: *CliCase) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(testing.io, self.log_path, case.arena(), .limited(1 << 20)) catch "";
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

test "L2 jev default: a CLI Run with memories in TinyKG and no advisor configured reaches only the model provider (#474)" {
    var case: CliCase = undefined;
    try case.init();
    defer case.deinit();
    const kg = try KgRun.prepare(&case);

    // The effective configuration first, which contacts nothing: if the CLI
    // took an advisor on its own, the Run below would try to reach it, so
    // stop here before it can.
    try expectDoctorJev(&case, &.{}, "jev_advisor off url=- source=none error=-");

    var provider = try harness.MockServer.start(OPENAI_SSE, 0);
    defer provider.stop();
    const run = try kg.run(&case, provider, &.{});
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expectEqual(@as(i32, 0), run.exit_code);

    // The model provider is the only server the Run reached, once, and the
    // request carries the recalled memory: this is the Run in which an
    // advisor, had one been configured, would have been consulted.
    try testing.expectEqual(@as(usize, 1), provider.requestCount());
    const request = provider.lastRequest() orelse return error.NoRequestCaptured;
    try expectContains(request.body(), "zorblax parser converts tab characters in indentation");

    // No advisor was built or consulted. The log says so for the whole Run
    // (an unreachable advisor would be logged too), and says the recall ran.
    const log = try kg.log(&case);
    try expectContains(log, "scoped_recall injected=");
    try expectAbsent(log, "System-One");
    try expectAbsent(log, "system_one");
}

test "L2 jev default: the same Run with an advisor named does consult it (#474)" {
    var case: CliCase = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    const kg = try KgRun.prepare(&case);

    // A loopback stand-in for the service: any answer counts as a consultation
    // here; the point is that the Run reaches it, and where it was told to.
    var advisor = try harness.MockServer.startRepeatingStatus("{}", "HTTP/1.1 200 OK", "");
    defer advisor.stop();
    const advisor_url = try std.fmt.allocPrint(a, "METACODES_JEV_URL=http://127.0.0.1:{d}", .{advisor.port});

    var provider = try harness.MockServer.start(OPENAI_SSE, 0);
    defer provider.stop();
    const run = try kg.run(&case, provider, &.{ advisor_url, "METACODES_JEV_MODE=advisory", "METACODES_JEV_DECISIONS=scoped_recall" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expectEqual(@as(i32, 0), run.exit_code);

    try testing.expectEqual(@as(usize, 1), provider.requestCount());
    // The consultation: one request to the named service, at the System-One path.
    try testing.expect(advisor.requestCount() >= 1);
    const consult = advisor.requestAt(0) orelse return error.NoRequestCaptured;
    const line_end = std.mem.indexOf(u8, consult.raw, "\r\n") orelse consult.raw.len;
    try testing.expectEqualStrings("POST /v1/systemone HTTP/1.1", consult.raw[0..line_end]);
    // And the log records it, as the first test shows it absent.
    const log = try kg.log(&case);
    try expectContains(log, "System-One advisor enabled");
    try expectContains(log, "scoped_recall system_one");
}
