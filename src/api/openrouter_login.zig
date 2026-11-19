//! OpenRouter's sign-in: a PKCE grant that ends in an API key of the user's
//! own account (`ProviderProfile.key_grant`), not in OAuth tokens.
//!
//! https://openrouter.ai/docs/guides/overview/auth/oauth, checked 2026-11-18
//! (snapshot under `.verify/openrouter/` in the maintainers' workspace):
//!
//! - The browser goes to `/auth?callback_url=…&code_challenge=…&code_challenge_method=S256`,
//!   here with `state` and a prefilled `key_label`. A loopback callback may
//!   use any port; the page names such a sign-in after its host and port.
//! - Without `callback_url` the page shows the code instead, for a machine
//!   with no browser (SSH, a container), and the user pastes it back. No
//!   `state` comes back that way, nor with a refusal.
//! - `POST /api/v1/auth/keys` with `{code, code_verifier, code_challenge_method}`
//!   answers `{key, user_id}`. A code works once, for ten minutes; a wrong
//!   code or verifier, or an expired code, is a 403.
//! - The key is an ordinary API key: nothing to refresh, no limit and no
//!   expiry unless the user set them on the page. Deleting it takes a
//!   management key, which this client never has: `/keys/<sha256 hex>` is the
//!   page its owner deletes it on.
//!
//! The sign-in ends where a pasted key does: `keys/<provider>.json`, as the
//! key setup's kind (`provider/api_key_store.zig`), with what `/api/v1/key`
//! said about the key then. Every address hangs off one origin, which
//! `METACODES_OPENROUTER_URL` replaces (a local mock in tests), so a test
//! that points it elsewhere cannot send a made-up code to openrouter.ai.

const std = @import("std");
const auth = @import("../core/auth.zig");
const http_status = @import("http_status.zig");
const http_connection = @import("http_connection.zig");
const catalog_fetch = @import("catalog_fetch.zig");
const oauth_login = @import("oauth_login.zig");
const provider_ids = @import("../provider/ids.zig");
const provider_profile = @import("../provider/profile.zig");
const api_key_store = @import("../provider/api_key_store.zig");
const provider_host = @import("../provider/host.zig");
const time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

const KeyGrant = provider_profile.KeyGrant;
const Slug = provider_ids.Slug;

/// Replaces every OpenRouter origin: development and tests point it at a
/// local mock. Read from the process environment only, never from `.env`
/// (which may hold keys, not addresses), and only https or plain http to a
/// loopback host is taken: the exchange carries the code and the verifier,
/// and its answer is the key.
pub const ORIGIN_ENV = "METACODES_OPENROUTER_URL";

/// Why a sign-in ended without a key. Nothing was stored in any of these.
pub const Error = error{
    /// The user declined on the provider's page.
    KeyGrantDeclined,
    /// The code is more than ten minutes old.
    KeyGrantCodeExpired,
    /// The provider refused the code (or the verifier it was made with).
    KeyGrantCodeRefused,
    /// Any other answer to the exchange, or one without a key in it.
    KeyGrantExchangeFailed,
};

/// One line for a failed sign-in, in the words the UI shows, into `buffer`.
/// `retry` is how the user starts over (`/login openrouter`, or the CLI's
/// command). A failure that is not the grant's own (the network, the disk)
/// is named by its error: "Could not reach OpenRouter (…)".
pub fn failureLine(buffer: []u8, err: anyerror, provider_label: []const u8, retry: []const u8) []const u8 {
    return switch (err) {
        error.KeyGrantDeclined => std.fmt.bufPrint(buffer, "{s} did not create a key: the request was declined. Nothing was stored.", .{provider_label}),
        error.KeyGrantCodeExpired => std.fmt.bufPrint(buffer, "That code expired (codes last 10 minutes). Run {s} again.", .{retry}),
        error.KeyGrantCodeRefused => std.fmt.bufPrint(buffer, "{s} refused the code. Copy it whole from the page that showed it, or start over with {s}.", .{ provider_label, retry }),
        error.KeyGrantExchangeFailed => std.fmt.bufPrint(buffer, "{s} answered without a key. Nothing was stored; run {s} again.", .{ provider_label, retry }),
        else => std.fmt.bufPrint(buffer, "Could not reach {s} ({s}). Nothing was stored.", .{ provider_label, @errorName(err) }),
    } catch "The sign-in failed. Nothing was stored.";
}

/// The origin every address of `grant` hangs off: `METACODES_OPENROUTER_URL`
/// when it is one this module takes (`originAccepted`), else the profile's.
pub fn origin(grant: KeyGrant) []const u8 {
    const raw = std.c.getenv(ORIGIN_ENV) orelse return grant.origin;
    const text = std.mem.trimEnd(u8, std.mem.span(raw), "/");
    return if (originAccepted(text)) text else grant.origin;
}

/// With `METACODES_OPENROUTER_URL` set, move the requests of every provider
/// that declares a key grant onto it too, so that one variable moves all of
/// such a provider's addresses: a test pointed at a local mock cannot reach
/// the real site by any of them. Without it, nothing changes.
pub fn applyOriginOverride(host: *provider_host.Host) void {
    var ids: [8]Slug = undefined;
    var count: usize = 0;
    for (host.registry.profiles.items) |profile| {
        if (profile.key_grant == null or count == ids.len) continue;
        ids[count] = profile.id;
        count += 1;
    }
    for (ids[0..count]) |id| {
        const profile = host.registry.findById(id) orelse continue;
        const grant = profile.key_grant orelse continue;
        const moved_to = origin(grant);
        if (std.mem.eql(u8, moved_to, grant.origin)) continue;
        // Never fall back: with the override set, the profile left as it was
        // would send keys and requests to the real site the variable was set
        // to keep them from. An accepted origin always rebases, so this is
        // out of memory or a profile this check no longer admits.
        host.rebaseOrigin(id, grant.origin, moved_to) catch |err|
            std.debug.panic("{s} is set, but {s} could not be moved onto it ({s})", .{ ORIGIN_ENV, profile.display_name, @errorName(err) });
    }
}

/// `https://<host>[:port]`, or `http://` to exactly 127.0.0.1, localhost or
/// [::1]; no path, no user info.
pub fn originAccepted(text: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, text, "https://"))
        text["https://".len..]
    else if (std.mem.startsWith(u8, text, "http://"))
        text["http://".len..]
    else
        return false;
    if (rest.len == 0) return false;
    if (std.mem.indexOfAny(u8, rest, "/?#@") != null) return false;
    if (std.mem.startsWith(u8, text, "https://")) return true;
    const host = if (std.mem.startsWith(u8, rest, "[::1]"))
        rest[0.."[::1]".len]
    else
        rest[0 .. std.mem.indexOfScalar(u8, rest, ':') orelse rest.len];
    if (host.len != rest.len and rest[host.len] != ':') return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "[::1]");
}

/// `<origin><path>`, owned.
pub fn address(allocator: std.mem.Allocator, grant_origin: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ grant_origin, path });
}

/// The loopback redirect and the state the callback must carry back.
pub const Callback = struct {
    url: []const u8,
    state: []const u8,
};

/// The page the browser opens. With `callback`, the page redirects there;
/// without, it shows the code to paste back.
pub fn authorizeUrl(
    allocator: std.mem.Allocator,
    grant_origin: []const u8,
    grant: KeyGrant,
    code_challenge: []const u8,
    callback: ?Callback,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("{s}{s}?", .{ grant_origin, grant.authorize_path });
    var first = true;
    if (callback) |value| {
        try auth.appendFormField(w, "callback_url", value.url, first);
        first = false;
    }
    try auth.appendFormField(w, "code_challenge", code_challenge, first);
    try auth.appendFormField(w, "code_challenge_method", "S256", false);
    if (callback) |value| try auth.appendFormField(w, "state", value.state, false);
    try auth.appendFormField(w, "key_label", grant.key_label, false);
    return out.toOwnedSlice();
}

/// The exchange's JSON body. Holds the code and the verifier: the caller
/// zeroes it.
pub fn exchangeBody(allocator: std.mem.Allocator, code: []const u8, verifier: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer {
        std.crypto.secureZero(u8, out.writer.buffer[0..out.writer.end]);
        out.deinit();
    }
    const w = &out.writer;
    try w.writeAll("{\"code\":");
    try std.json.Stringify.value(code, .{}, w);
    try w.writeAll(",\"code_verifier\":");
    try std.json.Stringify.value(verifier, .{}, w);
    try w.writeAll(",\"code_challenge_method\":\"S256\"}");
    return out.toOwnedSlice();
}

/// What a non-2xx exchange answer means. A 403 says "expired" for a code past
/// its ten minutes, and refuses any other code or verifier.
pub fn exchangeFailure(status: u16, body: []const u8) Error {
    if (status == 403) {
        return if (std.ascii.indexOfIgnoreCase(body, "expired") != null) error.KeyGrantCodeExpired else error.KeyGrantCodeRefused;
    }
    return error.KeyGrantExchangeFailed;
}

/// The key in a 2xx exchange answer, borrowed from `arena`.
pub fn parseExchange(arena: std.mem.Allocator, body: []const u8) Error![]const u8 {
    // Copied into the arena: the caller zeroes the answer, then this copy.
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always }) catch return error.KeyGrantExchangeFailed;
    if (root != .object) return error.KeyGrantExchangeFailed;
    const value = root.object.get("key") orelse return error.KeyGrantExchangeFailed;
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return error.KeyGrantExchangeFailed;
    return value.string;
}

/// What `GET /api/v1/key` said about a key. Strings borrow its arena.
pub const KeyInfo = struct {
    /// The key's short form (`sk-or-v1-0e6...1c96`), not its name: OpenRouter
    /// shows it under the name on its keys page, and this answer has no name.
    label: ?[]const u8 = null,
    limit_usd: ?f64 = null,
    expires_at: ?[]const u8 = null,
    free_tier: ?bool = null,
};

/// Strings are copied into `arena`: the answer they came from may be freed
/// before they are stored.
pub fn parseKeyInfo(arena: std.mem.Allocator, body: []const u8) ?KeyInfo {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always }) catch return null;
    if (root != .object) return null;
    const data = root.object.get("data") orelse return null;
    if (data != .object) return null;
    const object = data.object;
    return .{
        .label = if (object.get("label")) |value| (if (value == .string) value.string else null) else null,
        .limit_usd = if (object.get("limit")) |value| switch (value) {
            .float => |number| if (std.math.isFinite(number) and number >= 0) number else null,
            .integer => |number| if (number >= 0) @floatFromInt(number) else null,
            else => null,
        } else null,
        .expires_at = if (object.get("expires_at")) |value| (if (value == .string) value.string else null) else null,
        .free_tier = if (object.get("is_free_tier")) |value| (if (value == .bool) value.bool else null) else null,
    };
}

/// `<origin><manage_path><sha256 hex of key>`: the page where the key's owner
/// (only they can open it) deletes it. The digest names the key; it is not
/// the key and does not lead back to it.
pub fn manageUrl(allocator: std.mem.Allocator, grant_origin: []const u8, grant: KeyGrant, key: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ grant_origin, grant.manage_path, std.fmt.bytesToHex(digest, .lower) });
}

/// Where to store what the grant hands back.
pub const Target = struct {
    provider_id: Slug,
    provider_label: []const u8,
    kind: provider_profile.CredentialKind,
    state_root: []const u8,
};

/// The loopback way: listen, send the browser to the page, wait for the code
/// (Esc ends the wait within 100 ms through `abort_signal`), then `finish`.
pub fn signInWithBrowser(
    allocator: std.mem.Allocator,
    io: std.Io,
    grant_origin: []const u8,
    grant: KeyGrant,
    target: Target,
    open_browser: bool,
    port: u16,
    abort_signal: ?*const AbortSignal,
    notify: oauth_login.Notify,
) !void {
    var pkce = try auth.generatePkce(allocator);
    defer pkce.deinit(allocator);
    const state = try auth.randomBase64Url(allocator, 32);
    defer auth.secureFree(allocator, state);

    var server = try auth.CallbackServer.bind(port);
    defer server.close();
    const success_page = try std.fmt.allocPrint(allocator, "Signed in to {s}. You can close this tab.", .{target.provider_label});
    defer allocator.free(success_page);
    const denied_page = try std.fmt.allocPrint(allocator, "{s} did not create a key. You can close this tab and return to the terminal.", .{target.provider_label});
    defer allocator.free(denied_page);
    server.success_body = success_page;
    server.denied_body = denied_page;

    const callback_url = try std.fmt.allocPrint(allocator, "http://localhost:{d}{s}", .{ server.port, server.path });
    defer allocator.free(callback_url);
    const url = try authorizeUrl(allocator, grant_origin, grant, pkce.code_challenge, .{ .url = callback_url, .state = state });
    defer allocator.free(url);

    // Opened before the instructions say it was; "if it did not open" covers
    // a launcher that failed quietly.
    if (open_browser) auth.openBrowser(allocator, url) catch {};
    const text = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}\n\n{s} shows this sign-in as \"localhost:{d}\". Approve the new API key there; you can give it a spending limit and an expiry.\n",
        .{
            if (open_browser) "Opened your browser. If it did not open, open this URL:" else "Open this URL to sign in:",
            url,
            target.provider_label,
            server.port,
        },
    );
    defer allocator.free(text);
    notify.say(text);

    const code = server.waitForAuthorizationCode(allocator, state, abort_signal) catch |err| switch (err) {
        error.OAuthAccessDenied => return error.KeyGrantDeclined,
        else => return err,
    };
    defer auth.secureFree(allocator, code);
    try finish(allocator, io, grant_origin, grant, target, code, pkce.code_verifier, abort_signal);
}

/// The other-device way, before the code: the verifier stays here, the page
/// address goes to the user. Owned; `deinit` zeroes the verifier.
pub const Pending = struct {
    allocator: std.mem.Allocator,
    pkce: auth.PkceCodes,
    /// The page to open on any device; it shows the code to paste back.
    url: []u8,

    pub fn begin(allocator: std.mem.Allocator, grant_origin: []const u8, grant: KeyGrant) !Pending {
        var pkce = try auth.generatePkce(allocator);
        errdefer pkce.deinit(allocator);
        const url = try authorizeUrl(allocator, grant_origin, grant, pkce.code_challenge, null);
        return .{ .allocator = allocator, .pkce = pkce, .url = url };
    }

    pub fn verifier(self: *const Pending) []const u8 {
        return self.pkce.code_verifier;
    }

    pub fn deinit(self: *Pending) void {
        self.pkce.deinit(self.allocator);
        self.allocator.free(self.url);
        self.* = undefined;
    }
};

/// Trade `code` and `verifier` for the key, ask the provider about it, and
/// store both. Nothing is stored unless the exchange answered with a key.
pub fn finish(
    allocator: std.mem.Allocator,
    io: std.Io,
    grant_origin: []const u8,
    grant: KeyGrant,
    target: Target,
    code: []const u8,
    verifier: []const u8,
    abort_signal: ?*const AbortSignal,
) !void {
    if (aborted(abort_signal)) return error.Aborted;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exchange_url = try address(arena, grant_origin, grant.exchange_path);
    const body = try exchangeBody(allocator, std.mem.trim(u8, code, " \t\r\n"), verifier);
    defer auth.secureFree(allocator, body);
    const answer = try postJson(allocator, io, exchange_url, body);
    defer auth.secureFree(allocator, answer.body);
    if (answer.status < 200 or answer.status >= 300) return exchangeFailure(answer.status, answer.body);
    const key = try parseExchange(arena, answer.body);

    // What the provider says about the key: a GET it does not bill. A failure
    // here costs the description, never the key.
    var meta: api_key_store.Meta = .{ .obtained = .browser_sign_in };
    const info_url = try address(arena, grant_origin, grant.key_info_path);
    if (catalog_fetch.fetchAnswer(allocator, io, .{ .url = info_url, .bearer = key })) |info_answer| {
        defer allocator.free(info_answer.body);
        if (info_answer.status >= 200 and info_answer.status < 300) {
            if (parseKeyInfo(arena, info_answer.body)) |info| {
                meta.described = true;
                meta.label = if (info.label) |text| try arena.dupe(u8, text) else null;
                meta.limit_usd = info.limit_usd;
                meta.expires_at = if (info.expires_at) |text| try arena.dupe(u8, text) else null;
                meta.free_tier = info.free_tier;
            }
        }
    } else |_| {}

    try api_key_store.saveWithMeta(allocator, target.state_root, target.provider_id, target.kind, key, null, meta, time.nowUnix());
    // The parse tree held the key; the arena is released (unzeroed) next.
    std.crypto.secureZero(u8, @constCast(key));
}

fn aborted(signal: ?*const AbortSignal) bool {
    const value = signal orelse return false;
    return value.isAborted();
}

const Answer = struct {
    status: u16,
    /// Owned by the caller.
    body: []u8,
};

/// `POST` a JSON body, follow no redirect (the body carries the code and the
/// verifier, and only the exchange can answer it), and read the answer
/// whatever its status.
fn postJson(allocator: std.mem.Allocator, io: std.Io, url: []const u8, body: []u8) !Answer {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = http_status.no_redirects,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "accept", .value = "application/json" },
        },
    });
    defer request.deinit();
    try http_connection.sendBodyComplete(&request, body);
    var redirect_buffer: [4096]u8 = undefined;
    const response = try request.receiveHead(&redirect_buffer);
    const status = http_status.ResponseStatus.capture(&response);
    var transfer_buffer: [8192]u8 = undefined;
    const payload = try request.reader.bodyReader(
        &transfer_buffer,
        response.head.transfer_encoding,
        response.head.content_length,
    ).allocRemaining(allocator, std.Io.Limit.limited(256 * 1024));
    return .{ .status = status.code, .body = payload };
}

/// The key `provider_id` has stored now, as its manage page (owned), or null:
/// read before a new sign-in replaces it, so the user can be told the old one
/// still works on the provider's site.
pub fn storedKeyManageUrl(allocator: std.mem.Allocator, state_root: []const u8, provider_id: Slug, grant_origin: []const u8, grant: KeyGrant) ?[]u8 {
    var stored = (api_key_store.load(allocator, state_root, provider_id) catch return null) orelse return null;
    defer stored.deinit();
    return manageUrl(allocator, grant_origin, grant, stored.secret) catch null;
}

/// `Signed in to OpenRouter · key sk-or-v1-0e6...1c96 on your account · no
/// spending limit · never expires`, from what the provider said about the key; just
/// the first part when it said nothing. No newline.
pub fn writeSignedIn(w: *std.Io.Writer, provider_label: []const u8, meta: api_key_store.Meta) std.Io.Writer.Error!void {
    try w.print("Signed in to {s}", .{provider_label});
    try writeDescription(w, meta);
}

/// `Stored the key for OpenRouter · key sk-or-v1-4a2...07fe on your account · …`: a pasted
/// key, described as a sign-in's is. No newline.
pub fn writeStored(w: *std.Io.Writer, provider_label: []const u8, meta: api_key_store.Meta) std.Io.Writer.Error!void {
    try w.print("Stored the key for {s}", .{provider_label});
    try writeDescription(w, meta);
}

/// ` · key sk-or-v1-0e6...1c96 on your account · no spending limit · never
/// expires`, or nothing when the provider said nothing about the key. The key
/// is named by its short form, as the keys page shows it under the key's
/// name, unquoted: it is not a name.
fn writeDescription(w: *std.Io.Writer, meta: api_key_store.Meta) std.Io.Writer.Error!void {
    if (!meta.described) return;
    if (meta.label) |label| {
        try w.print(" · key {s} on your account", .{label});
    } else {
        try w.writeAll(" · a new key on your account");
    }
    if (meta.limit_usd) |limit| {
        try w.print(" · spending limit ${d:.2}", .{limit});
    } else {
        try w.writeAll(" · no spending limit");
    }
    if (meta.expires_at) |when| {
        // The date is enough: "2027-02-16T00:00:00Z" → "2027-02-16".
        try w.print(" · expires {s}", .{when[0..@min(when.len, 10)]});
    } else {
        try w.writeAll(" · never expires");
    }
}

/// The notices that follow a sign-in, one per line, each ending in a newline:
/// an account without paid credits, and the key a previous sign-in left on
/// the provider's site (`previous`, its manage page, when it is not this
/// key's).
pub fn writeAfterSignIn(
    w: *std.Io.Writer,
    provider_label: []const u8,
    grant_origin: []const u8,
    meta: api_key_store.Meta,
    previous: ?[]const u8,
    current: ?[]const u8,
) std.Io.Writer.Error!void {
    if (meta.free_tier orelse false) {
        try w.print("Your {s} account has no credits yet: only free models (:free) answer until you add some at {s}/credits\n", .{ provider_label, grant_origin });
    }
    const old = previous orelse return;
    if (current) |now| if (std.mem.eql(u8, old, now)) return;
    // "May": it may be gone already (deleted on the site, or expired), which
    // only a management key could tell.
    try w.print("The key from your previous sign-in may still work on {s}; delete it there if you no longer need it: {s}\n", .{ provider_label, old });
}

/// `2026-11-18` for a unix time, into `buffer` (at least 10 bytes).
pub fn dateOf(buffer: []u8, unix: i64) []const u8 {
    if (unix < 0) return "an unknown date";
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(unix) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 }) catch "an unknown date";
}

/// `login status`'s account of a stored key: where it is, how it came, and
/// what the provider said about it then. No newline; never the key.
/// `key: /s/keys/openrouter.json, from a browser sign-in on 2026-11-18 · no spending limit · never expires`
pub fn writeKeyStatus(w: *std.Io.Writer, path: []const u8, stored: *const api_key_store.Stored) std.Io.Writer.Error!void {
    var date_buf: [32]u8 = undefined;
    const date = if (stored.stored_at) |at| dateOf(&date_buf, at) else "an unknown date";
    const how = if (stored.meta.obtained) |obtained| switch (obtained) {
        .browser_sign_in => "from a browser sign-in",
        .pasted => "pasted",
    } else "stored";
    try w.print("key: {s}, {s} on {s}", .{ path, how, date });
    if (!stored.meta.described) return;
    if (stored.meta.limit_usd) |limit| {
        try w.print(" · spending limit ${d:.2}", .{limit});
    } else {
        try w.writeAll(" · no spending limit");
    }
    if (stored.meta.expires_at) |when| {
        try w.print(" · expires {s}", .{when[0..@min(when.len, 10)]});
    } else {
        try w.writeAll(" · never expires");
    }
}

/// True in an SSH session, where a loopback redirect lands on the remote
/// machine and the browser that would follow it is on another one.
pub fn sshSession() bool {
    for ([_][*:0]const u8{ "SSH_CONNECTION", "SSH_TTY" }) |name| {
        const value = std.c.getenv(name) orelse continue;
        if (std.mem.span(value).len > 0) return true;
    }
    return false;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const openrouter_profile = @import("../provider/profiles/openrouter.zig");

test "the authorize URL carries the challenge, S256, the label, and a callback with its state when there is one" {
    const a = testing.allocator;
    const grant = openrouter_profile.KEY_GRANT;
    const with_callback = try authorizeUrl(a, grant.origin, grant, "CHALLENGE-x_y", .{ .url = "http://localhost:1456/auth/callback", .state = "st/ate" });
    defer a.free(with_callback);
    try testing.expectEqualStrings(
        "https://openrouter.ai/auth?callback_url=http%3A%2F%2Flocalhost%3A1456%2Fauth%2Fcallback&code_challenge=CHALLENGE-x_y&code_challenge_method=S256&state=st%2Fate&key_label=metacodes",
        with_callback,
    );
    // No OAuth client: OpenRouter has none.
    try testing.expect(std.mem.indexOf(u8, with_callback, "client_id") == null);
    // The other-device way: no callback and no state, the page shows the code.
    const headless = try authorizeUrl(a, grant.origin, grant, "CHALLENGE", null);
    defer a.free(headless);
    try testing.expectEqualStrings("https://openrouter.ai/auth?code_challenge=CHALLENGE&code_challenge_method=S256&key_label=metacodes", headless);
}

test "the exchange body is JSON with the code, the verifier and S256" {
    const a = testing.allocator;
    const body = try exchangeBody(a, "co\"de", "verifier");
    defer a.free(body);
    try testing.expectEqualStrings("{\"code\":\"co\\\"de\",\"code_verifier\":\"verifier\",\"code_challenge_method\":\"S256\"}", body);
}

test "an exchange answer gives the key, and its failures say which" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("sk-or-v1-abc", try parseExchange(arena, "{\"key\":\"sk-or-v1-abc\",\"user_id\":\"user_1\"}"));
    try testing.expectError(error.KeyGrantExchangeFailed, parseExchange(arena, "{\"user_id\":\"user_1\"}"));
    try testing.expectError(error.KeyGrantExchangeFailed, parseExchange(arena, "{\"key\":\"  \"}"));
    try testing.expectError(error.KeyGrantExchangeFailed, parseExchange(arena, "<html></html>"));
    try testing.expectEqual(error.KeyGrantCodeExpired, exchangeFailure(403, "{\"error\":{\"code\":403,\"message\":\"Authorization code expired\"}}"));
    try testing.expectEqual(error.KeyGrantCodeRefused, exchangeFailure(403, "{\"error\":{\"code\":403,\"message\":\"Invalid code or code_verifier\"}}"));
    try testing.expectEqual(error.KeyGrantExchangeFailed, exchangeFailure(400, "{\"error\":{\"code\":400,\"message\":\"Invalid code_challenge_method\"}}"));
    try testing.expectEqual(error.KeyGrantExchangeFailed, exchangeFailure(500, ""));
    var line: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "That code expired (codes last 10 minutes). Run /login openrouter again.",
        failureLine(&line, error.KeyGrantCodeExpired, "OpenRouter", "/login openrouter"),
    );
    try testing.expectEqualStrings(
        "OpenRouter refused the code. Copy it whole from the page that showed it, or start over with metacodes login --provider openrouter.",
        failureLine(&line, error.KeyGrantCodeRefused, "OpenRouter", "metacodes login --provider openrouter"),
    );
    try testing.expectEqualStrings(
        "OpenRouter did not create a key: the request was declined. Nothing was stored.",
        failureLine(&line, error.KeyGrantDeclined, "OpenRouter", "/login openrouter"),
    );
    try testing.expectEqualStrings(
        "Could not reach OpenRouter (ConnectionRefused). Nothing was stored.",
        failureLine(&line, error.ConnectionRefused, "OpenRouter", "/login openrouter"),
    );
}

test "the key's description: label, limit, expiry and free tier, absent or null as none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const full = parseKeyInfo(arena, "{\"data\":{\"label\":\"sk-or-v1-0e6...1c96\",\"limit\":25.5,\"expires_at\":\"2027-02-16T00:00:00Z\",\"is_free_tier\":false,\"usage\":1.2}}").?;
    try testing.expectEqualStrings("sk-or-v1-0e6...1c96", full.label.?);
    try testing.expectEqual(@as(f64, 25.5), full.limit_usd.?);
    try testing.expectEqualStrings("2027-02-16T00:00:00Z", full.expires_at.?);
    try testing.expectEqual(false, full.free_tier.?);
    const bare = parseKeyInfo(arena, "{\"data\":{\"label\":\"sk-or-v1-0e6...1c96\",\"limit\":null,\"expires_at\":null,\"is_free_tier\":true}}").?;
    try testing.expect(bare.limit_usd == null and bare.expires_at == null);
    try testing.expectEqual(true, bare.free_tier.?);
    try testing.expectEqual(@as(f64, 10), parseKeyInfo(arena, "{\"data\":{\"limit\":10}}").?.limit_usd.?);
    try testing.expect(parseKeyInfo(arena, "{\"error\":{}}") == null);
    try testing.expect(parseKeyInfo(arena, "nope") == null);
}

test "the manage page is the origin's key page under the key's SHA-256" {
    const a = testing.allocator;
    const grant = openrouter_profile.KEY_GRANT;
    const url = try manageUrl(a, grant.origin, grant, "sk-or-v1-abc");
    defer a.free(url);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("sk-or-v1-abc", &digest, .{});
    const expected = try std.fmt.allocPrint(a, "https://openrouter.ai/keys/{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer a.free(expected);
    try testing.expectEqualStrings(expected, url);
    try testing.expect(std.mem.indexOf(u8, url, "sk-or-v1-abc") == null);
}

test "the signed-in line says what the provider said about the key, and nothing it did not" {
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeSignedIn(&w, "OpenRouter", .{ .obtained = .browser_sign_in, .described = true, .label = "sk-or-v1-0e6...1c96" });
    try testing.expectEqualStrings("Signed in to OpenRouter · key sk-or-v1-0e6...1c96 on your account · no spending limit · never expires", w.buffered());
    // The short form is not a name: no quotes make it look like one.
    try testing.expect(std.mem.indexOfScalar(u8, w.buffered(), '"') == null);
    w = .fixed(&buffer);
    try writeSignedIn(&w, "OpenRouter", .{ .described = true, .label = "sk-or-v1-0e6...1c96", .limit_usd = 25, .expires_at = "2027-02-16T00:00:00Z" });
    try testing.expectEqualStrings("Signed in to OpenRouter · key sk-or-v1-0e6...1c96 on your account · spending limit $25.00 · expires 2027-02-16", w.buffered());
    // Not described: no claim about limits either way.
    w = .fixed(&buffer);
    try writeSignedIn(&w, "OpenRouter", .{ .obtained = .browser_sign_in });
    try testing.expectEqualStrings("Signed in to OpenRouter", w.buffered());
    // A pasted key, described the same way.
    w = .fixed(&buffer);
    try writeStored(&w, "OpenRouter", .{ .obtained = .pasted, .described = true, .label = "sk-or-v1-4a2...07fe", .limit_usd = 5 });
    try testing.expectEqualStrings("Stored the key for OpenRouter · key sk-or-v1-4a2...07fe on your account · spending limit $5.00 · never expires", w.buffered());

    w = .fixed(&buffer);
    try writeAfterSignIn(&w, "OpenRouter", "https://openrouter.ai", .{ .described = true, .free_tier = true }, "https://openrouter.ai/keys/aa", "https://openrouter.ai/keys/bb");
    try testing.expectEqualStrings(
        "Your OpenRouter account has no credits yet: only free models (:free) answer until you add some at https://openrouter.ai/credits\n" ++
            "The key from your previous sign-in may still work on OpenRouter; delete it there if you no longer need it: https://openrouter.ai/keys/aa\n",
        w.buffered(),
    );
    // The same key again (a pasted key re-stored): nothing to delete.
    w = .fixed(&buffer);
    try writeAfterSignIn(&w, "OpenRouter", "https://openrouter.ai", .{}, "https://openrouter.ai/keys/aa", "https://openrouter.ai/keys/aa");
    try testing.expectEqualStrings("", w.buffered());
}

test "login status says where a stored key came from, when, and what the provider said about it" {
    var date_buf: [16]u8 = undefined;
    try testing.expectEqualStrings("2026-11-18", dateOf(&date_buf, 1_795_000_000 - 1_795_000_000 % 86_400));
    try testing.expectEqualStrings("1970-01-01", dateOf(&date_buf, 0));
    var secret = "sk-or-v1-x".*;
    var stored: api_key_store.Stored = .{
        .allocator = testing.allocator,
        .kind = .api_key,
        .secret = &secret,
        .meta = .{ .obtained = .browser_sign_in, .described = true, .label = "sk-or-v1-0e6...1c96" },
        .stored_at = 1_795_000_000,
    };
    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeKeyStatus(&w, "/s/keys/openrouter.json", &stored);
    try testing.expectEqualStrings("key: /s/keys/openrouter.json, from a browser sign-in on 2026-11-18 · no spending limit · never expires", w.buffered());
    stored.meta = .{};
    stored.stored_at = null;
    w = .fixed(&buffer);
    try writeKeyStatus(&w, "/s/keys/openrouter.json", &stored);
    try testing.expectEqualStrings("key: /s/keys/openrouter.json, stored on an unknown date", w.buffered());
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "sk-or") == null);
}

test "the origin override takes https, or plain http to a loopback host, and nothing else" {
    try testing.expect(originAccepted("https://openrouter.ai"));
    try testing.expect(originAccepted("https://or.example.test:8443"));
    try testing.expect(originAccepted("http://127.0.0.1:9123"));
    try testing.expect(originAccepted("http://localhost"));
    try testing.expect(originAccepted("http://[::1]:8080"));
    try testing.expect(!originAccepted("http://example.com"));
    try testing.expect(!originAccepted("http://localhost.example.com"));
    try testing.expect(!originAccepted("http://127.0.0.1.example.com:80"));
    try testing.expect(!originAccepted("https://openrouter.ai/api"));
    try testing.expect(!originAccepted("https://user@openrouter.ai"));
    try testing.expect(!originAccepted("ftp://127.0.0.1"));
    try testing.expect(!originAccepted("https://"));
}
