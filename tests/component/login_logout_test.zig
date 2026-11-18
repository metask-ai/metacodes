//! L2 for #485 and #499 part 2: `/login` and `/logout` switch a session
//! between the Metask account and local configuration, and signing out
//! leaves no Metask credential behind.
//!
//! In process, on a real `App`, against MockServers standing in for the
//! Metask gateway and for a relay `config.json` defines (the provider
//! `.env` configures):
//! - `bindMetaskSession` (what `/login` does once the Metask session is
//!   stored and a model and reasoning level are chosen, #527) moves the
//!   session, unbound or not, onto the sign-in: the next turn reaches the
//!   gateway the session names with the session's access token and that
//!   model;
//! - `signOutOfMetask` (`/logout`) removes both Metask sign-ins, moves a
//!   session on Metask to the `.env` provider, and never sends the Metask key
//!   again; with no `.env` provider the session is unbound and nothing is
//!   sent at all;
//! - `forgetProviderKey` (`/logout <provider>`) removes the stored key and
//!   leaves a session that ran on it without a credential;
//! - `applyMetaskSession` (`/login`) revokes the session it replaced, once
//!   the new one is stored and bound, and never when it fails (#560).
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`):
//! - `metacodes logout` removes both sign-ins and a Metask default, says
//!   which, and the next start falls back to `.env` instead of failing;
//! - `metacodes login --provider metask` revokes the session it replaced
//!   (#560);
//! - a plain start with only the Metask session signs in with it, at the
//!   gateway it names (#499, #527);
//! - a stored default whose provider has no key is passed over with one
//!   warning (level 2), and is used when it has one;
//! - `--provider` naming a provider without a key stops `-p` with its help.

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
const GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5\",\"max_input_tokens\":200000,\"max_tokens\":32000},{\"id\":\"glm-5-air\",\"max_input_tokens\":128000,\"max_tokens\":16000}]}";
/// The access tokens of the Metask sessions `/login` stores (#527).
const SESSION_TOKEN = "at-metask-session-one";
const NEW_SESSION_TOKEN = "at-metask-session-two";

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
    "METACODES_OAUTH_DIR", "METASK_SITE_URL",          RELAY_ENV,
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
        // Sign-out revokes a stored session at the server (#527): a dead
        // port, never Metask's, unless a case points it at its own mock.
        try self.guard("METASK_SITE_URL", "http://127.0.0.1:9");
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

    /// The Metask session `/login` stores (#527): a token response naming
    /// the gateway at `origin`, imported as `/login` imports it.
    fn tokenJson(self: *Case, origin: []const u8, access: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.arena(),
            \\{{"access_token":"{s}","refresh_token":"mrt-{s}","token_type":"bearer","expires_in":3600,"gateway_url":"{s}","models_url":"{s}/v1/models","scope":"read model:invoke"}}
        , .{ access, access, origin, origin });
    }

    fn storeSession(self: *Case, origin: []const u8, access: []const u8) !void {
        const token_json = try self.tokenJson(origin, access);
        try cc.api_provider_login.importTokenResponse(testing.allocator, self.state, cc.provider_ids.Slug.lit("metask"), token_json, null, null);
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

/// No request `server` received carries `secret`.
fn expectNeverSent(server: *harness.MockServer, secret: []const u8) !void {
    for (0..server.requestCount()) |index| {
        const captured = server.requestAt(index) orelse continue;
        if (std.mem.indexOf(u8, captured.raw, secret) != null) {
            std.debug.print("{s} was sent: {s}\n", .{ secret, requestLine(captured) });
            return error.CredentialStillSent;
        }
    }
}

/// The rendered offer id of `provider`'s offer for `model` on `protocol`.
fn offerIdText(app: *App, provider: []const u8, model: []const u8, protocol: []const u8) ![cc.provider_ids.OFFER_ID_TEXT_LEN]u8 {
    const host = try app.providerHost();
    for (host.kernel.catalogSnapshot().items()) |offer| {
        if (!offer.provider_id.eqlText(provider)) continue;
        if (!std.mem.eql(u8, offer.request_model_id, model)) continue;
        if (!std.mem.eql(u8, offer.protocol, protocol)) continue;
        return offer.offer_id.render();
    }
    return error.OfferMissing;
}

/// The offer the provider kernel holds in force: what the picker marks and
/// the next-step hints name.
fn currentOffer(app: *App) !?*const cc.provider_registry.ModelOffer {
    const host = try app.providerHost();
    const id = host.kernel.currentOfferId() orelse return null;
    return host.kernel.catalogSnapshot().find(id);
}

/// A `/model` pick of a Metask offer is refused for want of a credential:
/// nothing of the signed-out account is offered for it. (The compiled
/// offer's endpoint is Metask's own; a pick that wrongly succeeded is only
/// bound, never sent.)
fn expectMetaskPickRefused(app: *App) !void {
    const offer = try offerIdText(app, "metask", "claude-sonnet-4-6", "anthropic_messages");
    const outcome = cc.repl_picker_host.useSelector(app, &offer);
    if (outcome != .failed) {
        std.debug.print("a Metask pick after /logout was not refused: {s}\n", .{@tagName(outcome)});
        return error.SignedOutKeyStillOffered;
    }
    try testing.expectEqualStrings("MissingCredentials", outcome.failed);
}

fn sendOneTurn(app: *App) !void {
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try app.provider().sendStream(&messages, null, null, null, null, null, "");
    defer handle.deinit();
    while (try handle.next()) |event| switch (event) {
        .text => |text| app.allocator.free(text),
        else => {},
    };
}

/// A session started on the Metask sign-in (the historical route, as `main`
/// builds it from auth.json), at `gateway`; `.env` configures the relay.
fn signedInApp(case: *Case, io: std.Io, gateway: []const u8, layer: ?*const cc.app_state_env.Loaded) !*App {
    const a = case.arena();
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", (try std.fmt.allocPrintSentinel(a, "{s}/v1/messages", .{gateway}, 0)).ptr, "--model", "glm-5" }, a);
    try testing.expect(config.parse_error == null);
    config.state_root = case.state;
    config.credential_env_fallback = if (layer) |loaded| loaded.lookup() else null;
    return App.initWithOptions(testing.allocator, io, config, METASK_KEY, .{
        .route_state = .{ .bound = .metask },
        .local_provider = if (layer != null) .{ .name = "house-relay" } else null,
    });
}

test "/logout: a session on Metask moves to the .env provider and never sends the Metask key again (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    try case.write("state/.env", RELAY_ENV ++ "=" ++ RELAY_KEY ++ "\nMETACODES_PROVIDER=house-relay\n");
    try case.writeSignedIn();
    try case.write("state/oauth/metask.json", "{}");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{.{ .name = RELAY_ENV, .provider = "house-relay" }},
    });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try signedInApp(&case, io_runtime.io(), try originOf(a, gateway), &layer);
    defer app.deinit();
    try sendOneTurn(app);
    try testing.expectEqual(@as(usize, 1), gateway.requestCount());
    try testing.expectEqualStrings("Bearer " ++ METASK_KEY, headerValue(gateway.lastRequest().?, "authorization").?);

    const done = try app.signOutOfMetask();
    try testing.expect(done.removed.browser and done.removed.device);
    try testing.expect(done.session == .switched);
    try testing.expectEqualStrings("House relay", done.session.switched.name);
    try testing.expectEqual(cc.app_route_state.CredentialOrigin.local_config, done.session.switched.origin);
    try testing.expect(!done.key_in_shell and !done.key_in_local_config);
    try testing.expect(!case.exists("state/auth.json"));
    try testing.expect(!case.exists("state/oauth/metask.json"));
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("relay-model · from .env", app.bannerModelLine(&line_buf));

    // The next turn goes to the .env provider with its key; the gateway
    // sees nothing more, and nobody sees the Metask key again.
    try sendOneTurn(app);
    try testing.expectEqual(@as(usize, 1), gateway.requestCount());
    const captured = relay.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /relay/v1/chat/completions "));
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, headerValue(captured, "authorization").?);
    try expectNeverSent(relay, METASK_KEY);
    try testing.expect(app.metask_key_route == null);
    // The kernel holds the relay's offer: the switch was a selection commit.
    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expect(current.provider_id.eqlText("house-relay"));
    // And Metask is not usable any more: its key went with the sign-in.
    try expectMetaskPickRefused(app);
    try testing.expectEqual(@as(usize, 1), gateway.requestCount());
}

test "/logout: with no .env provider the session is unbound and nothing is sent (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    try case.writeSignedIn();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try signedInApp(&case, io_runtime.io(), try originOf(a, gateway), null);
    defer app.deinit();
    const done = try app.signOutOfMetask();
    try testing.expect(done.removed.browser and !done.removed.device);
    try testing.expect(done.session == .unbound);
    try testing.expect(app.unbound().? == .signed_out);
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    try testing.expectError(error.InvalidCredential, app.provider().sendStream(&messages, null, null, null, null, null, ""));
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());
    var reminder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reminder.deinit();
    try app.writeUnboundReminder(&reminder.writer);
    try expectContains(reminder.written(), "No model is set up: you signed out of Metask.\n");
    // No offer is in force, and the old key is offered to no Metask pick.
    try testing.expect((try currentOffer(app)) == null);
    try expectMetaskPickRefused(app);
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());
}

test "/login: the stored Metask session becomes the session's route at once, its token on every turn (#485, #527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // Unbound, as `main` starts the TUI with nothing configured.
    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    try testing.expect(app.sessionDir() == null);

    const origin = try originOf(a, gateway);
    const applied = app.applyMetaskSession(
        .{ .gateway = origin, .model = "glm-5", .effort = .low, .models_json = GATEWAY_MODELS },
        try case.tokenJson(origin, SESSION_TOKEN),
        null,
    );
    try testing.expect(applied.switch_error == null);
    try testing.expect(applied.storage_error == null);
    try testing.expect(applied.rollback_error == null);
    try testing.expect(app.unbound() == null);
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("glm-5 · Metask", app.bannerModelLine(&line_buf));
    try testing.expect(app.sessionDir() != null);
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());

    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expect(current.provider_id.eqlText("metask"));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/v1/messages", .{origin}), current.endpoint_ref);

    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /v1/messages "));
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(captured, "authorization").?);
    try testing.expectEqualStrings("\"glm-5\"", captured.jsonField("model").?);

    // The session started without a credential; after /login, Metask's other
    // models are usable in /model too, with the session's token.
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    const picked = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(picked, "authorization").?);
    try testing.expectEqualStrings("\"glm-5-air\"", picked.jsonField("model").?);
}

test "a session built without a key offers no empty Metask key: a Metask pick reads METASK_API_KEY from .env (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    try case.write("state/.env", "METASK_API_KEY=sk-metask-from-file\n");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{.{ .name = "METASK_API_KEY", .provider = "metask" }},
    });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // The historical route with an empty key, as a host that has none
    // builds it: the Metask key route is recorded with nothing in it.
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", (try std.fmt.allocPrintSentinel(a, "{s}/v1/messages", .{try originOf(a, gateway)}, 0)).ptr }, a);
    config.state_root = case.state;
    config.credential_env_fallback = layer.lookup();
    const app = try App.init(testing.allocator, io_runtime.io(), config, "");
    defer app.deinit();
    try testing.expect(app.metask_key_route != null);
    const host = try app.providerHost();
    try host.ingestMetask(try originOf(a, gateway), GATEWAY_MODELS, .messages);

    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    const outcome = cc.repl_picker_host.useSelector(app, &offer);
    if (outcome != .switched) {
        std.debug.print("the pick was not applied: {s}\n", .{if (outcome == .failed) outcome.failed else @tagName(outcome)});
        return error.EmptyKeyBlockedResolution;
    }
    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer sk-metask-from-file", headerValue(captured, "authorization").?);
}

test "/login from a key route, then again: each new session replaces the key and the previous token for every later pick (#485, #527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // On the Metask API-key route with a key (`main` built it from an older
    // sign-in's auth.json): `/models` and Metask picks would use it.
    const origin = try originOf(a, gateway);
    const app = try signedInApp(&case, io_runtime.io(), origin, null);
    defer app.deinit();
    try testing.expect(app.metask_key_route != null);

    try case.storeSession(origin, SESSION_TOKEN);
    try app.bindMetaskSession(.{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS });
    // The key route is gone with its key: a Metask pick authenticates with
    // the session from here.
    try testing.expect(app.metask_key_route == null);
    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expect(current.provider_id.eqlText("metask"));
    try testing.expectEqualStrings("glm-5", current.request_model_id);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(gateway.lastRequest().?, "authorization").?);
    try expectNeverSent(gateway, METASK_KEY);

    // A second /login stores another session: its token, not the first's,
    // goes with the very next request (no pick in between: the route the
    // switch bound must already carry it) and with every later pick.
    try case.storeSession(origin, NEW_SESSION_TOKEN);
    const sent_before = gateway.requestCount();
    try app.bindMetaskSession(.{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS });
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ NEW_SESSION_TOKEN, headerValue(gateway.lastRequest().?, "authorization").?);
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ NEW_SESSION_TOKEN, headerValue(captured, "authorization").?);
    try testing.expectEqualStrings("\"glm-5-air\"", captured.jsonField("model").?);
    for (sent_before..gateway.requestCount()) |index| {
        const later = gateway.requestAt(index) orelse continue;
        if (std.mem.indexOf(u8, later.raw, SESSION_TOKEN) != null) return error.PreviousTokenStillSent;
    }
}

test "a second /login's first request carries its own token to its own gateway, with no pick in between (#527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var first = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer first.stop();
    var second = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer second.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();

    // The first /login, a pick of another of its models and a turn: the
    // process now holds that session, its token loaded (the pick bound its
    // route through it).
    const first_origin = try originOf(a, first);
    var applied = app.applyMetaskSession(
        .{ .gateway = first_origin, .model = "glm-5", .models_json = GATEWAY_MODELS },
        try case.tokenJson(first_origin, SESSION_TOKEN),
        null,
    );
    try testing.expect(applied.switch_error == null and applied.storage_error == null);
    const air = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &air) == .switched);
    try testing.expect(app.oauth_session != null);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(first.lastRequest().?, "authorization").?);

    // A second /login, another account at another gateway. The very next
    // request goes there with the new token: the route was bound with it,
    // not with the session object the process held when the switch began.
    const second_origin = try originOf(a, second);
    applied = app.applyMetaskSession(
        .{ .gateway = second_origin, .model = "glm-5", .models_json = GATEWAY_MODELS },
        try case.tokenJson(second_origin, NEW_SESSION_TOKEN),
        null,
    );
    try testing.expect(applied.switch_error == null and applied.storage_error == null);
    try sendOneTurn(app);
    const captured = second.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ NEW_SESSION_TOKEN, headerValue(captured, "authorization").?);
    try expectNeverSent(second, SESSION_TOKEN);
    try testing.expectEqual(@as(usize, 1), first.requestCount());
}

// ── a sign-in revokes the session it replaced (#560) ────────────────────────

/// A third Metask session's access token.
const THIRD_SESSION_TOKEN = "at-metask-session-three";

/// The fake site's answer to a device-code request: the code is confirmed
/// at once, so the first poll gets the token response.
const DEVICE_GRANT = "{\"device_code\":\"dev-560\",\"user_code\":\"CODE-560\",\"verification_uri\":\"http://127.0.0.1:9/device\",\"expires_in\":60,\"interval\":1}";

const ReplacedOutcome = cc.api_metask_oauth.ReplacedOutcome;

/// The refresh token of the Metask session stored now.
fn storedRefreshToken(case: *Case) ![]const u8 {
    var session = try cc.provider_oauth.Session.initHome(testing.allocator, case.state, cc.provider_ids.Slug.lit("metask"));
    defer session.deinit();
    if (!try session.load()) return error.NoSessionStored;
    return case.arena().dupe(u8, session.tokens.?.refresh_token);
}

/// How many requests `server` received whose request line starts so.
fn countRequests(server: *harness.MockServer, line_prefix: []const u8) usize {
    var count: usize = 0;
    for (0..server.requestCount()) |index| {
        const captured = server.requestAt(index) orelse continue;
        if (std.mem.startsWith(u8, requestLine(captured), line_prefix)) count += 1;
    }
    return count;
}

/// Request `index` is a revocation of the session whose access token is
/// `access`: its refresh token, as the metacodes client, and nothing else.
fn expectRevocationOf(server: *harness.MockServer, index: usize, comptime access: []const u8) !void {
    const captured = server.requestAt(index) orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /api/oauth/revoke "));
    try testing.expectEqualStrings("token=mrt-" ++ access ++ "&token_type_hint=refresh_token&client_id=metacodes", captured.body());
    try expectAbsent(captured.raw, "Bearer");
}

/// A session on no route, as `main` starts the TUI with nothing configured.
fn unboundApp(case: *Case, io: std.Io) !*App {
    var config = cc.parseArgsForTest(&.{"metacodes"}, case.arena());
    config.state_root = case.state;
    return App.initWithOptions(testing.allocator, io, config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
}

test "a second /login revokes the session it replaced, once, with its refresh token, after the new token response (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    // Metask's site and its gateway at one origin, as at www.metask-ai.com:
    // a turn on the first session; the second sign-in's device code and
    // token response (naming the site, filled in once its port is known);
    // the revocation; a turn on the second session.
    var replies = [_][]const u8{ ANTHROPIC_SSE, DEVICE_GRANT, "", "", ANTHROPIC_SSE };
    var site = try harness.MockServer.startCassette(&replies, 0);
    defer site.stop();
    const origin = try originOf(a, site);
    replies[2] = try case.tokenJson(origin, NEW_SESSION_TOKEN);
    try case.guard("METASK_SITE_URL", (try a.dupeZ(u8, origin)).ptr);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try unboundApp(&case, io_runtime.io());
    defer app.deinit();

    // The first /login replaces nothing.
    var applied = app.applyMetaskSession(
        .{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS },
        try case.tokenJson(origin, SESSION_TOKEN),
        null,
    );
    try testing.expect(applied.switch_error == null and applied.storage_error == null);
    try testing.expectEqual(ReplacedOutcome.nothing_replaced, applied.replaced);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(site.lastRequest().?, "authorization").?);

    // The second: its device code and token response, then the switch.
    const token_json = try cc.api_metask_oauth.acquireDeviceToken(testing.allocator, io_runtime.io(), origin, false, null);
    defer testing.allocator.free(token_json);
    applied = app.applyMetaskSession(.{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS }, token_json, null);
    try testing.expect(applied.switch_error == null and applied.storage_error == null and applied.rollback_error == null);
    try testing.expectEqual(ReplacedOutcome.revoked, applied.replaced);
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));

    // Revoked after the new token response, with the first session's
    // refresh token and nothing of the second's.
    try testing.expectEqual(@as(usize, 4), site.requestCount());
    try testing.expect(std.mem.startsWith(u8, requestLine(site.requestAt(2).?), "POST /api/oauth/token "));
    try expectRevocationOf(site, 3, SESSION_TOKEN);
    try expectAbsent(site.requestAt(3).?.raw, NEW_SESSION_TOKEN);

    // The next turn carries the second session's token: the revocation
    // ended the first one only.
    try sendOneTurn(app);
    const turn = site.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(turn), "POST /v1/messages "));
    try testing.expectEqualStrings("Bearer " ++ NEW_SESSION_TOKEN, headerValue(turn, "authorization").?);
    try testing.expectEqual(@as(usize, 1), countRequests(site, "POST /api/oauth/revoke "));
}

test "a /login that is not stored or cannot bind sends no revocation: the previous session stays stored and working (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    // The site and its gateway: any request gets a turn's answer.
    var site = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer site.stop();
    const origin = try originOf(a, site);
    try case.guard("METASK_SITE_URL", (try a.dupeZ(u8, origin)).ptr);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try unboundApp(&case, io_runtime.io());
    defer app.deinit();
    var applied = app.applyMetaskSession(
        .{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS },
        try case.tokenJson(origin, SESSION_TOKEN),
        null,
    );
    try testing.expect(applied.switch_error == null and applied.storage_error == null);

    // Not stored: the token response names no gateway.
    const unusable = "{\"access_token\":\"" ++ NEW_SESSION_TOKEN ++ "\",\"refresh_token\":\"mrt-" ++ NEW_SESSION_TOKEN ++ "\",\"token_type\":\"bearer\",\"expires_in\":3600}";
    applied = app.applyMetaskSession(.{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS }, unusable, null);
    try testing.expect(applied.storage_error != null);
    try testing.expectEqual(ReplacedOutcome.nothing_replaced, applied.replaced);

    // Stored, but no route to bind (a model the gateway does not list), so
    // rolled back.
    applied = app.applyMetaskSession(
        .{ .gateway = origin, .model = "glm-7", .models_json = GATEWAY_MODELS },
        try case.tokenJson(origin, NEW_SESSION_TOKEN),
        null,
    );
    try testing.expectEqual(@as(?anyerror, error.OfferUnavailable), applied.switch_error);
    try testing.expect(applied.rollback_error == null);
    try testing.expectEqual(ReplacedOutcome.nothing_replaced, applied.replaced);

    // Nothing reached the site; the first session is the one stored, and works.
    try testing.expectEqual(@as(usize, 0), site.requestCount());
    try testing.expectEqualStrings("mrt-" ++ SESSION_TOKEN, try storedRefreshToken(&case));
    try sendOneTurn(app);
    try testing.expectEqual(@as(usize, 1), site.requestCount());
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(site.lastRequest().?, "authorization").?);
}

test "a revocation that is refused or not answered in time leaves the /login done (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    // The site refuses the first revocation, answers the second only when
    // released, then serves the turn.
    var site = try harness.MockServer.startHttpCassette(
        &.{ "{\"error\":\"server_error\"}", "", ANTHROPIC_SSE },
        &.{ "HTTP/1.1 500 Internal Server Error", "HTTP/1.1 200 OK", "HTTP/1.1 200 OK" },
    );
    defer site.stop();
    const origin = try originOf(a, site);
    try case.guard("METASK_SITE_URL", (try a.dupeZ(u8, origin)).ptr);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();
    const app = try unboundApp(&case, io_runtime.io());
    defer app.deinit();
    const choice: App.MetaskSession = .{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS };
    var applied = app.applyMetaskSession(choice, try case.tokenJson(origin, SESSION_TOKEN), null);
    try testing.expectEqual(ReplacedOutcome.nothing_replaced, applied.replaced);

    // Refused: the sign-in stands.
    applied = app.applyMetaskSession(choice, try case.tokenJson(origin, NEW_SESSION_TOKEN), null);
    try testing.expect(applied.switch_error == null and applied.storage_error == null and applied.rollback_error == null);
    try testing.expectEqual(ReplacedOutcome.failed, applied.replaced);
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));
    try expectRevocationOf(site, 0, SESSION_TOKEN);

    // Not answered: the sign-in stands once the bound is up.
    site.gateResponseAt(1);
    applied = app.applyMetaskSession(choice, try case.tokenJson(origin, THIRD_SESSION_TOKEN), null);
    try testing.expect(applied.switch_error == null and applied.storage_error == null and applied.rollback_error == null);
    try testing.expectEqual(ReplacedOutcome.timed_out, applied.replaced);
    site.releaseGatedResponse();
    try testing.expectEqualStrings("mrt-" ++ THIRD_SESSION_TOKEN, try storedRefreshToken(&case));
    try expectRevocationOf(site, 1, NEW_SESSION_TOKEN);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ THIRD_SESSION_TOKEN, headerValue(site.lastRequest().?, "authorization").?);
}

test "/login metask outside the dialog revokes the session it replaced and says so where it reports (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var replies = [_][]const u8{ DEVICE_GRANT, "", "" };
    var site = try harness.MockServer.startCassette(&replies, 0);
    defer site.stop();
    const origin = try originOf(a, site);
    replies[1] = try case.tokenJson(origin, NEW_SESSION_TOKEN);
    try case.guard("METASK_SITE_URL", (try a.dupeZ(u8, origin)).ptr);
    try case.storeSession(origin, SESSION_TOKEN);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // The line-mode REPL's `/login metask`, and the login list's Metask
    // entry, run this flow; it says what it did through its sink.
    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    const Sink = struct {
        fn write(ctx: *anyopaque, text: []const u8) void {
            const out: *std.Io.Writer.Allocating = @ptrCast(@alignCast(ctx));
            out.writer.writeAll(text) catch {};
        }
    };
    const prepared: cc.api_provider_login.MetaskPrepared = .{ .options = .{ .state_root = case.state, .open_browser = false } };
    const outcome = try prepared.run(testing.allocator, io_runtime.io(), .{ .ctx = &said, .write = Sink.write }, null);
    try testing.expect(outcome.provider_id.eqlText("metask"));
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));
    try testing.expectEqual(@as(usize, 3), site.requestCount());
    try testing.expect(std.mem.startsWith(u8, requestLine(site.requestAt(1).?), "POST /api/oauth/token "));
    try expectRevocationOf(site, 2, SESSION_TOKEN);
    try expectContains(said.written(), "Metask revoked the previous sign-in.\n");
}

/// A `/v1/models` answer of another account: no glm-5-air.
const OTHER_GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5\",\"max_input_tokens\":200000,\"max_tokens\":32000},{\"id\":\"glm-6\",\"max_input_tokens\":200000,\"max_tokens\":32000}]}";

test "/login that cannot move the session leaves the previous route and models working, and frees nothing in use (#485, #527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var second_gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer second_gateway.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const origin = try originOf(a, gateway);
    try case.writeSignedIn();
    const app = try signedInApp(&case, io_runtime.io(), origin, null);
    defer app.deinit();
    // Signed in once: on the session, with its models.
    try case.storeSession(origin, SESSION_TOKEN);
    try app.bindMetaskSession(.{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS });
    const messages_url = try std.fmt.allocPrint(a, "{s}/v1/messages", .{origin});

    // The real /login order: the second token response reaches the durable
    // import before its missing offer makes the route switch fail. It names
    // another gateway, so sending B on the old route would also cross origins.
    const second_origin = try originOf(a, second_gateway);
    const applied = app.applyMetaskSession(.{
        .gateway = second_origin,
        .model = "glm-5-air",
        .models_json = OTHER_GATEWAY_MODELS,
    }, try case.tokenJson(second_origin, NEW_SESSION_TOKEN), null);
    try testing.expectEqual(@as(?anyerror, error.OfferUnavailable), applied.switch_error);
    try testing.expect(applied.storage_error == null);
    try testing.expect(applied.rollback_error == null);

    // Everything is as before: the offer in force, the first sign-in's
    // models (glm-5-air is the first sign-in's), and the session's token.
    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expectEqualStrings("glm-5", current.request_model_id);
    try testing.expectEqualStrings(messages_url, current.endpoint_ref);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(gateway.lastRequest().?, "authorization").?);
    try testing.expectEqual(@as(usize, 0), second_gateway.requestCount());
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    const picked = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(picked, "authorization").?);
    try testing.expectEqualStrings("\"glm-5-air\"", picked.jsonField("model").?);
    try expectNeverSent(gateway, METASK_KEY);
    // The durable half rolled back too: a restart cannot pick up session B,
    // and the previous auth.json (including its key) is intact.
    var stored_session = try cc.provider_oauth.Session.initHome(testing.allocator, case.state, cc.provider_ids.Slug.lit("metask"));
    defer stored_session.deinit();
    try testing.expect(try stored_session.load());
    try testing.expectEqualStrings(SESSION_TOKEN, stored_session.tokens.?.access_token);
    var restored_auth = try cc.core_auth.loadDefault(testing.allocator, case.state);
    defer restored_auth.deinit(testing.allocator);
    try testing.expectEqualStrings("glm-5", restored_auth.selected_model.?);
    try testing.expectEqualStrings(METASK_KEY, restored_auth.api_key.?);
    // The testing allocator checks the rest at `app.deinit`: nothing the
    // failed sign-in allocated leaks, and nothing is freed twice.
}

test "/login that cannot bind a first session keeps the default and stores no partial sign-in (#485, #527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    try storeDefault(&case, "house-relay", "relay-model");
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    const origin = try originOf(a, gateway);
    // A model the gateway does not list: the switch fails.
    const applied = app.applyMetaskSession(
        .{ .gateway = origin, .model = "glm-7", .models_json = GATEWAY_MODELS },
        try case.tokenJson(origin, NEW_SESSION_TOKEN),
        null,
    );
    try testing.expectEqual(@as(?anyerror, error.OfferUnavailable), applied.switch_error);
    try testing.expect(!applied.default_forgotten);
    try testing.expect(applied.default_error == null);
    try testing.expect(applied.rollback_error == null);
    try testing.expect(app.unbound() != null);
    try testing.expect(!case.exists("state/oauth/metask.json"));
    try testing.expect(!case.exists("state/auth.json"));
    var store = try cc.provider_config_store.Store.initHome(a, case.state);
    defer store.deinit();
    var document = try store.load();
    defer document.deinit();
    try testing.expect(document.global_selection != null);
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());
}

test "/logout with .env configuring Metask: the session goes on with .env's key only, never the session signed out of (#485, #527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    const file_key = "sk-metask-from-the-env-file";
    try case.write("state/.env", "METASK_API_KEY=" ++ file_key ++ "\n");
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{.{ .name = "METASK_API_KEY", .provider = "metask" }},
    });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // Started on the historical route; `.env` holds only a Metask key, so it
    // configures Metask.
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", (try std.fmt.allocPrintSentinel(a, "{s}/v1/messages", .{try originOf(a, gateway)}, 0)).ptr, "--model", "glm-5" }, a);
    config.state_root = case.state;
    config.credential_env_fallback = layer.lookup();
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, METASK_KEY, .{
        .route_state = .{ .bound = .metask },
        .local_provider = .{ .name = "metask" },
    });
    defer app.deinit();
    try case.storeSession(try originOf(a, gateway), SESSION_TOKEN);
    try app.bindMetaskSession(.{ .gateway = try originOf(a, gateway), .model = "glm-5", .models_json = GATEWAY_MODELS });
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(gateway.lastRequest().?, "authorization").?);

    // A Metask key in the shell too: it is not what `.env` configures.
    const shell_key = "sk-metask-from-the-shell";
    try case.guard("METASK_API_KEY", shell_key);
    const done = try app.signOutOfMetask();
    try testing.expect(done.session == .switched);
    try testing.expectEqualStrings("Metask", done.session.switched.name);
    try testing.expectEqual(cc.app_route_state.CredentialOrigin.local_config, done.session.switched.origin);
    try testing.expect(done.key_in_shell and done.key_in_local_config);

    const signed_out_at = gateway.requestCount();
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ file_key, headerValue(gateway.lastRequest().?, "authorization").?);
    // Another of the account's models: still `.env`'s key.
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ file_key, headerValue(gateway.lastRequest().?, "authorization").?);
    for (signed_out_at..gateway.requestCount()) |index| {
        const captured = gateway.requestAt(index) orelse continue;
        for ([_][]const u8{ SESSION_TOKEN, METASK_KEY, shell_key }) |secret| {
            if (std.mem.indexOf(u8, captured.raw, secret) != null) {
                std.debug.print("{s} was sent after /logout: {s}\n", .{ secret, requestLine(captured) });
                return error.CredentialStillSent;
            }
        }
    }
}

test "/logout says where the .env provider's key came from: the shell's, ahead of the file (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    // `.env` names the relay; its key is in the shell only.
    try case.write("state/.env", "METACODES_PROVIDER=house-relay\n");
    try case.guard(RELAY_ENV, RELAY_KEY);
    var layer = try cc.app_state_env.load(testing.allocator, case.state, .{
        .keys = &.{.{ .name = RELAY_ENV, .provider = "house-relay" }},
    });
    defer layer.deinit();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try signedInApp(&case, io_runtime.io(), try originOf(a, gateway), &layer);
    defer app.deinit();
    const done = try app.signOutOfMetask();
    try testing.expect(done.session == .switched);
    try testing.expectEqualStrings("House relay", done.session.switched.name);
    try testing.expectEqual(cc.app_route_state.CredentialOrigin.environment, done.session.switched.origin);
    try testing.expectEqualStrings("from shell", done.session.switched.origin.label().?);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, headerValue(relay.lastRequest().?, "authorization").?);
}

test "/logout forgets a Metask default in the kernel too, at the store's revision (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    try case.writeSignedIn();
    try storeDefault(&case, "metask", "claude-sonnet-4-6");
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try signedInApp(&case, io_runtime.io(), try originOf(a, gateway), null);
    defer app.deinit();
    const host = try app.providerHost();
    const done = try app.signOutOfMetask();
    try testing.expect(done.default_cleared);
    var store = try cc.provider_config_store.Store.initHome(a, case.state);
    defer store.deinit();
    var document = try store.load();
    defer document.deinit();
    try testing.expect(document.global_selection == null);
    // The kernel mirrors the store's revision: a client that compares
    // against it sees no conflict that is not there.
    try testing.expectEqual(document.config_revision.value(), host.kernel.config_revision.value());
}

test "a named provider without its key starts unbound: no offer is marked current, in the picker or /providers (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // The offer `--provider house-relay` resolves to, which `main` records
    // for the session (`config.selected_offer_id`).
    const named = blk: {
        var config = cc.parseArgsForTest(&.{"metacodes"}, a);
        config.state_root = case.state;
        const probe = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
        defer probe.deinit();
        break :blk try offerIdText(probe, "house-relay", "relay-model", "openai_chat");
    };
    var config = cc.parseArgsForTest(&.{ "metacodes", "--provider", "house-relay" }, a);
    config.state_root = case.state;
    config.selected_offer_id = &named;
    // No key for it: `main` opens the TUI unbound (第十节第 3 条).
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{
        .route_state = .{ .unbound = .{ .missing_credential = cc.provider_ids.Slug.lit("house-relay") } },
    });
    defer app.deinit();
    const host = try app.providerHost();
    try testing.expect(host.kernel.currentOfferId() == null);
    // `/providers` marks what `model.list` calls current.
    var page: std.ArrayList(cc.provider_control_plane.OfferSummary) = .empty;
    defer page.deinit(testing.allocator);
    const listed = try host.kernel.modelList(.{}, .{}, testing.allocator, &page);
    for (listed.offers) |summary| try testing.expect(!summary.is_current);
    const described = host.kernel.modelDescribe(try cc.provider_ids.OfferId.parse(&named)) orelse return error.OfferMissing;
    try testing.expect(!described.is_current);
    // The picker marks the kernel's current offer.
    try app.refreshModelPicker();
    try testing.expect(app.model_picker.current_offer == null);
    try testing.expectEqual(@as(usize, 0), relay.requestCount());
}

test "/logout <provider>: the stored key goes, and a session that ran on it holds none (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    try cc.provider_api_key_store.save(testing.allocator, case.state, cc.provider_ids.Slug.lit("house-relay"), .api_key, RELAY_KEY, null, cc.util_time.nowUnix());
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    try testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("relay-model · saved key", app.bannerModelLine(&line_buf));

    const result = try app.forgetProviderKey(cc.provider_ids.Slug.lit("house-relay"));
    try testing.expect(result.removed and result.unbound);
    try testing.expect(!case.exists("state/keys/house-relay.json"));
    try testing.expect(app.unbound().? == .missing_credential);
    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    try testing.expectError(error.InvalidCredential, app.provider().sendStream(&messages, null, null, null, null, null, ""));
    try testing.expectEqual(@as(usize, 0), relay.requestCount());
    var reminder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reminder.deinit();
    try app.writeUnboundReminder(&reminder.writer);
    try expectContains(reminder.written(), "No model is set up: House relay has no key.\n  Put " ++ RELAY_ENV ++ " in your shell, or in ");
}

// ── through the real CLI ─────────────────────────────────────────────────────

const Run = struct {
    exit_code: i32,
    stderr: []const u8,
};

test "/logout revokes the Metask session at the server first, as the metacodes client, and sends no token anywhere else (#527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    // The authorization server: answers the revocation with 200.
    var site = try harness.MockServer.startCassette(&.{""}, 0);
    defer site.stop();
    try case.guard("METASK_SITE_URL", (try a.dupeZ(u8, try originOf(a, site))).ptr);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    const origin = try originOf(a, gateway);
    try case.storeSession(origin, SESSION_TOKEN);
    try app.bindMetaskSession(.{ .gateway = origin, .model = "glm-5", .models_json = GATEWAY_MODELS });

    const done = try app.signOutOfMetask();
    try testing.expectEqual(cc.api_metask_oauth.RevokeOutcome.revoked, done.revoke);
    try testing.expect(done.removed.device);
    try testing.expect(!case.exists("state/oauth/metask.json"));
    try testing.expectEqual(@as(usize, 1), site.requestCount());
    const revoke = site.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(revoke), "POST /api/oauth/revoke "));
    try expectContains(revoke.raw, "token=mrt-" ++ SESSION_TOKEN ++ "&token_type_hint=refresh_token&client_id=metacodes");
    // The access token goes nowhere at sign-out; the gateway heard nothing.
    try expectAbsent(revoke.raw, "Bearer");
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());
}

test "metacodes login --provider metask without a terminal revokes the session it replaced, after the new token response, and says so (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    // Two sign-ins at the site (and gateway): each a device code and a token
    // response (filled in once the port is known), then the revocation, the
    // second one refused.
    var replies = [_][]const u8{ DEVICE_GRANT, "", "", DEVICE_GRANT, "", "{\"error\":\"server_error\"}" };
    const ok = "HTTP/1.1 200 OK";
    var site = try harness.MockServer.startHttpCassette(&replies, &.{ ok, ok, ok, ok, ok, "HTTP/1.1 500 Internal Server Error" });
    defer site.stop();
    const origin = try originOf(a, site);
    replies[1] = try case.tokenJson(origin, NEW_SESSION_TOKEN);
    replies[4] = try case.tokenJson(origin, THIRD_SESSION_TOKEN);
    try case.storeSession(origin, SESSION_TOKEN);
    const site_env = try std.fmt.allocPrint(a, "METASK_SITE_URL={s}", .{origin});
    const secrets = [_][]const u8{ SESSION_TOKEN, NEW_SESSION_TOKEN, THIRD_SESSION_TOKEN, "mrt-" };

    const out = try runCli(&case, cli, &.{site_env}, &.{ "login", "--provider", "metask", "--no-browser" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try expectContains(out.stderr, "Stored Metask OAuth session. No secret was printed.\nMetask revoked the previous sign-in.\n");
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));
    try testing.expectEqual(@as(usize, 3), site.requestCount());
    try testing.expect(std.mem.startsWith(u8, requestLine(site.requestAt(1).?), "POST /api/oauth/token "));
    try expectRevocationOf(site, 2, SESSION_TOKEN);
    for (secrets) |secret| try expectAbsent(out.stderr, secret);

    // Refused: the sign-in is stored all the same, and the run says what
    // stays valid, in sign-out's words.
    const refused = try runCli(&case, cli, &.{site_env}, &.{ "login", "--provider", "metask", "--no-browser" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ refused.exit_code, refused.stderr });
    try testing.expectEqual(@as(i32, 0), refused.exit_code);
    try expectContains(refused.stderr, "warning: Metask could not revoke the previous sign-in; it stays valid there until it expires.\n");
    try testing.expectEqualStrings("mrt-" ++ THIRD_SESSION_TOKEN, try storedRefreshToken(&case));
    try testing.expectEqual(@as(usize, 6), site.requestCount());
    try expectRevocationOf(site, 5, NEW_SESSION_TOKEN);
    for (secrets) |secret| try expectAbsent(refused.stderr, secret);
}

test "metacodes login --provider metask --oauth-token-json revokes the session it replaced, not the same session imported again (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    // The site answers the one revocation.
    var site = try harness.MockServer.startCassette(&.{""}, 0);
    defer site.stop();
    const origin = try originOf(a, site);
    try case.storeSession(origin, SESSION_TOKEN);
    try case.write("work/token.json", try case.tokenJson(origin, NEW_SESSION_TOKEN));
    const site_env = try std.fmt.allocPrint(a, "METASK_SITE_URL={s}", .{origin});
    const args = [_][]const u8{ "login", "--provider", "metask", "--oauth-token-json", try std.fs.path.join(a, &.{ case.work, "token.json" }) };

    const out = try runCli(&case, cli, &.{site_env}, &args);
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try expectContains(out.stderr, "Stored an OAuth login for provider 'metask'. No secret was printed.\nMetask revoked the previous sign-in.\n");
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));
    try testing.expectEqual(@as(usize, 1), site.requestCount());
    try expectRevocationOf(site, 0, SESSION_TOKEN);

    // The same token response again: the session stored is that one, and
    // revoking it would end it. Nothing is sent, and nothing said.
    const again = try runCli(&case, cli, &.{site_env}, &args);
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ again.exit_code, again.stderr });
    try testing.expectEqual(@as(i32, 0), again.exit_code);
    try expectAbsent(again.stderr, "revoke");
    try testing.expectEqual(@as(usize, 1), site.requestCount());
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));
}

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
        // Sign-out revokes a stored session at the server (#527): a dead
        // port, never Metask's, unless a case points it at its own mock.
        "METASK_SITE_URL=http://127.0.0.1:9",
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
    try expectContains(out.stderr, "auth.json (an older browser sign-in, a key, or the model choice).");
    try expectContains(out.stderr, "Removed the Metask sign-in and its refresh token (");
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

test "metacodes login status says which level decides a plain start and what each holds, never a secret" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    const secrets = [_][]const u8{ RELAY_KEY, SESSION_TOKEN, METASK_KEY, "at-login", "rt-login" };

    // Nothing set up: level 7.
    var out = try runCli(&case, cli, &.{}, &.{ "login", "status" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try expectContains(out.stderr, "This start uses no provider: nothing is set up.");
    try expectContains(out.stderr, "Level 7 of 7 decided; the first that applies wins:");
    try expectContains(out.stderr, "> 7 nothing");
    try expectContains(out.stderr, "No secret was printed.");

    // `.env` configures a provider: level 6, named by the file.
    try case.write("state/config.json", try relayConfig(a, "http://127.0.0.1:9"));
    try case.write("state/.env", RELAY_ENV ++ "=" ++ RELAY_KEY ++ "\nMETACODES_PROVIDER=house-relay\n");
    out = try runCli(&case, cli, &.{}, &.{ "login", "status" });
    try expectContains(out.stderr, "This start uses House relay from ");
    try expectContains(out.stderr, "Level 6 of 7 decided");
    try expectContains(out.stderr, "; " ++ RELAY_ENV ++ ", METACODES_PROVIDER; configures House relay\n");
    for (secrets) |secret| try expectAbsent(out.stderr, secret);

    // The Metask session outranks it: level 5, with the model it chose.
    try case.storeSession("http://127.0.0.1:9", SESSION_TOKEN);
    try case.write("state/auth.json", "{\"selected_model\":\"glm-5\",\"reasoning_effort\":\"low\"}");
    out = try runCli(&case, cli, &.{}, &.{ "login", "status" });
    try expectContains(out.stderr, "This start uses Metask, signed in · glm-5 · reasoning low.");
    try expectContains(out.stderr, "> 5 Metask sign-in: the session (");
    try expectContains(out.stderr, "auth.json: model glm-5, reasoning low\n");
    for (secrets) |secret| try expectAbsent(out.stderr, secret);

    // A key in auth.json is the historical path's, ahead of the session.
    try case.writeSignedIn();
    out = try runCli(&case, cli, &.{}, &.{ "login", "status" });
    try expectContains(out.stderr, "This start uses Metask with the key in auth.json · glm-5 · reasoning low.");
    try expectContains(out.stderr, "; a key; an older browser sign-in\n");
    for (secrets) |secret| try expectAbsent(out.stderr, secret);

    // A default stored with /model whose provider has its key: level 4.
    try storeDefault(&case, "house-relay", "relay-model");
    out = try runCli(&case, cli, &.{}, &.{ "login", "status" });
    try expectContains(out.stderr, "This start uses the default stored with /model: House relay · relay-model.");
    try expectContains(out.stderr, "> 4 stored default: House relay · relay-model\n");

    // The shell names a provider: level 1, and the stored default is not consulted.
    out = try runCli(&case, cli, &.{"METACODES_PROVIDER=house-relay"}, &.{ "login", "status" });
    try expectContains(out.stderr, "This start uses the provider the shell names: METACODES_PROVIDER=house-relay.");
    try expectContains(out.stderr, "> 1 named at start: METACODES_PROVIDER=house-relay in the shell");
    try expectContains(out.stderr, "  4 stored default: not consulted, level 1 names a provider");

    // A key only in the shell chooses nothing, and is named, not printed.
    out = try runCli(&case, cli, &.{"DEEPSEEK_API_KEY=sk-shell-only-deepseek"}, &.{ "login", "status" });
    try expectContains(out.stderr, "Keys in the shell choose no provider: DEEPSEEK_API_KEY (DeepSeek).");
    try expectAbsent(out.stderr, "sk-shell-only-deepseek");
}

test "login status reads METACODES_AUTH_PRECEDENCE as the start does: under oauth-first an empty METASK_API_KEY leaves the session in charge (#537)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    // The gateway: its `/v1/models` (read at the start with the session's
    // token), then the turn.
    var gateway = try harness.MockServer.startCassette(&.{ GATEWAY_MODELS, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    try case.storeSession(try originOf(a, gateway), SESSION_TOKEN);
    try case.write("state/auth.json", "{\"selected_model\":\"glm-5\",\"reasoning_effort\":\"low\"}");
    // `METASK_API_KEY=` is set but empty: under the default api_key_first it
    // asks for the historical path; under oauth-first it does not.
    const oauth_first = [_][]const u8{ "METACODES_AUTH_PRECEDENCE=oauth-first", "METASK_API_KEY=" };

    const status = try runCli(&case, cli, &oauth_first, &.{ "login", "status" });
    errdefer std.debug.print("status exit {d}; stderr:\n{s}\n", .{ status.exit_code, status.stderr });
    try expectContains(status.stderr, "This start uses Metask, signed in · glm-5 · reasoning low.");
    try expectContains(status.stderr, "> 5 Metask sign-in: the session (");
    try expectContains(status.stderr, "METACODES_AUTH_PRECEDENCE=oauth-first");
    try expectAbsent(status.stderr, SESSION_TOKEN);

    // And a plain start does sign in with it.
    const out = try runCli(&case, cli, &oauth_first, &.{ "-p", "hi" });
    errdefer std.debug.print("start exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    const turn = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(turn, "authorization").?);

    // Under the default, the same empty variable sets the session aside, and
    // both say there is nothing to start with.
    const default_status = try runCli(&case, cli, &.{"METASK_API_KEY="}, &.{ "login", "status" });
    try expectContains(default_status.stderr, "Level 7 of 7 decided");
    const sent = gateway.requestCount();
    const default_start = try runCli(&case, cli, &.{"METASK_API_KEY="}, &.{ "-p", "hi" });
    try testing.expect(default_start.exit_code != 0);
    try testing.expectEqual(sent, gateway.requestCount());
}

test "login status does not call the /model default's own shell key one that chooses no provider" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    // DeepSeek is the stored default and its key is in the shell. That key is
    // the default's own credential, so only OpenAI's key chooses no provider.
    try storeDefault(&case, "deepseek", "deepseek-v4-pro");
    const out = try runCli(&case, cli, &.{ "DEEPSEEK_API_KEY=sk-shell-deepseek", "OPENAI_API_KEY=sk-shell-openai" }, &.{ "login", "status" });
    try expectContains(out.stderr, "This start uses the default stored with /model: DeepSeek · deepseek-v4-pro.");
    try expectContains(out.stderr, "Keys in the shell choose no provider: OPENAI_API_KEY (OpenAI).");
    try expectAbsent(out.stderr, "DEEPSEEK_API_KEY (DeepSeek)");
    for ([_][]const u8{ "sk-shell-deepseek", "sk-shell-openai" }) |secret| try expectAbsent(out.stderr, secret);
}

test "a plain start with only the Metask session signs in with it, at the gateway it names, ahead of .env (#499, #527)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    // The gateway: its `/v1/models` (read at the start with the session's
    // token), then the turn.
    var gateway = try harness.MockServer.startCassette(&.{ GATEWAY_MODELS, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    // `.env` configures another provider: level 4, below the sign-in.
    try case.write("state/.env", RELAY_ENV ++ "=" ++ RELAY_KEY ++ "\nMETACODES_PROVIDER=house-relay\n");
    try case.storeSession(try originOf(a, gateway), SESSION_TOKEN);
    // The model `/login` chose, as it records it.
    try case.write("state/auth.json", "{\"selected_model\":\"glm-5\",\"reasoning_effort\":\"low\"}");

    const out = try runCli(&case, cli, &.{}, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try testing.expectEqual(@as(i32, 0), out.exit_code);
    try testing.expectEqual(@as(usize, 0), relay.requestCount());
    const turn = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(turn), "POST /v1/messages "));
    try testing.expectEqualStrings("Bearer " ++ SESSION_TOKEN, headerValue(turn, "authorization").?);
    try testing.expectEqualStrings("\"glm-5\"", turn.jsonField("model").?);
    try expectAbsent(out.stderr, SESSION_TOKEN);
}

test "a stored default without a credential is passed over with one warning, and used once it has one (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    try storeDefault(&case, "house-relay", "relay-model");
    try case.writeSignedIn();
    const base_url = try std.fmt.allocPrint(a, "METACODES_BASE_URL={s}/v1/messages", .{try originOf(a, gateway)});

    // No relay key anywhere: the default is passed over for the Metask
    // sign-in (level 3), and the run says so once.
    const skipped = try runCli(&case, cli, &.{base_url}, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ skipped.exit_code, skipped.stderr });
    try testing.expectEqual(@as(i32, 0), skipped.exit_code);
    try expectContains(skipped.stderr, "warning: The default model, House relay · relay-model, has no key or sign-in; this session uses glm-5 · Metask.");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, skipped.stderr, "The default model"));
    try testing.expectEqual(@as(usize, 0), relay.requestCount());
    try testing.expectEqualStrings("Bearer " ++ METASK_KEY, headerValue(gateway.lastRequest().?, "authorization").?);

    // With its key, the default is what the start uses, without a word.
    const used = try runCli(&case, cli, &.{ base_url, RELAY_ENV ++ "=" ++ RELAY_KEY }, &.{ "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ used.exit_code, used.stderr });
    try testing.expectEqual(@as(i32, 0), used.exit_code);
    try expectAbsent(used.stderr, "The default model");
    try testing.expectEqualStrings("Bearer " ++ RELAY_KEY, headerValue(relay.lastRequest().?, "authorization").?);
    try testing.expectEqual(@as(usize, 1), gateway.requestCount());
}

test "--provider naming a provider without a key stops -p with its help, sending nothing (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const cli = (try cliPath(&case)) orelse return error.SkipZigTest;
    try case.enter();
    const a = case.arena();
    var relay = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer relay.stop();
    try case.write("state/config.json", try relayConfig(a, try originOf(a, relay)));
    // A Metask sign-in is there; it is not used in the named provider's place.
    try case.writeSignedIn();
    const run = try runCli(&case, cli, &.{}, &.{ "--provider", "house-relay", "-p", "hi" });
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ run.exit_code, run.stderr });
    try testing.expect(run.exit_code != 0);
    try expectContains(run.stderr, "Authentication required for provider 'house-relay'.");
    try expectContains(run.stderr, "export " ++ RELAY_ENV ++ "=...");
    try testing.expectEqual(@as(usize, 0), relay.requestCount());
}
