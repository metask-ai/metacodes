//! L2 evidence: a credential is sent only to the provider it belongs to, on
//! the route the session is actually on.
//!
//! The other providers are configured relays in the state root's
//! `config.json`, so every request reaches a MockServer on loopback. Every
//! secret here is a made-up string. Mock transport only: no provider-backed
//! calls.
//!
//! Each section covers a place that handed one provider's credential to
//! another:
//!
//!   * The configured credential pool (`providers.<id>.credentials[]`) was one
//!     list for every provider, so a provider with no key of its own took
//!     another provider's member whenever its profile accepted the kind, and
//!     a route that names an account fell back to another one when that
//!     account's variable was unset.
//!   * A `/model` switch that could not bind left the kernel's selection and
//!     the process's OAuth session on the new provider, and the next turn's
//!     token refresh installed that provider's token on the route the
//!     clients were still on.
//!   * The turn's token refresh followed the kernel's effective selection,
//!     not the route the clients were bound to, so after a pick in the
//!     global or once scope it put the previous route's OAuth token on the
//!     new one, and replaced a key or a pool account a route was bound with.
//!   * The Metask refresh callback stayed on the clients after the session
//!     left the Metask sign-in's route, so another endpoint's 401
//!     `token_expired` was retried with the Metask token, and it answered
//!     with whatever OAuth session the process held.
//!   * A transport's own refresh on a 401 `token_expired` installed and
//!     replayed the refreshed token on whatever route the client had been
//!     moved to while the refresh ran.
//!   * The `/models` key list was fetched with the Metask sign-in from
//!     whatever route the session was on.
//!   * A key picked in that list was installed on whatever route the session
//!     was on.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const App = cc.app_module.App;
const Slug = cc.provider_ids.Slug;

const SESSION_KEY = "fake-session-key-0001";
const RELAY_KEY = "fake-relay-key-0002";
const POOL_WORK_KEY = "fake-pool-work-0003";
const POOL_PERSONAL_KEY = "fake-pool-personal-0004";
const PROVIDER_DEFAULT_KEY = "fake-provider-default-0005";
const LOGIN_TOKEN = "fake-login-token-0006";
const OAUTH_ACCESS_1 = "fake-oauth-access-0007";
const OAUTH_ACCESS_2 = "fake-oauth-access-0008";
const METASK_ACCESS = "fake-metask-access-0009";
const KEY_PROD = "fake-key-prod-0010";
const KEY_DEV = "fake-key-dev-0011";

const ANTHROPIC_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5.3-flash\",\"display_name\":\"glm-5.3-flash\",\"max_tokens\":8192}]}";
const KEYS_BODY =
    "{\"code\":0,\"data\":{\"items\":[" ++
    "{\"id\":1,\"name\":\"Prod key\",\"key\":\"" ++ KEY_PROD ++ "\",\"status\":\"active\"}," ++
    "{\"id\":2,\"name\":\"Dev key\",\"key\":\"" ++ KEY_DEV ++ "\",\"status\":\"active\"}]}}";
const TOKEN_EXPIRED_BODY = "{\"error\":{\"code\":\"token_expired\",\"message\":\"expired\"}}";

/// Variables that would supply a credential, move the route, or send a
/// request somewhere the case did not set up.
const cleared_variables = [_][*:0]const u8{
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METASK_SITE_URL",
    "METACODES_PROVIDER",
    "METACODES_CONFIG_FILE",
    "METACODES_AUTH_FILE",
    "METACODES_OAUTH_DIR",
    "METACODE_API_KEYS_URL",
    "METACODES_NO_PROBE",
    "RELAY_TOKEN",
    "RELAY_A_TOKEN",
    "RELAY_B_TOKEN",
    "RELAY_A_KEY_WORK",
    "RELAY_A_KEY_PERSONAL",
};

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

/// A scratch state root as HOME holding the case's `config.json`; the
/// variables above cleared; no KG daemon. Everything is restored at the end.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [cleared_variables.len + 4]EnvGuard,
    guard_count: usize,

    fn init(self: *Case, config_json: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        for (cleared_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try self.arena.allocator().dupeZ(u8, self.root)).ptr);
        try self.setEnv("METACODES_KG_AUTOSTART", "0");
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = config_json });
    }

    /// A variable already guarded is set in place: its first guard holds the
    /// value to restore.
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

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    /// The config `main` hands `App.init` for `argv`.
    fn config(self: *Case, argv: []const [*:0]const u8) !cc.types_mod.Config {
        var parsed = cc.parseArgsForTest(argv, self.arena.allocator());
        try std.testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }

    /// `metacodes login`'s browser sign-in in `<state root>/auth.json`: the
    /// Metask account's OAuth token, which asks for the account's key list.
    fn storeMetaskLogin(self: *Case) !void {
        const a = std.testing.allocator;
        const path = try std.fs.path.join(a, &.{ self.root, "auth.json" });
        defer a.free(path);
        var creds = cc.core_auth.StoredCredentials{ .oauth = .{
            .access_token = try a.dupe(u8, LOGIN_TOKEN),
            .refresh_token = try a.dupe(u8, "fake-login-refresh"),
            .expires_at = cc.util_time.nowUnix() + 3600,
        } };
        defer creds.deinit(a);
        try cc.core_auth.saveToPath(a, path, creds);
    }

    /// A stored OAuth login for `provider`, as `login --provider` leaves it.
    fn storeOAuthLogin(self: *Case, provider: []const u8, outcome: cc.provider_oauth.RefreshOutcome, now: i64) !void {
        var session = try cc.provider_oauth.Session.initHome(std.testing.allocator, self.root, try Slug.parse(provider));
        defer session.deinit();
        try session.importOutcome(outcome, now);
    }
};

/// `http://127.0.0.1:<port>`, the origin `urlOwned` puts `/v1/messages` behind.
fn originOf(allocator: std.mem.Allocator, server: *harness.MockServer) ![]u8 {
    const url = try server.urlOwned(allocator);
    return url[0 .. url.len - "/v1/messages".len];
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

/// No request `server` received carries `secret` anywhere. A failure names
/// the request, never the secret.
fn expectNeverSent(server: *harness.MockServer, secret: []const u8) !void {
    for (0..server.requestCount()) |index| {
        const captured = server.requestAt(index) orelse continue;
        if (std.mem.indexOf(u8, captured.raw, secret) != null) {
            std.debug.print("a credential reached the wrong endpoint: {s}\n", .{requestLine(captured)});
            return error.CredentialCrossedProviders;
        }
    }
}

/// Whether `server`'s request `index` carries `secret` as its bearer.
fn sentBearer(server: *harness.MockServer, index: usize, secret: []const u8) bool {
    const captured = server.requestAt(index) orelse return false;
    const value = headerValue(captured, "authorization") orelse return false;
    return std.mem.startsWith(u8, value, "Bearer ") and std.mem.eql(u8, value["Bearer ".len..], secret);
}

/// Send one turn on whatever route the session is on now.
fn waitTaken(app: *cc.app_module.App, comptime taken: fn (*cc.app_module.App) bool) !void {
    var waited_ms: u32 = 0;
    while (!taken(app)) : (waited_ms += 5) {
        if (waited_ms > 20_000) return error.WaitTimedOut;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
}

fn loadApiKeyCatalog(app: *cc.app_module.App) !void {
    app.ensureApiKeyCatalog();
    try waitTaken(app, cc.app_module.App.takeApiKeyCatalog);
}

fn pickApiKey(app: *cc.app_module.App, index: usize) !void {
    try app.selectApiKeyForModels(index);
    try waitTaken(app, cc.app_module.App.takeModelsRefresh);
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

/// The rendered id of `provider`'s offer for `model` on the Messages wire,
/// bound to the account `credential` (or to none).
fn offerIdText(app: *App, provider: []const u8, model: []const u8, credential: ?[]const u8) ![cc.provider_ids.OFFER_ID_TEXT_LEN]u8 {
    const host = try app.providerHost();
    for (host.kernel.catalogSnapshot().items()) |offer| {
        if (!offer.provider_id.eqlText(provider)) continue;
        if (!std.mem.eql(u8, offer.request_model_id, model)) continue;
        if (!std.mem.eql(u8, offer.protocol, "anthropic_messages")) continue;
        if (credential) |wanted| {
            const bound = offer.credential_ref orelse continue;
            if (!bound.eqlText(wanted)) continue;
        } else if (offer.credential_ref != null) continue;
        return offer.offer_id.render();
    }
    return error.OfferMissing;
}

/// An API-key relay on the Messages wire, `"<id>": {...}` inside
/// `custom_providers`.
fn relayDefinition(allocator: std.mem.Allocator, id: []const u8, variable: []const u8, origin: []const u8, model: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\"{s}": {{"display_name": "{s}", "credential_kinds": ["api_key"],
        \\  "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}/{s}", "protocol": "anthropic_messages"}}],
        \\  "models": [{{"request_model_id": "{s}", "display_name": "{s}"}}]}}
    , .{ id, id, variable, origin, id, model, model });
}

/// A provider that signs in with OAuth only, its token endpoint at `token_url`.
fn oauthDefinition(allocator: std.mem.Allocator, origin: []const u8, token_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\"house-oauth": {{"display_name": "House OAuth", "credential_kinds": ["openai_oauth"],
        \\  "oauth": {{"token_url": "{s}", "client_id": "metacodes-test"}},
        \\  "channels": [{{"id": "primary", "base_url": "{s}/oauth", "protocol": "anthropic_messages"}}],
        \\  "models": [{{"request_model_id": "oauth-model", "display_name": "OAuth model"}}]}}
    , .{ token_url, origin });
}

const UNREACHABLE_ORIGIN = "http://127.0.0.1:9";

// ── the credential pool ──────────────────────────────────────────────────────

/// Two relays; relay-a has a pool of two accounts, relay-b none.
fn poolConfig(allocator: std.mem.Allocator, origin_a: []const u8, origin_b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"custom_providers": {{{s}, {s}}},
        \\ "providers": {{"relay-a": {{"credentials": [
        \\   {{"id": "work", "env": "RELAY_A_KEY_WORK", "kind": "api_key"}},
        \\   {{"id": "personal", "env": "RELAY_A_KEY_PERSONAL", "kind": "api_key"}}]}}}}}}
    , .{
        try relayDefinition(allocator, "relay-a", "RELAY_A_TOKEN", origin_a, "relay-a-model"),
        try relayDefinition(allocator, "relay-b", "RELAY_B_TOKEN", origin_b, "relay-b-model"),
    });
}

test "L2 credential scope: one provider's pool never authenticates another provider's route" {
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer gateway.stop();
    var relay_b = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer relay_b.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var case: Case = undefined;
    try case.init(try poolConfig(setup.allocator(), UNREACHABLE_ORIGIN, try originOf(setup.allocator(), relay_b)));
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    // relay-a's account has its key; relay-b has none of its own.
    try case.setEnv("RELAY_A_KEY_WORK", POOL_WORK_KEY);

    const gateway_url = try allocator.dupeZ(u8, try gateway.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", gateway_url.ptr, "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    // relay-b accepts a plain API key, the kind relay-a's member is.
    const outcome = cc.repl_picker_host.useSelector(app, "relay-b-model");
    try sendOneTurn(app);

    try expectNeverSent(relay_b, POOL_WORK_KEY);
    try std.testing.expectEqual(@as(usize, 0), relay_b.requestCount());
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqualStrings("MissingCredentials", outcome.failed);
    // The session is still on its own route, with its own key.
    try std.testing.expect(sentBearer(gateway, gateway.requestCount() - 1, SESSION_KEY));
}

test "L2 credential scope: the picker counts a provider ready on its own pool, never on another provider's" {
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var case: Case = undefined;
    try case.init(try poolConfig(setup.allocator(), UNREACHABLE_ORIGIN, UNREACHABLE_ORIGIN));
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    // relay-a's `work` account has its key; nothing else does.
    try case.setEnv("RELAY_A_KEY_WORK", POOL_WORK_KEY);

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", UNREACHABLE_ORIGIN ++ "/v1/messages", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    // What `/model` lists, and which of it a commit could bind now (#488).
    var listing = try app.listModelOffers();
    defer listing.deinit(std.testing.allocator);
    var work_ready = false;
    var relay_b_listed = false;
    for (listing.page.items, listing.ready.items) |summary, ready| {
        if (summary.provider_id.eqlText("relay-b")) {
            relay_b_listed = true;
            // relay-b has no key of its own, and relay-a's member is not one.
            try std.testing.expect(!ready);
        }
        if (!summary.provider_id.eqlText("relay-a")) continue;
        // A provider with a pool lists one route per account.
        const account = summary.credential_ref orelse continue;
        // The account whose variable is set, and only that one.
        try std.testing.expectEqual(account.eqlText("work"), ready);
        if (account.eqlText("work")) work_ready = ready;
    }
    try std.testing.expect(relay_b_listed);
    try std.testing.expect(work_ready);
}

test "L2 credential scope: a route that names an account uses that account or none" {
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer gateway.stop();
    var relay_a = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer relay_a.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var case: Case = undefined;
    try case.init(try poolConfig(setup.allocator(), try originOf(setup.allocator(), relay_a), UNREACHABLE_ORIGIN));
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    // `work`'s variable is unset. The other account and relay-a's own
    // variable both have a key.
    try case.setEnv("RELAY_A_KEY_PERSONAL", POOL_PERSONAL_KEY);
    try case.setEnv("RELAY_A_TOKEN", PROVIDER_DEFAULT_KEY);

    const gateway_url = try allocator.dupeZ(u8, try gateway.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", gateway_url.ptr, "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    const work = try offerIdText(app, "relay-a", "relay-a-model", "work");
    const refused = cc.repl_picker_host.useSelector(app, &work);
    try sendOneTurn(app);
    // Neither stands in for `work`: the route would bill an account it does
    // not name.
    try expectNeverSent(relay_a, POOL_PERSONAL_KEY);
    try expectNeverSent(relay_a, PROVIDER_DEFAULT_KEY);
    try std.testing.expect(refused == .failed);
    try std.testing.expectEqualStrings("MissingCredentials", refused.failed);
    try std.testing.expect(sentBearer(gateway, gateway.requestCount() - 1, SESSION_KEY));

    // The account whose key is there is used, for its own route.
    const personal = try offerIdText(app, "relay-a", "relay-a-model", "personal");
    try std.testing.expect(cc.repl_picker_host.useSelector(app, &personal) == .switched);
    try sendOneTurn(app);
    try std.testing.expectEqual(@as(usize, 1), relay_a.requestCount());
    try std.testing.expect(sentBearer(relay_a, 0, POOL_PERSONAL_KEY));
}

test "L2 credential scope: a provider's pool holds only that provider's members" {
    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const text = try std.fmt.allocPrint(setup.allocator(),
        \\{{"providers": {{
        \\  "relay-a": {{"credentials": [{{"id": "work", "env": "RELAY_A_KEY_WORK", "kind": "api_key"}}]}},
        \\  "relay-b": {{"credentials": [{{"id": "work", "env": "RELAY_A_KEY_PERSONAL", "kind": "api_key"}}]}}}}}}
    , .{});
    var case: Case = undefined;
    try case.init("{}");
    defer case.deinit();
    try case.setEnv("RELAY_A_KEY_WORK", POOL_WORK_KEY);
    try case.setEnv("RELAY_A_KEY_PERSONAL", POOL_PERSONAL_KEY);

    var document = try cc.provider_config_doc.parse(std.testing.allocator, text);
    defer document.deinit();
    var buffer: [cc.provider_config_doc.MAX_POOL_CREDENTIALS]cc.provider_credential.PoolEntry = undefined;
    // Both providers call their account `work`; each pool is its own.
    const pool = App.credentialPoolFrom(&document, Slug.lit("relay-b"), &buffer, cc.provider_credential.EnvLookup.empty());
    try std.testing.expectEqual(@as(usize, 1), pool.len);
    try std.testing.expect(pool[0].provider_id.eqlText("relay-b"));
    try std.testing.expectEqualStrings(POOL_PERSONAL_KEY, pool[0].secret);
    try std.testing.expectEqual(@as(usize, 0), App.credentialPoolFrom(&document, Slug.lit("deepseek"), &buffer, cc.provider_credential.EnvLookup.empty()).len);
}

// ── a switch that cannot bind ────────────────────────────────────────────────

test "L2 credential scope: a switch that cannot bind leaves the kernel and the OAuth session where the session is" {
    var gateway = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer gateway.stop();
    // The provider's token endpoint is down at the switch and back by the
    // next turn.
    const token_json = "{\"access_token\":\"" ++ OAUTH_ACCESS_2 ++ "\",\"refresh_token\":\"fake-oauth-refresh-2\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
    var token = try harness.MockServer.startHttpCassette(
        &.{ "{\"error\":\"temporarily_unavailable\"}", token_json },
        &.{ "HTTP/1.1 503 Service Unavailable", "HTTP/1.1 200 OK" },
    );
    defer token.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const token_url = try std.fmt.allocPrint(setup.allocator(), "{s}/token", .{try originOf(setup.allocator(), token)});
    const config_json = try std.fmt.allocPrint(setup.allocator(), "{{\"custom_providers\": {{{s}}}}}", .{try oauthDefinition(setup.allocator(), UNREACHABLE_ORIGIN, token_url)});
    var case: Case = undefined;
    try case.init(config_json);
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    // A login whose access token has expired: the switch has to refresh it.
    const now = cc.util_time.nowUnix();
    try case.storeOAuthLogin("house-oauth", .{
        .access_token = OAUTH_ACCESS_1,
        .refresh_token = "fake-oauth-refresh-1",
        .expires_in_seconds = 10,
    }, now - 3600);

    const gateway_url = try allocator.dupeZ(u8, try gateway.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", gateway_url.ptr, "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();
    const host = try app.providerHost();
    const before = host.kernel.currentOfferId();

    // The refresh fails, the provider has no other credential: refused.
    const outcome = cc.repl_picker_host.useSelector(app, "oauth-model");
    // The next turn boundary, the token endpoint answering again.
    const replaced = try app.refreshRouteCredential();
    try sendOneTurn(app);

    try expectNeverSent(gateway, OAUTH_ACCESS_2);
    try expectNeverSent(gateway, OAUTH_ACCESS_1);
    try std.testing.expect(outcome == .failed);
    try std.testing.expectEqualStrings("MissingCredentials", outcome.failed);
    try std.testing.expect(!replaced);
    // The refresh at the switch was the only exchange.
    try std.testing.expectEqual(@as(usize, 1), token.requestCount());
    try std.testing.expect(sentBearer(gateway, gateway.requestCount() - 1, SESSION_KEY));
    // The kernel names the route the session is on, and the process keeps
    // the OAuth session it had (none, on this route).
    const after = host.kernel.currentOfferId();
    try std.testing.expectEqual(before == null, after == null);
    if (before) |id| try std.testing.expect(id.eql(after.?));
    try std.testing.expect(app.oauth_session_provider == null);
    try std.testing.expect(app.oauth_session == null);
}

// ── the turn's token refresh ─────────────────────────────────────────────────

/// The state root of a session on the Metask device sign-in: a relay on the
/// Messages wire and an OAuth-only provider.
fn deviceSessionConfig(setup: std.mem.Allocator, relay_origin: []const u8) ![]u8 {
    return std.fmt.allocPrint(setup, "{{\"custom_providers\": {{{s}, {s}}}}}", .{
        try relayDefinition(setup, "relay", "RELAY_TOKEN", relay_origin, "relay-model"),
        try oauthDefinition(setup, UNREACHABLE_ORIGIN, UNREACHABLE_ORIGIN ++ "/token"),
    });
}

/// An App on the Metask device sign-in's route at `metask_origin`, in a case
/// initialised with `deviceSessionConfig`. Both providers have a live login.
fn deviceSessionApp(case: *Case, metask_origin: []const u8, io: std.Io) !*App {
    try case.setEnv("RELAY_TOKEN", RELAY_KEY);
    const now = cc.util_time.nowUnix();
    try case.storeOAuthLogin("metask", .{
        .access_token = METASK_ACCESS,
        .refresh_token = "fake-metask-refresh",
        .expires_in_seconds = 3600,
        .gateway_url = metask_origin,
    }, now);
    try case.storeOAuthLogin("house-oauth", .{
        .access_token = OAUTH_ACCESS_1,
        .refresh_token = "fake-oauth-refresh-1",
        .expires_in_seconds = 3600,
    }, now);

    const allocator = case.arena.allocator();
    const argv = [_][*:0]const u8{ "metacodes", "--provider", "metask" };
    var config = try case.config(&argv);
    // What `main` records for a device sign-in: the gateway's Messages
    // endpoint, the session's access token as the key.
    config.metask_oauth_selected = true;
    config.resolved_provider_id = "metask";
    config.base_url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{metask_origin});
    config.model = "glm-5.3-flash";
    config.model_explicit = true;
    return App.init(std.testing.allocator, io, config, METASK_ACCESS);
}

/// Commit `provider`'s offer for `model` on the Messages wire (bound to the
/// account `credential`, or to none) in `scope`, as the picker does after Tab
/// set the scope.
fn commitIn(app: *App, provider: []const u8, model: []const u8, credential: ?[]const u8, scope: cc.provider_selection.Scope) !void {
    const rendered = try offerIdText(app, provider, model, credential);
    const host = try app.providerHost();
    const offer = host.kernel.catalogSnapshot().find(try cc.provider_ids.OfferId.parse(&rendered)) orelse return error.OfferMissing;
    const outcome = try app.commitModelSelection(.{
        .offer_id = offer.offer_id,
        .offer_revision = offer.offer_revision,
        .controls = .{},
        .scope = scope,
    });
    if (outcome != .committed) return error.CommitRefused;
}

test "L2 credential scope: a pick for every future session takes the turn's token refresh along" {
    var metask = try harness.MockServer.startCassette(&.{GATEWAY_MODELS}, 0);
    defer metask.stop();
    var relay = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer relay.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var io_runtime = @import("platform").signal.threadedIo(setup.allocator(), .{});
    defer io_runtime.deinit();
    var case: Case = undefined;
    try case.init(try deviceSessionConfig(setup.allocator(), try originOf(setup.allocator(), relay)));
    defer case.deinit();
    const app = try deviceSessionApp(&case, try originOf(setup.allocator(), metask), io_runtime.io());
    defer app.deinit();

    // This session's pick: a Metask model, on the device sign-in.
    try commitIn(app, "metask", "glm-5.3-flash", null, .session);
    // Then the relay with Tab on "every future session". The clients move to
    // it; the kernel's session scope still holds the Metask pick, and a
    // narrower scope wins.
    try commitIn(app, "relay", "relay-model", null, .global);
    // The next turn: its token refresh, then the request.
    const replaced = try app.refreshRouteCredential();
    try sendOneTurn(app);

    try expectNeverSent(relay, METASK_ACCESS);
    try std.testing.expect(!replaced);
    try std.testing.expect(sentBearer(relay, relay.requestCount() - 1, RELAY_KEY));
}

test "L2 credential scope: a pick for one turn does not follow the session to its next route" {
    var relay = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer relay.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const config_json = try std.fmt.allocPrint(setup.allocator(), "{{\"custom_providers\": {{{s}, {s}}}}}", .{
        try relayDefinition(setup.allocator(), "relay", "RELAY_TOKEN", try originOf(setup.allocator(), relay), "relay-model"),
        try oauthDefinition(setup.allocator(), UNREACHABLE_ORIGIN, UNREACHABLE_ORIGIN ++ "/token"),
    });
    var case: Case = undefined;
    try case.init(config_json);
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    try case.setEnv("RELAY_TOKEN", RELAY_KEY);
    // A live login: binding it needs no request.
    try case.storeOAuthLogin("house-oauth", .{
        .access_token = OAUTH_ACCESS_1,
        .refresh_token = "fake-oauth-refresh-1",
        .expires_in_seconds = 3600,
    }, cc.util_time.nowUnix());

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", UNREACHABLE_ORIGIN ++ "/v1/messages", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    // The OAuth provider for "the next turn only", then the relay for the
    // session. Nothing expires the first, and it outranks the second.
    try commitIn(app, "house-oauth", "oauth-model", null, .once);
    try commitIn(app, "relay", "relay-model", null, .session);
    const replaced = try app.refreshRouteCredential();
    try sendOneTurn(app);

    try expectNeverSent(relay, OAUTH_ACCESS_1);
    try std.testing.expect(!replaced);
    try std.testing.expect(sentBearer(relay, relay.requestCount() - 1, RELAY_KEY));
}

test "L2 credential scope: the turn's token refresh keeps the account the route was bound to" {
    var house = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer house.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    // A provider that takes an API key or an OAuth sign-in, with a pool
    // account and a live login.
    const config_json = try std.fmt.allocPrint(setup.allocator(),
        \\{{"custom_providers": {{"house-oauth": {{"display_name": "House OAuth", "credential_kinds": ["api_key", "openai_oauth"],
        \\  "oauth": {{"token_url": "{s}/token", "client_id": "metacodes-test"}},
        \\  "channels": [{{"id": "primary", "base_url": "{s}/oauth", "protocol": "anthropic_messages"}}],
        \\  "models": [{{"request_model_id": "oauth-model", "display_name": "OAuth model"}}]}}}},
        \\ "providers": {{"house-oauth": {{"credentials": [{{"id": "work", "env": "HOUSE_KEY_WORK", "kind": "api_key"}}]}}}}}}
    , .{ UNREACHABLE_ORIGIN, try originOf(setup.allocator(), house) });
    var case: Case = undefined;
    try case.init(config_json);
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    try case.setEnv("HOUSE_KEY_WORK", POOL_WORK_KEY);
    try case.storeOAuthLogin("house-oauth", .{
        .access_token = OAUTH_ACCESS_1,
        .refresh_token = "fake-oauth-refresh-1",
        .expires_in_seconds = 3600,
    }, cc.util_time.nowUnix());

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", UNREACHABLE_ORIGIN ++ "/v1/messages", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    // The route names the `work` account: the bind uses its key.
    try commitIn(app, "house-oauth", "oauth-model", "work", .session);
    const replaced = try app.refreshRouteCredential();
    try sendOneTurn(app);

    try expectNeverSent(house, OAUTH_ACCESS_1);
    try std.testing.expect(!replaced);
    try std.testing.expect(sentBearer(house, house.requestCount() - 1, POOL_WORK_KEY));
}

test "L2 credential scope: a start on a provider's own sign-in renews it at the turn boundary" {
    var house = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer house.stop();
    const token_json = "{\"access_token\":\"" ++ OAUTH_ACCESS_2 ++ "\",\"refresh_token\":\"fake-oauth-refresh-2\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
    var token = try harness.MockServer.startCassette(&.{token_json}, 0);
    defer token.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const house_origin = try originOf(setup.allocator(), house);
    const token_url = try std.fmt.allocPrint(setup.allocator(), "{s}/token", .{try originOf(setup.allocator(), token)});
    const config_json = try std.fmt.allocPrint(setup.allocator(), "{{\"custom_providers\": {{{s}}}}}", .{try oauthDefinition(setup.allocator(), house_origin, token_url)});
    var case: Case = undefined;
    try case.init(config_json);
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    // The sign-in startup bound has expired by this turn.
    try case.storeOAuthLogin("house-oauth", .{
        .access_token = OAUTH_ACCESS_1,
        .refresh_token = "fake-oauth-refresh-1",
        .expires_in_seconds = 10,
    }, cc.util_time.nowUnix() - 3600);

    const argv = [_][*:0]const u8{ "metacodes", "--provider", "house-oauth" };
    var config = try case.config(&argv);
    // What a start that binds the provider's own sign-in records: its route,
    // the sign-in's access token as the key, `.sign_in` as where it came from.
    config.resolved_provider_id = "house-oauth";
    config.provider_kind = .anthropic;
    config.base_url = try std.fmt.allocPrint(allocator, "{s}/oauth/v1/messages", .{house_origin});
    config.model = "oauth-model";
    config.model_explicit = true;
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.initWithOptions(std.testing.allocator, io_runtime.io(), config, OAUTH_ACCESS_1, .{ .route_state = .{ .bound = .sign_in } });
    defer app.deinit();
    _ = try app.providerHost();

    // No pick yet: the route is the one the session started on, bound with
    // that provider's own token, which the turn boundary renews.
    const replaced = try app.refreshRouteCredential();
    try sendOneTurn(app);

    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(usize, 1), token.requestCount());
    try std.testing.expect(sentBearer(house, house.requestCount() - 1, OAUTH_ACCESS_2));
}

const OAUTH_ACCESS_3 = "fake-oauth-access-0012";

test "L2 credential scope: a pick bound with a provider's sign-in renews it at the turn boundary" {
    var house = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer house.stop();
    // The pick's refresh answers with a token inside the refresh margin, so
    // the next turn boundary renews it again.
    const short_lived = "{\"access_token\":\"" ++ OAUTH_ACCESS_2 ++ "\",\"refresh_token\":\"fake-oauth-refresh-2\",\"token_type\":\"Bearer\",\"expires_in\":60}";
    const renewed = "{\"access_token\":\"" ++ OAUTH_ACCESS_3 ++ "\",\"refresh_token\":\"fake-oauth-refresh-3\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
    var token = try harness.MockServer.startCassette(&.{ short_lived, renewed }, 0);
    defer token.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const token_url = try std.fmt.allocPrint(setup.allocator(), "{s}/token", .{try originOf(setup.allocator(), token)});
    const config_json = try std.fmt.allocPrint(setup.allocator(), "{{\"custom_providers\": {{{s}}}}}", .{try oauthDefinition(setup.allocator(), try originOf(setup.allocator(), house), token_url)});
    var case: Case = undefined;
    try case.init(config_json);
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");
    try case.storeOAuthLogin("house-oauth", .{
        .access_token = OAUTH_ACCESS_1,
        .refresh_token = "fake-oauth-refresh-1",
        .expires_in_seconds = 10,
    }, cc.util_time.nowUnix() - 3600);

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", UNREACHABLE_ORIGIN ++ "/v1/messages", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    try commitIn(app, "house-oauth", "oauth-model", null, .session);
    const replaced = try app.refreshRouteCredential();
    try sendOneTurn(app);

    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(usize, 2), token.requestCount());
    try std.testing.expect(sentBearer(house, house.requestCount() - 1, OAUTH_ACCESS_3));
}

// ── the Metask refresh callback ──────────────────────────────────────────────

test "L2 credential scope: another provider's expired-token answer is never retried with the Metask sign-in" {
    // The gateway answers the sign-in's model catalog at startup.
    var metask = try harness.MockServer.startCassette(&.{GATEWAY_MODELS}, 0);
    defer metask.stop();
    // The relay says its token expired, in the Metask gateway's own words.
    var relay = try harness.MockServer.startHttpCassette(
        &.{ TOKEN_EXPIRED_BODY, ANTHROPIC_END_TURN_SSE },
        &.{ "HTTP/1.1 401 Unauthorized", "HTTP/1.1 200 OK" },
    );
    defer relay.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var io_runtime = @import("platform").signal.threadedIo(setup.allocator(), .{});
    defer io_runtime.deinit();
    var case: Case = undefined;
    try case.init(try deviceSessionConfig(setup.allocator(), try originOf(setup.allocator(), relay)));
    defer case.deinit();
    const app = try deviceSessionApp(&case, try originOf(setup.allocator(), metask), io_runtime.io());
    defer app.deinit();
    try std.testing.expect(app.oauth_session_provider.?.eqlText("metask"));
    try std.testing.expect(app.api_client.refresh_fn != null);

    try std.testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    const turn = sendOneTurn(app);

    try expectNeverSent(relay, METASK_ACCESS);
    try std.testing.expectError(error.Unauthorized, turn);
    try std.testing.expectEqual(@as(usize, 1), relay.requestCount());
    try std.testing.expect(sentBearer(relay, 0, RELAY_KEY));

    // Back on the sign-in's route, its token refreshes as before.
    const metask_offer = try offerIdText(app, "metask", "glm-5.3-flash", null);
    try std.testing.expect(cc.repl_picker_host.useSelector(app, &metask_offer) == .switched);
    try std.testing.expect(app.api_client.refresh_fn != null);
}

test "L2 credential scope: the Metask refresh never answers with another provider's sign-in" {
    var metask = try harness.MockServer.startCassette(&.{GATEWAY_MODELS}, 0);
    defer metask.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var io_runtime = @import("platform").signal.threadedIo(setup.allocator(), .{});
    defer io_runtime.deinit();
    var case: Case = undefined;
    try case.init(try deviceSessionConfig(setup.allocator(), UNREACHABLE_ORIGIN));
    defer case.deinit();
    const app = try deviceSessionApp(&case, try originOf(setup.allocator(), metask), io_runtime.io());
    defer app.deinit();

    // The process's OAuth session becomes another provider's, as a route
    // switch to it does, while the Metask refresh is still installed.
    const host = try app.providerHost();
    const other = host.registry.findById(Slug.lit("house-oauth")).?;
    const token = (try app.oauthAccessToken(other, cc.util_time.nowUnix())).?;
    std.crypto.secureZero(u8, token);
    std.testing.allocator.free(token);
    try std.testing.expect(app.oauth_session_provider.?.eqlText("house-oauth"));

    const refresh = app.api_client.refresh_fn.?;
    try std.testing.expectError(error.NoTokens, refresh(app.api_client.refresh_ctx.?, METASK_ACCESS));
}

test "L2 credential scope: another provider's refresh token never reaches Metask's token endpoint" {
    var metask = try harness.MockServer.startCassette(&.{GATEWAY_MODELS}, 0);
    defer metask.stop();
    // Metask's site, whose token endpoint the Metask refresh posts to.
    const metask_token = "{\"access_token\":\"fake-metask-access-renewed\",\"refresh_token\":\"fake-metask-refresh-2\",\"token_type\":\"Bearer\",\"expires_in\":3600}";
    var site = try harness.MockServer.startCassette(&.{metask_token}, 0);
    defer site.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var io_runtime = @import("platform").signal.threadedIo(setup.allocator(), .{});
    defer io_runtime.deinit();
    var case: Case = undefined;
    try case.init(try deviceSessionConfig(setup.allocator(), UNREACHABLE_ORIGIN));
    defer case.deinit();
    try case.setEnv("METASK_SITE_URL", (try setup.allocator().dupeZ(u8, try originOf(setup.allocator(), site))).ptr);
    const app = try deviceSessionApp(&case, try originOf(setup.allocator(), metask), io_runtime.io());
    defer app.deinit();

    // The process's OAuth session becomes another provider's, as a route
    // switch to it does, and that provider's own access token is the one a
    // request on its route carried when it came back 401 `token_expired`.
    const host = try app.providerHost();
    const other = host.registry.findById(Slug.lit("house-oauth")).?;
    const token = (try app.oauthAccessToken(other, cc.util_time.nowUnix())).?;
    std.crypto.secureZero(u8, token);
    std.testing.allocator.free(token);

    // Still installed: nothing rebound the clients.
    const refresh = app.api_client.refresh_fn orelse return error.NoRefreshCallback;
    if (refresh(app.api_client.refresh_ctx.?, OAUTH_ACCESS_1)) |answered| {
        std.crypto.secureZero(u8, answered);
        std.testing.allocator.free(answered);
    } else |_| {}
    try expectNeverSent(site, "fake-oauth-refresh-1");
    try std.testing.expectEqual(@as(usize, 0), site.requestCount());
}

// ── a refresh that finishes after the route moved ───────────────────────────

/// A refresh callback that moves the client's route before answering, as a
/// `/model` commit from the reply's key thread does mid-refresh.
fn RouteMover(comptime ClientT: type) type {
    return struct {
        client: *ClientT,
        to: []const u8,
        move: bool,

        fn refresh(ctx: *anyopaque, stale: []const u8) anyerror![]u8 {
            _ = stale;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.move) self.client.base_url = self.to;
            return std.testing.allocator.dupe(u8, "fake-refreshed-token");
        }
    };
}

test "L2 credential scope: a token refreshed while the route moved is not sent on the new route" {
    var first = try harness.MockServer.startHttpCassette(
        &.{ TOKEN_EXPIRED_BODY, ANTHROPIC_END_TURN_SSE },
        &.{ "HTTP/1.1 401 Unauthorized", "HTTP/1.1 200 OK" },
    );
    defer first.stop();
    var moved = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer moved.stop();
    const a = std.testing.allocator;
    const first_url = try first.urlOwned(a);
    defer a.free(first_url);
    const moved_url = try moved.urlOwned(a);
    defer a.free(moved_url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), SESSION_KEY, "claude-sonnet-4-6", first_url);
    defer client.deinit();
    var mover = RouteMover(cc.client_mod.Client){ .client = &client, .to = moved_url, .move = true };
    client.setRefreshCallback(@ptrCast(&mover), RouteMover(cc.client_mod.Client).refresh);

    const empty: []const cc.types_mod.ApiMessage = &.{};
    if (client.sendMessageStream(empty, null, null)) |sent| {
        var response = sent;
        response.deinit();
        try expectNeverSent(moved, "fake-refreshed-token");
        return error.ReplayedOnTheNewRoute;
    } else |err| try std.testing.expectEqual(error.Unauthorized, err);
    try expectNeverSent(moved, "fake-refreshed-token");
    try std.testing.expectEqual(@as(usize, 0), moved.requestCount());
    try std.testing.expectEqualStrings(SESSION_KEY, client.credential.lendable().?);

    // Where the route stayed, the refreshed token is replayed as before.
    var again = try harness.MockServer.startHttpCassette(
        &.{ TOKEN_EXPIRED_BODY, ANTHROPIC_END_TURN_SSE },
        &.{ "HTTP/1.1 401 Unauthorized", "HTTP/1.1 200 OK" },
    );
    defer again.stop();
    const again_url = try again.urlOwned(a);
    defer a.free(again_url);
    client.base_url = again_url;
    mover.move = false;
    var response = try client.sendMessageStream(empty, null, null);
    while (true) {
        const maybe = response.next() catch break;
        const event = maybe orelse break;
        switch (event) {
            .text => |text| a.free(text),
            else => {},
        }
        if (response.done) break;
    }
    response.deinit();
    try std.testing.expect(sentBearer(again, 1, "fake-refreshed-token"));
}

test "L2 credential scope: an OpenAI-wire token refreshed while the route moved is not sent on the new route" {
    const OPENAI_SSE =
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
        "data: [DONE]\n\n";
    var first = try harness.MockServer.startHttpCassette(
        &.{ TOKEN_EXPIRED_BODY, OPENAI_SSE },
        &.{ "HTTP/1.1 401 Unauthorized", "HTTP/1.1 200 OK" },
    );
    defer first.stop();
    var moved = try harness.MockServer.startCassette(&.{OPENAI_SSE}, 0);
    defer moved.stop();
    var urls = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer urls.deinit();
    const first_url = try std.fmt.allocPrint(urls.allocator(), "{s}/v1/chat/completions", .{try originOf(urls.allocator(), first)});
    const moved_url = try std.fmt.allocPrint(urls.allocator(), "{s}/v1/chat/completions", .{try originOf(urls.allocator(), moved)});
    const a = std.testing.allocator;

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_runtime.io(), SESSION_KEY, "relay-model", first_url);
    defer client.deinit();
    var mover = RouteMover(cc.api_openai.OpenAIClient){ .client = &client, .to = moved_url, .move = true };
    client.setRefreshCallback(@ptrCast(&mover), RouteMover(cc.api_openai.OpenAIClient).refresh);

    const messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    if (client.provider().sendStream(&messages, null, null, null, null, null, "")) |sent| {
        var handle = sent;
        handle.deinit();
        try expectNeverSent(moved, "fake-refreshed-token");
        return error.ReplayedOnTheNewRoute;
    } else |err| try std.testing.expectEqual(error.Unauthorized, err);
    try expectNeverSent(moved, "fake-refreshed-token");
    try std.testing.expectEqual(@as(usize, 0), moved.requestCount());
    try std.testing.expectEqualStrings(SESSION_KEY, client.credential.lendable().?);
}

// ── the Metask account's key list ────────────────────────────────────────────

/// A Metask API-key route at `gateway`, a relay on the Messages wire with a
/// key, and the browser sign-in in `auth.json`.
fn keyListCase(case: *Case, setup: std.mem.Allocator, relay_origin: []const u8) !void {
    const config_json = try std.fmt.allocPrint(setup, "{{\"custom_providers\": {{{s}}}}}", .{try relayDefinition(setup, "relay", "RELAY_TOKEN", relay_origin, "relay-model")});
    try case.init(config_json);
    try case.setEnv("RELAY_TOKEN", RELAY_KEY);
    try case.storeMetaskLogin();
}

test "L2 credential scope: the account's key list is asked for only on the Metask route" {
    // The startup `/v1/models` probe, then the key list the menu loads once
    // the session is back on the Metask route.
    var gateway = try harness.MockServer.startCassette(&.{ GATEWAY_MODELS, KEYS_BODY }, 0);
    defer gateway.stop();
    var relay = try harness.MockServer.startCassette(&.{KEYS_BODY}, 0);
    defer relay.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var case: Case = undefined;
    try keyListCase(&case, setup.allocator(), try originOf(setup.allocator(), relay));
    defer case.deinit();
    const allocator = case.arena.allocator();

    const gateway_url = try allocator.dupeZ(u8, try gateway.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", gateway_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();
    try std.testing.expect(app.onMetaskKeyRoute());

    // `/model` typed on another provider's route, before the menu ever
    // loaded the list (Ctrl+O first, then `/model`).
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    try std.testing.expect(!app.onMetaskKeyRoute());
    app.ensureApiKeyCatalog();
    try expectNeverSent(relay, LOGIN_TOKEN);
    try std.testing.expectEqual(@as(usize, 0), relay.requestCount());
    try std.testing.expectEqual(@as(usize, 0), app.api_key_catalog.entries.items.len);

    // Back on the Metask gateway, the menu loads it from there.
    const metask_offer = try offerIdText(app, "metask", "glm-5.3-flash", null);
    try std.testing.expect(cc.repl_picker_host.useSelector(app, &metask_offer) == .switched);
    try std.testing.expect(app.onMetaskKeyRoute());
    try loadApiKeyCatalog(app);
    try std.testing.expectEqual(@as(usize, 2), gateway.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, requestLine(gateway.requestAt(1).?), "GET /api/v1/keys?"));
    try std.testing.expect(sentBearer(gateway, 1, LOGIN_TOKEN));
    try std.testing.expectEqual(@as(usize, 2), app.api_key_catalog.entries.items.len);

    // Leaving the route drops the list; it is the Metask account's.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    try std.testing.expectEqual(@as(usize, 0), app.api_key_catalog.entries.items.len);
    app.ensureApiKeyCatalog();
    try std.testing.expectEqual(@as(usize, 0), relay.requestCount());
}

test "L2 credential scope: a session started on another provider never asks for the key list" {
    var relay = try harness.MockServer.startCassette(&.{ GATEWAY_MODELS, KEYS_BODY }, 0);
    defer relay.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    const relay_origin = try originOf(setup.allocator(), relay);
    var case: Case = undefined;
    try keyListCase(&case, setup.allocator(), relay_origin);
    defer case.deinit();
    const allocator = case.arena.allocator();

    const argv = [_][*:0]const u8{ "metacodes", "--provider", "relay" };
    var config = try case.config(&argv);
    // What `main`'s startup route resolution records for `--provider relay`.
    config.resolved_provider_id = "relay";
    config.provider_kind = .anthropic;
    config.base_url = try std.fmt.allocPrint(allocator, "{s}/relay/v1/messages", .{relay_origin});
    config.model = "relay-model";
    config.model_explicit = true;
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, RELAY_KEY);
    defer app.deinit();

    // `/model` typed in the input box.
    app.ensureApiKeyCatalog();
    try expectNeverSent(relay, LOGIN_TOKEN);
    // Only the startup `/v1/models` probe, with the relay's own key.
    try std.testing.expectEqual(@as(usize, 1), relay.requestCount());
    try std.testing.expect(sentBearer(relay, 0, RELAY_KEY));
}

// ── a Metask offer at another Metask gateway ────────────────────────────────

test "L2 credential scope: the key list follows the session onto another Metask gateway" {
    // The key route's own gateway answers the startup probe.
    var gateway = try harness.MockServer.startCassette(&.{GATEWAY_MODELS}, 0);
    defer gateway.stop();
    // Another Metask gateway: the key list, then a pick's `/v1/models`.
    var other = try harness.MockServer.startCassette(&.{ KEYS_BODY, GATEWAY_MODELS }, 0);
    defer other.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var case: Case = undefined;
    try keyListCase(&case, setup.allocator(), UNREACHABLE_ORIGIN);
    defer case.deinit();
    const allocator = case.arena.allocator();

    const gateway_url = try allocator.dupeZ(u8, try gateway.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", gateway_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    // Metask's offers at another gateway, as the compiled ones point at the
    // default gateway rather than a `--base-url` one; the session picks one.
    const host = try app.providerHost();
    try host.ingestMetask(try originOf(allocator, other), GATEWAY_MODELS, .messages);
    try commitIn(app, "metask", "glm-5.3-flash", null, .session);

    // Still a Metask gateway, with a Metask key: the list and a pick work.
    try std.testing.expect(app.onMetaskKeyRoute());
    try loadApiKeyCatalog(app);
    try std.testing.expect(std.mem.startsWith(u8, requestLine(other.requestAt(0) orelse return error.NoKeyList), "GET /api/v1/keys?"));
    try std.testing.expect(sentBearer(other, 0, LOGIN_TOKEN));
    var prod: ?usize = null;
    for (app.api_key_catalog.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.secret, KEY_PROD)) prod = index;
    }
    try pickApiKey(app, prod orelse return error.NoProdKey);
    try std.testing.expect(sentBearer(other, 1, KEY_PROD));
}

test "L2 credential scope: a key picked in /models stays on the Metask route" {
    // Startup probe, key list, then each pick's `/v1/models`: dev, prod, dev.
    var gateway = try harness.MockServer.startCassette(&.{ GATEWAY_MODELS, KEYS_BODY, GATEWAY_MODELS, GATEWAY_MODELS, GATEWAY_MODELS }, 0);
    defer gateway.stop();
    var relay = try harness.MockServer.startCassette(&.{ANTHROPIC_END_TURN_SSE}, 0);
    defer relay.stop();

    var setup = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer setup.deinit();
    var case: Case = undefined;
    try keyListCase(&case, setup.allocator(), try originOf(setup.allocator(), relay));
    defer case.deinit();
    const allocator = case.arena.allocator();

    const gateway_url = try allocator.dupeZ(u8, try gateway.urlOwned(allocator));
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", gateway_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    // The testing allocator checks that every key a pick replaced is freed.
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    try loadApiKeyCatalog(app);
    var prod: ?usize = null;
    var dev: ?usize = null;
    for (app.api_key_catalog.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.secret, KEY_PROD)) prod = index;
        if (std.mem.eql(u8, entry.secret, KEY_DEV)) dev = index;
    }
    try pickApiKey(app, dev.?);
    try std.testing.expect(sentBearer(gateway, 2, KEY_DEV));
    try pickApiKey(app, prod.?);
    try std.testing.expect(sentBearer(gateway, 3, KEY_PROD));
    // The key it replaced is retired, not freed: a client may still be
    // reading it.
    const retired = app.retired_api_key orelse return error.PreviousKeyNotRetired;
    try std.testing.expectEqualStrings(KEY_DEV, retired);
    // A third pick retires prod and frees dev, retired two picks ago.
    try pickApiKey(app, dev.?);
    try std.testing.expect(sentBearer(gateway, 4, KEY_DEV));
    try std.testing.expectEqualStrings(KEY_PROD, app.retired_api_key orelse return error.PreviousKeyNotRetired);

    try std.testing.expect(cc.repl_picker_host.useSelector(app, "relay-model") == .switched);
    // A list left from the Metask route, picked from on the relay's.
    try app.api_key_catalog.addCurrentKeyFallback(KEY_DEV);
    try std.testing.expectError(error.NotOnMetaskKeyRoute, app.selectApiKeyForModels(0));
    try sendOneTurn(app);

    try expectNeverSent(relay, KEY_DEV);
    try expectNeverSent(relay, KEY_PROD);
    try std.testing.expectEqual(@as(usize, 1), relay.requestCount());
    try std.testing.expect(sentBearer(relay, 0, RELAY_KEY));
}
