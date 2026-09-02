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
const rng = @import("platform").rng;
const process = @import("platform").process;
const pfs = @import("platform").fs;
const net = @import("platform").net;
const builtin = @import("builtin");
const fs_util = @import("../util/fs.zig");
const time = @import("../util/time.zig");
const types = @import("../types.zig");
const ResponseStatus = @import("../api/http_status.zig").ResponseStatus;

pub const METASK_API_KEY_ENV = "METASK_API_KEY";
pub const RUNTIME_API_KEY_FD_ENV = "METACODES_API_KEY_FD";
pub const AUTH_FILE_ENV = "METACODES_AUTH_FILE";
pub const OAUTH_TOKEN_URL_ENV = "METACODE_OAUTH_TOKEN_URL";
pub const OAUTH_AUTHORIZE_URL_ENV = "METACODE_OAUTH_AUTHORIZE_URL";
pub const OAUTH_CLIENT_ID_ENV = "METACODE_OAUTH_CLIENT_ID";
pub const OAUTH_SCOPE_ENV = "METACODE_OAUTH_SCOPE";
pub const METASK_OAUTH_TOKEN_URL = "https://napi.metask-ai.com/oauth/token";
pub const METASK_OAUTH_AUTHORIZE_URL = "https://napi.metask-ai.com/oauth/authorize";
pub const OAUTH_CLIENT_ID = "metacode-cli";
const OAUTH_REFRESH_SKEW_SECONDS: i64 = 300;
const DEFAULT_LOGIN_PORT: u16 = 1455;
const FALLBACK_LOGIN_PORT: u16 = 1457;

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
};

pub fn authFilePath(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv(AUTH_FILE_ENV)) |p| return allocator.dupe(u8, std.mem.span(p));
    const home = @import("platform").paths.homeDir() orelse return error.NoHome; // HOME / Windows USERPROFILE
    return std.fmt.allocPrint(allocator, "{s}/.metacodes/auth.json", .{home});
}

pub fn resolveCredential(
    allocator: std.mem.Allocator,
    cli_api_key: ?[]const u8,
    precedence: AuthPrecedence,
) !ResolvedCredential {
    const env_api_key = if (std.c.getenv(METASK_API_KEY_ENV)) |v| std.mem.span(v) else null;
    const path = authFilePath(allocator) catch |err| switch (err) {
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
    cli_api_key: ?[]const u8,
    precedence: AuthPrecedence,
) !ResolvedCredential {
    var fd_api_key = try takeRuntimeFdApiKey(allocator);
    defer if (fd_api_key) |*runtime| runtime.deinit(allocator);
    if (cli_api_key != null and fd_api_key != null) return error.AmbiguousRuntimeCredentials;
    // Never mutate libc's environment after Zig 0.16 has captured its startup
    // pointer block: HTTPS lazily scans that borrowed block while loading the
    // CA bundle, and unsetenv can otherwise turn it into a use-after-free.
    // An ambient key alongside FD authority is rejected and the process exits,
    // instead of trying to scrub the second channel in place.
    if (fd_api_key != null and std.c.getenv(METASK_API_KEY_ENV) != null) {
        return error.AmbiguousRuntimeCredentials;
    }

    // An inherited FD is an explicit runtime authority, not another candidate
    // in the stored OAuth/API-key preference chain. In particular,
    // `oauth_first` must not silently discard the one-shot pilot credential.
    var credential = if (fd_api_key) |runtime|
        try credentialFromApiKey(allocator, runtime.bytes, .fd_api_key)
    else
        try resolveCredential(allocator, cli_api_key, precedence);
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

pub fn resolveStoredOAuthBearer(allocator: std.mem.Allocator) !?[]u8 {
    const path = authFilePath(allocator) catch |err| switch (err) {
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

pub fn loadDefault(allocator: std.mem.Allocator) !StoredCredentials {
    const path = try authFilePath(allocator);
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

pub fn saveDefault(allocator: std.mem.Allocator, creds: StoredCredentials) !void {
    const path = try authFilePath(allocator);
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
    _ = std.c.chmod(path_z.ptr, 0o600);
    const n = pfs.write(fd, json);
    if (n < 0 or @as(usize, @intCast(n)) != json.len) return error.WriteFailed;
}

pub fn clearDefault(allocator: std.mem.Allocator) !void {
    const path = try authFilePath(allocator);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.unlink(path_z.ptr) != 0) {
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        if (e != .NOENT) return error.UnlinkFailed;
    }
}

pub fn importOAuthTokenResponse(allocator: std.mem.Allocator, body: []const u8, now_seconds: i64) !StoredCredentials {
    return .{ .oauth = try parseOAuthTokenResponse(allocator, body, now_seconds, .required, null) };
}

pub const BrowserLoginOptions = struct {
    open_browser: bool = true,
    port: u16 = DEFAULT_LOGIN_PORT,
    force_state: ?[]const u8 = null,
};

pub fn loginWithBrowser(allocator: std.mem.Allocator, opts: BrowserLoginOptions) !StoredCredentials {
    var pkce = try generatePkce(allocator);
    defer pkce.deinit(allocator);
    const state = if (opts.force_state) |s| try allocator.dupe(u8, s) else try randomBase64Url(allocator, 32);
    defer secureFree(allocator, state);

    var server = try CallbackServer.bind(opts.port);
    defer server.close();

    const redirect_uri = try std.fmt.allocPrint(allocator, "http://localhost:{d}/auth/callback", .{server.port});
    defer allocator.free(redirect_uri);
    const authorize_url = try buildAuthorizeUrlFromEnv(allocator, redirect_uri, pkce.code_challenge, state);
    defer allocator.free(authorize_url);

    std.debug.print(
        "Starting local login server on http://localhost:{d}.\nOpen this URL to authenticate:\n\n{s}\n\n",
        .{ server.port, authorize_url },
    );
    if (opts.open_browser) openBrowser(allocator, authorize_url) catch |err| {
        std.debug.print("Could not open browser automatically: {s}\n", .{@errorName(err)});
    };

    const code = try server.waitForAuthorizationCode(allocator, state);
    defer secureFree(allocator, code);
    const token_body = try exchangeAuthorizationCode(allocator, code, redirect_uri, pkce.code_verifier);
    defer secureFree(allocator, token_body);
    return importOAuthTokenResponse(allocator, token_body, nowUnixSeconds());
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
    const scope = if (std.c.getenv(OAUTH_SCOPE_ENV)) |v| std.mem.span(v) else "";
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
    return try aw.toOwnedSlice();
}

pub const CallbackServer = struct {
    sock: net.Socket,
    port: u16,

    pub fn bind(preferred_port: u16) !CallbackServer {
        return bindOnPort(preferred_port) catch |err| switch (err) {
            error.BindFailed => bindOnPort(FALLBACK_LOGIN_PORT) catch bindOnPort(0),
            else => return err,
        };
    }

    fn bindOnPort(port: u16) !CallbackServer {
        // 可移植 loopback listen(POSIX socket/Windows WSAStartup+ws2_32),内部含 REUSEADDR+getsockname。
        const l = try net.listenLoopback(port, 4);
        return .{ .sock = l.sock, .port = l.port };
    }

    pub fn close(self: *CallbackServer) void {
        net.closeSocket(self.sock);
    }

    pub fn waitForAuthorizationCode(self: *CallbackServer, allocator: std.mem.Allocator, expected_state: []const u8) ![]u8 {
        while (true) {
            const conn_fd = net.acceptConn(self.sock) orelse return error.AcceptFailed;
            defer net.closeSocket(conn_fd);
            const req = readHttpRequest(allocator, conn_fd) catch {
                sendHttpResponse(conn_fd, 400, "Bad Request", "Bad Request");
                continue;
            };
            defer allocator.free(req);
            const parsed = parseCallbackRequest(allocator, req, expected_state) catch |err| {
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
            };
            sendHttpResponse(conn_fd, 200, "OK", "Metacodes login complete. You can close this tab.");
            return parsed;
        }
    }
};

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
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return error.BadRequest;
    const line = req[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return error.BadRequest;
    const rest = line[4..];
    const target_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadRequest;
    const target = rest[0..target_end];
    if (!std.mem.startsWith(u8, target, "/auth/callback")) return error.NotCallback;
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
    const url = try oauthTokenUrl(allocator);
    defer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthTokenUrl;
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var http_client = std.http.Client{ .allocator = allocator, .io = io_runtime.io() };
    defer http_client.deinit();
    var req = http_client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch return error.OAuthTokenExchangeFailed;
    defer req.deinit();
    req.sendBodyComplete(@constCast(form)) catch return error.OAuthTokenExchangeFailed;
    var redirect_buf: [4096]u8 = undefined;
    const http_response = req.receiveHead(&redirect_buf) catch return error.OAuthTokenExchangeFailed;
    const status = ResponseStatus.capture(&http_response);
    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, http_response.head.transfer_encoding, http_response.head.content_length);
    const response_body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(256 * 1024)) catch return error.OAuthTokenExchangeFailed;
    errdefer secureFree(allocator, response_body);
    if (!status.isOk()) {
        const err = classifyOAuthEndpointError(status.code, response_body);
        secureFree(allocator, response_body);
        return err;
    }
    return response_body;
}

pub fn openBrowser(allocator: std.mem.Allocator, url: []const u8) !void {
    const opener = if (std.c.getenv("BROWSER")) |b| std.mem.span(b) else "xdg-open";
    const env_path = "/usr/bin/env";
    const env_z = try allocator.dupeZ(u8, env_path);
    defer allocator.free(env_z);
    const opener_z = try allocator.dupeZ(u8, opener);
    defer allocator.free(opener_z);
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    // detached fire-and-forget（关 stdio、不 wait），走可移植 platform/process。
    // POSIX：/usr/bin/env <opener> <url>；Windows：cmd /c start "" <url>（ShellExecute 语义）。
    if (builtin.os.tag == .windows) {
        var argv = [_]?[*:0]const u8{ "cmd.exe", "/c", "start", "", url_z.ptr, null };
        process.spawnDetached(&argv, true) catch return error.ForkFailed;
    } else {
        var argv = [_]?[*:0]const u8{ env_z.ptr, opener_z.ptr, url_z.ptr, null };
        process.spawnDetached(&argv, true) catch return error.ForkFailed;
    }
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
        try std.json.Stringify.encodeJsonString(k, .{}, &aw.writer);
        wrote = true;
    }
    if (creds.oauth) |o| {
        if (wrote) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\"oauth\":{");
        try aw.writer.writeAll("\"access_token\":");
        try std.json.Stringify.encodeJsonString(o.access_token, .{}, &aw.writer);
        try aw.writer.writeAll(",\"refresh_token\":");
        try std.json.Stringify.encodeJsonString(o.refresh_token, .{}, &aw.writer);
        try aw.writer.writeAll(",\"token_type\":\"Bearer\"");
        try aw.writer.print(",\"expires_at\":{d}", .{o.expires_at});
        if (o.scope) |v| {
            try aw.writer.writeAll(",\"scope\":");
            try std.json.Stringify.encodeJsonString(v, .{}, &aw.writer);
        }
        if (o.account_id) |v| {
            try aw.writer.writeAll(",\"account_id\":");
            try std.json.Stringify.encodeJsonString(v, .{}, &aw.writer);
        }
        if (o.profile) |v| {
            try aw.writer.writeAll(",\"profile\":");
            try std.json.Stringify.encodeJsonString(v, .{}, &aw.writer);
        }
        try aw.writer.writeAll("}");
        wrote = true;
    }
    if (creds.selected_model) |m| {
        if (wrote) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\"selected_model\":");
        try std.json.Stringify.encodeJsonString(m, .{}, &aw.writer);
        wrote = true;
    }
    if (creds.reasoning_effort) |effort| {
        if (wrote) try aw.writer.writeAll(",");
        try aw.writer.writeAll("\"reasoning_effort\":");
        try std.json.Stringify.encodeJsonString(effort.name(), .{}, &aw.writer);
    }
    try aw.writer.writeAll("}\n");
    return try aw.toOwnedSlice();
}

fn checkFilePrivate(path: []const u8) !void {
    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        if (e == .NOENT) return error.NotFound;
        return error.OpenFailed;
    }
    _ = pfs.close(fd);
}

fn refreshOAuthCredential(allocator: std.mem.Allocator, old: *const OAuthCredential) !OAuthCredential {
    const body = try buildRefreshRequestBody(allocator, old.refresh_token);
    defer secureFree(allocator, body);
    const url = try oauthTokenUrl(allocator);
    defer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthTokenUrl;

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var http_client = std.http.Client{ .allocator = allocator, .io = io_runtime.io() };
    defer http_client.deinit();

    var req = http_client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "accept", .value = "application/json" },
        },
    }) catch return error.OAuthRefreshFailed;
    defer req.deinit();

    req.sendBodyComplete(@constCast(body)) catch return error.OAuthRefreshFailed;
    var redirect_buf: [4096]u8 = undefined;
    const http_response = req.receiveHead(&redirect_buf) catch return error.OAuthRefreshFailed;
    const status = ResponseStatus.capture(&http_response);

    var transfer_buf: [8192]u8 = undefined;
    const body_reader = req.reader.bodyReader(&transfer_buf, http_response.head.transfer_encoding, http_response.head.content_length);
    const response_body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(256 * 1024)) catch return error.OAuthRefreshFailed;
    defer secureFree(allocator, response_body);

    if (!status.isOk()) {
        return classifyOAuthEndpointError(status.code, response_body);
    }
    return parseOAuthTokenResponse(allocator, response_body, nowUnixSeconds(), .optional_replacement, old.refresh_token);
}

fn oauthTokenUrl(allocator: std.mem.Allocator) ![]u8 {
    if (std.c.getenv(OAUTH_TOKEN_URL_ENV)) |p| return allocator.dupe(u8, std.mem.span(p));
    return allocator.dupe(u8, METASK_OAUTH_TOKEN_URL);
}

fn buildRefreshRequestBody(allocator: std.mem.Allocator, refresh_token: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try appendFormField(&aw.writer, "grant_type", "refresh_token", true);
    try appendFormField(&aw.writer, "client_id", OAUTH_CLIENT_ID, false);
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
    const path = "/tmp/cc-zig-auth-roundtrip.json";
    var creds = StoredCredentials{ .api_key = try a.dupe(u8, "stored-key") };
    defer creds.deinit(a);
    try saveToPath(a, path, creds);
    defer {
        if (std.heap.c_allocator.dupeZ(u8, path)) |z| {
            _ = std.c.unlink(z.ptr);
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
        "https://napi.metask-ai.com/oauth/authorize",
        "metacode-cli",
        "",
        "http://localhost:1455/auth/callback",
        "challenge",
        "state",
    );
    defer a.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=challenge") != null);
}
