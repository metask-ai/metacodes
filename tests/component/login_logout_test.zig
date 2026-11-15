//! L2 for #499 part 2: `metacodes logout` leaves no Metask credential
//! behind.
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`), against a MockServer
//! standing in for a relay `config.json` defines (the provider `.env`
//! configures): `metacodes logout` removes both Metask sign-ins — the
//! browser one in auth.json and the device-code one in oauth/metask.json —
//! and a stored default that resolves to Metask, says which, prints no
//! secret, and the next start falls back to `.env` instead of failing.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const testing = std.testing;
const App = cc.app_module.App;

const METASK_KEY = "sk-metask-login-key";
const RELAY_KEY = "sk-relay-env-key";
const RELAY_ENV = "HOUSE_RELAY_TOKEN";

const ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";
const GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5\",\"max_input_tokens\":200000,\"max_tokens\":32000}]}";

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

const cleared = [_][*:0]const u8{
    "METASK_API_KEY",      "OPENAI_API_KEY",           "GEMINI_API_KEY",        "GOOGLE_API_KEY",
    "ZAI_API_KEY",         "GLM_API_KEY",              "Z_AI_API_KEY",          "DEEPSEEK_API_KEY",
    "KIMI_API_KEY",        "MOONSHOT_API_KEY",         "KIMI_CODE_API_KEY",     "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY",     "AWS_BEARER_TOKEN_BEDROCK", "METACODES_PROVIDER",    "METACODES_MODEL",
    "METACODES_BASE_URL",  "METASK_GATEWAY_URL",       "METACODES_CONFIG_FILE", "METACODES_AUTH_FILE",
    "METACODES_OAUTH_DIR", RELAY_ENV,
};

/// A state root, a working directory and a home; keys cleared, no probe, no
/// TinyKG start, no advisor.
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
        for ([_][]const u8{ "state", "state/oauth", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ root, "state" });
        self.work = try std.fs.path.join(a, &.{ root, "work" });
        self.home = try std.fs.path.join(a, &.{ root, "home" });
    }

    fn enter(self: *Case) !void {
        const a = self.arena_state.allocator();
        for (cleared) |name| try self.guard(name, null);
        try self.guard("HOME", (try a.dupeZ(u8, self.home)).ptr);
        try self.guard("METACODES_HOME", (try a.dupeZ(u8, self.state)).ptr);
        try self.guard("METACODES_NO_PROBE", "1");
        try self.guard("METACODES_KG_AUTOSTART", "0");
        try self.guard("METACODES_JEV_URL", "off");
    }

    fn guard(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.count]) |*existing| {
            if (std.mem.orderZ(u8, existing.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
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

    fn write(self: *Case, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn exists(self: *Case, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }

    /// The auth.json `metacodes login` leaves.
    fn writeSignedIn(self: *Case) !void {
        try self.write("state/auth.json", try std.fmt.allocPrint(self.arena(),
            \\{{"api_key":"{s}","oauth":{{"access_token":"at-login","refresh_token":"rt-login","token_type":"Bearer","expires_at":{d}}},"selected_model":"glm-5","reasoning_effort":"low"}}
        , .{ METASK_KEY, cc.util_time.nowUnix() + 86_400 }));
        const path = try std.fs.path.joinZ(self.arena(), &.{ self.state, "auth.json" });
        _ = @import("platform").fs.chmod(path.ptr, 0o600);
    }
};

fn originOf(a: std.mem.Allocator, server: *harness.MockServer) ![]const u8 {
    const url = try server.urlOwned(a);
    return url[0 .. url.len - "/v1/messages".len];
}

fn relayConfig(a: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"custom_providers": {{"house-relay": {{
        \\  "display_name": "House relay",
        \\  "credential_kinds": ["api_key"],
        \\  "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}/relay/v1", "protocol": "openai_chat"}}],
        \\  "models": [{{"request_model_id": "relay-model", "display_name": "Relay model"}}]}}}}}}
    , .{ RELAY_ENV, origin });
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

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

// ── through the real CLI ─────────────────────────────────────────────────────

const Run = struct {
    exit_code: i32,
    stderr: []const u8,
};

fn runCli(case: *Case, cli: []const u8, env: []const []const u8, args: []const []const u8) !Run {
    const a = case.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const base = [_][]const u8{
        "/usr/bin/env",
        try std.fmt.allocPrint(a, "HOME={s}", .{case.home}),
        "PATH=/usr/bin:/bin",
        "METACODES_KG_AUTOSTART=0",
        "METACODES_JEV_URL=off",
        "METACODES_NO_PROBE=1",
    };
    for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
    for ([_][]const u8{ cli, "--state-dir", case.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, case.work);
    return .{ .exit_code = out.exit_code, .stderr = out.stderr };
}

fn cliPath(case: *Case) !?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return null;
    return try std.Io.Dir.cwd().realPathFileAlloc(testing.io, std.mem.span(raw_cli), case.arena());
}

/// Store `config.json`'s `global_selection` on `provider`'s offer for `model`
/// (what `/model`'s "every future session" commits), resolved in an App
/// built on this state root.
fn storeDefault(case: *Case, provider: []const u8, model: []const u8) !void {
    const a = case.arena();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    const host = try app.providerHost();
    const offer = for (host.kernel.catalogSnapshot().items()) |*candidate| {
        if (candidate.provider_id.eqlText(provider) and std.mem.eql(u8, candidate.request_model_id, model)) break candidate;
    } else return error.OfferMissing;
    var store = try cc.provider_config_store.Store.initHome(a, case.state);
    defer store.deinit();
    _ = try cc.provider_config_store.setGlobalSelection(&store, cc.provider_selection.RuntimeSelection.pinned(offer.offer_id, offer.offer_revision, .global), null, null);
}

test "metacodes logout removes both Metask sign-ins and a Metask default, says which, and the next start falls back (#499, #485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    try case.writeSignedIn();
    try case.write("state/oauth/metask.json", "{\"access_token\":\"at-device\",\"refresh_token\":\"rt-device\"}");
    try storeDefault(&case, "metask", "claude-sonnet-4-6");

    const out = try runCli(&case, cli, &.{}, &.{"logout"});
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try expectContains(out.stderr, "Removed the Metask browser sign-in (");
    try expectContains(out.stderr, "Removed the Metask device-code sign-in and its refresh token (");
    try expectContains(out.stderr, "Forgot the default model, which was a Metask one.");
    for ([_][]const u8{ METASK_KEY, "at-device", "rt-device", "at-login", "rt-login" }) |secret| try expectAbsent(out.stderr, secret);
    try testing.expect(!case.exists("state/auth.json"));
    try testing.expect(!case.exists("state/oauth/metask.json"));
    var store = try cc.provider_config_store.Store.initHome(a, case.state);
    defer store.deinit();
    var document = try store.load();
    defer document.deinit();
    try testing.expect(document.global_selection == null);

    // The next plain start: no Metask credential, no stored default, the
    // .env provider decides.
    try case.write("state/.env", RELAY_ENV ++ "=" ++ RELAY_KEY ++ "\n");
    const next = try runCli(&case, cli, &.{}, &.{ "-p", "hi" });
    errdefer std.debug.print("next start exit {d}; stderr:\n{s}\n", .{ next.exit_code, next.stderr });
    try testing.expectEqual(@as(i32, 0), next.exit_code);
    const captured = relay.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, headerValue(captured, "authorization").?);

    // Nothing left: says so.
    const again = try runCli(&case, cli, &.{}, &.{ "logout", "--provider", "metask" });
    try expectContains(again.stderr, "No Metask sign-in was stored.");
}
