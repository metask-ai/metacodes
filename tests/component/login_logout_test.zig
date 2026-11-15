//! L2 for #485 and #499 part 2: `/login` and `/logout` switch a session
//! between the Metask account and local configuration, and signing out
//! leaves no Metask credential behind.
//!
//! In process, on a real `App`, against MockServers standing in for the
//! Metask gateway and for a relay `config.json` defines (the provider
//! `.env` configures):
//! - `bindMetaskSignIn` (what `/login` does once key, model and reasoning
//!   level are chosen) moves the session, unbound or not, onto the sign-in:
//!   the next turn reaches the gateway with that key and model;
//! - `signOutOfMetask` (`/logout`) removes both Metask sign-ins, moves a
//!   session on Metask to the `.env` provider, and never sends the Metask key
//!   again; with no `.env` provider the session is unbound and nothing is
//!   sent at all;
//! - `forgetProviderKey` (`/logout <provider>`) removes the stored key and
//!   leaves a session that ran on it without a credential.
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`):
//! - `metacodes logout` removes both sign-ins and a Metask default, says
//!   which, and the next start falls back to `.env` instead of failing;
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
/// The key a second `/login` hands over.
const NEW_METASK_KEY = "sk-metask-signed-in-again";

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

test "/login: the chosen key and model become the session's route at once (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_SSE}, 0);
    defer gateway.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // Unbound, as `main` starts the TUI with nothing configured.
    var config = cc.parseArgsForTest(&.{"metacodes"}, a);
    config.state_root = case.state;
    const app = try App.initWithOptions(testing.allocator, io_runtime.io(), config, "", .{ .route_state = .{ .unbound = .nothing_configured } });
    defer app.deinit();
    try testing.expect(app.sessionDir() == null);

    const messages_url = try std.fmt.allocPrint(a, "{s}/v1/messages", .{try originOf(a, gateway)});
    try app.bindMetaskSignIn(.{
        .messages_url = messages_url,
        .key = METASK_KEY,
        .model = "glm-5",
        .effort = .low,
        .models_json = GATEWAY_MODELS,
    });
    try testing.expect(app.unbound() == null);
    var line_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("glm-5 · Metask", app.bannerModelLine(&line_buf));
    try testing.expect(app.sessionDir() != null);
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());

    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expect(current.provider_id.eqlText("metask"));

    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /v1/messages "));
    try testing.expectEqualStrings("Bearer " ++ METASK_KEY, headerValue(captured, "authorization").?);
    try testing.expectEqualStrings("\"glm-5\"", captured.jsonField("model").?);

    // The session started without a key; after /login, Metask's other
    // models are usable in /model too, with the sign-in's key.
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    const picked = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ METASK_KEY, headerValue(picked, "authorization").?);
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

test "/login again: the new key replaces the old one for every later Metask pick, and the kernel names its offer (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // On the Metask API-key route with the old key (`main` built it from
    // auth.json): `/models` and Metask picks would authenticate with it.
    const app = try signedInApp(&case, io_runtime.io(), try originOf(a, gateway), null);
    defer app.deinit();
    try testing.expect(app.metask_key_route != null);

    const messages_url = try std.fmt.allocPrint(a, "{s}/v1/messages", .{try originOf(a, gateway)});
    try app.bindMetaskSignIn(.{ .messages_url = messages_url, .key = NEW_METASK_KEY, .model = "glm-5", .models_json = GATEWAY_MODELS });
    // A selection commit: the kernel's current offer is the sign-in's.
    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expect(current.provider_id.eqlText("metask"));
    try testing.expectEqualStrings("glm-5", current.request_model_id);
    try testing.expectEqualStrings(messages_url, current.endpoint_ref);

    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ NEW_METASK_KEY, headerValue(gateway.lastRequest().?, "authorization").?);
    // A later pick of another of the account's models: still the new key.
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    const captured = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ NEW_METASK_KEY, headerValue(captured, "authorization").?);
    try testing.expectEqualStrings("\"glm-5-air\"", captured.jsonField("model").?);
    try expectNeverSent(gateway, METASK_KEY);
}

/// A `/v1/models` answer of another account: no glm-5-air.
const OTHER_GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5\",\"max_input_tokens\":200000,\"max_tokens\":32000},{\"id\":\"glm-6\",\"max_input_tokens\":200000,\"max_tokens\":32000}]}";
/// The key a `/login` that fails hands over.
const FAILED_SIGN_IN_KEY = "sk-metask-sign-in-that-failed";

test "/login that cannot move the session leaves the previous key, route and models working, and frees nothing in use (#485)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var gateway = try harness.MockServer.startCassette(&.{ ANTHROPIC_SSE, ANTHROPIC_SSE }, 0);
    defer gateway.stop();
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    const app = try signedInApp(&case, io_runtime.io(), try originOf(a, gateway), null);
    defer app.deinit();
    // Signed in once: the session's key route holds that sign-in's key, the
    // one a Metask pick authenticates with.
    const messages_url = try std.fmt.allocPrint(a, "{s}/v1/messages", .{try originOf(a, gateway)});
    try app.bindMetaskSignIn(.{ .messages_url = messages_url, .key = NEW_METASK_KEY, .model = "glm-5", .models_json = GATEWAY_MODELS });

    // A second sign-in whose offer is nowhere: the endpoint it names is not
    // the one its gateway's models are offered at.
    const astray = try std.fmt.allocPrint(a, "{s}//v1/messages", .{try originOf(a, gateway)});
    try testing.expectError(error.OfferUnavailable, app.bindMetaskSignIn(.{
        .messages_url = astray,
        .key = FAILED_SIGN_IN_KEY,
        .model = "glm-5",
        .models_json = OTHER_GATEWAY_MODELS,
    }));

    // Everything is as before: the route, the offer in force, the account's
    // models (glm-5-air is the first sign-in's), and its key.
    try testing.expectEqualStrings(try originOf(a, gateway), app.metask_key_route.?.gateway_origin);
    const current = (try currentOffer(app)) orelse return error.NoCurrentOffer;
    try testing.expectEqualStrings("glm-5", current.request_model_id);
    try testing.expectEqualStrings(messages_url, current.endpoint_ref);
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ NEW_METASK_KEY, headerValue(gateway.lastRequest().?, "authorization").?);
    const offer = try offerIdText(app, "metask", "glm-5-air", "anthropic_messages");
    try testing.expect(cc.repl_picker_host.useSelector(app, &offer) == .switched);
    try sendOneTurn(app);
    const picked = gateway.lastRequest() orelse return error.NoRequestCaptured;
    try testing.expectEqualStrings("Bearer " ++ NEW_METASK_KEY, headerValue(picked, "authorization").?);
    try testing.expectEqualStrings("\"glm-5-air\"", picked.jsonField("model").?);
    try expectNeverSent(gateway, FAILED_SIGN_IN_KEY);
    // The testing allocator checks the rest at `app.deinit`: nothing the
    // failed sign-in allocated leaks, and nothing is freed twice.
}

test "/login that cannot move the session still forgets the stored default: the sign-in is the latest choice (#485)" {
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
    const astray = try std.fmt.allocPrint(a, "{s}//v1/messages", .{try originOf(a, gateway)});
    const applied = app.applyMetaskSignIn(.{ .messages_url = astray, .key = METASK_KEY, .model = "glm-5", .models_json = GATEWAY_MODELS });
    try testing.expectEqual(@as(?anyerror, error.OfferUnavailable), applied.switch_error);
    try testing.expect(applied.default_forgotten);
    try testing.expect(applied.default_error == null);
    try testing.expect(app.unbound() != null);
    var store = try cc.provider_config_store.Store.initHome(a, case.state);
    defer store.deinit();
    var document = try store.load();
    defer document.deinit();
    try testing.expect(document.global_selection == null);
    try testing.expectEqual(@as(usize, 0), gateway.requestCount());
}

test "/logout with .env configuring Metask: the session goes on with .env's key only, never the one signed out of (#485)" {
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
    const messages_url = try std.fmt.allocPrint(a, "{s}/v1/messages", .{try originOf(a, gateway)});
    try app.bindMetaskSignIn(.{ .messages_url = messages_url, .key = NEW_METASK_KEY, .model = "glm-5", .models_json = GATEWAY_MODELS });
    try sendOneTurn(app);
    try testing.expectEqualStrings("Bearer " ++ NEW_METASK_KEY, headerValue(gateway.lastRequest().?, "authorization").?);

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
        for ([_][]const u8{ NEW_METASK_KEY, METASK_KEY, shell_key }) |secret| {
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
