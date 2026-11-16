//! L2 for the next step after a rejected sign-in or a used-up balance
//! (`src/repl/next_step.zig`), through the real CLI.
//!
//! The CLI (`METACODES_TEST_CLI_BIN`, started through a symlink named
//! `metacodes-dev`, as a side-by-side install is) runs `-p` with a state root
//! and a working directory of its own, in an environment holding only what
//! each case sets, against a MockServer on the loopback that answers every
//! request with one failure. After the raw error it prints, one more line
//! says what to do, in the command line's words (`metacodes-dev login`,
//! `--provider`), and the exit code stays 1:
//! - Metask (the historical path, `METASK_API_KEY`): HTTP 401 says sign in
//!   again, HTTP 402 says top up or switch provider;
//! - DeepSeek, which `<state root>/.env` configures: HTTP 401 names
//!   `DEEPSEEK_API_KEY` and this install's `.env`, never the key; HTTP 402
//!   says top up with DeepSeek;
//! - HTTP 400, which a retry or another model may fix, gets no such line.
//!
//! In process, on a real `App` (no request is sent): the route the line names
//! is the one in force, so a `/model` pick mid-session moves it from Metask to
//! the picked provider, here one that `config.json` defines.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const testing = std.testing;

const metask_key = "sk-placeholder-metask-key";
const deepseek_key = "sk-placeholder-deepseek-key";

const UNAUTHORIZED = "HTTP/1.1 401 Unauthorized";
const PAYMENT_REQUIRED = "HTTP/1.1 402 Payment Required";
const BAD_REQUEST = "HTTP/1.1 400 Bad Request";
const AUTHENTICATION_BODY = "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}";
const BALANCE_BODY = "{\"error\":\"insufficient_balance\",\"message\":\"Your balance is insufficient. Please top up.\"}";
const INVALID_BODY = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"max_tokens is too large\"}}";

/// Every line this change prints starts with one of these.
const NEXT_STEP_OPENINGS = [_][]const u8{ "Your Metask sign-in", "Your Metask balance", "DeepSeek rejected", "DeepSeek reports" };

const Run = struct {
    exit_code: i32,
    stderr: []const u8,
};

/// One scratch install (a state root, a working directory, a home) and the
/// CLI behind a `metacodes-dev` symlink.
const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    command: []const u8,
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
        const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), a);
        try self.tmp.dir.symLink(testing.io, exe, "bin/metacodes-dev", .{});
        self.command = try std.fs.path.join(a, &.{ root, "bin/metacodes-dev" });
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// `metacodes-dev --state-dir <state> -p hi` in `work`, with only `env`
    /// (and a home, a PATH, no TinyKG start, no advisor, no model probe) set.
    fn run(self: *Case, env: []const []const u8) !Run {
        const a = self.arena();
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        const base = [_][]const u8{
            "/usr/bin/env",
            try std.fmt.allocPrint(a, "HOME={s}", .{self.home}),
            "PATH=/usr/bin:/bin",
            "METACODES_KG_AUTOSTART=0",
            "METACODES_JEV_URL=off",
            "METACODES_NO_PROBE=1",
        };
        for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
        for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
        for ([_][]const u8{ self.command, "--state-dir", self.state, "-p", "hi" }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
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
        return .{ .exit_code = out.exit_code, .stderr = out.stderr };
    }
};

/// `http://127.0.0.1:<port>`.
fn originOf(a: std.mem.Allocator, server: *harness.MockServer) ![]const u8 {
    const url = try server.urlOwned(a);
    return url[0 .. url.len - "/v1/messages".len];
}

/// The run failed with exit code 1 on the one request `server` answered with
/// `status`, which stderr reports, and its last line is `line`.
fn expectNextStep(run: Run, server: *harness.MockServer, status: []const u8, line: []const u8) !void {
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expectEqual(@as(i32, 1), run.exit_code);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    const raw_error = std.mem.lastIndexOf(u8, run.stderr, status) orelse return error.RawErrorMissing;
    const trimmed = std.mem.trimEnd(u8, run.stderr, "\n");
    const last_line = trimmed[(std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return error.NoLineBeforeNextStep) + 1 ..];
    try testing.expectEqualStrings(line, last_line);
    // After the raw error, and said once.
    try testing.expect(std.mem.lastIndexOf(u8, run.stderr, line).? > raw_error);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, run.stderr, line));
}

test "-p: a rejected Metask sign-in and a used-up Metask balance say what to do next" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    var rejected = try harness.MockServer.startRepeatingStatus(AUTHENTICATION_BODY, UNAUTHORIZED, "");
    defer rejected.stop();
    const signed_out = try case.run(&.{
        "METASK_API_KEY=" ++ metask_key,
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, rejected)}),
    });
    try expectNextStep(signed_out, rejected, "HTTP 401", "Your Metask sign-in is no longer valid. Sign in again: metacodes-dev login");

    var broke = try harness.MockServer.startRepeatingStatus(BALANCE_BODY, PAYMENT_REQUIRED, "");
    defer broke.stop();
    const no_balance = try case.run(&.{
        "METASK_API_KEY=" ++ metask_key,
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, broke)}),
    });
    try expectNextStep(no_balance, broke, "HTTP 402", "Your Metask balance has run out. Top up your Metask account, or switch provider: --provider");
}

test "-p: DeepSeek from the install's .env names its variable and that file, never the key" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();
    try case.tmp.dir.writeFile(testing.io, .{
        .sub_path = "state/.env",
        .data = "DEEPSEEK_API_KEY=" ++ deepseek_key ++ "\nMETACODES_PROVIDER=deepseek\n",
    });
    const env_path = try std.fs.path.join(a, &.{ case.state, ".env" });

    var rejected = try harness.MockServer.startRepeatingStatus(AUTHENTICATION_BODY, UNAUTHORIZED, "");
    defer rejected.stop();
    const bad_key = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, rejected)})});
    try expectNextStep(bad_key, rejected, "HTTP 401", try std.fmt.allocPrint(
        a,
        "DeepSeek rejected the API key. Check DEEPSEEK_API_KEY in {s} or your shell, then restart.",
        .{env_path},
    ));
    // The request went to DeepSeek's path; the key itself is never printed.
    try testing.expect(std.mem.startsWith(u8, rejected.lastRequest().?.raw, "POST /chat/completions "));
    try testing.expect(std.mem.indexOf(u8, bad_key.stderr, deepseek_key) == null);

    var broke = try harness.MockServer.startRepeatingStatus(BALANCE_BODY, PAYMENT_REQUIRED, "");
    defer broke.stop();
    const no_balance = try case.run(&.{try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}", .{try originOf(a, broke)})});
    try expectNextStep(no_balance, broke, "HTTP 402", "DeepSeek reports no balance or quota left. Top up with DeepSeek, or switch provider: --provider");
}

test "-p: a failure that is neither adds no next step" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const a = case.arena();

    var server = try harness.MockServer.startRepeatingStatus(INVALID_BODY, BAD_REQUEST, "");
    defer server.stop();
    const run = try case.run(&.{
        "METASK_API_KEY=" ++ metask_key,
        try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, server)}),
    });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expectEqual(@as(i32, 1), run.exit_code);
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    try testing.expect(std.mem.indexOf(u8, run.stderr, "HTTP 400") != null);
    for (NEXT_STEP_OPENINGS) |opening| try testing.expect(std.mem.indexOf(u8, run.stderr, opening) == null);
}

// ── in process: the route a /model pick moved to ─────────────────────────────

const ppaths = @import("platform").paths;

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

test "the line names the provider a /model pick moved the session to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)]);
    for ([_][]const u8{ "state", "home" }) |dir| try tmp.dir.createDirPath(testing.io, dir);
    const state = try std.fs.path.join(a, &.{ root, "state" });

    // A provider of the user's own, on a port nothing listens on: no request
    // is made. Its key comes from the environment; no other credential does.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "state/config.json", .data =
        \\{"custom_providers": {"house-relay": {
        \\  "display_name": "House relay",
        \\  "credential_kinds": ["api_key"],
        \\  "env_aliases": [{"name": "HOUSE_RELAY_TOKEN", "kind": "api_key", "canonical": true}],
        \\  "channels": [{"id": "primary", "base_url": "http://127.0.0.1:9/relay/v1", "protocol": "openai_chat"}],
        \\  "models": [{"request_model_id": "relay-model", "display_name": "Relay model"}]}}}
    });
    const settings = [_]struct { [*:0]const u8, ?[*:0]const u8 }{
        .{ "HOUSE_RELAY_TOKEN", "sk-placeholder-relay-key" },
        .{ "METASK_API_KEY", null },
        .{ "METASK_GATEWAY_URL", null },
        .{ "METACODES_PROVIDER", null },
        .{ "METACODES_CONFIG_FILE", null },
        .{ "HOME", (try a.dupeZ(u8, try std.fs.path.join(a, &.{ root, "home" }))).ptr },
        .{ "METACODES_NO_PROBE", "1" },
        .{ "METACODES_KG_AUTOSTART", "0" },
    };
    var guards: [settings.len]EnvGuard = undefined;
    var set: usize = 0;
    defer while (set > 0) {
        set -= 1;
        guards[set].restore();
    };
    for (settings) |setting| {
        guards[set] = try EnvGuard.set(setting[0], setting[1]);
        set += 1;
    }

    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    // The historical path: Metask, by `--api-key`.
    var config = cc.parseArgsForTest(&.{ "metacodes", "--api-key", metask_key, "--base-url", "http://127.0.0.1:9/v1/messages", "--model", "claude-sonnet-4-6" }, a);
    try testing.expect(config.parse_error == null);
    config.state_root = state;
    const app = try cc.app_module.App.init(testing.allocator, io_runtime.io(), config, metask_key);
    defer app.deinit();

    const rejected: cc.api_model_error.Detail = .{ .category = .authentication, .http_status = 401 };
    const on_metask = (try cc.repl_next_step.forFailure(a, app, &rejected, .interactive)) orelse return error.NoNextStep;
    try testing.expectEqualStrings("Your Metask sign-in is no longer valid. Sign in again: /login", on_metask);

    try testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    const on_relay = (try cc.repl_next_step.forFailure(a, app, &rejected, .interactive)) orelse return error.NoNextStep;
    try testing.expectEqualStrings(try std.fmt.allocPrint(
        a,
        "House relay rejected the API key. Check HOUSE_RELAY_TOKEN in {s} or your shell, then restart.",
        .{try std.fs.path.join(a, &.{ state, ".env" })},
    ), on_relay);
    const broke: cc.api_model_error.Detail = .{ .category = .payment_required, .http_status = 402 };
    const out_of_balance = (try cc.repl_next_step.forFailure(a, app, &broke, .{ .print = "metacodes-dev" })) orelse return error.NoNextStep;
    try testing.expectEqualStrings("House relay reports no balance or quota left. Top up with House relay, or switch provider: --provider", out_of_balance);
}
