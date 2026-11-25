//! L2: what a start asks the gateway for, and when.
//!
//! The 2026-10-23 startup trace showed two fixed round trips before the
//! banner: the account's API-key list (refused with a plain API key, every
//! start) and `/v1/models` (~0.25 s). Locked here on a real `App.init`
//! against a MockServer that records every request:
//!   - startup sends `GET /v1/models` and nothing else; the key list waits
//!     for the `/models` key menu (`App.ensureApiKeyCatalog`), is skipped
//!     outright when only an API key could be sent to the account endpoint,
//!     and is fetched with the login token (or with the API key from a named
//!     `METACODE_API_KEYS_URL`) when there is one;
//!   - with the REPL's `models_cache`, a cold start fetches `/v1/models` and
//!     waits for it at most the startup wait, and stores it; a warm start
//!     sends nothing before init returns, answers from the stored copy, and a
//!     background refresh that the REPL adopts updates both the catalog and
//!     the copy; an expired copy is a cold start; an answer for a credential
//!     the session has since left is dropped.

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;

/// Sets (or unsets, with null) one variable and puts the old value back.
const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const a = std.testing.allocator;
        const previous = if (std.c.getenv(name)) |raw| try a.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

const MODELS_A =
    \\{"data":[{"id":"claude-sonnet-4-5","max_tokens":11111,"max_input_tokens":100000}]}
;
const MODELS_B =
    \\{"data":[{"id":"claude-sonnet-4-5","max_tokens":22222,"max_input_tokens":200000}]}
;
const MODELS_C =
    \\{"data":[{"id":"claude-sonnet-4-5","max_tokens":33333,"max_input_tokens":300000}]}
;
const KEYS =
    \\{"code":0,"data":{"items":[
    \\{"id":1,"name":"Prod key","key":"sk-prod-1111","status":"active"},
    \\{"id":2,"name":"Dev key","key":"sk-dev-2222","status":"active"}]}}
;

/// A HOME and a state root of their own, a probe-enabled environment, and the
/// guards that undo it. Each `start` builds a fresh App against `url`.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    guards: [8]EnvGuard,
    guard_count: usize = 0,
    home: []const u8,
    state: []const u8,

    fn setup(self: *Fixture) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        self.arena = std.heap.ArenaAllocator.init(a);
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        const root = try arena.dupe(u8, root_buffer[0..len]);
        try self.tmp.dir.createDirPath(std.testing.io, "home");
        try self.tmp.dir.createDirPath(std.testing.io, "state");
        self.home = try std.fs.path.join(arena, &.{ root, "home" });
        self.state = try std.fs.path.join(arena, &.{ root, "state" });
        self.guard_count = 0;
        errdefer self.restoreGuards();
        try self.guard("HOME", (try arena.dupeZ(u8, self.home)).ptr);
        try self.guard("CODEX_HOME", (try std.fs.path.joinZ(arena, &.{ self.home, ".codex" })).ptr);
        // The probes under test run only without METACODES_NO_PROBE.
        try self.guard("METACODES_NO_PROBE", null);
        try self.guard("METACODES_KG_AUTOSTART", "0");
        try self.guard("METACODE_API_KEYS_URL", null);
        try self.guard("METACODES_JEV_URL", "");
        self.io_rt = @import("platform").signal.threadedIo(arena, .{});
    }

    fn guard(self: *Fixture, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        self.guards[self.guard_count] = try EnvGuard.set(name, value);
        self.guard_count += 1;
    }

    fn restoreGuards(self: *Fixture) void {
        while (self.guard_count > 0) {
            self.guard_count -= 1;
            self.guards[self.guard_count].restore();
        }
    }

    fn deinit(self: *Fixture) void {
        self.io_rt.deinit();
        self.restoreGuards();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn start(self: *Fixture, url: []const u8, options: cc.app_module.App.InitOptions) !*cc.app_module.App {
        const arena = self.arena.allocator();
        const argv = [_][*:0]const u8{
            "metacodes",
            "--permission",
            "bypassPermissions",
            "--base-url",
            (try arena.dupeZ(u8, url)).ptr,
            "--model",
            "claude-sonnet-4-5",
        };
        var config = cc.parseArgsForTest(&argv, arena);
        try std.testing.expect(config.parse_error == null);
        config.state_root = self.state;
        return cc.app_module.App.initWithOptions(std.testing.allocator, self.io_rt.io(), config, "test-key", options);
    }

    /// The stored `/v1/models` copy for this fixture's route, if any.
    fn cached(self: *Fixture, url: []const u8, api_key: []const u8) ?[]u8 {
        const a = std.testing.allocator;
        const value = std.fmt.allocPrint(a, "Bearer {s}", .{api_key}) catch return null;
        defer a.free(value);
        const key = cc.models_cache.Key.of(url, .{ .name = "authorization", .value = value });
        return cc.models_cache.load(a, self.state, key, url, cc.util_time.nowUnix(), cc.models_cache.TTL_SECONDS);
    }
};

fn requestLine(srv: *harness.MockServer, index: usize) []const u8 {
    const req = srv.requestAt(index) orelse return "";
    const end = std.mem.indexOf(u8, req.raw, "\r\n") orelse req.raw.len;
    return req.raw[0..end];
}

fn hasHeader(srv: *harness.MockServer, index: usize, line: []const u8) bool {
    const req = srv.requestAt(index) orelse return false;
    return std.ascii.indexOfIgnoreCase(req.raw, line) != null;
}

/// Wait for the background refresh to settle (it talks to a local mock).
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

fn waitRefresh(app: *cc.app_module.App) !void {
    const refresh = app.models_refresh orelse return error.NoRefresh;
    var waited_ms: u32 = 0;
    while (!refresh.finished()) : (waited_ms += 5) {
        if (waited_ms > 10_000) return error.RefreshTimeout;
        std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
    }
}

test "L2 startup: init asks only for /v1/models; a plain API key never reaches the account key endpoint" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    var srv = try harness.MockServer.startCassette(&.{MODELS_A}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);

    const app = try fx.start(url, .{});
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, requestLine(srv, 0), "GET /v1/models "));
    try std.testing.expectEqual(@as(u32, 11111), app.api_client.resolveMaxTokens());
    try std.testing.expectEqual(cc.app_module.ApiKeyCatalogLoad.deferred, app.api_key_catalog_load);
    try std.testing.expectEqual(@as(usize, 0), app.api_key_catalog.entries.items.len);

    // The key menu needs the list: no login token, no named endpoint → no request,
    // and the key in use is the one entry.
    try loadApiKeyCatalog(app);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expectEqual(@as(usize, 1), app.api_key_catalog.entries.items.len);
    try std.testing.expectEqualStrings("Current API key", app.api_key_catalog.entries.items[0].label);
    try std.testing.expectEqualStrings("test-key", app.api_key_catalog.entries.items[0].secret);
    // Once.
    app.ensureApiKeyCatalog();
    try std.testing.expectEqual(@as(usize, 1), app.api_key_catalog.entries.items.len);
}

test "L2 startup: a named key endpoint gets the API key when the key menu first needs it" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    var srv = try harness.MockServer.startCassette(&.{ MODELS_A, KEYS }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    const keys_url = try std.fmt.allocPrintSentinel(fx.arena.allocator(), "http://127.0.0.1:{d}/api/v1/keys?page=1&page_size=100", .{srv.port}, 0);
    try fx.guard("METACODE_API_KEYS_URL", keys_url.ptr);

    const app = try fx.start(url, .{});
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());

    try loadApiKeyCatalog(app);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, requestLine(srv, 1), "GET /api/v1/keys?page=1&page_size=100 "));
    try std.testing.expect(hasHeader(srv, 1, "authorization: Bearer test-key"));
    try std.testing.expectEqual(@as(usize, 2), app.api_key_catalog.entries.items.len);
    try std.testing.expectEqualStrings("Dev key", app.api_key_catalog.entries.items[1].label);
}

test "L2 startup: a stored login token lists the account's keys, still only when the menu needs them" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = std.testing.allocator;
    var creds = cc.core_auth.StoredCredentials{ .oauth = .{
        .access_token = try a.dupe(u8, "login-token-l2"),
        .refresh_token = try a.dupe(u8, "login-refresh-l2"),
        .expires_at = cc.util_time.nowUnix() + 3600,
    } };
    defer creds.deinit(a);
    try cc.core_auth.saveDefault(a, fx.state, creds);

    var srv = try harness.MockServer.startCassette(&.{ MODELS_A, KEYS }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const app = try fx.start(url, .{});
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());

    try loadApiKeyCatalog(app);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, requestLine(srv, 1), "GET /api/v1/keys?page=1&page_size=100 "));
    try std.testing.expect(hasHeader(srv, 1, "authorization: Bearer login-token-l2"));
    try std.testing.expectEqual(@as(usize, 2), app.api_key_catalog.entries.items.len);
}

test "L2 startup: with the models cache, a cold start fetches /v1/models before init returns and stores the answer" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{MODELS_A}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const app = try fx.start(url, .{ .models_cache = true });
    defer app.deinit();
    // The same request, answered before init returns, as without the cache.
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, requestLine(srv, 0), "GET /v1/models "));
    try std.testing.expect(app.models_refresh == null);
    try std.testing.expectEqual(@as(u32, 11111), app.api_client.resolveMaxTokens());
    const stored = fx.cached(url, "test-key") orelse return error.NotStored;
    defer a.free(stored);
    try std.testing.expectEqualStrings(MODELS_A, stored);
    // Keyed by credential: another key has no copy.
    try std.testing.expect(fx.cached(url, "other-key") == null);
}

test "L2 startup: a warm start answers from the stored copy and adopts the background refresh at the REPL's idle point" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{MODELS_B}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    const key = cc.models_cache.Key.of(url, .{ .name = "authorization", .value = "Bearer test-key" });
    try cc.models_cache.store(a, fx.state, key, url, MODELS_A, cc.util_time.nowUnix());

    const app = try fx.start(url, .{ .models_cache = true });
    defer app.deinit();
    // Init answered from the copy: the first request carries its limits.
    try std.testing.expect(app.models_refresh != null);
    try std.testing.expectEqual(@as(u32, 11111), app.api_client.resolveMaxTokens());
    try waitRefresh(app);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(std.mem.startsWith(u8, requestLine(srv, 0), "GET /v1/models "));
    try std.testing.expect(hasHeader(srv, 0, "authorization: Bearer test-key"));
    // Until the REPL adopts it, the session keeps the copy's answer.
    try std.testing.expectEqual(@as(u32, 11111), app.api_client.resolveMaxTokens());
    app.adoptModelCatalogRefresh();
    try std.testing.expect(app.models_refresh == null);
    try std.testing.expectEqual(@as(u32, 22222), app.api_client.resolveMaxTokens());
    // And the next start's copy is the refreshed answer.
    const stored = fx.cached(url, "test-key") orelse return error.NotStored;
    defer a.free(stored);
    try std.testing.expectEqualStrings(MODELS_B, stored);
}

test "L2 startup: an expired models copy is a cold start" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{MODELS_B}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    const key = cc.models_cache.Key.of(url, .{ .name = "authorization", .value = "Bearer test-key" });
    try cc.models_cache.store(a, fx.state, key, url, MODELS_A, cc.util_time.nowUnix() - cc.models_cache.TTL_SECONDS - 60);

    const app = try fx.start(url, .{ .models_cache = true });
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(app.models_refresh == null);
    try std.testing.expectEqual(@as(u32, 22222), app.api_client.resolveMaxTokens());
    const stored = fx.cached(url, "test-key") orelse return error.NotStored;
    defer a.free(stored);
    try std.testing.expectEqualStrings(MODELS_B, stored);
}

test "L2 startup: a refresh for a key the session has since left is dropped" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const a = std.testing.allocator;
    // Refresh (B), then the key list, then the probe for the picked key (C).
    var srv = try harness.MockServer.startCassette(&.{ MODELS_B, KEYS, MODELS_C }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    const keys_url = try std.fmt.allocPrintSentinel(fx.arena.allocator(), "http://127.0.0.1:{d}/api/v1/keys?page=1&page_size=100", .{srv.port}, 0);
    try fx.guard("METACODE_API_KEYS_URL", keys_url.ptr);
    const key = cc.models_cache.Key.of(url, .{ .name = "authorization", .value = "Bearer test-key" });
    try cc.models_cache.store(a, fx.state, key, url, MODELS_A, cc.util_time.nowUnix());

    const app = try fx.start(url, .{ .models_cache = true });
    defer app.deinit();
    try waitRefresh(app);
    // `/models`: pick the Dev key; its own probe answers C.
    try loadApiKeyCatalog(app);
    try pickApiKey(app, 1);
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
    try std.testing.expect(hasHeader(srv, 2, "authorization: Bearer sk-dev-2222"));
    try std.testing.expectEqual(@as(u32, 33333), app.api_client.resolveMaxTokens());
    // The finished refresh answered for test-key: not this session's key any more.
    app.adoptModelCatalogRefresh();
    try std.testing.expect(app.models_refresh == null);
    try std.testing.expectEqual(@as(u32, 33333), app.api_client.resolveMaxTokens());
}

test "L2 startup: a theme the host resolved is the App's theme" {
    var fx: Fixture = undefined;
    try fx.setup();
    defer fx.deinit();
    var srv = try harness.MockServer.startCassette(&.{MODELS_A}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    const app = try fx.start(url, .{ .theme_variant = .light });
    defer app.deinit();
    try std.testing.expectEqual(@as(@TypeOf(app.theme_variant), .light), app.theme_variant);
}
