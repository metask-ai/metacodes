//! Metask credential storage and request credential resolution.
//!
//! Supports API-key auth plus Metask OAuth. The primary OAuth path is a
//! browser-based authorization-code + PKCE flow with a short-lived loopback
//! callback server. The token JSON import path remains for headless CI and
//! recovery.
//!
//! Metask's own resolution and storage stay here byte for byte. The PKCE,
//! loopback-callback, authorize-URL and form-encoding primitives are exported
//! because `api/oauth_login.zig` runs the same RFC 6749 flow for other
//! providers (issue #33); one implementation of state validation and redirect
//! parsing is worth more than a second copy that can drift from it.

const std = @import("std");
const tt = @import("../tools/test_tmp.zig"); // 测试 fixture 唯一路径(并发隔离)
const rng = @import("platform").rng;
const process = @import("platform").process;
const pfs = @import("platform").fs;
const net = @import("platform").net;
const sync = @import("platform").sync;
const builtin = @import("builtin");
const fs_util = @import("../util/fs.zig");
const time = @import("../util/time.zig");
const types = @import("../types.zig");
const ResponseStatus = @import("../api/http_status.zig").ResponseStatus;
const no_redirects = @import("../api/http_status.zig").no_redirects;
const http_connection = @import("../api/http_connection.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const util_json = @import("../util/json.zig");

pub const METASK_API_KEY_ENV = "METASK_API_KEY";
pub const RUNTIME_API_KEY_FD_ENV = "METACODES_API_KEY_FD";
pub const AUTH_FILE_ENV = "METACODES_AUTH_FILE";
pub const OAUTH_TOKEN_URL_ENV = "METACODE_OAUTH_TOKEN_URL";
pub const OAUTH_AUTHORIZE_URL_ENV = "METACODE_OAUTH_AUTHORIZE_URL";
pub const OAUTH_CLIENT_ID_ENV = "METACODE_OAUTH_CLIENT_ID";
pub const OAUTH_SCOPE_ENV = "METACODE_OAUTH_SCOPE";
/// Metask's OAuth authorization server (#527): its
/// `/.well-known/oauth-authorization-server` names these endpoints, and the
/// gateway its tokens are for is on the same host.
pub const METASK_SITE_URL = "https://www.metask-ai.com";
pub const METASK_OAUTH_TOKEN_URL = METASK_SITE_URL ++ "/api/oauth/token";
pub const METASK_OAUTH_AUTHORIZE_URL = METASK_SITE_URL ++ "/oauth/authorize";
/// The public client registered for metacodes there, used by the browser and
/// the device-code sign-in alike.
pub const OAUTH_CLIENT_ID = "metacodes";
/// Without a scope the server grants `read` only, which cannot call models.
pub const METASK_OAUTH_SCOPE = "read model:invoke";
/// The loopback path registered for `metacodes`; any port is accepted.
pub const METASK_CALLBACK_PATH = "/auth/metask/callback";
/// Where an OAuth sign-in kept in `auth.json` is refreshed. Since #527 the
/// sign-in is the Metask session (`oauth/metask.json`) and nothing writes one
/// here, so one found here came from an earlier version's browser sign-in:
/// napi.metask-ai.com issued it to the client `metacode-cli`, and only that
/// server can refresh it. Metask keeps that server through the move to www,
/// so such a sign-in keeps working until the next `/login` replaces it.
pub const LEGACY_OAUTH_TOKEN_URL = "https://napi.metask-ai.com/oauth/token";
pub const LEGACY_OAUTH_CLIENT_ID = "metacode-cli";
const OAUTH_REFRESH_SKEW_SECONDS: i64 = 300;
const DEFAULT_LOGIN_PORT: u16 = 1455;
const FALLBACK_LOGIN_PORT: u16 = 1457;
pub const LOGIN_CALLBACK_TIMEOUT_ENV = "METACODES_LOGIN_CALLBACK_TIMEOUT_MS";
pub const DEFAULT_LOGIN_CALLBACK_TIMEOUT_MS: u64 = 10 * std.time.ms_per_min;

pub fn sshSession() bool {
    for ([_][*:0]const u8{ "SSH_CONNECTION", "SSH_TTY" }) |name| {
        const value = std.c.getenv(name) orelse continue;
        if (std.mem.span(value).len > 0) return true;
    }
    return false;
}

pub fn sshForwardLine(buffer: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buffer, "Over SSH? Forward the port first: ssh -L {d}:127.0.0.1:{d} <you>@<this machine>\n", .{ port, port }) catch
        "Over SSH? Forward the callback port to this machine with ssh -L first.\n";
}

pub const PasteRefusal = enum { not_an_address, other_page, other_sign_in, no_code, refused };

pub const PasteSource = struct {
    ctx: *anyopaque,
    take: *const fn (ctx: *anyopaque, out: []u8) ?[]const u8,
    refused: *const fn (ctx: *anyopaque, why: PasteRefusal) void,
    prompt: ?[]const u8 = null,
};

pub const PASTE_PROMPT = "Browser on another computer? Once you sign in there, it ends on a page that does not load: paste that page's address here and press Enter.\n";

pub fn pasteRefusalText(why: PasteRefusal) []const u8 {
    return switch (why) {
        .not_an_address => "That is not an address. Paste the whole address the browser ended on (it starts with http://localhost).",
        .other_page => "That is not this sign-in's page. Paste the address the browser ended on after you signed in.",
        .other_sign_in => "That address is from another sign-in. Paste the address from this sign-in's page.",
        .no_code => "That address carries no code. Paste the address the browser ended on after you signed in.",
        .refused => "The sign-in was refused on that page. Sign in again in the browser, then paste the new address.",
    };
}

pub fn pastedRequest(buffer: []u8, pasted: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, pasted, " \t\r\n\"'<>");
    if (text.len == 0) return null;
    const after_scheme = if (std.mem.indexOf(u8, text, "://")) |at| text[at + 3 ..] else text;
    const slash = std.mem.indexOfScalar(u8, after_scheme, '/') orelse return null;
    const with_fragment = after_scheme[slash..];
    const target = with_fragment[0 .. std.mem.indexOfScalar(u8, with_fragment, '#') orelse with_fragment.len];
    if (std.mem.indexOfAny(u8, target, " \t\r\n") != null) return null;
    return std.fmt.bufPrint(buffer, "GET {s} HTTP/1.1\r\n\r\n", .{target}) catch null;
}

pub const PasteBox = struct {
    mutex: sync.Mutex = .{},
    text: [4096]u8 = undefined,
    len: usize = 0,
    pending: bool = false,
    last_refusal: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn submit(self: *PasteBox, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(text.len, self.text.len);
        @memcpy(self.text[0..n], text[0..n]);
        self.len = n;
        self.pending = true;
        self.last_refusal.store(0, .release);
    }

    pub fn refusal(self: *const PasteBox) ?PasteRefusal {
        const raw = self.last_refusal.load(.acquire);
        return if (raw == 0) null else @enumFromInt(raw - 1);
    }

    pub fn source(self: *PasteBox) PasteSource {
        return .{ .ctx = self, .take = take, .refused = refused };
    }

    fn take(ctx: *anyopaque, out: []u8) ?[]const u8 {
        const self: *PasteBox = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.pending) return null;
        self.pending = false;
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.text[0..n]);
        return out[0..n];
    }

    fn refused(ctx: *anyopaque, why: PasteRefusal) void {
        const self: *PasteBox = @ptrCast(@alignCast(ctx));
        self.last_refusal.store(@as(u8, @intFromEnum(why)) + 1, .release);
    }
};

pub fn loginCallbackTimeoutMs() ?u64 {
    const raw = std.c.getenv(LOGIN_CALLBACK_TIMEOUT_ENV) orelse return DEFAULT_LOGIN_CALLBACK_TIMEOUT_MS;
    const value = std.fmt.parseInt(u64, std.mem.span(raw), 10) catch return DEFAULT_LOGIN_CALLBACK_TIMEOUT_MS;
    return if (value == 0) null else value;
}

pub const AuthPrecedence = types.AuthPrecedence;

pub fn parsePrecedence(s: []const u8) ?AuthPrecedence {
    if (std.mem.eql(u8, s, "api-key-first") or std.mem.eql(u8, s, "api_key_first")) return .api_key_first;
    if (std.mem.eql(u8, s, "oauth-first") or std.mem.eql(u8, s, "oauth_first")) return .oauth_first;
    return null;
}

pub const CredentialSource = enum {
    cli_api_key,
    fd_api_key,
    env_api_key,
    stored_api_key,
    stored_oauth,
};

pub const ResolvedCredential = struct {
    bearer_token: []u8,
    source: CredentialSource,
    /// A consumed runtime descriptor is kept open at EOF for the session so
    /// its stale environment number cannot be reused for another descriptor.
    /// CLOEXEC prevents every later tool/process boundary from inheriting it.
    spent_runtime_fd: ?pfs.Fd = null,

    pub fn deinit(self: *ResolvedCredential, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.bearer_token);
        if (self.spent_runtime_fd) |fd| _ = pfs.close(fd);
        self.* = undefined;
    }
};

pub const OAuthCredential = struct {
    access_token: []u8,
    refresh_token: []u8,
    token_type: []const u8 = "Bearer",
    expires_at: i64,
    scope: ?[]u8 = null,
    account_id: ?[]u8 = null,
    profile: ?[]u8 = null,

    pub fn deinit(self: *OAuthCredential, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.access_token);
        secureFree(allocator, self.refresh_token);
        if (self.scope) |v| allocator.free(v);
        if (self.account_id) |v| allocator.free(v);
        if (self.profile) |v| allocator.free(v);
        self.* = undefined;
    }
};

pub const StoredCredentials = struct {
    api_key: ?[]u8 = null,
    oauth: ?OAuthCredential = null,
    selected_model: ?[]u8 = null,
    reasoning_effort: ?types.ReasoningEffort = null,

    pub fn deinit(self: *StoredCredentials, allocator: std.mem.Allocator) void {
        if (self.api_key) |k| secureFree(allocator, k);
        if (self.oauth) |*o| o.deinit(allocator);
        if (self.selected_model) |m| allocator.free(m);
        self.* = .{};
    }

    /// An independent copy for staging a replacement while keeping the
    /// previous credentials available for rollback. Secret buffers are copied.
    pub fn clone(self: *const StoredCredentials, allocator: std.mem.Allocator) !StoredCredentials {
        var out = StoredCredentials{ .reasoning_effort = self.reasoning_effort };
        errdefer out.deinit(allocator);
        if (self.api_key) |value| out.api_key = try allocator.dupe(u8, value);
        if (self.oauth) |value| {
            out.oauth = blk: {
                const access = try allocator.dupe(u8, value.access_token);
                errdefer secureFree(allocator, access);
                const refresh = try allocator.dupe(u8, value.refresh_token);
                errdefer secureFree(allocator, refresh);
                break :blk .{
                    .access_token = access,
                    .refresh_token = refresh,
                    .token_type = value.token_type,
                    .expires_at = value.expires_at,
                };
            };
            if (value.scope) |text| out.oauth.?.scope = try allocator.dupe(u8, text);
            if (value.account_id) |text| out.oauth.?.account_id = try allocator.dupe(u8, text);
            if (value.profile) |text| out.oauth.?.profile = try allocator.dupe(u8, text);
        }
        if (self.selected_model) |value| out.selected_model = try allocator.dupe(u8, value);
        return out;
    }

    /// What a Metask browser sign-in leaves here (#527): the model and
    /// reasoning level chosen. The sign-in itself is the Metask session, so
    /// a key or an older sign-in held here goes: left here it would outrank
    /// the session at the next start. The model is copied before anything is
    /// freed, so a copy that fails leaves the credentials whole.
    pub fn recordSessionChoice(self: *StoredCredentials, allocator: std.mem.Allocator, model: []const u8, effort: ?types.ReasoningEffort) error{OutOfMemory}!void {
        const model_copy = try allocator.dupe(u8, model);
        if (self.selected_model) |old| allocator.free(old);
        self.selected_model = model_copy;
        self.reasoning_effort = effort;
        if (self.api_key) |old| secureFree(allocator, old);
        self.api_key = null;
        if (self.oauth) |*old| old.deinit(allocator);
        self.oauth = null;
    }
};

/// `METACODES_AUTH_FILE`, else `<state_root>/auth.json`. An empty state root
/// (the host has none) is `error.NoHome`.
pub fn authFilePath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    if (std.c.getenv(AUTH_FILE_ENV)) |p| return allocator.dupe(u8, std.mem.span(p));
    if (state_root.len == 0) return error.NoHome;
    return std.fs.path.join(allocator, &.{ state_root, "auth.json" });
}

pub fn resolveCredential(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    cli_api_key: ?[]const u8,
    precedence: AuthPrecedence,
) !ResolvedCredential {
    return resolveCredentialWithEnvFallback(allocator, state_root, cli_api_key, precedence, null);
}

/// `resolveCredential` for a host that keeps a layer below the process
/// environment (the CLI's `<state root>/.env`, #486). `env_fallback_api_key`
/// is `METASK_API_KEY` in that layer: it counts as the environment variable,
/// and only when the process environment leaves that unset.
pub fn resolveCredentialWithEnvFallback(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    cli_api_key: ?[]const u8,
    precedence: AuthPrecedence,
    env_fallback_api_key: ?[]const u8,
) !ResolvedCredential {
    const env_api_key = if (std.c.getenv(METASK_API_KEY_ENV)) |v| std.mem.span(v) else env_fallback_api_key;
    const path = authFilePath(allocator, state_root) catch |err| switch (err) {
        error.NoHome => null,
        else => return err,
    };
    defer if (path) |p| allocator.free(p);
    var stored = if (path) |p| loadFromPath(allocator, p) catch |err| switch (err) {
        error.NotFound => StoredCredentials{},
        else => return err,
    } else StoredCredentials{};
    defer stored.deinit(allocator);

    if (precedence == .oauth_first) {
        if (try credentialFromStoredOAuth(allocator, &stored, path)) |c| return c;
        if (cli_api_key) |k| return credentialFromApiKey(allocator, k, .cli_api_key);
        if (env_api_key) |k| return credentialFromApiKey(allocator, k, .env_api_key);
    } else {
        if (cli_api_key) |k| return credentialFromApiKey(allocator, k, .cli_api_key);
        if (env_api_key) |k| return credentialFromApiKey(allocator, k, .env_api_key);
        if (stored.api_key) |k| return credentialFromApiKey(allocator, k, .stored_api_key);
        if (try credentialFromStoredOAuth(allocator, &stored, path)) |c| return c;
    }

    if (stored.api_key) |k| return credentialFromApiKey(allocator, k, .stored_api_key);
    return error.MissingCredentials;
}

/// Runtime-only credential boundary.
///
/// The one-shot FD authority is consumed before App/tool threads exist. An
/// ambient METASK_API_KEY alongside it is rejected as ambiguous before App
/// initialization; mutating libc's borrowed startup environment is forbidden.
/// Ordinary env-based sessions preserve their historical inheritance semantics
/// because detached teammate processes still authenticate through the inherited
/// environment. Production evaluation never uses that path: its parent supplies
/// only the FD inside a minimal child environment.
pub fn resolveRuntimeCredential(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    cli_api_key: ?[]const u8,
    precedence: AuthPrecedence,
) !ResolvedCredential {
    return resolveRuntimeCredentialWithEnvFallback(allocator, state_root, cli_api_key, precedence, null);
}

/// `resolveRuntimeCredential` with the host's layer below the process
/// environment (`resolveCredentialWithEnvFallback`).
pub fn resolveRuntimeCredentialWithEnvFallback(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    cli_api_key: ?[]const u8,
    precedence: AuthPrecedence,
    env_fallback_api_key: ?[]const u8,
) !ResolvedCredential {
    var fd_api_key = try takeRuntimeFdApiKey(allocator);
    defer if (fd_api_key) |*runtime| runtime.deinit(allocator);
    if (cli_api_key != null and fd_api_key != null) return error.AmbiguousRuntimeCredentials;
    // Never mutate libc's environment after Zig 0.16 has captured its startup
    // pointer block: HTTPS lazily scans that borrowed block while loading the
    // CA bundle, and unsetenv can otherwise turn it into a use-after-free.
    // An ambient key alongside FD authority is rejected and the process exits,
    // instead of trying to scrub the second channel in place. A key in the
    // layer below the environment is a second channel too: a teammate this
    // process starts reads the same file.
    if (fd_api_key != null and (std.c.getenv(METASK_API_KEY_ENV) != null or env_fallback_api_key != null)) {
        return error.AmbiguousRuntimeCredentials;
    }

    // An inherited FD is an explicit runtime authority, not another candidate
    // in the stored OAuth/API-key preference chain. In particular,
    // `oauth_first` must not silently discard the one-shot pilot credential.
    var credential = if (fd_api_key) |runtime|
        try credentialFromApiKey(allocator, runtime.bytes, .fd_api_key)
    else
        try resolveCredentialWithEnvFallback(allocator, state_root, cli_api_key, precedence, env_fallback_api_key);
    errdefer credential.deinit(allocator);
    if (fd_api_key) |*runtime| {
        credential.spent_runtime_fd = runtime.fd;
        runtime.fd = pfs.invalid_fd;
    }
    return credential;
}

const MAX_RUNTIME_API_KEY_BYTES: usize = 16 * 1024;

/// Consume a credential from an inherited descriptor without ever placing the
/// secret in argv or the process's initial environment. The descriptor number
/// itself arrives through RUNTIME_API_KEY_FD_ENV. Zig 0.16 borrows the initial
/// POSIX environment block, so the variable is deliberately not removed in
/// place. Instead the descriptor is drained, marked CLOEXEC, and held open at
/// EOF until `ResolvedCredential.deinit`; the stale number carries no secret
/// and cannot alias a later descriptor or cross an exec boundary.
const RuntimeFdApiKey = struct {
    bytes: []u8,
    fd: pfs.Fd,

    fn deinit(self: *RuntimeFdApiKey, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.bytes);
        if (self.fd >= 0) _ = pfs.close(self.fd);
        self.* = undefined;
    }
};

fn takeRuntimeFdApiKey(allocator: std.mem.Allocator) !?RuntimeFdApiKey {
    const raw = std.c.getenv(RUNTIME_API_KEY_FD_ENV) orelse return null;
    const raw_fd = std.mem.span(raw);
    const fd = std.fmt.parseInt(pfs.Fd, raw_fd, 10) catch return error.InvalidCredentialFd;
    if (fd < 3) return error.InvalidCredentialFd;
    errdefer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);

    var bytes = std.ArrayList(u8).empty;
    errdefer {
        // Failure paths (oversize, read failure, OOM) may already hold a
        // credential prefix. Do not return that prefix to the allocator
        // without first erasing it.
        @memset(bytes.items, 0);
        bytes.deinit(allocator);
    }
    var chunk: [1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(fd, &chunk) catch return error.CredentialFdReadFailed;
        if (count == 0) break;
        if (bytes.items.len > MAX_RUNTIME_API_KEY_BYTES -| count) {
            return error.CredentialFdTooLarge;
        }
        try bytes.appendSlice(allocator, chunk[0..count]);
    }
    if (bytes.items.len == 0) return error.MissingCredentials;
    return .{ .bytes = try bytes.toOwnedSlice(allocator), .fd = fd };
}

fn credentialFromApiKey(allocator: std.mem.Allocator, key_raw: []const u8, source: CredentialSource) !ResolvedCredential {
    const key = std.mem.trim(u8, key_raw, " \t\r\n");
    if (key.len == 0) return error.MissingCredentials;
    return .{ .bearer_token = try allocator.dupe(u8, key), .source = source };
}

fn credentialFromStoredOAuth(
    allocator: std.mem.Allocator,
    stored: *StoredCredentials,
    path: ?[]const u8,
) !?ResolvedCredential {
    if (stored.oauth) |*o| {
        if (!std.ascii.eqlIgnoreCase(o.token_type, "Bearer")) return error.UnsupportedTokenType;
        if (o.access_token.len == 0) return error.InvalidCredentials;
        if (o.refresh_token.len == 0) return error.InvalidCredentials;
        if (o.expires_at <= nowUnixSeconds() + OAUTH_REFRESH_SKEW_SECONDS) {
            const save_path = path orelse return error.NoHome;
            var refreshed: ?OAuthCredential = try refreshOAuthCredential(allocator, o);
            errdefer if (refreshed) |*r| r.deinit(allocator);
            try saveToPath(allocator, save_path, .{
                .api_key = stored.api_key,
                .oauth = refreshed.?,
                .selected_model = stored.selected_model,
                .reasoning_effort = stored.reasoning_effort,
            });
            o.deinit(allocator);
            stored.oauth = refreshed.?;
            refreshed = null;
        }
    } else return null;
    return .{ .bearer_token = try allocator.dupe(u8, stored.oauth.?.access_token), .source = .stored_oauth };
}

pub fn resolveStoredOAuthBearer(allocator: std.mem.Allocator, state_root: []const u8) !?[]u8 {
    const path = authFilePath(allocator, state_root) catch |err| switch (err) {
        error.NoHome => return null,
        else => return err,
    };
    defer allocator.free(path);
    var stored = loadFromPath(allocator, path) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer stored.deinit(allocator);
    const credential = (try credentialFromStoredOAuth(allocator, &stored, path)) orelse return null;
    return credential.bearer_token;
}

pub fn loadDefault(allocator: std.mem.Allocator, state_root: []const u8) !StoredCredentials {
    const path = try authFilePath(allocator, state_root);
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !StoredCredentials {
    try checkFilePrivate(path);
    const content = try readFileAlloc(allocator, path);
    defer secureFree(allocator, content);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    return parseStoredCredentials(allocator, parsed.value);
}

pub fn saveDefault(allocator: std.mem.Allocator, state_root: []const u8, creds: StoredCredentials) !void {
    const path = try authFilePath(allocator, state_root);
    defer allocator.free(path);
    try saveToPath(allocator, path, creds);
}

pub fn saveToPath(allocator: std.mem.Allocator, path: []const u8, creds: StoredCredentials) !void {
    if (std.fs.path.dirname(path)) |dir| try fs_util.mkdirParents(dir);
    const json = try serializeStoredCredentials(allocator, creds);
    defer secureFree(allocator, json);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    _ = pfs.chmod(path_z.ptr, 0o600);
    const n = pfs.write(fd, json);
    if (n < 0 or @as(usize, @intCast(n)) != json.len) return error.WriteFailed;
}

pub fn clearDefault(allocator: std.mem.Allocator, state_root: []const u8) !void {
    const path = try authFilePath(allocator, state_root);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    // 宽字符删除(Windows DeleteFileW;#121)。已经不存在 = 目标状态达成,不算失败;其它失败
    // (EACCES、共享冲突)如实上报——不能靠事后 exists() 猜,父目录不可搜索时它同样失败。
    pfs.unlinkPath(path_z.ptr) catch |err| switch (err) {
        error.NotFound => return,
        error.UnlinkFailed => return error.UnlinkFailed,
    };
}

pub fn importOAuthTokenResponse(allocator: std.mem.Allocator, body: []const u8, now_seconds: i64) !StoredCredentials {
    return .{ .oauth = try parseOAuthTokenResponse(allocator, body, now_seconds, .required, null) };
}

pub const BrowserLoginOptions = struct {
    open_browser: bool = true,
    port: u16 = DEFAULT_LOGIN_PORT,
    force_state: ?[]const u8 = null,
    /// Checked while the callback is awaited (`error.Aborted`): `/login`'s
    /// Esc (#485). Null waits for the browser for as long as it takes.
    abort_signal: ?*const AbortSignal = null,
    /// Where the instructions go (the URL to open). Null prints them to
    /// stderr, as `metacodes login` always has; the TUI draws them instead.
    notify: ?Notify = null,
    timeout_ms: ?u64 = null,
    paste: ?PasteSource = null,
};

/// A sink for the lines the user must act on, shaped like
/// `api/oauth_login.zig`'s (that file is outside the MCP client's import
/// boundary, which reaches this one).
pub const Notify = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub fn loginWithBrowser(allocator: std.mem.Allocator, opts: BrowserLoginOptions) !StoredCredentials {
    const token_body = try loginWithBrowserTokenJson(allocator, opts);
    defer secureFree(allocator, token_body);
    return importOAuthTokenResponse(allocator, token_body, nowUnixSeconds());
}

/// The browser sign-in up to the token endpoint's answer, returned as it
/// came (owned; secret, so zero it before freeing). Metask's answer names
/// the gateway its tokens are for (`gateway_url`, `models_url`), which
/// `auth.json` has no place for: `/login` and `metacodes login` store it as
/// the Metask session (`provider_login.importTokenResponse`, #527).
pub fn loginWithBrowserTokenJson(allocator: std.mem.Allocator, opts: BrowserLoginOptions) ![]u8 {
    var pkce = try generatePkce(allocator);
    defer pkce.deinit(allocator);
    const state = if (opts.force_state) |s| try allocator.dupe(u8, s) else try randomBase64Url(allocator, 32);
    defer secureFree(allocator, state);

    var server = try CallbackServer.bind(opts.port);
    defer server.close();
    server.path = METASK_CALLBACK_PATH;
    if (opts.timeout_ms) |ms| server.deadline_ms = time.nowMs() +| @as(time.Millis, @intCast(@min(ms, std.math.maxInt(time.Millis))));
    server.paste = opts.paste;
    var refusal: Refusal = .{};
    server.refusal = &refusal;

    const redirect_uri = try std.fmt.allocPrint(allocator, "http://localhost:{d}{s}", .{ server.port, METASK_CALLBACK_PATH });
    defer allocator.free(redirect_uri);
    const authorize_url = try buildAuthorizeUrlFromEnv(allocator, redirect_uri, pkce.code_challenge, state);
    defer allocator.free(authorize_url);

    var line_buf: [512]u8 = undefined;
    say(opts.notify, std.fmt.bufPrint(&line_buf, "Starting local login server on http://localhost:{d}.\nOpen this URL to authenticate:\n\n", .{server.port}) catch "Open this URL to authenticate:\n\n");
    say(opts.notify, authorize_url);
    say(opts.notify, "\n\n");
    if (sshSession()) say(opts.notify, sshForwardLine(&line_buf, server.port));
    if (opts.paste) |source| if (source.prompt) |prompt| say(opts.notify, prompt);
    if (opts.open_browser) openBrowser(allocator, authorize_url) catch |err| {
        say(opts.notify, std.fmt.bufPrint(&line_buf, "Could not open browser automatically: {s}\n", .{@errorName(err)}) catch "Could not open the browser automatically.\n");
    };

    const code = server.waitForAuthorizationCode(allocator, state, opts.abort_signal) catch |err| {
        if (err == error.OAuthAccessDenied) say(opts.notify, refusal.line(&line_buf));
        return err;
    };
    defer secureFree(allocator, code);
    if (opts.abort_signal) |signal| if (signal.isAborted()) return error.Aborted;
    return exchangeAuthorizationCode(allocator, code, redirect_uri, pkce.code_verifier);
}

/// `text` to `notify`, or to stderr when there is none (the CLI).
fn say(notify: ?Notify, text: []const u8) void {
    if (notify) |sink| sink.write(sink.ctx, text) else std.debug.print("{s}", .{text});
}

pub const PkceCodes = struct {
    code_verifier: []u8,
    code_challenge: []u8,

    pub fn deinit(self: *PkceCodes, allocator: std.mem.Allocator) void {
        secureFree(allocator, self.code_verifier);
        secureFree(allocator, self.code_challenge);
        self.* = undefined;
    }
};

pub fn generatePkce(allocator: std.mem.Allocator) !PkceCodes {
    const verifier = try randomBase64Url(allocator, 64);
    errdefer secureFree(allocator, verifier);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(digest.len);
    const challenge = try allocator.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(challenge, &digest);
    return .{ .code_verifier = verifier, .code_challenge = challenge };
}

pub fn randomBase64Url(allocator: std.mem.Allocator, nbytes: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, nbytes);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    if (!rng.randomBytes(bytes[0..nbytes])) return error.RandomFailed;
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(nbytes);
    const out = try allocator.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
    return out;
}

pub fn buildAuthorizeUrlForTest(
    allocator: std.mem.Allocator,
    authorize_url: []const u8,
    client_id: []const u8,
    scope: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    return buildAuthorizeUrl(allocator, authorize_url, client_id, scope, redirect_uri, code_challenge, state);
}

fn buildAuthorizeUrlFromEnv(
    allocator: std.mem.Allocator,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    const authorize_url = if (std.c.getenv(OAUTH_AUTHORIZE_URL_ENV)) |v| std.mem.span(v) else METASK_OAUTH_AUTHORIZE_URL;
    const client_id = if (std.c.getenv(OAUTH_CLIENT_ID_ENV)) |v| std.mem.span(v) else OAUTH_CLIENT_ID;
    const scope = if (std.c.getenv(OAUTH_SCOPE_ENV)) |v| std.mem.span(v) else METASK_OAUTH_SCOPE;
    return buildAuthorizeUrl(allocator, authorize_url, client_id, scope, redirect_uri, code_challenge, state);
}

pub fn buildAuthorizeUrl(
    allocator: std.mem.Allocator,
    authorize_url: []const u8,
    client_id: []const u8,
    scope: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    const none: []const struct { name: []const u8, value: []const u8 } = &.{};
    return buildAuthorizeUrlWith(allocator, authorize_url, client_id, scope, redirect_uri, code_challenge, state, none);
}

/// `buildAuthorizeUrl`, then `extra` in order, each value URL-encoded:
/// a slice of anything with `name` and `value` (`profile.OAuthParam`).
pub fn buildAuthorizeUrlWith(
    allocator: std.mem.Allocator,
    authorize_url: []const u8,
    client_id: []const u8,
    scope: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
    extra: anytype,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll(authorize_url);
    try aw.writer.writeByte(if (std.mem.indexOfScalar(u8, authorize_url, '?') == null) '?' else '&');
    try appendFormField(&aw.writer, "response_type", "code", true);
    try appendFormField(&aw.writer, "client_id", client_id, false);
    try appendFormField(&aw.writer, "redirect_uri", redirect_uri, false);
    if (scope.len > 0) try appendFormField(&aw.writer, "scope", scope, false);
    try appendFormField(&aw.writer, "code_challenge", code_challenge, false);
    try appendFormField(&aw.writer, "code_challenge_method", "S256", false);
    try appendFormField(&aw.writer, "state", state, false);
    for (extra) |param| try appendFormField(&aw.writer, param.name, param.value, false);
    return try aw.toOwnedSlice();
}

/// What the authorization server sent the browser back with instead of a
/// code (RFC 6749 §4.1.2.1): its `error` and `error_description`, decoded,
/// flattened to printable ASCII and cut to fit. They come from the server and
/// are shown to the user, never parsed further.
pub const Refusal = struct {
    code_buf: [64]u8 = undefined,
    code_len: usize = 0,
    description_buf: [256]u8 = undefined,
    description_len: usize = 0,

    pub fn code(self: *const Refusal) []const u8 {
        return self.code_buf[0..self.code_len];
    }

    pub fn description(self: *const Refusal) []const u8 {
        return self.description_buf[0..self.description_len];
    }

    pub fn line(self: *const Refusal, buffer: []u8) []const u8 {
        const text = if (self.description_len > 0)
            std.fmt.bufPrint(buffer, "The sign-in was refused: {s} ({s}).\n", .{ self.code(), self.description() })
        else
            std.fmt.bufPrint(buffer, "The sign-in was refused: {s}.\n", .{self.code()});
        return text catch "The sign-in was refused.\n";
    }

    fn fill(self: *Refusal, allocator: std.mem.Allocator, query: []const u8) void {
        self.code_len = copyParam(allocator, query, "error", &self.code_buf);
        self.description_len = copyParam(allocator, query, "error_description", &self.description_buf);
    }

    fn copyParam(allocator: std.mem.Allocator, query: []const u8, name: []const u8, out: []u8) usize {
        const raw = findQueryParam(query, name) orelse return 0;
        const decoded = percentDecode(allocator, raw) catch return 0;
        defer allocator.free(decoded);
        var len: usize = 0;
        for (decoded) |byte| {
            if (len == out.len) break;
            out[len] = if (byte >= 0x20 and byte < 0x7f) byte else ' ';
            len += 1;
        }
        return len;
    }
};

pub const CallbackServer = struct {
    sock: net.Socket,
    port: u16,
    /// The redirect URI's path. MCP logins use Claude Code's `/callback`,
    /// so a client registered for Claude Code's redirect works here too.
    path: []const u8 = "/auth/callback",
    /// What the browser is told once the code has arrived.
    success_body: []const u8 = "Metacodes login complete. You can close this tab.",
    /// When set, a callback on `path` that carries an `error` ends the wait
    /// with `error.OAuthAccessDenied` and this page, whether or not it
    /// carries the state: OpenRouter sends a refusal back without one, and
    /// the sign-in would otherwise wait on a tab that says "State mismatch".
    /// Such a callback can only end the wait; a code still needs the state.
    denied_body: ?[]const u8 = null,
    /// When set, a callback that carries the expected state and an `error`
    /// ends the wait with `error.OAuthAccessDenied`, what the server said
    /// copied here. Null keeps waiting after answering it. `denied_body`,
    /// when set, answers first.
    refusal: ?*Refusal = null,
    deadline_ms: ?time.Millis = null,
    paste: ?PasteSource = null,

    /// Bound on each accepted connection's reads and writes: a client that
    /// connects and then stalls must not pin the wait (and with it Esc in the
    /// picker's credential stage, #67).
    pub const CALLBACK_IO_TIMEOUT_MS: u32 = 1000;

    pub fn bind(preferred_port: u16) !CallbackServer {
        return bindOnPort(preferred_port) catch |err| switch (err) {
            error.BindFailed => bindOnPort(FALLBACK_LOGIN_PORT) catch bindOnPort(0),
            else => return err,
        };
    }

    /// Bind the first of `ports` that is free, in order, and nothing else:
    /// for a client whose redirect URIs name these ports only. All of them
    /// taken is `error.CallbackPortsInUse`. Nothing is sent to whatever holds
    /// one; it may be another program's own sign-in.
    pub fn bindFirstFree(ports: []const u16) !CallbackServer {
        for (ports) |port| {
            return bindOnPort(port) catch |err| switch (err) {
                error.BindFailed => continue,
                else => return err,
            };
        }
        return error.CallbackPortsInUse;
    }

    fn bindOnPort(port: u16) !CallbackServer {
        // 可移植 loopback listen(POSIX socket/Windows WSAStartup+ws2_32),内部含 REUSEADDR+getsockname。
        const l = try net.listenLoopback(port, 4);
        return .{ .sock = l.sock, .port = l.port };
    }

    pub fn close(self: *CallbackServer) void {
        net.closeSocket(self.sock);
    }

    pub fn waitForAuthorizationCode(self: *CallbackServer, allocator: std.mem.Allocator, expected_state: []const u8, abort_signal: ?*const AbortSignal) ![]u8 {
        var pasted_buf: [4096]u8 = undefined;
        var request_buf: [4200]u8 = undefined;
        while (true) {
            if (abort_signal) |signal| if (signal.isAborted()) return error.Aborted;
            if (self.deadline_ms) |deadline| if (time.nowMs() >= deadline) return error.CallbackTimedOut;
            if (self.paste) |source| if (source.take(source.ctx, &pasted_buf)) |pasted| {
                const req = pastedRequest(&request_buf, pasted) orelse {
                    source.refused(source.ctx, .not_an_address);
                    continue;
                };
                switch (self.judge(allocator, req, expected_state)) {
                    .code => |code| return code,
                    .denied_page, .refused => return error.OAuthAccessDenied,
                    .rejected => |err| {
                        source.refused(source.ctx, switch (err) {
                            error.NotCallback => .other_page,
                            error.StateMismatch => .other_sign_in,
                            error.MissingCode => .no_code,
                            error.OAuthDenied => .refused,
                            else => .not_an_address,
                        });
                        continue;
                    },
                }
            };
            if (!net.pollReadable(self.sock, 100)) continue;
            const conn_fd = net.acceptConn(self.sock) orelse return error.AcceptFailed;
            defer net.closeSocket(conn_fd);
            // Bounded IO turns a partial request into a 400 and the loop checks
            // the signal again instead of blocking in recv.
            net.setRecvTimeoutMs(conn_fd, CALLBACK_IO_TIMEOUT_MS);
            net.setSendTimeoutMs(conn_fd, CALLBACK_IO_TIMEOUT_MS);
            const req = readHttpRequest(allocator, conn_fd) catch {
                sendHttpResponse(conn_fd, 400, "Bad Request", "Bad Request");
                continue;
            };
            defer allocator.free(req);
            switch (self.judge(allocator, req, expected_state)) {
                .code => |code| {
                    sendHttpResponse(conn_fd, 200, "OK", self.success_body);
                    return code;
                },
                .denied_page => {
                    sendHttpResponse(conn_fd, 400, "Bad Request", self.denied_body.?);
                    return error.OAuthAccessDenied;
                },
                .refused => {
                    sendHttpResponse(conn_fd, 400, "Bad Request", "The sign-in was refused. You can close this tab.");
                    return error.OAuthAccessDenied;
                },
                .rejected => |err| {
                    const body = switch (err) {
                        error.NotCallback => "Not Found",
                        error.StateMismatch => "State mismatch",
                        error.OAuthDenied => "OAuth authorization was denied",
                        error.MissingCode => "Missing authorization code",
                        else => "Bad Request",
                    };
                    const status: u16 = if (err == error.NotCallback) 404 else 400;
                    const reason = if (status == 404) "Not Found" else "Bad Request";
                    sendHttpResponse(conn_fd, status, reason, body);
                    continue;
                },
            }
        }
    }

    const Verdict = union(enum) { code: []u8, denied_page, refused, rejected: anyerror };

    fn judge(self: *CallbackServer, allocator: std.mem.Allocator, req: []const u8, expected_state: []const u8) Verdict {
        if (self.denied_body != null and callbackCarriesError(req, self.path)) return .denied_page;
        const parsed = parseCallbackRequestAt(allocator, req, self.path, expected_state) catch |err| {
            if (err == error.OAuthDenied) if (self.refusal) |refusal| {
                refusal.fill(allocator, callbackQuery(req));
                return .refused;
            };
            return .{ .rejected = err };
        };
        return .{ .code = parsed };
    }
};

/// Whether `req` is a GET of `path` whose query names an `error`.
fn callbackCarriesError(req: []const u8, path: []const u8) bool {
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return false;
    const line = req[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return false;
    const rest = line[4..];
    const target = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse return false];
    if (!std.mem.startsWith(u8, target, path)) return false;
    const query_pos = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    return findQueryParam(target[query_pos + 1 ..], "error") != null;
}

test "a callback that names an error is recognized with or without a state" {
    try std.testing.expect(callbackCarriesError("GET /auth/callback?error=access_denied HTTP/1.1\r\n\r\n", "/auth/callback"));
    try std.testing.expect(callbackCarriesError("GET /auth/callback?state=s&error=x HTTP/1.1\r\n\r\n", "/auth/callback"));
    try std.testing.expect(!callbackCarriesError("GET /auth/callback?code=c&state=s HTTP/1.1\r\n\r\n", "/auth/callback"));
    try std.testing.expect(!callbackCarriesError("GET /other?error=x HTTP/1.1\r\n\r\n", "/auth/callback"));
    try std.testing.expect(!callbackCarriesError("POST /auth/callback?error=x HTTP/1.1\r\n\r\n", "/auth/callback"));
}

fn readHttpRequest(allocator: std.mem.Allocator, fd: net.Socket) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (out.items.len < 64 * 1024) {
        const n = net.recv(fd, &buf);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
        if (std.mem.indexOf(u8, out.items, "\r\n\r\n") != null) break;
    }
    return try out.toOwnedSlice(allocator);
}

fn sendHttpResponse(fd: net.Socket, status: u16, reason: []const u8, body: []const u8) void {
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, reason, body.len },
    ) catch return;
    _ = net.send(fd, header);
    _ = net.send(fd, body);
}

pub fn parseCallbackRequestForTest(allocator: std.mem.Allocator, req: []const u8, expected_state: []const u8) ![]u8 {
    return parseCallbackRequest(allocator, req, expected_state);
}

fn parseCallbackRequest(allocator: std.mem.Allocator, req: []const u8, expected_state: []const u8) ![]u8 {
    return parseCallbackRequestAt(allocator, req, "/auth/callback", expected_state);
}

fn parseCallbackRequestAt(allocator: std.mem.Allocator, req: []const u8, path: []const u8, expected_state: []const u8) ![]u8 {
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return error.BadRequest;
    const line = req[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return error.BadRequest;
    const rest = line[4..];
    const target_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadRequest;
    const target = rest[0..target_end];
    if (!std.mem.startsWith(u8, target, path)) return error.NotCallback;
    const query_pos = std.mem.indexOfScalar(u8, target, '?') orelse return error.MissingCode;
    const query = target[query_pos + 1 ..];
    const state_raw = findQueryParam(query, "state") orelse return error.StateMismatch;
    const state = try percentDecode(allocator, state_raw);
    defer allocator.free(state);
    if (!std.mem.eql(u8, state, expected_state)) return error.StateMismatch;
    if (findQueryParam(query, "error") != null) return error.OAuthDenied;
    const code_raw = findQueryParam(query, "code") orelse return error.MissingCode;
    const code = try percentDecode(allocator, code_raw);
    errdefer secureFree(allocator, code);
    if (code.len == 0) return error.MissingCode;
    return code;
}

/// The query of a request line's target, empty when there is none. Only
/// called on a request `parseCallbackRequestAt` already accepted the line of.
fn callbackQuery(req: []const u8) []const u8 {
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return "";
    const line = req[0..line_end];
    const target_start = (std.mem.indexOfScalar(u8, line, ' ') orelse return "") + 1;
    const target_end = std.mem.indexOfScalarPos(u8, line, target_start, ' ') orelse line.len;
    const target = line[target_start..target_end];
    const query_pos = std.mem.indexOfScalar(u8, target, '?') orelse return "";
    return target[query_pos + 1 ..];
}

fn findQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos <= query.len) {
        const next = std.mem.indexOfScalarPos(u8, query, pos, '&') orelse query.len;
        const part = query[pos..next];
        if (std.mem.indexOfScalar(u8, part, '=')) |eq| {
            if (std.mem.eql(u8, part[0..eq], key)) return part[eq + 1 ..];
        }
        if (next == query.len) break;
        pos = next + 1;
    }
    return null;
}

fn percentDecode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
        } else if (c == '%' and i + 2 < value.len) {
            const hi = hexVal(value[i + 1]) orelse return error.BadPercentEncoding;
            const lo = hexVal(value[i + 2]) orelse return error.BadPercentEncoding;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return 10 + c - 'a';
    if (c >= 'A' and c <= 'F') return 10 + c - 'A';
    return null;
}

fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    code: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try appendFormField(&aw.writer, "grant_type", "authorization_code", true);
    try appendFormField(&aw.writer, "client_id", if (std.c.getenv(OAUTH_CLIENT_ID_ENV)) |v| std.mem.span(v) else OAUTH_CLIENT_ID, false);
    try appendFormField(&aw.writer, "code", code, false);
    try appendFormField(&aw.writer, "redirect_uri", redirect_uri, false);
    try appendFormField(&aw.writer, "code_verifier", code_verifier, false);
    const form = try aw.toOwnedSlice();
    defer secureFree(allocator, form);
    return postTokenForm(allocator, form);
}

fn postTokenForm(allocator: std.mem.Allocator, form: []const u8) ![]u8 {
    const url = try oauthTokenUrl(allocator, .metask);
    defer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthTokenUrl;
    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    var http_client = std.http.Client{ .allocator = allocator, .io = io_runtime.io() };
    defer http_client.deinit();
    var req = http_client.request(.POST, uri, .{
        // Only the token endpoint can answer a grant it received.
        .redirect_behavior = no_redirects,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch return error.OAuthTokenExchangeFailed;
    defer req.deinit();
    http_connection.sendBodyComplete(&req, @constCast(form)) catch return error.OAuthTokenExchangeFailed;
    var redirect_buf: [4096]u8 = undefined;
    const http_response = http_connection.receiveHead(&req, &redirect_buf) catch return error.OAuthTokenExchangeFailed;
    const status = ResponseStatus.capture(&http_response);
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = http_connection.bodyReader(&http_response, &transfer_buf);
    const response_body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(256 * 1024)) catch return error.OAuthTokenExchangeFailed;
    errdefer secureFree(allocator, response_body);
    if (!status.isOk()) {
        const err = classifyOAuthEndpointError(status.code, response_body);
        secureFree(allocator, response_body);
        return err;
    }
    return response_body;
}

/// The program that opens a URL when `BROWSER` names none. macOS has no
/// `xdg-open`: with it as the default, `/usr/bin/env` exec'd fine and then
/// exited 127, so no sign-in page ever opened there and nothing said so.
fn defaultOpener(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .macos => "open",
        else => "xdg-open",
    };
}

pub fn openBrowser(allocator: std.mem.Allocator, url: []const u8) !void {
    const opener = if (std.c.getenv("BROWSER")) |b| std.mem.span(b) else defaultOpener(builtin.os.tag);
    const env_path = "/usr/bin/env";
    const env_z = try allocator.dupeZ(u8, env_path);
    defer allocator.free(env_z);
    const opener_z = try allocator.dupeZ(u8, opener);
    defer allocator.free(opener_z);
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    // detached fire-and-forget（关 stdio、不 wait），走可移植 platform/process。
    // POSIX：/usr/bin/env <opener> <url>；Windows：系统目录的 rundll32.exe url.dll,FileProtocolHandler <url>，不经 cmd.exe。
    if (builtin.os.tag == .windows) {
        const launcher = try windowsUrlLauncher(allocator, if (std.c.getenv("SystemRoot")) |root| std.mem.span(root) else null);
        defer allocator.free(launcher);
        var argv = windowsOpenUrlArgv(launcher.ptr, url_z.ptr);
        process.spawnDetached(&argv, true) catch return error.ForkFailed;
    } else {
        var argv = [_]?[*:0]const u8{ env_z.ptr, opener_z.ptr, url_z.ptr, null };
        process.spawnDetached(&argv, true) catch return error.ForkFailed;
    }
}

fn windowsUrlLauncher(allocator: std.mem.Allocator, system_root: ?[]const u8) ![:0]u8 {
    const root = std.mem.trimEnd(u8, system_root orelse "", "\\");
    if (root.len == 0) return allocator.dupeZ(u8, "rundll32.exe");
    return std.fmt.allocPrintSentinel(allocator, "{s}\\System32\\rundll32.exe", .{root}, 0);
}

fn windowsOpenUrlArgv(launcher: [*:0]const u8, url: [*:0]const u8) [4]?[*:0]const u8 {
    return .{ launcher, "url.dll,FileProtocolHandler", url, null };
}

const RefreshTokenPolicy = enum { required, optional_replacement };

fn parseOAuthTokenResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
    now_seconds: i64,
    refresh_policy: RefreshTokenPolicy,
    previous_refresh_token: ?[]const u8,
) !OAuthCredential {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedTokenResponse;
    const obj = parsed.value.object;
    const access = try dupNonEmptyString(allocator, obj, "access_token");
    errdefer secureFree(allocator, access);
    const refresh = if (getString(obj, "refresh_token")) |v| blk: {
        if (v.len == 0) return error.MalformedTokenResponse;
        break :blk try allocator.dupe(u8, v);
    } else switch (refresh_policy) {
        .required => return error.MalformedTokenResponse,
        .optional_replacement => if (previous_refresh_token) |prev| try allocator.dupe(u8, prev) else return error.MalformedTokenResponse,
    };
    errdefer secureFree(allocator, refresh);
    const token_type_raw = getString(obj, "token_type") orelse return error.MalformedTokenResponse;
    if (!std.ascii.eqlIgnoreCase(token_type_raw, "Bearer")) return error.UnsupportedTokenType;
    const expires_in = try getPositiveI64(obj, "expires_in");
    if (expires_in > std.math.maxInt(i64) - now_seconds) return error.MalformedTokenResponse;
    const expires_at = now_seconds + expires_in;
    if (expires_at <= now_seconds) return error.MalformedTokenResponse;

    return .{
        .access_token = access,
        .refresh_token = refresh,
        .expires_at = expires_at,
        .scope = try dupOptionalString(allocator, obj, "scope"),
        .account_id = try dupOptionalString(allocator, obj, "account_id"),
        .profile = try dupOptionalString(allocator, obj, "profile"),
    };
}

fn parseStoredCredentials(allocator: std.mem.Allocator, value: std.json.Value) !StoredCredentials {
    if (value != .object) return error.InvalidCredentials;
    const obj = value.object;
    var out = StoredCredentials{};
    errdefer out.deinit(allocator);
    if (getString(obj, "api_key")) |k| {
        if (k.len > 0) out.api_key = try allocator.dupe(u8, k);
    }
    if (getString(obj, "selected_model")) |m| {
        if (m.len > 0) out.selected_model = try allocator.dupe(u8, m);
    }
    if (getString(obj, "reasoning_effort")) |e| {
        out.reasoning_effort = types.ReasoningEffort.parse(e) orelse return error.InvalidCredentials;
    }
    if (obj.get("oauth")) |oauth_value| {
        if (oauth_value != .object) return error.InvalidCredentials;
        const oauth_obj = oauth_value.object;
        const access = try dupNonEmptyString(allocator, oauth_obj, "access_token");
        errdefer secureFree(allocator, access);
        const refresh = try dupNonEmptyString(allocator, oauth_obj, "refresh_token");
        errdefer secureFree(allocator, refresh);
        const token_type_s = getString(oauth_obj, "token_type") orelse "Bearer";
        if (!std.ascii.eqlIgnoreCase(token_type_s, "Bearer")) return error.UnsupportedTokenType;
        out.oauth = .{
            .access_token = access,
            .refresh_token = refresh,
            .expires_at = try getInteger(oauth_obj, "expires_at"),
            .scope = try dupOptionalString(allocator, oauth_obj, "scope"),
            .account_id = try dupOptionalString(allocator, oauth_obj, "account_id"),
            .profile = try dupOptionalString(allocator, oauth_obj, "profile"),
        };
    }
    return out;
}

fn serializeStoredCredentials(allocator: std.mem.Allocator, creds: StoredCredentials) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.writer.writeAll("{");
    var wrote = false;
    if (creds.api_key) |k| {
        try aw.writer.writeAll("\"api_key\":");
        try util_json.writeJsonString(&aw.writer, k);
        wrote = true;
    }
    if (creds.oauth) |o| {
        if (wrote) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\"oauth\":{");
        try aw.writer.writeAll("\"access_token\":");
        try util_json.writeJsonString(&aw.writer, o.access_token);
        try aw.writer.writeAll(",\"refresh_token\":");
        try util_json.writeJsonString(&aw.writer, o.refresh_token);
        try aw.writer.writeAll(",\"token_type\":\"Bearer\"");
        try aw.writer.print(",\"expires_at\":{d}", .{o.expires_at});
        if (o.scope) |v| {
            try aw.writer.writeAll(",\"scope\":");
            try util_json.writeJsonString(&aw.writer, v);
        }
        if (o.account_id) |v| {
            try aw.writer.writeAll(",\"account_id\":");
            try util_json.writeJsonString(&aw.writer, v);
        }
        if (o.profile) |v| {
            try aw.writer.writeAll(",\"profile\":");
            try util_json.writeJsonString(&aw.writer, v);
        }
        try aw.writer.writeAll("}");
        wrote = true;
    }
    if (creds.selected_model) |m| {
        if (wrote) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\"selected_model\":");
        try util_json.writeJsonString(&aw.writer, m);
        wrote = true;
    }
    if (creds.reasoning_effort) |effort| {
        if (wrote) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\"reasoning_effort\":");
        try util_json.writeJsonString(&aw.writer, effort.name());
    }
    try aw.writer.writeAll("}\n");
    return try aw.toOwnedSlice();
}

fn checkFilePrivate(path: []const u8) !void {
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        if (pfs.lastErrnoIs(.NOENT)) return error.NotFound;
        return error.OpenFailed;
    }
    _ = pfs.close(fd);
}

fn refreshOAuthCredential(allocator: std.mem.Allocator, old: *const OAuthCredential) !OAuthCredential {
    const body = try buildRefreshRequestBody(allocator, old.refresh_token);
    defer secureFree(allocator, body);
    // `auth.json`'s sign-in is an earlier version's: napi issued it.
    const url = try oauthTokenUrl(allocator, .legacy_napi);
    defer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthTokenUrl;

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    var http_client = std.http.Client{ .allocator = allocator, .io = io_runtime.io() };
    defer http_client.deinit();

    var req = http_client.request(.POST, uri, .{
        // Only the token endpoint can answer a grant it received.
        .redirect_behavior = no_redirects,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch return error.OAuthRefreshFailed;
    defer req.deinit();

    http_connection.sendBodyComplete(&req, @constCast(body)) catch return error.OAuthRefreshFailed;
    var redirect_buf: [4096]u8 = undefined;
    const http_response = http_connection.receiveHead(&req, &redirect_buf) catch return error.OAuthRefreshFailed;
    const status = ResponseStatus.capture(&http_response);

    var transfer_buf: [8192]u8 = undefined;
    const body_reader = http_connection.bodyReader(&http_response, &transfer_buf);
    const response_body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(256 * 1024)) catch return error.OAuthRefreshFailed;
    defer secureFree(allocator, response_body);

    if (!status.isOk()) {
        return classifyOAuthEndpointError(status.code, response_body);
    }
    return parseOAuthTokenResponse(allocator, response_body, nowUnixSeconds(), .optional_replacement, old.refresh_token);
}

/// The OAuth servers a token request goes to: www for the browser sign-in's
/// code exchange (#527), napi to refresh a sign-in it issued
/// (`LEGACY_OAUTH_TOKEN_URL`).
const TokenEndpoint = enum { metask, legacy_napi };

/// `METACODE_OAUTH_TOKEN_URL` (a local server, a test's mock), else the
/// endpoint's own.
fn oauthTokenUrl(allocator: std.mem.Allocator, endpoint: TokenEndpoint) ![]u8 {
    if (std.c.getenv(OAUTH_TOKEN_URL_ENV)) |p| return allocator.dupe(u8, std.mem.span(p));
    return allocator.dupe(u8, switch (endpoint) {
        .metask => METASK_OAUTH_TOKEN_URL,
        .legacy_napi => LEGACY_OAUTH_TOKEN_URL,
    });
}

/// The refresh grant for `auth.json`'s sign-in, as the client napi issued it
/// to (`LEGACY_OAUTH_CLIENT_ID`).
fn buildRefreshRequestBody(allocator: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try appendFormField(&aw.writer, "grant_type", "refresh_token", true);
    try appendFormField(&aw.writer, "client_id", LEGACY_OAUTH_CLIENT_ID, false);
    try appendFormField(&aw.writer, "refresh_token", refresh_token, false);
    return try aw.toOwnedSlice();
}

pub fn appendFormField(writer: *std.Io.Writer, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte('&');
    try appendFormEncoded(writer, name);
    try writer.writeByte('=');
    try appendFormEncoded(writer, value);
}

fn appendFormEncoded(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if ((c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~')
        {
            try writer.writeByte(c);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[c >> 4]);
            try writer.writeByte(hex[c & 0x0f]);
        }
    }
}

pub fn classifyOAuthEndpointError(status_code: u16, body: []const u8) anyerror {
    if (parseOAuthErrorCode(body)) |code| {
        defer std.heap.c_allocator.free(code);
        if (std.mem.eql(u8, code, "invalid_grant")) return error.OAuthLoginRequired;
        if (std.mem.eql(u8, code, "temporarily_unavailable")) return error.OAuthEndpointTransient;
        if (std.mem.eql(u8, code, "invalid_client") or
            std.mem.eql(u8, code, "unauthorized_client"))
        {
            return error.OAuthClientRejected;
        }
        if (std.mem.eql(u8, code, "invalid_request") or
            std.mem.eql(u8, code, "unsupported_grant_type") or
            std.mem.eql(u8, code, "invalid_scope"))
        {
            return error.OAuthProtocolError;
        }
    }
    return switch (status_code) {
        429, 500, 502, 503 => error.OAuthEndpointTransient,
        else => error.OAuthRefreshFailed,
    };
}

test "OAuth endpoint classification accepts the full wire status domain" {
    try std.testing.expectEqual(
        error.OAuthEndpointTransient,
        classifyOAuthEndpointError(429, "{}"),
    );
    try std.testing.expectEqual(
        error.OAuthRefreshFailed,
        classifyOAuthEndpointError(529, "{}"),
    );
    try std.testing.expectEqual(
        error.OAuthLoginRequired,
        classifyOAuthEndpointError(529, "{\"error\":\"invalid_grant\"}"),
    );
}

fn parseOAuthErrorCode(body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("error") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return std.heap.c_allocator.dupe(u8, v.string) catch null;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.NotFound;
    defer _ = pfs.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, buf[0..buf.len]);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

fn dupNonEmptyString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    const s = getString(obj, key) orelse return error.MalformedTokenResponse;
    if (s.len == 0) return error.MalformedTokenResponse;
    return try allocator.dupe(u8, s);
}

fn dupOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const s = getString(obj, key) orelse return null;
    if (s.len == 0) return null;
    return try allocator.dupe(u8, s);
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const v = obj.get(key) orelse return error.InvalidCredentials;
    if (v != .integer) return error.InvalidCredentials;
    return @intCast(v.integer);
}

fn getPositiveI64(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const v = try getInteger(obj, key);
    if (v <= 0) return error.MalformedTokenResponse;
    return v;
}

fn nowUnixSeconds() i64 {
    return time.nowUnix();
}

pub fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    @memset(bytes, 0);
    allocator.free(bytes);
}

test "import OAuth token response requires refresh token and positive expiry" {
    const a = std.testing.allocator;
    var creds = try importOAuthTokenResponse(a,
        \\{"access_token":"access","refresh_token":"refresh","token_type":"bearer","expires_in":3600,"scope":"metacode:use","account_id":"acct"}
    , 100);
    defer creds.deinit(a);
    try std.testing.expect(creds.oauth != null);
    try std.testing.expectEqualStrings("access", creds.oauth.?.access_token);
    try std.testing.expectEqual(@as(i64, 3700), creds.oauth.?.expires_at);
    try std.testing.expectError(error.MalformedTokenResponse, importOAuthTokenResponse(a,
        \\{"access_token":"access","token_type":"Bearer","expires_in":3600}
    , 100));
}

test "stored credentials roundtrip keeps file private" {
    const a = std.testing.allocator;
    var path_buf: [512]u8 = undefined;
    const path = tt.path(&path_buf, "auth-roundtrip.json");
    var creds = StoredCredentials{ .api_key = try a.dupe(u8, "stored-key") };
    defer creds.deinit(a);
    try saveToPath(a, path, creds);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, path)) |z| {
            pfs.unlinkPath(z.ptr) catch {};
            std.heap.c_allocator.free(z);
        } else |_| {}
    }
    var loaded = try loadFromPath(a, path);
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings("stored-key", loaded.api_key.?);
}

test "browser authorize URL omits empty scope" {
    const a = std.testing.allocator;
    const url = try buildAuthorizeUrlForTest(
        a,
        METASK_OAUTH_AUTHORIZE_URL,
        OAUTH_CLIENT_ID,
        "",
        "http://localhost:1455" ++ METASK_CALLBACK_PATH,
        "challenge",
        "state",
    );
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=challenge") != null);
}

test "a Metask browser sign-in asks www for model access as metacodes, back on its registered path (#527)" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings("https://www.metask-ai.com/oauth/authorize", METASK_OAUTH_AUTHORIZE_URL);
    try std.testing.expectEqualStrings("https://www.metask-ai.com/api/oauth/token", METASK_OAUTH_TOKEN_URL);
    const url = try buildAuthorizeUrlForTest(
        a,
        METASK_OAUTH_AUTHORIZE_URL,
        OAUTH_CLIENT_ID,
        METASK_OAUTH_SCOPE,
        "http://localhost:1455" ++ METASK_CALLBACK_PATH,
        "challenge",
        "state",
    );
    defer a.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "https://www.metask-ai.com/oauth/authorize?response_type=code&client_id=metacodes&"));
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fmetask%2Fcallback&") != null);
    // Without `model:invoke` the server grants `read` only.
    try std.testing.expect(std.mem.indexOf(u8, url, "&scope=read%20model%3Ainvoke&") != null);
}

test "an auth.json sign-in from before #527 refreshes where it was issued: napi, as metacode-cli" {
    const a = std.testing.allocator;
    const body = try buildRefreshRequestBody(a, "old refresh/1");
    defer a.free(body);
    try std.testing.expectEqualStrings("grant_type=refresh_token&client_id=metacode-cli&refresh_token=old%20refresh%2F1", body);
    // The override (a local server, a test's mock) serves both endpoints.
    if (std.c.getenv(OAUTH_TOKEN_URL_ENV) != null) return error.SkipZigTest;
    const refresh_url = try oauthTokenUrl(a, .legacy_napi);
    defer a.free(refresh_url);
    try std.testing.expectEqualStrings("https://napi.metask-ai.com/oauth/token", refresh_url);
    // A new browser sign-in's code goes to www.
    const exchange_url = try oauthTokenUrl(a, .metask);
    defer a.free(exchange_url);
    try std.testing.expectEqualStrings("https://www.metask-ai.com/api/oauth/token", exchange_url);
}

test "the loopback wait returns the code a valid callback carries" {
    const a = std.testing.allocator;
    var server = try CallbackServer.bind(0);
    defer server.close();
    const Worker = struct {
        fn run(port: u16) void {
            const c = net.connectLoopback(port) catch return;
            defer net.closeSocket(c);
            _ = net.send(c, "GET /auth/callback?state=s&code=abc123 HTTP/1.1\r\nHost: localhost\r\n\r\n");
            var b: [256]u8 = undefined;
            _ = net.recv(c, &b);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{server.port});
    const code = try server.waitForAuthorizationCode(a, "s", null);
    defer secureFree(a, code);
    try std.testing.expectEqualStrings("abc123", code);
    t.join();
}

test "a pasted address becomes the callback request, whatever the browser shows around it (#722)" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("GET /auth/metask/callback?code=c&state=s HTTP/1.1\r\n\r\n", pastedRequest(&buffer, "http://localhost:1455/auth/metask/callback?code=c&state=s").?);
    try std.testing.expectEqualStrings("GET /auth/callback?code=c&state=s HTTP/1.1\r\n\r\n", pastedRequest(&buffer, "  localhost:1457/auth/callback?code=c&state=s#done\r\n").?);
    try std.testing.expectEqualStrings("GET /auth/callback?code=c&state=s HTTP/1.1\r\n\r\n", pastedRequest(&buffer, "\"/auth/callback?code=c&state=s\"").?);
    try std.testing.expect(pastedRequest(&buffer, "") == null);
    try std.testing.expect(pastedRequest(&buffer, "MOCK-4711") == null);
    try std.testing.expect(pastedRequest(&buffer, "http://localhost:1455/auth/callback?code=c d") == null);
}

test "the loopback wait takes a pasted address as the browser's callback, and says why it refuses another (#722)" {
    const a = std.testing.allocator;
    var server = try CallbackServer.bind(0);
    defer server.close();
    const Pastes = struct {
        lines: []const []const u8,
        next: usize = 0,
        refusals: [4]PasteRefusal = undefined,
        refused_count: usize = 0,
        fn take(ctx: *anyopaque, out: []u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.next == self.lines.len) return null;
            const line = self.lines[self.next];
            self.next += 1;
            @memcpy(out[0..line.len], line);
            return out[0..line.len];
        }
        fn refused(ctx: *anyopaque, why: PasteRefusal) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.refusals[self.refused_count] = why;
            self.refused_count += 1;
        }
    };
    var pastes = Pastes{ .lines = &.{
        "MOCK-4711",
        "http://localhost:1455/elsewhere?code=x&state=s",
        "http://localhost:1455/auth/callback?code=x&state=another",
        "http://localhost:1455/auth/callback?state=s",
        "http://localhost:1455/auth/callback?code=abc123&state=s",
    } };
    server.paste = .{ .ctx = &pastes, .take = Pastes.take, .refused = Pastes.refused };
    server.deadline_ms = time.nowMs() + 5_000;
    const code = try server.waitForAuthorizationCode(a, "s", null);
    defer secureFree(a, code);
    try std.testing.expectEqualStrings("abc123", code);
    try std.testing.expectEqualSlices(PasteRefusal, &.{ .not_an_address, .other_page, .other_sign_in, .no_code }, pastes.refusals[0..pastes.refused_count]);
}

test "a pasted refusal ends a wait that ends on refusals, as the browser's would (#722)" {
    const a = std.testing.allocator;
    var server = try CallbackServer.bind(0);
    defer server.close();
    var refusal: Refusal = .{};
    server.refusal = &refusal;
    var box: PasteBox = .{};
    box.submit("http://localhost:1456/auth/callback?error=access_denied&error_description=no&state=s");
    server.paste = box.source();
    server.deadline_ms = time.nowMs() + 5_000;
    try std.testing.expectError(error.OAuthAccessDenied, server.waitForAuthorizationCode(a, "s", null));
    try std.testing.expectEqualStrings("access_denied", refusal.code());
}

test "a callback wait with a bound ends when it passes (#722)" {
    const a = std.testing.allocator;
    var server = try CallbackServer.bind(0);
    defer server.close();
    server.deadline_ms = time.nowMs() + 150;
    try std.testing.expectError(error.CallbackTimedOut, server.waitForAuthorizationCode(a, "s", null));
}

test "the loopback wait stops when the signal aborts" {
    var server = try CallbackServer.bind(0);
    defer server.close();
    var signal = AbortSignal.init();
    const Worker = struct {
        fn run(s: *AbortSignal) void {
            time.sleepMs(50);
            s.abort(.user_interrupt);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&signal});
    try std.testing.expectError(error.Aborted, server.waitForAuthorizationCode(std.testing.allocator, "s", &signal));
    t.join();
}

test "on Windows the whole URL reaches rundll32 as one argument, with no cmd.exe to end it at the first & (#727)" {
    const a = std.testing.allocator;
    const launcher = try windowsUrlLauncher(a, "C:\\Windows\\");
    defer a.free(launcher);
    const url = "https://www.metask-ai.com/oauth/authorize?response_type=code&client_id=metacodes&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fmetask%2Fcallback&scope=read%20model%3Ainvoke&state=a^b|c<d>e%PATH%";
    var argv = windowsOpenUrlArgv(launcher.ptr, url);
    const cmdline = try process.buildWindowsCmdline(a, &argv);
    defer a.free(cmdline);
    const expected = try std.unicode.utf8ToUtf16LeAllocZ(a, "C:\\Windows\\System32\\rundll32.exe url.dll,FileProtocolHandler " ++ url);
    defer a.free(expected);
    try std.testing.expectEqualSlices(u16, expected, cmdline);

    const bare = try windowsUrlLauncher(a, null);
    defer a.free(bare);
    try std.testing.expectEqualStrings("rundll32.exe", bare);
}

test "the rundll32 a Windows sign-in hands its URL to is where this machine keeps it (#727)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const root = std.c.getenv("SystemRoot") orelse return error.SkipZigTest;
    const launcher = try windowsUrlLauncher(a, std.mem.span(root));
    defer a.free(launcher);
    try std.testing.expect(std.fs.path.isAbsolute(launcher));
    try std.testing.expect(pfs.exists(launcher.ptr));
}

test "the loopback wait keeps serving a wrong-state callback and still aborts" {
    var server = try CallbackServer.bind(0);
    defer server.close();
    var signal = AbortSignal.init();
    const Worker = struct {
        fn run(port: u16, s: *AbortSignal) void {
            const c = net.connectLoopback(port) catch return;
            defer net.closeSocket(c);
            _ = net.send(c, "GET /auth/callback?state=wrong&code=x HTTP/1.1\r\nHost: localhost\r\n\r\n");
            var b: [256]u8 = undefined;
            _ = net.recv(c, &b);
            time.sleepMs(50);
            s.abort(.user_interrupt);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{ server.port, &signal });
    try std.testing.expectError(error.Aborted, server.waitForAuthorizationCode(std.testing.allocator, "s", &signal));
    t.join();
}

test "the loopback wait is not pinned by a client that connects and stalls" {
    var server = try CallbackServer.bind(0);
    defer server.close();
    var signal = AbortSignal.init();
    const Worker = struct {
        fn run(port: u16, s: *AbortSignal) void {
            const c = net.connectLoopback(port) catch return;
            defer net.closeSocket(c);
            // A request line and then silence: no terminator ever arrives.
            _ = net.send(c, "GET /auth/callback?state=s HTTP/1.1");
            time.sleepMs(300);
            s.abort(.user_interrupt);
            time.sleepMs(CallbackServer.CALLBACK_IO_TIMEOUT_MS + 500);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{ server.port, &signal });
    defer t.join();
    try std.testing.expectError(error.Aborted, server.waitForAuthorizationCode(std.testing.allocator, "s", &signal));
}

test "the default URL opener exists on the platform it is used on" {
    try std.testing.expectEqualStrings("open", defaultOpener(.macos));
    try std.testing.expectEqualStrings("xdg-open", defaultOpener(.linux));
    try std.testing.expectEqualStrings("xdg-open", defaultOpener(.freebsd));
}
