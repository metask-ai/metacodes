//! L2 evidence: the guided API-key login for a provider without OAuth (the
//! GLM Coding Plan) checks the pasted key, stores it in that provider's own
//! file, and the next request on that provider — and only that provider —
//! authenticates with it.
//!
//! Before: `login --provider zai-coding-plan` refused ("declares no OAuth
//! token endpoint"), a Z.AI key could live only in an environment variable,
//! and a `/model` pick of a Z.AI model without one ended in
//! `MissingCredentials`.
//!
//! `/model` takes no key itself (#488): a provider without one is not
//! listed, and the key this login stores makes its routes ones a pick
//! applies.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const App = cc.app_module.App;
const Slug = cc.provider_ids.Slug;
const provider_login = cc.api_provider_login;
const key_store = cc.provider_api_key_store;
const picker_host = cc.repl_picker_host;

const GOOD_KEY = "plan-key-good";
const MODELS_OK = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5.3\"}]}";
const ANTHROPIC_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

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

const cleared_variables = [_][*:0]const u8{
    "ZAI_API_KEY",
    "GLM_API_KEY",
    "Z_AI_API_KEY",
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY",
    "MOONSHOT_API_KEY",
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODES_KEY_CHECK_URL",
    "METACODES_CONFIG_FILE",
};

/// A scratch state root as HOME, every key variable cleared, no probe, no KG.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try self.arena.allocator().dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_NO_PROBE", "1");
        try self.setEnv("METACODES_KG_AUTOSTART", "0");
    }

    fn setEnv(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.guard_count]) |*guard| {
            if (std.mem.orderZ(u8, guard.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
        self.guards[self.guard_count] = try EnvGuard.set(self.arena.allocator(), name, value);
        self.guard_count += 1;
    }

    /// Point the key check at `server` (`METACODES_KEY_CHECK_URL`).
    fn checkAt(self: *Case, server: *harness.MockServer) !void {
        const url = try server.urlOwned(self.arena.allocator());
        const origin = url[0 .. url.len - "/v1/messages".len];
        const check = try std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/api/coding/paas/v4/models", .{origin}, 0);
        try self.setEnv("METACODES_KEY_CHECK_URL", check.ptr);
    }

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn config(self: *Case, argv: []const [*:0]const u8) !cc.types_mod.Config {
        var parsed = cc.parseArgsForTest(argv, self.arena.allocator());
        try std.testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }
};

fn zaiProfile(registry: *cc.provider_registry.ProviderRegistry) *const cc.provider_profile.ProviderProfile {
    return registry.find("zai-coding-plan").?;
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

fn runKey(case: *Case, io: std.Io, key: []const u8) !void {
    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const prepared = try provider_login.prepareApiKey(zaiProfile(&registry), "cn-personal", null, key, .{ .state_root = case.root });
    _ = try prepared.run(std.testing.allocator, io, cc.api_oauth_login.stderrNotify(), null);
}

test "L2 key login: a key the check accepts is stored; a refused or unchecked one is not" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var io_runtime = @import("platform").signal.threadedIo(case.arena.allocator(), .{});
    defer io_runtime.deinit();
    const zai = Slug.lit("zai-coding-plan");

    // Refused (401): nothing is stored.
    {
        var server = try harness.MockServer.startWithStatus("{\"error\":{\"message\":\"unauthorized\"}}", 0, "HTTP/1.1 401 Unauthorized");
        defer server.stop();
        try case.checkAt(server);
        try std.testing.expectError(error.KeyRefused, runKey(&case, io_runtime.io(), "  plan-key-bad \n"));
        try std.testing.expectEqualStrings("GET /api/coding/paas/v4/models HTTP/1.1", requestLine(server.lastRequest().?));
        // Surrounding whitespace from a paste is not part of the key.
        try std.testing.expectEqualStrings("Bearer plan-key-bad", headerValue(server.lastRequest().?, "authorization").?);
        try std.testing.expect(try key_store.load(std.testing.allocator, case.root, zai) == null);
    }
    // The check could not be made (500): nothing is stored either.
    {
        var server = try harness.MockServer.startWithStatus("{}", 0, "HTTP/1.1 500 Internal Server Error");
        defer server.stop();
        try case.checkAt(server);
        try std.testing.expectError(error.KeyCheckFailed, runKey(&case, io_runtime.io(), GOOD_KEY));
        try std.testing.expect(try key_store.load(std.testing.allocator, case.root, zai) == null);
    }
    // Accepted (200): stored as the Coding Plan kind, with its page.
    {
        var server = try harness.MockServer.start(MODELS_OK, 0);
        defer server.stop();
        try case.checkAt(server);
        try runKey(&case, io_runtime.io(), GOOD_KEY);
        var stored = (try key_store.load(std.testing.allocator, case.root, zai)).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings(GOOD_KEY, stored.secret);
        try std.testing.expectEqual(cc.provider_credential.CredentialKind.zai_coding_plan_api_key, stored.kind);
        try std.testing.expectEqualStrings("cn-personal", stored.page.?);
    }
}

test "L2 key login: a 200 that is not the provider's answer stores nothing" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var io_runtime = @import("platform").signal.threadedIo(case.arena.allocator(), .{});
    defer io_runtime.deinit();
    // A captive portal's page, and Z.AI's own 200-with-failure shape.
    for ([_][]const u8{
        "<html><body>Sign in to the network</body></html>",
        "{\"success\":false,\"code\":401,\"msg\":\"token invalid\"}",
    }) |body| {
        var server = try harness.MockServer.start(body, 0);
        defer server.stop();
        try case.checkAt(server);
        try std.testing.expectError(error.KeyCheckFailed, runKey(&case, io_runtime.io(), GOOD_KEY));
        try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan")) == null);
    }
}

test "L2 key login: a key never follows a redirect, from the check or any catalog GET" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();

    // The redirect goes to another host name for the same listener's address
    // family: `localhost` is not `127.0.0.1`, so std's client treats it as a
    // different domain.
    var target = try harness.MockServer.start(MODELS_OK, 0);
    defer target.stop();
    const location = try std.fmt.allocPrint(allocator, "location: http://localhost:{d}/api/coding/paas/v4/models\r\n", .{target.port});
    var redirect = try harness.MockServer.startRepeatingStatus("", "HTTP/1.1 302 Found", location);
    defer redirect.stop();
    try case.checkAt(redirect);

    // The key check stops at the redirect: the host that would answer never
    // saw the key, so its answer proves nothing.
    try std.testing.expectError(error.KeyCheckFailed, runKey(&case, io_runtime.io(), GOOD_KEY));
    try std.testing.expectEqual(@as(usize, 0), target.requestCount());
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan")) == null);

    // Any catalog GET carrying a credential: std's client would re-send the
    // header to whatever host the redirect names.
    const url = try redirect.urlOwned(allocator);
    const models_url = try std.fmt.allocPrint(allocator, "{s}/api/coding/paas/v4/models", .{url[0 .. url.len - "/v1/messages".len]});
    try std.testing.expectError(error.HttpError, cc.api_catalog_fetch.fetch(std.testing.allocator, io_runtime.io(), .{ .url = models_url, .bearer = GOOD_KEY }));
    try std.testing.expectEqualStrings("Bearer " ++ GOOD_KEY, headerValue(redirect.lastRequest().?, "authorization").?);
    try std.testing.expectEqual(@as(usize, 0), target.requestCount());

    // A public catalog still follows it.
    const answer = try cc.api_catalog_fetch.fetch(std.testing.allocator, io_runtime.io(), .{ .url = models_url });
    defer std.testing.allocator.free(answer.body);
    const followed = target.lastRequest() orelse return error.RedirectNotFollowed;
    try std.testing.expect(headerValue(followed, "authorization") == null);
}

test "L2 key login: a stored key starts a Z.AI session and reaches its requests, and no other provider's" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    try key_store.save(std.testing.allocator, case.root, Slug.lit("zai-coding-plan"), .zai_coding_plan_api_key, GOOD_KEY, "cn-personal", 1);

    // Startup: no variable holds a key; the store answers for Z.AI.
    {
        const argv = [_][*:0]const u8{ "metacodes", "--provider", "zai-coding-plan" };
        const config = try case.config(&argv);
        const secret = try cc.resolveProviderScopedSecret(std.testing.allocator, config, "zai-coding-plan");
        defer std.testing.allocator.free(secret);
        try std.testing.expectEqualStrings(GOOD_KEY, secret);
        // ...and not for OpenAI.
        try std.testing.expectError(error.MissingCredentials, cc.resolveProviderScopedSecret(std.testing.allocator, config, "openai"));
    }

    // A session on the Z.AI route sends it.
    var server = try harness.MockServer.start(ANTHROPIC_END_TURN_SSE, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--provider", "zai-coding-plan", "--model", "glm-5.3", "--base-url", messages_url.ptr };
    const config = try case.config(&argv);
    const secret = try cc.resolveProviderScopedSecret(std.testing.allocator, config, "zai-coding-plan");
    defer std.testing.allocator.free(secret);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, secret);
    defer app.deinit();
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    while (try handle.next()) |event| switch (event) {
        .text => |text| app.allocator.free(text),
        else => {},
    };
    handle.deinit();
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings("POST /v1/messages HTTP/1.1", requestLine(captured));
    try std.testing.expectEqualStrings("Bearer " ++ GOOD_KEY, headerValue(captured, "authorization").?);
}

test "L2 key login (#488): /model takes no key and does not list a provider without one; the key /login stored makes its routes applicable" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    // Any request the picker made would land here.
    var check = try harness.MockServer.start(MODELS_OK, 0);
    defer check.stop();
    try case.checkAt(check);

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const argv = [_][*:0]const u8{"metacodes"};
    const app = try App.init(std.testing.allocator, io_runtime.io(), try case.config(&argv), "metask-key");
    defer app.deinit();
    const picker = &app.model_picker;
    var rows = cc.repl_model_picker.Picker.RowBuffer.init(std.testing.allocator);
    defer rows.deinit();

    // No key: the plan is not listed, so typing its name finds nothing, and
    // Enter neither commits nor shows a setup. No key stage, no worker, no
    // request.
    var ui: cc.tui_ui_state.UiState = .{};
    picker_host.open(app, &ui, .unguarded);
    for ("zai-coding-plan") |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte }, .unguarded);
    try std.testing.expectEqual(@as(usize, 0), (try picker.rows(&rows)).len);
    for ([_]cc.repl_model_picker.Key{ .enter, .right }) |key| {
        try std.testing.expectEqual(picker_host.Result.ignored, picker_host.onKey(app, &ui, key, .unguarded));
    }
    try std.testing.expectEqual(cc.repl_model_picker.Stage.list, picker.stage);
    try std.testing.expect(picker.setup == null);
    const env_path = try std.fs.path.join(allocator, &.{ case.root, ".env" });
    try std.testing.expectEqualStrings(env_path, picker.localConfigPath());
    try std.testing.expectEqual(@as(usize, 0), check.requestCount());
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("zai-coding-plan")) == null);
    // The session stays on the route it started on.
    try std.testing.expectEqualStrings("metask-key", app.api_key);
    picker_host.close(app, &ui, .unguarded);

    // The key `/login zai-coding-plan` would store: the next /model lists
    // the plan, and a pick applies its route with that key.
    try key_store.save(std.testing.allocator, case.root, Slug.lit("zai-coding-plan"), .zai_coding_plan_api_key, GOOD_KEY, null, 1);
    picker_host.open(app, &ui, .unguarded);
    for ("zai-coding-plan") |byte| _ = picker_host.onKey(app, &ui, .{ .char = byte }, .unguarded);
    const configured = try picker.rows(&rows);
    try std.testing.expect(configured.len > 1);
    try std.testing.expect(picker.offers.items[configured[0].heading.offer_index].provider_id.eqlText("zai-coding-plan"));
    try std.testing.expect(configured[1] == .model);
    try std.testing.expect(picker.offers.items[configured[1].model.offer_index].provider_id.eqlText("zai-coding-plan"));
    // The cursor is on GLM-5.3, listed first; Enter applies its preferred
    // route, the first (cn-anthropic).
    const focused = picker.focusedOffer() orelse return error.NoFocusedOffer;
    try std.testing.expectEqualStrings("glm-5.3", focused.request_model_id);
    try std.testing.expectEqual(picker_host.Result.committed, picker_host.onKey(app, &ui, .enter, .unguarded));
    try std.testing.expectEqualStrings("glm-5.3", app.activeModel());
    try std.testing.expectEqualStrings(GOOD_KEY, app.api_key);
    // Another provider bills the session from here, and the notice says so.
    try std.testing.expect(std.mem.indexOf(u8, picker.notice(), "from now on billed to your Z.AI GLM Coding Plan account") != null);
    try std.testing.expectEqual(@as(usize, 0), check.requestCount());
}

// ── phase 2: every built-in vendor takes a pasted key ───────────────────────

/// A vendor `/login <id>` now guides to a key page, and where its requests
/// (so its key check) carry the key.
const GuidedVendor = struct {
    id: []const u8,
    /// The page the default channel's region leads to.
    page: []const u8,
    header: []const u8,
    prefix: []const u8 = "",
};

const GUIDED_VENDORS = [_]GuidedVendor{
    .{ .id = "openai", .page = "platform", .header = "authorization", .prefix = "Bearer " },
    // Gemini reads `x-goog-api-key`; a bearer token is an OAuth token to it.
    .{ .id = "gemini", .page = "aistudio", .header = "x-goog-api-key" },
    .{ .id = "qwen", .page = "cn", .header = "authorization", .prefix = "Bearer " },
    .{ .id = "minimax", .page = "cn", .header = "authorization", .prefix = "Bearer " },
    .{ .id = "kimi", .page = "cn", .header = "authorization", .prefix = "Bearer " },
};

test "L2 key login (phase 2): OpenAI, Gemini, Qwen, MiniMax and Kimi check a pasted key where their requests carry it, and store it as theirs" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();

    for (GUIDED_VENDORS) |vendor| {
        errdefer std.debug.print("vendor: {s}\n", .{vendor.id});
        var server = try harness.MockServer.start(MODELS_OK, 0);
        defer server.stop();
        try case.checkAt(server);
        const profile = registry.find(vendor.id).?;
        const key = try std.fmt.allocPrint(allocator, "guided-{s}-key", .{vendor.id});
        const prepared = try provider_login.prepareApiKey(profile, null, profile.default_channel, key, .{ .state_root = case.root });
        try std.testing.expectEqualStrings(vendor.page, prepared.page.id.slice());
        _ = try prepared.run(std.testing.allocator, io_runtime.io(), cc.api_oauth_login.stderrNotify(), null);

        const captured = server.lastRequest() orelse return error.NoRequestCaptured;
        try std.testing.expectEqualStrings("GET /api/coding/paas/v4/models HTTP/1.1", requestLine(captured));
        const expected = try std.fmt.allocPrint(allocator, "{s}{s}", .{ vendor.prefix, key });
        try std.testing.expectEqualStrings(expected, headerValue(captured, vendor.header) orelse "");
        // The key goes in one place only.
        if (!std.mem.eql(u8, vendor.header, "authorization")) try std.testing.expect(headerValue(captured, "authorization") == null);
        // The check says it is metacodes, as every request does
        // (`http_connection.user_agent`), not std's `zig/<version>`.
        try std.testing.expectEqualStrings("metacodes/" ++ cc.VERSION, headerValue(captured, "user-agent") orelse "");

        var stored = (try key_store.load(std.testing.allocator, case.root, try Slug.parse(vendor.id))).?;
        defer stored.deinit();
        try std.testing.expectEqualStrings(key, stored.secret);
        try std.testing.expectEqual(cc.provider_credential.CredentialKind.api_key, stored.kind);
        try std.testing.expectEqualStrings(vendor.page, stored.page.?);
    }
}

test "L2 key login (phase 2): Gemini's 400 API_KEY_INVALID refuses the key; that 400 from a bearer vendor, or a 400 for another reason, only fails the check" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    var io_runtime = @import("platform").signal.threadedIo(case.arena.allocator(), .{});
    defer io_runtime.deinit();
    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const run = struct {
        fn key(root: []const u8, io: std.Io, profile: *const cc.provider_profile.ProviderProfile) !void {
            const prepared = try provider_login.prepareApiKey(profile, null, profile.default_channel, "guided-wrong-key", .{ .state_root = root });
            _ = try prepared.run(std.testing.allocator, io, cc.api_oauth_login.stderrNotify(), null);
        }
    };

    // Google's answer to a made-up key on the model listing (2026-11-17).
    var refused = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"," ++
            "\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"API_KEY_INVALID\",\"domain\":\"googleapis.com\"}]}}",
        "HTTP/1.1 400 Bad Request",
        "",
    );
    defer refused.stop();
    try case.checkAt(refused);
    try std.testing.expectError(error.KeyRefused, run.key(case.root, io_runtime.io(), registry.find("gemini").?));
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("gemini")) == null);
    // The same 400 from a vendor that does not word refusals that way says
    // nothing about the key.
    try std.testing.expectError(error.KeyCheckFailed, run.key(case.root, io_runtime.io(), registry.find("qwen").?));
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("qwen")) == null);

    // Gemini's 400 for an unsupported location is not about the key either.
    var located = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"code\":400,\"message\":\"User location is not supported for the API use.\",\"status\":\"FAILED_PRECONDITION\"}}",
        "HTTP/1.1 400 Bad Request",
        "",
    );
    defer located.stop();
    try case.checkAt(located);
    try std.testing.expectError(error.KeyCheckFailed, run.key(case.root, io_runtime.io(), registry.find("gemini").?));
    try std.testing.expect(try key_store.load(std.testing.allocator, case.root, Slug.lit("gemini")) == null);

    // A key in its own header follows no redirect either: the host the 302
    // names never sees it.
    var target = try harness.MockServer.start(MODELS_OK, 0);
    defer target.stop();
    const location = try std.fmt.allocPrint(case.arena.allocator(), "location: http://localhost:{d}/api/coding/paas/v4/models\r\n", .{target.port});
    var redirect = try harness.MockServer.startRepeatingStatus("", "HTTP/1.1 302 Found", location);
    defer redirect.stop();
    try case.checkAt(redirect);
    try std.testing.expectError(error.KeyCheckFailed, run.key(case.root, io_runtime.io(), registry.find("gemini").?));
    try std.testing.expectEqualStrings("guided-wrong-key", headerValue(redirect.lastRequest().?, "x-goog-api-key").?);
    try std.testing.expectEqual(@as(usize, 0), target.requestCount());
}
