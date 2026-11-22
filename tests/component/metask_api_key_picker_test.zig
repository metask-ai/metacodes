//! L2 evidence: on the historical Metask API-key route (no `--provider`, no
//! Metask session login) the `/model` picker offers what the session's own
//! gateway answers on `/v1/models`, at the endpoint the session talks to, marks
//! the model it runs, and a pick is sent with the session's key.
//!
//! Before: the picker listed the compiled Claude inventory at the default
//! gateway whatever `--base-url` said, marked nothing, a gateway model fell
//! through to the name-only path, and a stored login key could not
//! authenticate any pick (`MissingCredentials`, then a sign-in prompt).
//!
//! Mock transport only: the gateway is a MockServer cassette answering, in
//! order, the startup `/v1/models` probe and what the case sends next. The
//! account key list is fetched only when a case opens the `/models` key menu
//! (`ensureApiKeyCatalog`), as the REPL does.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const ppaths = @import("platform").paths;

const picker_mod = cc.repl_model_picker;
const App = cc.app_module.App;

const SESSION_KEY = "stored-session-key";
const KEY_PROD = "KEY_PROD_1234";
const KEY_DEV = "KEY_DEV_5678";

const KEYS_BODY =
    "{\"code\":0,\"data\":{\"items\":[" ++
    "{\"id\":1,\"name\":\"Prod key\",\"key\":\"" ++ KEY_PROD ++ "\",\"status\":\"active\"}," ++
    "{\"id\":2,\"name\":\"Dev key\",\"key\":\"" ++ KEY_DEV ++ "\",\"status\":\"active\"}]}}";
const GATEWAY_MODELS =
    "{\"object\":\"list\",\"data\":[" ++
    "{\"id\":\"glm-5.3-flash\",\"display_name\":\"glm-5.3-flash\",\"max_input_tokens\":1048576,\"max_tokens\":131072," ++
    "\"capabilities\":{\"thinking\":{\"supported\":true},\"image_input\":{\"supported\":true}}}," ++
    "{\"id\":\"kimi-k3\",\"display_name\":\"Kimi K3\",\"max_input_tokens\":262144,\"max_tokens\":32768}" ++
    "]}";
const DEV_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"dev-model\",\"max_tokens\":8192}]}";
const END_TURN_SSE =
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

/// Variables that would move the session off the stored-key API-key route,
/// stop the startup probe, or send the key-list probe elsewhere.
const route_variables = [_][*:0]const u8{
    "METACODES_NO_PROBE",
    "METASK_API_KEY",
    "METASK_GATEWAY_URL",
    "METACODES_PROVIDER",
    "METACODE_API_KEYS_URL",
};

/// A scratch state root as HOME, the route variables cleared, everything
/// restored at the end.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [route_variables.len + 1]EnvGuard,
    guard_count: usize,

    fn init(self: *Case) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.guard_count = 0;
        self.root = self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)];
        for (route_variables) |name| try self.setEnv(name, null);
        try self.setEnv("HOME", (try self.arena.allocator().dupeZ(u8, self.root)).ptr);
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

    fn deinit(self: *Case) void {
        var index = self.guard_count;
        while (index > 0) {
            index -= 1;
            self.guards[index].restore();
        }
        self.tmp.cleanup();
        self.arena.deinit();
    }

    /// The config `main` hands `App.init` on the historical path: no provider
    /// named, no `--api-key`, no Metask session login.
    fn config(self: *Case, argv: []const [*:0]const u8) !cc.types_mod.Config {
        var parsed = cc.parseArgsForTest(argv, self.arena.allocator());
        try std.testing.expect(parsed.parse_error == null);
        parsed.state_root = self.root;
        return parsed;
    }
};

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

/// The Metask offers a freshly refreshed picker snapshot holds, by wire model id.
fn metaskOffers(app: *App, buffer: [][]const u8) ![][]const u8 {
    try app.refreshModelPicker();
    return snapshotMetaskOffers(app, buffer);
}

/// The Metask offers the picker snapshot holds right now, without refreshing it.
fn snapshotMetaskOffers(app: *App, buffer: [][]const u8) [][]const u8 {
    var len: usize = 0;
    for (app.model_picker.offers.items) |offer| {
        if (!offer.provider_id.eqlText("metask")) continue;
        buffer[len] = offer.request_model_id;
        len += 1;
    }
    return buffer[0..len];
}

fn containsModel(models: []const []const u8, wanted: []const u8) bool {
    for (models) |model| if (std.mem.eql(u8, model, wanted)) return true;
    return false;
}

/// The wire model id of the offer the picker marks current, if any.
fn currentModel(app: *App) ?[]const u8 {
    const current = app.model_picker.current_offer orelse return null;
    for (app.model_picker.offers.items) |offer| {
        if (offer.offer_id.eql(current)) return offer.request_model_id;
    }
    return null;
}

/// Send one turn on whatever route the session is on and return what reached
/// the gateway.
fn waitUntil(app: *App, comptime done: fn (*App) bool) !void {
    var waited_ms: u32 = 0;
    while (!done(app)) : (waited_ms += 5) {
        if (waited_ms > 20_000) return error.WaitTimedOut;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
}

fn sendOneTurn(app: *App, server: *harness.MockServer) !harness.CapturedRequest {
    const empty: []const cc.types_mod.ApiMessage = &.{};
    var response = try app.api_client.sendMessageStream(empty, null, null);
    while (true) {
        const maybe = response.next() catch break;
        const event = maybe orelse break;
        switch (event) {
            .text => |text| app.api_client.allocator.free(text),
            else => {},
        }
        if (response.done) break;
    }
    response.deinit();
    return server.lastRequest() orelse error.NoRequestCaptured;
}

test "L2 metask api-key route: the picker offers the gateway's models at the session's endpoint and marks the one in use" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    const bodies = [_][]const u8{ GATEWAY_MODELS, END_TURN_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    try std.testing.expect(config.provider_profile == null and config.api_key == null and !config.metask_oauth_selected);

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    // Leak-checked: the route record, the kept document, and every ingest
    // arena belong to the App and its host.
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    // Exactly the gateway's models, none of the compiled Claude inventory.
    var buffer: [64][]const u8 = undefined;
    const models = try metaskOffers(app, &buffer);
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expect(containsModel(models, "glm-5.3-flash"));
    try std.testing.expect(containsModel(models, "kimi-k3"));
    for (app.model_picker.offers.items) |offer| {
        if (!offer.provider_id.eqlText("metask")) continue;
        // The endpoint the session already talks to, on its one wire.
        try std.testing.expectEqualStrings(messages_url, offer.endpoint_ref);
        try std.testing.expectEqualStrings("anthropic_messages", offer.protocol);
    }
    // The model the session runs is the marked one.
    try std.testing.expectEqualStrings("glm-5.3-flash", currentModel(app).?);

    // Drive the picker the way the keyboard does: type the model, Enter.
    const picker = &app.model_picker;
    for ("kimi") |byte| _ = picker.onKey(.{ .char = byte });
    try std.testing.expectEqual(picker_mod.Stage.list, picker.stage);
    const outcome = picker.onKey(.enter);
    // One wire per model: Enter on the model commits it.
    try std.testing.expect(outcome == .commit);
    const committed = try app.commitModelSelection(outcome.commit);
    try std.testing.expect(committed == .committed);
    try std.testing.expectEqualStrings("kimi-k3", app.activeModel());

    const captured = try sendOneTurn(app, server);
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /v1/messages "));
    // The stored login key, which no environment variable or flag carries.
    try std.testing.expectEqualStrings("Bearer " ++ SESSION_KEY, headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("\"kimi-k3\"", captured.jsonField("model").?);

    // `/model use` resolves the same catalog. Z.AI lists glm-5.3-flash too
    // (four channels); the name means the provider the session is on.
    try std.testing.expect(cc.repl_picker_host.useSelector(app, "glm-5.3-flash") == .switched);
    try std.testing.expectEqualStrings("glm-5.3-flash", app.activeModel());
    // A name only another provider serves, on several channels, is still a
    // question rather than a guess.
    const elsewhere = cc.repl_picker_host.useSelector(app, "glm-5.3");
    try std.testing.expect(elsewhere == .ambiguous);
    try std.testing.expectEqual(@as(usize, 4), elsewhere.ambiguous.total);
}

test "L2 metask api-key route: every page of a paginated /v1/models becomes the inventory" {
    // The gateway's list is Anthropic-shaped (`has_more` + `last_id`); a
    // reader that kept only the first page dropped every model after it.
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    const page_one =
        "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5.3-flash\",\"max_tokens\":131072},{\"id\":\"kimi-k3\"}]," ++
        "\"first_id\":\"glm-5.3-flash\",\"last_id\":\"kimi-k3\",\"has_more\":true}";
    const page_two = "{\"object\":\"list\",\"data\":[{\"id\":\"deepseek-v4\"}],\"last_id\":\"deepseek-v4\",\"has_more\":false}";
    const bodies = [_][]const u8{ page_one, page_two };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    try std.testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(server.requestAt(0).?));
    try std.testing.expectEqualStrings("GET /v1/models?after_id=kimi-k3&limit=1000 HTTP/1.1", requestLine(server.requestAt(1).?));
    try std.testing.expectEqualStrings("Bearer " ++ SESSION_KEY, headerValue(server.requestAt(1).?, "authorization").?);

    var buffer: [64][]const u8 = undefined;
    const models = try metaskOffers(app, &buffer);
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expect(containsModel(models, "glm-5.3-flash"));
    try std.testing.expect(containsModel(models, "kimi-k3"));
    try std.testing.expect(containsModel(models, "deepseek-v4"));
    // The client catalog (limits, `/models`) holds the second page too.
    try std.testing.expectEqual(@as(usize, 3), app.api_client.catalog.entries.items.len);
}

test "L2 metask api-key route: a /models key switch replaces the inventory and its key authenticates the pick" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    // The session started on the ambient key; the user then picks another one
    // in `/models`. The picked key must win over the environment.
    try case.setEnv("METASK_API_KEY", "ambient-env-key");

    const bodies = [_][]const u8{ GATEWAY_MODELS, KEYS_BODY, DEV_MODELS, END_TURN_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));
    // A plain API key reaches the account key list only where that endpoint
    // is named (`api_keys.bearerFor`).
    const origin = cc.app_module.MetaskKeyRoute.gatewayOriginOf(messages_url).?;
    const keys_url = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}/api/v1/keys?page=1&page_size=100", .{origin}));
    try case.setEnv("METACODE_API_KEYS_URL", keys_url.ptr);

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, "ambient-env-key");
    defer app.deinit();

    var buffer: [64][]const u8 = undefined;
    try std.testing.expect(containsModel(try metaskOffers(app, &buffer), "kimi-k3"));

    // Opening the `/models` key menu loads the account's keys, off the input thread.
    app.ensureApiKeyCatalog();
    try std.testing.expect(app.apiKeyCatalogLoading());
    try waitUntil(app, App.takeApiKeyCatalog);
    var dev_index: ?usize = null;
    for (app.api_key_catalog.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.secret, KEY_DEV)) dev_index = index;
    }
    // The host already exists, so the re-probe has to reach it directly.
    try app.selectApiKeyForModels(dev_index.?);
    try waitUntil(app, App.takeModelsRefresh);
    try std.testing.expect(std.mem.startsWith(u8, requestLine(server.requestAt(1).?), "GET /api/v1/keys?"));
    try std.testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(server.requestAt(2).?));
    try std.testing.expectEqualStrings("Bearer " ++ KEY_DEV, headerValue(server.requestAt(2).?, "authorization").?);

    // A picker left open sees the new list without being reopened.
    const models = snapshotMetaskOffers(app, &buffer);
    try std.testing.expectEqual(@as(usize, 1), models.len);
    try std.testing.expectEqualStrings("dev-model", models[0]);

    try std.testing.expect(cc.repl_picker_host.useSelector(app, "dev-model") == .switched);
    const captured = try sendOneTurn(app, server);
    try std.testing.expectEqualStrings("Bearer " ++ KEY_DEV, headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("\"dev-model\"", captured.jsonField("model").?);
}

test "L2 metask api-key route: another provider's /v1/models never becomes Metask's inventory" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    const bodies = [_][]const u8{GATEWAY_MODELS};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-4.6" };
    var config = try case.config(&argv);
    // A named non-Metask provider on the Messages wire probes the same way.
    config.provider_profile = "zai-coding-plan";
    config.resolved_provider_id = "zai-coding-plan";
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(allocator, io_runtime.io(), config, "zai-key");
    defer app.deinit();
    try std.testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(server.requestAt(0).?));

    try std.testing.expect(app.metask_key_route == null);
    var buffer: [64][]const u8 = undefined;
    const models = try metaskOffers(app, &buffer);
    try std.testing.expect(containsModel(models, "claude-sonnet-4-6"));
    try std.testing.expect(!containsModel(models, "glm-5.3-flash"));
    try std.testing.expect(!containsModel(models, "kimi-k3"));
}

test "L2 metask api-key route: a warm start offers the cached gateway models, and the background refresh replaces them" {
    // The interactive REPL answers `/v1/models` from the stored copy and
    // refreshes it on a background thread. Both answers are the route's
    // inventory: a picker fed only by the network probe showed the compiled
    // Claude list on every warm start.
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    // Only the background refresh reaches the gateway.
    const bodies = [_][]const u8{DEV_MODELS};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));
    const key = cc.models_cache.Key.of(messages_url, .{ .name = "authorization", .value = "Bearer " ++ SESSION_KEY });
    try cc.models_cache.store(allocator, case.root, key, messages_url, GATEWAY_MODELS, cc.util_time.nowUnix());

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.initWithOptions(std.testing.allocator, io_runtime.io(), config, SESSION_KEY, .{ .models_cache = true });
    defer app.deinit();

    // The stored copy is the inventory before any request has returned.
    var buffer: [64][]const u8 = undefined;
    const warm = try metaskOffers(app, &buffer);
    try std.testing.expectEqual(@as(usize, 2), warm.len);
    try std.testing.expect(containsModel(warm, "kimi-k3"));
    try std.testing.expectEqualStrings("glm-5.3-flash", currentModel(app).?);

    const refresh = app.models_refresh orelse return error.NoRefresh;
    var waited_ms: u32 = 0;
    while (!refresh.finished()) : (waited_ms += 5) {
        if (waited_ms > 10_000) return error.RefreshTimeout;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(server.requestAt(0).?));

    // Adopted at the REPL's idle point, it reaches a picker left open.
    app.adoptModelCatalogRefresh();
    const refreshed = snapshotMetaskOffers(app, &buffer);
    try std.testing.expectEqual(@as(usize, 1), refreshed.len);
    try std.testing.expectEqualStrings("dev-model", refreshed[0]);
}

test "L2 metask api-key route: with no gateway answer the compiled inventory stays and the running model is marked" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");

    const argv = [_][*:0]const u8{ "metacodes", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    try std.testing.expect(app.metask_key_route != null);
    try std.testing.expect(app.metask_key_route.?.models_json == null);
    var buffer: [64][]const u8 = undefined;
    const models = try metaskOffers(app, &buffer);
    try std.testing.expectEqual(@as(usize, 6), models.len);
    try std.testing.expect(containsModel(models, "claude-opus-4-6"));
    // The default gateway's compiled offer is the route this session runs.
    try std.testing.expectEqualStrings("claude-sonnet-4-6", currentModel(app).?);
}

test "L2 metask api-key route: a --base-url session with no gateway answer marks no compiled offer" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();
    try case.setEnv("METACODES_NO_PROBE", "1");

    // The compiled offers point at the default gateway; this session talks to
    // another one, so none of them is the route it runs.
    const argv = [_][*:0]const u8{ "metacodes", "--base-url", "http://127.0.0.1:9/v1/messages", "--model", "claude-sonnet-4-6" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    var buffer: [64][]const u8 = undefined;
    try std.testing.expect(containsModel(try metaskOffers(app, &buffer), "claude-sonnet-4-6"));
    try std.testing.expect(currentModel(app) == null);
}

test "L2 metask api-key route: a cold start waits for a /v1/models that never answers only for the startup wait" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    const bodies = [_][]const u8{GATEWAY_MODELS};
    var server = try harness.MockServer.startCassetteSilentFrom(&bodies, 0);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const started = cc.util_time.nowMs();
    const app = try App.initWithOptions(std.testing.allocator, io_runtime.io(), config, SESSION_KEY, .{ .models_cache = true });
    defer app.deinit();
    const waited = cc.util_time.nowMs() - started;

    try std.testing.expect(waited >= cc.models_cache.STARTUP_WAIT_MS - 100);
    try std.testing.expect(waited < cc.models_cache.STARTUP_WAIT_MS + 3_000);
    try std.testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(server.requestAt(0).?));
    try std.testing.expect(app.modelsRefreshRunning());
    try std.testing.expectEqual(@as(usize, 0), app.api_client.catalog.entries.items.len);
}

test "L2 metask api-key route: opening the key menu returns at once while the account key list never answers" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    const bodies = [_][]const u8{ GATEWAY_MODELS, KEYS_BODY };
    var server = try harness.MockServer.startCassetteSilentFrom(&bodies, 1);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));
    const origin = cc.app_module.MetaskKeyRoute.gatewayOriginOf(messages_url).?;
    const keys_url = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}/api/v1/keys?page=1&page_size=100", .{origin}));
    try case.setEnv("METACODE_API_KEYS_URL", keys_url.ptr);

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();

    const started = cc.util_time.nowMs();
    app.ensureApiKeyCatalog();
    try std.testing.expect(cc.util_time.nowMs() - started < 1_000);
    try std.testing.expect(app.apiKeyCatalogLoading());
    try waitForRequests(server, 2);
    try std.testing.expect(std.mem.startsWith(u8, requestLine(server.requestAt(1).?), "GET /api/v1/keys?"));
    try std.testing.expect(!app.takeApiKeyCatalog());
    try std.testing.expect(app.apiKeyCatalogLoading());
    try std.testing.expectEqual(@as(usize, 0), app.api_key_catalog.entries.items.len);
}

test "L2 metask api-key route: a key pick returns at once while that key's /v1/models never answers" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    const allocator = case.arena.allocator();

    const bodies = [_][]const u8{ GATEWAY_MODELS, KEYS_BODY, DEV_MODELS };
    var server = try harness.MockServer.startCassetteSilentFrom(&bodies, 2);
    defer server.stop();
    const messages_url = try allocator.dupeZ(u8, try server.urlOwned(allocator));
    const origin = cc.app_module.MetaskKeyRoute.gatewayOriginOf(messages_url).?;
    const keys_url = try allocator.dupeZ(u8, try std.fmt.allocPrint(allocator, "{s}/api/v1/keys?page=1&page_size=100", .{origin}));
    try case.setEnv("METACODE_API_KEYS_URL", keys_url.ptr);

    const argv = [_][*:0]const u8{ "metacodes", "--base-url", messages_url.ptr, "--model", "glm-5.3-flash" };
    const config = try case.config(&argv);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const app = try App.init(std.testing.allocator, io_runtime.io(), config, SESSION_KEY);
    defer app.deinit();
    app.ensureApiKeyCatalog();
    try waitUntil(app, App.takeApiKeyCatalog);

    const started = cc.util_time.nowMs();
    try app.selectApiKeyForModels(1);
    try std.testing.expect(cc.util_time.nowMs() - started < 1_000);
    try std.testing.expect(app.modelsRefreshRunning());
    try waitForRequests(server, 3);
    try std.testing.expectEqualStrings("Bearer " ++ KEY_DEV, headerValue(server.requestAt(2).?, "authorization").?);
    try std.testing.expect(!app.takeModelsRefresh());
}

test "L2 catalog transports: a server that accepts and never answers ends each GET at its deadline" {
    var server = try harness.MockServer.startCassetteSilentFrom(&.{ GATEWAY_MODELS, GATEWAY_MODELS, KEYS_BODY }, 0);
    defer server.stop();
    const allocator = std.testing.allocator;
    const messages_url = try server.urlOwned(allocator);
    defer allocator.free(messages_url);
    const origin = cc.app_module.MetaskKeyRoute.gatewayOriginOf(messages_url).?;
    const models_url = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{origin});
    defer allocator.free(models_url);
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();
    const limit_ms: u32 = 300;

    var started = cc.util_time.nowMs();
    try std.testing.expectError(error.TimedOut, cc.api_catalog_fetch.fetchAnswer(allocator, io, .{ .url = models_url, .bearer = SESSION_KEY, .timeout_ms = limit_ms }));
    try expectEndedNear(started, limit_ms);

    var http_client = std.http.Client{ .allocator = allocator, .io = io };
    defer http_client.deinit();
    var status: u16 = 0;
    started = cc.util_time.nowMs();
    try std.testing.expectError(error.TimedOut, cc.client_mod.getModelsList(allocator, &http_client, messages_url, .{ .header = .{ .name = "authorization", .value = "Bearer " ++ SESSION_KEY } }, &status, limit_ms));
    try expectEndedNear(started, limit_ms);

    started = cc.util_time.nowMs();
    try std.testing.expectError(error.TimedOut, cc.api_api_keys.fetchList(allocator, io, models_url, SESSION_KEY, limit_ms));
    try expectEndedNear(started, limit_ms);
}

fn expectEndedNear(started: i64, limit_ms: u32) !void {
    const waited = cc.util_time.nowMs() - started;
    try std.testing.expect(waited >= limit_ms - 50);
    try std.testing.expect(waited < limit_ms + 3_000);
}

fn waitForRequests(server: *harness.MockServer, count: usize) !void {
    var waited_ms: u32 = 0;
    while (server.requestAt(count - 1) == null) : (waited_ms += 5) {
        if (waited_ms > 10_000) return error.WaitTimedOut;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
}
