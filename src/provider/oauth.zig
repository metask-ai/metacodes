//! Provider-scoped OAuth lifecycle (issue #16, delivery slice P1).
//!
//! Metask's OAuth lives in `core/auth.zig` and stays there, byte for byte. This
//! is the same lifecycle for *any* provider that declares an OAuth credential
//! kind — OpenAI and Codex first — kept in the provider subsystem so it is
//! reachable from provider-scoped credential resolution and so a token for one
//! vendor can never satisfy another.
//!
//! Three properties are the whole point:
//!
//! - **Single flight.** N turns discovering an expired access token at once
//!   perform *one* refresh. Without this, a rotated refresh token makes the
//!   losers of the race present a token the server has already invalidated, and
//!   the session dies with an authentication error that looks random.
//! - **Rotated-refresh persistence is atomic.** A provider that returns a new
//!   refresh token has invalidated the old one; a crash between "used" and
//!   "saved" would lock the user out permanently. The write goes through the
//!   same temp-file + fsync + rename path the config store uses.
//! - **Nothing here performs I/O.** The token exchange is a caller-supplied
//!   function, so this module has no transport dependency and every test drives
//!   a fake exchange rather than a network.

const std = @import("std");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const ids = @import("ids.zig");
const profile_mod = @import("profile.zig");

pub const Slug = ids.Slug;

/// Refresh this many seconds before the server's expiry. A token that expires
/// mid-flight fails the request it was attached to, so the margin has to cover
/// a slow request rather than just clock skew.
pub const REFRESH_MARGIN_SECONDS: i64 = 120;

pub const OAuthError = error{
    OutOfMemory,
    NoTokens,
    /// The provider refused the refresh token. Retrying cannot help — the user
    /// has to log in again — so this is deliberately not a transport error.
    RefreshRejected,
    RefreshFailed,
    MalformedTokenResponse,
    PersistFailed,
    NoHome,
    PathTooLong,
};

pub const TokenSet = struct {
    access_token: []u8,
    refresh_token: []u8,
    /// Unix seconds. The value the provider reported, not a local guess.
    expires_at: i64,
    token_type: []u8,
    scope: ?[]u8 = null,
    account_id: ?[]u8 = null,

    pub fn deinit(self: *TokenSet, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.access_token);
        secureFree(allocator, self.refresh_token);
        allocator.free(self.token_type);
        if (self.scope) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        self.* = undefined;
    }

    pub fn isExpiredAt(self: TokenSet, now_seconds: i64) bool {
        return now_seconds + REFRESH_MARGIN_SECONDS >= self.expires_at;
    }
};

/// What a token endpoint returned. The caller fills this in; parsing the wire
/// format is `parseTokenResponse`.
pub const RefreshOutcome = struct {
    access_token: []const u8,
    /// Absent means the provider kept the existing refresh token. Present means
    /// it rotated, and the old one is already dead.
    refresh_token: ?[]const u8 = null,
    expires_in_seconds: i64,
    token_type: []const u8 = "Bearer",
    scope: ?[]const u8 = null,
};

/// Caller-supplied token exchange. Returning an error must not leave partial
/// state: this module writes nothing until the exchange succeeds.
pub const ExchangeFn = *const fn (
    ctx: *anyopaque,
    provider_id: Slug,
    refresh_token: []const u8,
    arena: std.mem.Allocator,
) OAuthError!RefreshOutcome;

pub const Exchange = struct {
    ctx: *anyopaque,
    run: ExchangeFn,
};

/// One provider's OAuth state.
///
/// Borrowed by every thread that needs a token, so all mutation happens under
/// `mutex` and every waiter is woken through `settled`.
pub const Session = struct {
    allocator: std.mem.Allocator,
    provider_id: Slug,
    /// Where rotated tokens are persisted. Owned.
    path: []u8,

    mutex: sync.Mutex = .{},
    settled: sync.Condition = .{},
    tokens: ?TokenSet = null,
    refreshing: bool = false,
    /// Bumped on every successful refresh. A thread that waited compares
    /// generations to know a *different* thread's refresh already covered it.
    generation: u64 = 0,
    last_error: ?OAuthError = null,
    /// Refreshes actually performed. A single-flight test that cannot count
    /// exchanges cannot prove single flight.
    exchange_count: usize = 0,
    /// Callers that found a refresh already in flight and waited for it.
    ///
    /// Also for the test, and load-bearing there: with one exchange counted and
    /// zero waiters, the callers simply ran one after another and each found a
    /// fresh token — an outcome a *broken* implementation produces just as
    /// happily. Only a non-zero wait count proves the race actually happened.
    waited_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        provider_id: Slug,
        path: []const u8,
    ) OAuthError!Session {
        return .{
            .allocator = allocator,
            .provider_id = provider_id,
            .path = allocator.dupe(u8, path) catch return error.OutOfMemory,
        };
    }

    /// `<home>/.metacodes/oauth/<provider>.json`, or `METACODES_OAUTH_DIR`.
    pub fn initHome(
        allocator: std.mem.Allocator,
        provider_id: Slug,
    ) OAuthError!Session {
        const dir = if (std.c.getenv("METACODES_OAUTH_DIR")) |raw|
            std.mem.span(raw)
        else blk: {
            const home = @import("platform").paths.homeDir() orelse return error.NoHome;
            break :blk std.fmt.allocPrint(allocator, "{s}/.metacodes/oauth", .{home}) catch
                return error.OutOfMemory;
        };
        const owned_dir = std.c.getenv("METACODES_OAUTH_DIR") == null;
        defer if (owned_dir) allocator.free(dir);

        const path = std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, provider_id.slice() }) catch
            return error.OutOfMemory;
        defer allocator.free(path);
        return init(allocator, provider_id, path);
    }

    pub fn deinit(self: *Session) void {
        if (self.tokens) |*set| set.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    /// Install tokens obtained by an initial login. Takes ownership.
    pub fn adopt(self: *Session, tokens: TokenSet) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.tokens) |*old| old.deinit(self.allocator);
        self.tokens = tokens;
        self.generation +%= 1;
    }

    /// Install a token response obtained by an initial login, and persist it.
    ///
    /// Persisting here rather than on first use matters: the login already
    /// consumed whatever one-shot grant produced these tokens, so a crash
    /// before saving would lose the login entirely.
    pub fn importOutcome(self: *Session, outcome: RefreshOutcome, now_seconds: i64) OAuthError!void {
        const refresh = outcome.refresh_token orelse return error.MalformedTokenResponse;
        var tokens = try own(self.allocator, outcome, refresh, now_seconds);
        errdefer tokens.deinit(self.allocator);
        try self.persist(tokens);
        self.adopt(tokens);
    }

    /// Load persisted tokens. A missing file is "not logged in", not an error.
    pub fn load(self: *Session) OAuthError!bool {
        const text = readFile(self.allocator, self.path) catch return false;
        defer secureFree(self.allocator, text);
        if (text.len == 0) return false;
        const parsed = try parseStored(self.allocator, text);
        self.adopt(parsed);
        return true;
    }

    /// A usable access token, refreshing first when it is at or past expiry.
    ///
    /// The returned slice is owned by the caller: handing out a borrow of state
    /// another thread may refresh underneath it is a use-after-free waiting for
    /// a slow request.
    pub fn accessToken(
        self: *Session,
        now_seconds: i64,
        exchange: Exchange,
    ) OAuthError![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            const current = self.tokens orelse return error.NoTokens;
            if (!current.isExpiredAt(now_seconds)) {
                return self.allocator.dupe(u8, current.access_token) catch error.OutOfMemory;
            }
            if (self.refreshing) {
                // Someone else is already exchanging. Wait for them rather than
                // starting a second exchange: with a rotating refresh token the
                // second one would present a token the server just killed.
                self.waited_count += 1;
                self.settled.wait(&self.mutex);
                // The in-flight refresh has settled, and its outcome is ours.
                // Retrying here would perform a second exchange against the
                // same refresh token — and for the failure that matters most,
                // `invalid_grant`, that token is already dead, so every waiter
                // would burn one more request to be told the same thing.
                // A *later* call still retries: only this cohort shares the
                // result.
                if (self.last_error) |err| return err;
                // Success, or a spurious wake: the loop re-checks. A fresh
                // token returns above; a still-running refresh waits again.
                continue;
            }
            break;
        }

        self.refreshing = true;
        self.last_error = null;
        const refresh_token = self.allocator.dupe(u8, self.tokens.?.refresh_token) catch {
            self.finishRefresh(error.OutOfMemory);
            return error.OutOfMemory;
        };
        defer secureFree(self.allocator, refresh_token);

        // The exchange runs with the lock released: it is I/O, and holding a
        // lock across it would serialize every reader behind the network.
        self.mutex.unlock();
        const result = self.runExchange(refresh_token, exchange, now_seconds);
        self.mutex.lock();

        if (result) |_| {
            self.finishRefresh(null);
            const current = self.tokens orelse return error.NoTokens;
            return self.allocator.dupe(u8, current.access_token) catch error.OutOfMemory;
        } else |err| {
            self.finishRefresh(err);
            return err;
        }
    }

    fn finishRefresh(self: *Session, err: ?OAuthError) void {
        self.refreshing = false;
        self.last_error = err;
        self.generation +%= 1;
        self.settled.broadcast();
    }

    /// Perform one exchange and install its result. Called with the lock *not*
    /// held; it takes the lock only to swap the tokens in.
    fn runExchange(
        self: *Session,
        refresh_token: []const u8,
        exchange: Exchange,
        now_seconds: i64,
    ) OAuthError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const outcome = try exchange.run(exchange.ctx, self.provider_id, refresh_token, arena.allocator());

        var replacement = try own(self.allocator, outcome, refresh_token, now_seconds);
        errdefer replacement.deinit(self.allocator);

        // Persist *before* the new tokens become the live ones. A provider that
        // rotated has already invalidated the old refresh token, so a crash
        // after using it and before saving would lock the user out; writing
        // first means the worst case is a token that is saved but not yet in
        // memory, which the next load recovers.
        try self.persist(replacement);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.exchange_count += 1;
        if (self.tokens) |*old| old.deinit(self.allocator);
        self.tokens = replacement;
    }

    fn persist(self: *Session, tokens: TokenSet) OAuthError!void {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.allocator);
        renderStored(self.allocator, &buffer, tokens) catch return error.OutOfMemory;
        writeAtomicPrivate(self.allocator, self.path, buffer.items) catch return error.PersistFailed;
    }
};

fn own(
    allocator: std.mem.Allocator,
    outcome: RefreshOutcome,
    previous_refresh: []const u8,
    now_seconds: i64,
) OAuthError!TokenSet {
    if (outcome.access_token.len == 0) return error.MalformedTokenResponse;
    if (outcome.expires_in_seconds <= 0) return error.MalformedTokenResponse;

    const access = allocator.dupe(u8, outcome.access_token) catch return error.OutOfMemory;
    errdefer secureFree(allocator, access);
    // An absent rotated token means the provider kept the existing one; an
    // empty *present* one is malformed, and treating it as "keep" would hide a
    // broken provider until the next expiry.
    if (outcome.refresh_token) |value| {
        if (value.len == 0) return error.MalformedTokenResponse;
    }
    const refresh = allocator.dupe(u8, outcome.refresh_token orelse previous_refresh) catch
        return error.OutOfMemory;
    errdefer secureFree(allocator, refresh);
    const token_type = allocator.dupe(u8, outcome.token_type) catch return error.OutOfMemory;
    errdefer allocator.free(token_type);
    const scope = if (outcome.scope) |value|
        (allocator.dupe(u8, value) catch return error.OutOfMemory)
    else
        null;

    return .{
        .access_token = access,
        .refresh_token = refresh,
        .expires_at = now_seconds + outcome.expires_in_seconds,
        .token_type = token_type,
        .scope = scope,
    };
}

// ── wire parsing ─────────────────────────────────────────────────────────────

/// Parse a standard OAuth token response. Shared by the initial exchange and
/// the refresh, because RFC 6749 makes them the same shape.
pub fn parseTokenResponse(arena: std.mem.Allocator, body: []const u8) OAuthError!RefreshOutcome {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return error.MalformedTokenResponse;
    if (root != .object) return error.MalformedTokenResponse;

    const access = stringOf(root.object.get("access_token")) orelse return error.MalformedTokenResponse;
    const expires = switch (root.object.get("expires_in") orelse return error.MalformedTokenResponse) {
        .integer => |value| value,
        .float => |value| @as(i64, @intFromFloat(value)),
        else => return error.MalformedTokenResponse,
    };
    return .{
        .access_token = access,
        .refresh_token = stringOf(root.object.get("refresh_token")),
        .expires_in_seconds = expires,
        .token_type = stringOf(root.object.get("token_type")) orelse "Bearer",
        .scope = stringOf(root.object.get("scope")),
    };
}

/// Classify a token-endpoint failure. `invalid_grant` means the refresh token
/// is dead: retrying is pointless and the user must log in again, so it is
/// deliberately not reported as a transport error a retry loop would chew on.
pub fn classifyTokenError(status: u16, body: []const u8) OAuthError {
    if (status == 400 or status == 401) {
        if (std.mem.indexOf(u8, body, "invalid_grant") != null) return error.RefreshRejected;
        if (std.mem.indexOf(u8, body, "invalid_client") != null) return error.RefreshRejected;
        return error.RefreshRejected;
    }
    return error.RefreshFailed;
}

// ── persistence ──────────────────────────────────────────────────────────────

fn renderStored(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tokens: TokenSet) !void {
    try out.appendSlice(allocator, "{\"schema_version\":1,\"access_token\":");
    try writeJsonString(allocator, out, tokens.access_token);
    try out.appendSlice(allocator, ",\"refresh_token\":");
    try writeJsonString(allocator, out, tokens.refresh_token);
    try out.appendSlice(allocator, ",\"token_type\":");
    try writeJsonString(allocator, out, tokens.token_type);
    const expires = try std.fmt.allocPrint(allocator, ",\"expires_at\":{d}", .{tokens.expires_at});
    defer allocator.free(expires);
    try out.appendSlice(allocator, expires);
    if (tokens.scope) |value| {
        try out.appendSlice(allocator, ",\"scope\":");
        try writeJsonString(allocator, out, value);
    }
    try out.append(allocator, '}');
}

fn parseStored(allocator: std.mem.Allocator, text: []const u8) OAuthError!TokenSet {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) catch
        return error.MalformedTokenResponse;
    if (root != .object) return error.MalformedTokenResponse;

    const access = stringOf(root.object.get("access_token")) orelse return error.MalformedTokenResponse;
    const refresh = stringOf(root.object.get("refresh_token")) orelse return error.MalformedTokenResponse;
    const expires = switch (root.object.get("expires_at") orelse return error.MalformedTokenResponse) {
        .integer => |value| value,
        else => return error.MalformedTokenResponse,
    };
    const token_type = stringOf(root.object.get("token_type")) orelse "Bearer";

    const access_owned = allocator.dupe(u8, access) catch return error.OutOfMemory;
    errdefer secureFree(allocator, access_owned);
    const refresh_owned = allocator.dupe(u8, refresh) catch return error.OutOfMemory;
    errdefer secureFree(allocator, refresh_owned);
    const type_owned = allocator.dupe(u8, token_type) catch return error.OutOfMemory;
    return .{
        .access_token = access_owned,
        .refresh_token = refresh_owned,
        .expires_at = expires,
        .token_type = type_owned,
    };
}

/// Temp file + fsync + rename, 0600, with the parent created on demand — the
/// same durability contract `config_store` uses, for the same reason: a partial
/// write here costs the user their login.
fn writeAtomicPrivate(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    ensureParent(allocator, path) catch {};
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp);
    const temp_z = try allocator.dupeZ(u8, temp);
    defer allocator.free(temp_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd = pfs.open(temp_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.PersistFailed;
    var wrote: usize = 0;
    while (wrote < bytes.len) {
        const n = pfs.write(fd, bytes[wrote..]);
        if (n <= 0) {
            pfs.close(fd);
            _ = pfs.unlinkPath(temp_z) catch {};
            return error.PersistFailed;
        }
        wrote += @intCast(n);
    }
    pfs.fsyncChecked(fd) catch {
        pfs.close(fd);
        _ = pfs.unlinkPath(temp_z) catch {};
        return error.PersistFailed;
    };
    pfs.close(fd);
    if (pfs.renameReplace(temp_z.ptr, path_z.ptr) != 0) {
        _ = pfs.unlinkPath(temp_z) catch {};
        return error.PersistFailed;
    }
}

fn ensureParent(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    const dir = std.fs.path.dirname(path) orelse return;
    // Every level, not just the last: on a fresh installation neither
    // `~/.metacodes` nor `~/.metacodes/oauth` exists, and a single `mkdir` of
    // the leaf fails with ENOENT — so the very first `login --provider` could
    // not store its token.
    try @import("../util/fs.zig").mkdirParents(dir);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = try pfs.openZ(path_z, .{ .ACCMODE = .RDONLY }, 0);
    defer pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    if (info.size > 256 * 1024) return error.FileTooLarge;
    const buffer = try allocator.alloc(u8, @intCast(info.size));
    errdefer secureFree(allocator, buffer);
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = try pfs.readZ(fd, buffer[filled..]);
        if (n == 0) break;
        filled += n;
    }
    return buffer[0..filled];
}

fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |byte| switch (byte) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => {
            if (byte < 0x20) {
                const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{byte});
                defer allocator.free(escaped);
                try out.appendSlice(allocator, escaped);
            } else try out.append(allocator, byte);
        },
    };
    try out.append(allocator, '"');
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

/// Credential kinds this lifecycle serves. Metask keeps its historical path.
pub fn servesKind(kind: profile_mod.CredentialKind) bool {
    return switch (kind) {
        .openai_oauth, .openai_codex_oauth => true,
        else => false,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeExchange = struct {
    calls: usize = 0,
    mutex: sync.Mutex = .{},
    /// Simulated network time, so the single-flight window is real rather than
    /// instantaneous.
    delay_ms: u64 = 0,
    rotate: bool = true,
    fail: ?OAuthError = null,
    last_presented: [128]u8 = undefined,
    last_presented_len: usize = 0,

    fn run(
        ctx: *anyopaque,
        _: Slug,
        refresh_token: []const u8,
        arena: std.mem.Allocator,
    ) OAuthError!RefreshOutcome {
        const self: *FakeExchange = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        self.calls += 1;
        const call = self.calls;
        const len = @min(refresh_token.len, self.last_presented.len);
        @memcpy(self.last_presented[0..len], refresh_token[0..len]);
        self.last_presented_len = len;
        const delay = self.delay_ms;
        const failure = self.fail;
        const rotate = self.rotate;
        self.mutex.unlock();

        if (delay > 0) sync.sleepMs(delay);
        if (failure) |err| return err;

        return .{
            .access_token = std.fmt.allocPrint(arena, "access-{d}", .{call}) catch return error.OutOfMemory,
            .refresh_token = if (rotate)
                (std.fmt.allocPrint(arena, "refresh-{d}", .{call}) catch return error.OutOfMemory)
            else
                null,
            .expires_in_seconds = 3600,
        };
    }

    fn exchange(self: *FakeExchange) Exchange {
        return .{ .ctx = @ptrCast(self), .run = FakeExchange.run };
    }

    fn presented(self: *FakeExchange) []const u8 {
        return self.last_presented[0..self.last_presented_len];
    }
};

fn tempSession(a: std.mem.Allocator, name: []const u8) !Session {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/tmp/metacodes-oauth-{s}.json", .{name});
    var cleanup: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".tmp" }) |suffix| {
        const target = std.fmt.bufPrintZ(&cleanup, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
    return Session.init(a, Slug.lit("openai"), path);
}

fn removePath(path: []const u8) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".tmp" }) |suffix| {
        const target = std.fmt.bufPrintZ(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        pfs.unlinkPath(target) catch {};
    }
}

fn removeSession(session: *const Session) void {
    removePath(session.path);
}

fn seed(a: std.mem.Allocator, session: *Session, expires_at: i64) !void {
    session.adopt(.{
        .access_token = try a.dupe(u8, "access-0"),
        .refresh_token = try a.dupe(u8, "refresh-0"),
        .expires_at = expires_at,
        .token_type = try a.dupe(u8, "Bearer"),
    });
}

test "a live access token is returned without touching the network" {
    const a = testing.allocator;
    var session = try tempSession(a, "live");
    defer session.deinit();
    defer removeSession(&session);
    try seed(a, &session, 10_000);

    var fake = FakeExchange{};
    const token = try session.accessToken(1_000, fake.exchange());
    defer a.free(token);
    try testing.expectEqualStrings("access-0", token);
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "an expiring token refreshes before it expires, not after" {
    const a = testing.allocator;
    var session = try tempSession(a, "margin");
    defer session.deinit();
    defer removeSession(&session);
    try seed(a, &session, 1_000);

    var fake = FakeExchange{};
    // Still inside the margin: a token that expires mid-flight fails the
    // request it was attached to, so the margin has to trigger early.
    const token = try session.accessToken(1_000 - REFRESH_MARGIN_SECONDS, fake.exchange());
    defer a.free(token);
    try testing.expectEqualStrings("access-1", token);
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a rotated refresh token replaces the old one and is what the next refresh presents" {
    const a = testing.allocator;
    var session = try tempSession(a, "rotate");
    defer session.deinit();
    defer removeSession(&session);
    try seed(a, &session, 0);

    var fake = FakeExchange{};
    const first = try session.accessToken(1_000, fake.exchange());
    a.free(first);
    try testing.expectEqualStrings("refresh-0", fake.presented());

    session.tokens.?.expires_at = 0;
    const second = try session.accessToken(2_000, fake.exchange());
    a.free(second);
    // Presenting the dead token again is exactly the failure rotation causes.
    try testing.expectEqualStrings("refresh-1", fake.presented());
}

test "a provider that keeps its refresh token does not lose it" {
    const a = testing.allocator;
    var session = try tempSession(a, "keep");
    defer session.deinit();
    defer removeSession(&session);
    try seed(a, &session, 0);

    var fake = FakeExchange{ .rotate = false };
    const token = try session.accessToken(1_000, fake.exchange());
    a.free(token);
    try testing.expectEqualStrings("refresh-0", session.tokens.?.refresh_token);

    // An empty *present* refresh token is malformed, not "keep": treating it as
    // keep would hide a broken provider until the next expiry.
    const Empty = struct {
        fn run(_: *anyopaque, _: Slug, _: []const u8, _: std.mem.Allocator) OAuthError!RefreshOutcome {
            return .{ .access_token = "a", .refresh_token = "", .expires_in_seconds = 60 };
        }
    };
    var anchor: u8 = 0;
    session.tokens.?.expires_at = 0;
    try testing.expectError(error.MalformedTokenResponse, session.accessToken(2_000, .{
        .ctx = @ptrCast(&anchor),
        .run = Empty.run,
    }));
}

test "rotated tokens are persisted atomically and survive a reload" {
    const a = testing.allocator;
    var session = try tempSession(a, "persist");
    const path = try a.dupe(u8, session.path);
    defer a.free(path);
    defer removePath(path);
    try seed(a, &session, 0);

    var fake = FakeExchange{};
    const token = try session.accessToken(1_000, fake.exchange());
    a.free(token);
    session.deinit();

    // A crash right here is the dangerous moment: the provider has already
    // invalidated `refresh-0`, so the file must already hold `refresh-1`.
    var reloaded = try Session.init(a, Slug.lit("openai"), path);
    defer reloaded.deinit();
    try testing.expect(try reloaded.load());
    try testing.expectEqualStrings("refresh-1", reloaded.tokens.?.refresh_token);
    try testing.expectEqualStrings("access-1", reloaded.tokens.?.access_token);
    try testing.expectEqual(@as(i64, 1_000 + 3600), reloaded.tokens.?.expires_at);
}

test "concurrent expiry performs exactly one refresh" {
    const a = testing.allocator;
    var session = try tempSession(a, "single-flight");
    defer session.deinit();
    defer removeSession(&session);
    try seed(a, &session, 0);

    // A real window, so the racers genuinely overlap.
    var fake = FakeExchange{ .delay_ms = 60 };
    const Worker = struct {
        session: *Session,
        exchange: Exchange,
        allocator: std.mem.Allocator,
        token: ?[]u8 = null,
        failed: bool = false,

        fn run(self: *@This()) void {
            const result = self.session.accessToken(1_000, self.exchange) catch {
                self.failed = true;
                return;
            };
            self.token = result;
        }
    };

    var workers: [8]Worker = undefined;
    var threads: [8]std.Thread = undefined;
    for (&workers) |*worker| worker.* = .{ .session = &session, .exchange = fake.exchange(), .allocator = a };
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[index]});
    }
    for (&threads) |*thread| thread.join();

    for (&workers) |*worker| {
        try testing.expect(!worker.failed);
        defer if (worker.token) |token| a.free(token);
        // Every waiter gets the *same* token — the one refresh that happened.
        try testing.expectEqualStrings("access-1", worker.token.?);
    }
    // The whole point: N threads discovering expiry at once perform one
    // exchange. Without single flight, the losers present a refresh token the
    // server already rotated away.
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expectEqual(@as(usize, 1), session.exchange_count);
    // And the race really happened. One exchange with nobody waiting would mean
    // the threads merely ran in sequence, each finding a token the previous one
    // had already refreshed — an outcome a broken implementation produces just
    // as happily. Verified by probe: serializing the spawns fails this line.
    try testing.expect(session.waited_count > 0);
}

test "a rejected refresh reaches every waiter and is not retried as a transport error" {
    const a = testing.allocator;
    var session = try tempSession(a, "rejected");
    defer session.deinit();
    defer removeSession(&session);
    try seed(a, &session, 0);

    var fake = FakeExchange{ .delay_ms = 40, .fail = error.RefreshRejected };
    const Worker = struct {
        session: *Session,
        exchange: Exchange,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            _ = self.session.accessToken(1_000, self.exchange) catch |caught| {
                self.err = caught;
                return;
            };
        }
    };
    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    for (&workers) |*worker| worker.* = .{ .session = &session, .exchange = fake.exchange() };
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[index]});
    }
    for (&threads) |*thread| thread.join();

    var rejected: usize = 0;
    for (&workers) |*worker| {
        if (worker.err) |err| {
            try testing.expectEqual(anyerror.RefreshRejected, err);
            rejected += 1;
        }
    }
    // The waiters really waited, so the single exchange below is single flight
    // rather than four calls that happened not to overlap.
    try testing.expect(session.waited_count > 0);
    // Every caller learns the login is dead; none of them silently proceeds
    // with an expired token.
    try testing.expectEqual(@as(usize, 4), rejected);
    // And exactly one exchange happened. `invalid_grant` means the refresh
    // token is already dead, so a waiter that retried would burn another
    // request to be told the same thing — single flight has to cover the
    // failure path, not just the happy one.
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "the token endpoint's wire shape parses, and invalid_grant is terminal" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const outcome = try parseTokenResponse(arena.allocator(),
        \\{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":3600,"scope":"api"}
    );
    try testing.expectEqualStrings("at", outcome.access_token);
    try testing.expectEqualStrings("rt", outcome.refresh_token.?);
    try testing.expectEqual(@as(i64, 3600), outcome.expires_in_seconds);

    // A response with no rotated token is legal; one with no access token is not.
    const kept = try parseTokenResponse(arena.allocator(),
        \\{"access_token":"at2","expires_in":60}
    );
    try testing.expect(kept.refresh_token == null);
    try testing.expectError(error.MalformedTokenResponse, parseTokenResponse(arena.allocator(),
        \\{"expires_in":60}
    ));

    // `invalid_grant` means the user must log in again; retrying is pointless,
    // so it must not look like a transport failure a retry loop would chew on.
    try testing.expectEqual(OAuthError.RefreshRejected, classifyTokenError(400, "{\"error\":\"invalid_grant\"}"));
    try testing.expectEqual(OAuthError.RefreshFailed, classifyTokenError(503, "upstream down"));
}

test "the lifecycle serves the OAuth kinds and leaves Metask on its own path" {
    try testing.expect(servesKind(.openai_oauth));
    try testing.expect(servesKind(.openai_codex_oauth));
    // Metask's OAuth stays in core/auth.zig, byte for byte.
    try testing.expect(!servesKind(.metask_oauth));
    try testing.expect(!servesKind(.api_key));
}

test "the token store creates every missing parent directory" {
    const a = std.testing.allocator;
    const root = "/tmp/metacodes-oauth-parents";
    const path = root ++ "/nested/deeper/openai.json";
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cleanup = struct {
        fn run(buf: []u8) void {
            for ([_][]const u8{
                root ++ "/nested/deeper/openai.json",
                root ++ "/nested/deeper/openai.json.tmp",
            }) |target| {
                const z = std.fmt.bufPrintZ(buf, "{s}", .{target}) catch continue;
                pfs.unlinkPath(z) catch {};
            }
            for ([_][]const u8{ root ++ "/nested/deeper", root ++ "/nested", root }) |dir| {
                const z = std.fmt.bufPrintZ(buf, "{s}", .{dir}) catch continue;
                _ = std.c.rmdir(z.ptr);
            }
        }
    }.run;
    cleanup(&buffer);
    defer cleanup(&buffer);

    var session = try Session.init(a, Slug.lit("openai"), path);
    defer session.deinit();
    // A single `mkdir` of the leaf would fail with ENOENT here, which is the
    // state a fresh installation is in.
    try session.importOutcome(.{
        .access_token = "at",
        .refresh_token = "rt",
        .expires_in_seconds = 3600,
    }, 1_000);

    var reloaded = try Session.init(a, Slug.lit("openai"), path);
    defer reloaded.deinit();
    try testing.expect(try reloaded.load());
    try testing.expectEqualStrings("rt", reloaded.tokens.?.refresh_token);
}
