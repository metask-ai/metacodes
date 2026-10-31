//! MCP authorization for HTTP servers (basic/authorization.mdx, revisions
//! 2025-03-26 through 2025-11-25): discovery, login, token storage and
//! refresh.
//!
//! - **Discovery.** A 401's `WWW-Authenticate: Bearer resource_metadata=…`
//!   (or the RFC 9728 well-known locations) names the protected resource's
//!   metadata; its `authorization_servers[0]` is the issuer whose RFC 8414 /
//!   OpenID Connect metadata gives the endpoints. A server that publishes no
//!   resource metadata is treated as a 2025-03-26 server: the authorization
//!   server is the MCP URL's origin, with `/authorize`, `/token` and
//!   `/register` as defaults when it has no metadata either.
//! - **Login** (`metacodes mcp login <server>`): a pre-configured client
//!   (`oauth.clientId`) or RFC 7591 dynamic registration, then the
//!   authorization code grant with PKCE S256 and a loopback redirect
//!   (`http://localhost:<port>/callback`), with the RFC 8707 `resource`
//!   parameter on both the authorization and the token request.
//! - **Storage.** One 0600 file per (server name, URL) under
//!   `<state root>/mcp-oauth/`, written atomically: a rotated refresh token
//!   is the only copy the user has.
//! - **Use.** `TokenSource` hands the transports the current bearer,
//!   refreshes it before it expires and once after the server rejects it
//!   (single flight: N requests that see one 401 perform one refresh).
//!
//! Static configuration wins: a server whose headers or
//! `bearerTokenEnvVar` already set `Authorization` never gets a stored
//! token.

const std = @import("std");
const auth = @import("../core/auth.zig");
const provider_oauth = @import("../provider/oauth.zig");
const provider = @import("../api/provider.zig");
const http_status = @import("../api/http_status.zig");
const http_connection = @import("../api/http_connection.zig");
const util_time = @import("../util/time.zig");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const net = @import("platform").net;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const config = @import("config.zig");
const url_util = @import("url.zig");

/// Sent on discovery requests (basic/authorization.mdx: clients SHOULD
/// include `MCP-Protocol-Version` during metadata discovery).
pub const DISCOVERY_PROTOCOL_VERSION = "2025-11-25";
/// Refresh this long before the reported expiry, so a token never expires
/// between being attached and being checked.
pub const REFRESH_MARGIN_SECONDS: i64 = 60;
/// Silence after which a discovery, registration or token request is cut.
const HTTP_IDLE_LIMIT_MS: u64 = 30_000;
const MAX_METADATA_BYTES: usize = 256 * 1024;
pub const CALLBACK_PATH = "/callback";
const STORE_DIR = "mcp-oauth";
const STORE_VERSION: u32 = 1;

pub const Error = error{
    /// The server neither challenged nor published resource metadata.
    McpOAuthNotAdvertised,
    /// No authorization server metadata, and no 2025-03-26 fallback applies.
    McpOAuthMetadataUnavailable,
    /// The authorization server does not list S256 in
    /// `code_challenge_methods_supported` (the client MUST refuse).
    McpOAuthPkceUnsupported,
    /// An endpoint is plain HTTP on a non-loopback host.
    McpOAuthInsecureEndpoint,
    /// The resource metadata names a resource that does not cover this URL.
    McpOAuthResourceMismatch,
    /// The metadata's `issuer` is not the authorization server it came from.
    McpOAuthIssuerMismatch,
    /// No `oauth.clientId` and no registration endpoint.
    McpOAuthNoClient,
    McpOAuthRegistrationFailed,
    McpOAuthTokenRequestFailed,
    /// The authorization server refused the grant (`invalid_grant`, …).
    McpOAuthTokenRejected,
    McpOAuthMalformedResponse,
    McpOAuthNetwork,
    McpOAuthNoStateRoot,
    McpOAuthPersistFailed,
    McpOAuthCallbackPortBusy,
};

// ============================================================================
// WWW-Authenticate
// ============================================================================

/// The `Bearer` challenge of a `WWW-Authenticate` header. Slices borrow the
/// header; quoted values are returned without their quotes.
pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parse the `Bearer` challenge (RFC 6750 §3, RFC 9728 §5.1) out of a
/// header that may carry several. Null when there is none.
pub fn parseChallenge(header: []const u8) ?Challenge {
    var index: usize = 0;
    while (index < header.len) {
        index = skipSeparators(header, index);
        const scheme_start = index;
        while (index < header.len and isTokenChar(header[index])) index += 1;
        const scheme = header[scheme_start..index];
        if (scheme.len == 0) {
            index += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(scheme, "bearer")) return parseParams(header, index);
        // Skip this scheme's parameters up to the next scheme.
        index = skipParams(header, index);
    }
    return null;
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null;
}

fn skipSeparators(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t' or text[index] == ',')) index += 1;
    return index;
}

const Param = struct { key: []const u8, value: []const u8, end: usize };

/// One `key=value` / `key="value"` at `start`, or null when the next token
/// is a new scheme (no `=` after it).
fn nextParam(text: []const u8, start: usize) ?Param {
    var index = skipSeparators(text, start);
    const key_start = index;
    while (index < text.len and isTokenChar(text[index])) index += 1;
    const key = text[key_start..index];
    if (key.len == 0) return null;
    while (index < text.len and text[index] == ' ') index += 1;
    if (index >= text.len or text[index] != '=') return null;
    index += 1;
    while (index < text.len and text[index] == ' ') index += 1;
    if (index < text.len and text[index] == '"') {
        const value_start = index + 1;
        var cursor = value_start;
        while (cursor < text.len and text[cursor] != '"') : (cursor += 1) {
            if (text[cursor] == '\\') cursor += 1;
        }
        const value_end = @min(cursor, text.len);
        return .{ .key = key, .value = text[value_start..value_end], .end = @min(cursor + 1, text.len) };
    }
    const value_start = index;
    while (index < text.len and text[index] != ',' and text[index] != ' ') index += 1;
    return .{ .key = key, .value = text[value_start..index], .end = index };
}

fn parseParams(text: []const u8, start: usize) Challenge {
    var challenge: Challenge = .{};
    var index = start;
    while (nextParam(text, index)) |param| {
        index = param.end;
        if (std.ascii.eqlIgnoreCase(param.key, "resource_metadata")) challenge.resource_metadata = param.value;
        if (std.ascii.eqlIgnoreCase(param.key, "scope")) challenge.scope = param.value;
        if (std.ascii.eqlIgnoreCase(param.key, "error")) challenge.@"error" = param.value;
    }
    return challenge;
}

fn skipParams(text: []const u8, start: usize) usize {
    var index = start;
    while (nextParam(text, index)) |param| index = param.end;
    return index;
}

// ============================================================================
// HTTP
// ============================================================================

const Response = struct {
    status: u16,
    /// Empty when not read.
    body: []const u8,
    www_authenticate: ?[]const u8,
};

/// What may cut a request short: the caller's interrupt and its deadline
/// (absolute, `util_time.nowMs`).
pub const Interrupt = struct {
    abort: ?*const AbortSignal = null,
    deadline_ms: ?i64 = null,

    fn idleLimitMs(self: Interrupt) u64 {
        const deadline = self.deadline_ms orelse return HTTP_IDLE_LIMIT_MS;
        const remaining = deadline - util_time.nowMs();
        return @min(HTTP_IDLE_LIMIT_MS, @as(u64, @intCast(@max(remaining, 1))));
    }

    fn expired(self: Interrupt) bool {
        if (self.abort) |signal| if (signal.isAborted()) return true;
        if (self.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return true;
        return false;
    }
};

const RequestSpec = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    headers: []const std.http.Header = &.{},
    content_type: ?[]const u8 = null,
    body: ?[]const u8 = null,
    /// Metadata documents may move (`.well-known` behind a redirect); a
    /// request that carries a grant, a token or configured headers never
    /// follows one (`http_status.no_redirects`).
    follow_redirects: bool = false,
    /// A probe of an event stream reads the head only.
    read_body: bool = true,
};

/// One request on a fresh client, cut after `HTTP_IDLE_LIMIT_MS` of silence
/// (less when the deadline is nearer) or when `abort` fires. Strings land in
/// `arena`.
fn send(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, spec: RequestSpec, interrupt: Interrupt) !Response {
    const abort = interrupt.abort;
    if (interrupt.expired()) return interrupted(interrupt);
    const uri = std.Uri.parse(spec.url) catch return error.InvalidUrl;
    var registry: provider.RequestAbortRegistry = .{};
    defer registry.deinit(gpa);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var request = client.request(spec.method, uri, .{
        .headers = .{
            .accept_encoding = .omit,
            .content_type = if (spec.content_type) |value| .{ .override = value } else .default,
        },
        .redirect_behavior = if (spec.follow_redirects) .init(3) else http_status.no_redirects,
        .extra_headers = spec.headers,
    }) catch return Error.McpOAuthNetwork;
    defer request.deinit();
    try registry.registerMonitored(gpa, abort, @ptrCast(&request), shutdownRequest, interrupt.idleLimitMs());
    defer registry.unregister(@ptrCast(&request));
    if (spec.body) |body| {
        http_connection.sendBodyComplete(&request, @constCast(body)) catch return interrupted(interrupt);
    } else {
        http_connection.sendBodiless(&request) catch return interrupted(interrupt);
    }
    var redirect: [4096]u8 = undefined;
    var response = request.receiveHead(&redirect) catch return interrupted(interrupt);
    const status = http_status.ResponseStatus.capture(&response).code;
    var www_authenticate: ?[]const u8 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "www-authenticate") and www_authenticate == null)
            www_authenticate = try arena.dupe(u8, header.value);
    }
    if (!spec.read_body) return .{ .status = status, .body = "", .www_authenticate = www_authenticate };
    var transfer: [8192]u8 = undefined;
    const reader = response.reader(&transfer);
    const body = reader.allocRemaining(arena, .limited(MAX_METADATA_BYTES)) catch return interrupted(interrupt);
    return .{ .status = status, .body = body, .www_authenticate = www_authenticate };
}

fn interrupted(interrupt: Interrupt) anyerror {
    if (interrupt.abort) |signal| if (signal.isAborted()) return error.Aborted;
    if (interrupt.deadline_ms) |deadline| if (util_time.nowMs() >= deadline) return error.Timeout;
    return Error.McpOAuthNetwork;
}

fn shutdownRequest(raw: *anyopaque) void {
    const request: *std.http.Client.Request = @ptrCast(@alignCast(raw));
    provider.abortHttpRequest(request);
}

/// GET a JSON metadata document; null for any non-2xx answer or a body
/// that is not a JSON object.
fn fetchMetadata(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, url: []const u8, abort: ?*const AbortSignal) !?std.json.ObjectMap {
    const response = send(arena, gpa, io, .{
        .url = url,
        .headers = &.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "MCP-Protocol-Version", .value = DISCOVERY_PROTOCOL_VERSION },
        },
        .follow_redirects = true,
    }, .{ .abort = abort }) catch |err| switch (err) {
        error.Aborted, error.OutOfMemory => return err,
        else => return null,
    };
    if (response.status < 200 or response.status >= 300) return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return null;
    if (parsed != .object) return null;
    return parsed.object;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn stringArray(arena: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = object.get(key) orelse return &.{};
    if (value != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| if (item == .string) try out.append(arena, item.string);
    return out.toOwnedSlice(arena);
}

// ============================================================================
// Discovery
// ============================================================================

/// Where and how to authorize for one MCP server. Strings live in the
/// discovery arena.
pub const Plan = struct {
    /// RFC 8707 `resource`.
    resource: []const u8,
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8,
    /// Space-separated, or null to request the server's default.
    scope: ?[]const u8,
};

pub const Target = struct {
    url: []const u8,
    wire: config.HttpWire,
    /// Configured headers (never an Authorization: a server with one does
    /// not log in).
    headers: []const std.http.Header = &.{},
};

/// An unauthenticated request in the server's own transport: the 401 it
/// earns names the resource metadata and the scopes to ask for.
fn probe(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, target: Target, abort: ?*const AbortSignal) !Response {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.appendSlice(arena, target.headers);
    switch (target.wire) {
        .streamable => {
            try headers.append(arena, .{ .name = "Accept", .value = "application/json, text/event-stream" });
            const body =
                \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"metacodes","version":"login"}}}
            ;
            return send(arena, gpa, io, .{
                .method = .POST,
                .url = target.url,
                .headers = headers.items,
                .content_type = "application/json",
                .body = body,
                .read_body = false,
            }, .{ .abort = abort });
        },
        .legacy_sse => {
            try headers.append(arena, .{ .name = "Accept", .value = "text/event-stream" });
            return send(arena, gpa, io, .{ .url = target.url, .headers = headers.items, .read_body = false }, .{ .abort = abort });
        },
    }
}

pub fn discover(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    target: Target,
    settings: config.OAuthSettings,
    abort: ?*const AbortSignal,
) !Plan {
    const probed = probe(arena, gpa, io, target, abort) catch |err| switch (err) {
        error.Aborted, error.OutOfMemory => return err,
        else => Response{ .status = 0, .body = "", .www_authenticate = null },
    };
    const challenge: Challenge = if (probed.status == 401 or probed.status == 403)
        (if (probed.www_authenticate) |header| parseChallenge(header) orelse .{} else .{})
    else
        .{};

    // Protected resource metadata: the challenge's pointer, else the
    // well-known locations.
    var resource_metadata: ?std.json.ObjectMap = null;
    if (challenge.resource_metadata) |location| {
        if (!url_util.isSecureEndpoint(location)) return Error.McpOAuthInsecureEndpoint;
        resource_metadata = try fetchMetadata(arena, gpa, io, location, abort);
    }
    if (resource_metadata == null) {
        for (try url_util.protectedResourceMetadataUrls(arena, target.url)) |candidate| {
            resource_metadata = try fetchMetadata(arena, gpa, io, candidate, abort);
            if (resource_metadata != null) break;
        }
    }
    if (resource_metadata == null and probed.status != 401 and settings.auth_server_metadata_url == null)
        return if (probed.status == 0) Error.McpOAuthNetwork else Error.McpOAuthNotAdvertised;

    var resource = try url_util.canonicalResource(arena, target.url);
    var issuer: []const u8 = try url_util.origin(arena, target.url);
    var resource_scopes: []const []const u8 = &.{};
    // 2025-03-26: no resource metadata, the MCP origin is the authorization
    // server and its endpoints may be the spec's defaults.
    var legacy = true;
    if (resource_metadata) |metadata| {
        legacy = false;
        if (stringField(metadata, "resource")) |advertised| {
            if (!url_util.resourceCovers(advertised, target.url)) return Error.McpOAuthResourceMismatch;
            resource = advertised;
        }
        const servers = try stringArray(arena, metadata, "authorization_servers");
        if (servers.len == 0) return Error.McpOAuthMetadataUnavailable;
        issuer = servers[0];
        resource_scopes = try stringArray(arena, metadata, "scopes_supported");
    }
    if (!url_util.isSecureEndpoint(issuer)) return Error.McpOAuthInsecureEndpoint;

    var server_metadata: ?std.json.ObjectMap = null;
    if (settings.auth_server_metadata_url) |location| {
        server_metadata = try fetchMetadata(arena, gpa, io, location, abort);
        if (server_metadata == null) return Error.McpOAuthMetadataUnavailable;
    } else {
        for (try url_util.authorizationServerMetadataUrls(arena, issuer)) |candidate| {
            server_metadata = try fetchMetadata(arena, gpa, io, candidate, abort);
            if (server_metadata != null) break;
        }
    }

    var plan: Plan = .{
        .resource = resource,
        .issuer = issuer,
        .authorization_endpoint = undefined,
        .token_endpoint = undefined,
        .registration_endpoint = null,
        .scope = null,
    };
    if (server_metadata) |metadata| {
        if (stringField(metadata, "issuer")) |claimed| {
            if (settings.auth_server_metadata_url == null and
                !std.mem.eql(u8, std.mem.trimEnd(u8, claimed, "/"), std.mem.trimEnd(u8, issuer, "/")))
                return Error.McpOAuthIssuerMismatch;
            plan.issuer = claimed;
        }
        plan.authorization_endpoint = stringField(metadata, "authorization_endpoint") orelse return Error.McpOAuthMetadataUnavailable;
        plan.token_endpoint = stringField(metadata, "token_endpoint") orelse return Error.McpOAuthMetadataUnavailable;
        plan.registration_endpoint = stringField(metadata, "registration_endpoint");
        const methods = try stringArray(arena, metadata, "code_challenge_methods_supported");
        const s256 = for (methods) |method| {
            if (std.mem.eql(u8, method, "S256")) break true;
        } else false;
        if (!s256) return Error.McpOAuthPkceUnsupported;
    } else if (legacy) {
        const base = try url_util.origin(arena, issuer);
        plan.authorization_endpoint = try std.fmt.allocPrint(arena, "{s}/authorize", .{base});
        plan.token_endpoint = try std.fmt.allocPrint(arena, "{s}/token", .{base});
        plan.registration_endpoint = try std.fmt.allocPrint(arena, "{s}/register", .{base});
    } else {
        return Error.McpOAuthMetadataUnavailable;
    }
    for ([_][]const u8{ plan.authorization_endpoint, plan.token_endpoint }) |endpoint| {
        if (!url_util.isSecureEndpoint(endpoint)) return Error.McpOAuthInsecureEndpoint;
    }
    if (plan.registration_endpoint) |endpoint| if (!url_util.isSecureEndpoint(endpoint)) return Error.McpOAuthInsecureEndpoint;

    // Scope selection (basic/authorization.mdx): the user's configuration,
    // then the challenge, then everything the resource lists.
    plan.scope = settings.scopes orelse challenge.scope orelse
        (if (resource_scopes.len != 0) try std.mem.join(arena, " ", resource_scopes) else null);
    return plan;
}

// ============================================================================
// Stored credentials
// ============================================================================

/// What `<state root>/mcp-oauth/<file>.json` holds. Every string is owned by
/// the allocator `deinit` is given.
pub const Record = struct {
    version: u32 = STORE_VERSION,
    server: []const u8,
    url: []const u8,
    resource: []const u8,
    issuer: []const u8,
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    /// Unix seconds; null when the server stated no lifetime.
    expires_at: ?i64 = null,
    scope: ?[]const u8 = null,

    pub fn deinit(self: *Record, gpa: std.mem.Allocator) void {
        inline for (std.meta.fields(Record)) |field| {
            switch (field.type) {
                []const u8 => wipe(gpa, @field(self, field.name)),
                ?[]const u8 => if (@field(self, field.name)) |value| wipe(gpa, value),
                else => {},
            }
        }
        self.* = undefined;
    }

    fn clone(self: Record, gpa: std.mem.Allocator) !Record {
        var out: Record = self;
        var done: usize = 0;
        errdefer {
            inline for (std.meta.fields(Record), 0..) |field, index| {
                if (index < done) switch (field.type) {
                    []const u8 => wipe(gpa, @field(out, field.name)),
                    ?[]const u8 => if (@field(out, field.name)) |value| wipe(gpa, value),
                    else => {},
                };
            }
        }
        inline for (std.meta.fields(Record)) |field| {
            switch (field.type) {
                []const u8 => @field(out, field.name) = try gpa.dupe(u8, @field(self, field.name)),
                ?[]const u8 => @field(out, field.name) = if (@field(self, field.name)) |value| try gpa.dupe(u8, value) else null,
                else => {},
            }
            done += 1;
        }
        return out;
    }

    pub fn isExpiredAt(self: Record, now_seconds: i64) bool {
        const expires_at = self.expires_at orelse return false;
        return now_seconds + REFRESH_MARGIN_SECONDS >= expires_at;
    }
};

fn wipe(gpa: std.mem.Allocator, bytes: []const u8) void {
    const mutable: []u8 = @constCast(bytes);
    std.crypto.secureZero(u8, mutable);
    gpa.free(mutable);
}

/// `<state root>/mcp-oauth/<name>-<16 hex of sha256(name NUL url)>.json`:
/// readable, and a token for one URL is never found under another.
pub fn storePath(gpa: std.mem.Allocator, state_root: []const u8, server_name: []const u8, server_url: []const u8) ![]u8 {
    if (state_root.len == 0) return Error.McpOAuthNoStateRoot;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(server_name);
    hasher.update(&.{0});
    hasher.update(server_url);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var safe: [48]u8 = undefined;
    const length = @min(server_name.len, safe.len);
    for (server_name[0..length], safe[0..length]) |c, *out| {
        out.* = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') c else '_';
    }
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    const file = try std.fmt.allocPrint(gpa, "{s}-{s}.json", .{ safe[0..length], &hex });
    defer gpa.free(file);
    return std.fs.path.join(gpa, &.{ state_root, STORE_DIR, file });
}

/// The stored record, or null when there is none (or it is for another
/// URL, or unreadable — a broken file means "log in again").
pub fn loadRecord(gpa: std.mem.Allocator, path: []const u8, server_url: []const u8) !?Record {
    const bytes = provider_oauth.readFile(gpa, path) catch return null;
    defer provider_oauth.secureFree(gpa, bytes);
    var parsed = std.json.parseFromSlice(Record, gpa, bytes, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (parsed.value.version != STORE_VERSION) return null;
    if (!std.mem.eql(u8, parsed.value.url, server_url)) return null;
    if (parsed.value.access_token.len == 0) return null;
    return try parsed.value.clone(gpa);
}

pub fn saveRecord(gpa: std.mem.Allocator, path: []const u8, record: Record) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, record, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 });
    defer provider_oauth.secureFree(gpa, bytes);
    provider_oauth.writeAtomicPrivate(gpa, path, bytes) catch return Error.McpOAuthPersistFailed;
}

/// Forget the stored login. True when there was one.
pub fn removeRecord(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    pfs.unlinkPath(path_z) catch |err| switch (err) {
        error.NotFound => return false,
        else => return Error.McpOAuthPersistFailed,
    };
    return true;
}

// ============================================================================
// Token endpoint
// ============================================================================

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8,
    expires_in: ?i64,
    scope: ?[]const u8,
};

fn parseTokenResponse(arena: std.mem.Allocator, body: []const u8) !TokenResponse {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return Error.McpOAuthMalformedResponse;
    if (parsed != .object) return Error.McpOAuthMalformedResponse;
    const object = parsed.object;
    const access_token = stringField(object, "access_token") orelse return Error.McpOAuthMalformedResponse;
    if (stringField(object, "token_type")) |token_type| {
        if (!std.ascii.eqlIgnoreCase(token_type, "bearer")) return Error.McpOAuthMalformedResponse;
    }
    const expires_in: ?i64 = if (object.get("expires_in")) |value| switch (value) {
        .integer => |seconds| if (seconds > 0) seconds else null,
        .float => |seconds| if (seconds > 0 and seconds < 1e12) @intFromFloat(seconds) else null,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    } else null;
    return .{
        .access_token = access_token,
        .refresh_token = stringField(object, "refresh_token"),
        .expires_in = expires_in,
        .scope = stringField(object, "scope"),
    };
}

/// POST a token request. An `error` the server names (`invalid_grant`,
/// `invalid_client`) is a rejection; anything else is a failure.
fn tokenRequest(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, endpoint: []const u8, form: []const u8, interrupt: Interrupt) !TokenResponse {
    const response = send(arena, gpa, io, .{
        .method = .POST,
        .url = endpoint,
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .content_type = "application/x-www-form-urlencoded",
        .body = form,
    }, interrupt) catch |err| switch (err) {
        error.Aborted, error.OutOfMemory => return err,
        else => return Error.McpOAuthTokenRequestFailed,
    };
    if (response.status >= 200 and response.status < 300) return parseTokenResponse(arena, response.body);
    if (response.status == 400 or response.status == 401) return Error.McpOAuthTokenRejected;
    return Error.McpOAuthTokenRequestFailed;
}

fn appendClientAuth(writer: *std.Io.Writer, record_client_id: []const u8, client_secret: ?[]const u8) !void {
    try auth.appendFormField(writer, "client_id", record_client_id, false);
    if (client_secret) |secret| try auth.appendFormField(writer, "client_secret", secret, false);
}

// ============================================================================
// TokenSource: the transports' view of a stored login
// ============================================================================

/// A stored login shared by one server's transport. Thread-safe: a
/// refresh is single flight within the process, and the store is re-read
/// before refreshing, so a token another session already rotated is adopted
/// rather than refreshed again with a dead refresh token.
pub const TokenSource = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    mutex: sync.Mutex = .{},
    record: Record,
    /// Bumped whenever the token changes; a transport that sent generation
    /// N and got a 401 refreshes only if nobody has moved past N yet.
    generation: u64 = 1,
    /// The refresh token was refused: only a new login helps.
    dead: bool = false,
    /// After a refresh that failed for want of a network, the next attempt
    /// waits until then (`util_time.nowMs`), so every request does not pay
    /// for an unreachable authorization server.
    retry_after_ms: i64 = 0,
    /// The last rotation could not be written: the file holds a token the
    /// server already revoked, which must not be adopted back.
    store_stale: bool = false,

    /// The stored login for this server, or null when there is none.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, state_root: []const u8, server_name: []const u8, server_url: []const u8) !?*TokenSource {
        const path = storePath(gpa, state_root, server_name, server_url) catch |err| switch (err) {
            Error.McpOAuthNoStateRoot => return null,
            else => return err,
        };
        errdefer gpa.free(path);
        var record = (try loadRecord(gpa, path, server_url)) orelse {
            gpa.free(path);
            return null;
        };
        errdefer record.deinit(gpa);
        const self = try gpa.create(TokenSource);
        self.* = .{ .gpa = gpa, .io = io, .path = path, .record = record };
        return self;
    }

    pub fn destroy(self: *TokenSource) void {
        const gpa = self.gpa;
        self.record.deinit(gpa);
        gpa.free(self.path);
        gpa.destroy(self);
    }

    /// `Authorization` value for the current token, refreshed first when it
    /// is about to expire. Copies into `out` (gpa-owned) only when the
    /// generation moved past `seen`.
    pub fn current(self: *TokenSource, out_gpa: std.mem.Allocator, seen: *u64, out: *?[]u8, interrupt: Interrupt) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.record.isExpiredAt(util_time.nowUnix())) {
            if (!self.adoptStoredLocked()) _ = self.refreshLocked(interrupt);
        }
        if (seen.* == self.generation and out.* != null) return;
        const value = std.fmt.allocPrint(out_gpa, "Bearer {s}", .{self.record.access_token}) catch return;
        if (out.*) |old| wipe(out_gpa, old);
        out.* = value;
        seen.* = self.generation;
    }

    /// The server answered 401 to a request that carried generation `sent`.
    /// True when a newer token is available (another request or session
    /// refreshed, or this call did).
    pub fn recover(self: *TokenSource, sent: u64, interrupt: Interrupt) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.generation != sent) return true;
        if (self.adoptStoredLocked()) return true;
        return self.refreshLocked(interrupt);
    }

    /// Another process may have refreshed (and rotated) since this one
    /// loaded the store: take its token instead of spending ours.
    fn adoptStoredLocked(self: *TokenSource) bool {
        if (self.store_stale) return false;
        var stored = (loadRecord(self.gpa, self.path, self.record.url) catch null) orelse return false;
        const changed = !std.mem.eql(u8, stored.access_token, self.record.access_token);
        if (!changed) {
            stored.deinit(self.gpa);
            return false;
        }
        self.record.deinit(self.gpa);
        self.record = stored;
        self.generation += 1;
        self.dead = false;
        return true;
    }

    fn refreshLocked(self: *TokenSource, interrupt: Interrupt) bool {
        if (self.dead) return false;
        const refresh_token = self.record.refresh_token orelse return false;
        if (util_time.nowMs() < self.retry_after_ms) return false;
        const log = @import("../util/log.zig");
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var form: std.Io.Writer.Allocating = .init(arena);
        auth.appendFormField(&form.writer, "grant_type", "refresh_token", true) catch return false;
        auth.appendFormField(&form.writer, "refresh_token", refresh_token, false) catch return false;
        appendClientAuth(&form.writer, self.record.client_id, self.record.client_secret) catch return false;
        auth.appendFormField(&form.writer, "resource", self.record.resource, false) catch return false;
        const response = tokenRequest(arena, self.gpa, self.io, self.record.token_endpoint, form.written(), interrupt) catch |err| {
            switch (err) {
                Error.McpOAuthTokenRejected => self.dead = true,
                error.Aborted => {},
                else => self.retry_after_ms = util_time.nowMs() + @as(i64, @intCast(HTTP_IDLE_LIMIT_MS)),
            }
            log.warn("mcp", "OAuth refresh for '{s}' failed: {s}", .{ self.record.server, @errorName(err) });
            return false;
        };
        var next = self.record;
        next.access_token = response.access_token;
        // Absent: the server kept the refresh token.
        if (response.refresh_token) |rotated| next.refresh_token = rotated;
        next.expires_at = if (response.expires_in) |seconds| util_time.nowUnix() + seconds else null;
        if (response.scope) |scope| next.scope = scope;
        const owned = next.clone(self.gpa) catch return false;
        // Persist before switching: a rotated refresh token that only lives
        // in memory dies with the process. If the write fails, the new token
        // is still the only valid one, so it is used — and the user is told
        // that the next session will need a new login.
        self.store_stale = false;
        saveRecord(self.gpa, self.path, owned) catch |err| {
            self.store_stale = true;
            log.err("mcp", "OAuth token for '{s}' could not be saved to {s} ({s}); this session keeps working, the next one will need `metacodes mcp login {s}`", .{ self.record.server, self.path, @errorName(err), self.record.server });
        };
        self.record.deinit(self.gpa);
        self.record = owned;
        self.generation += 1;
        return true;
    }
};

/// One transport's bearer state: the source it draws from and the header
/// value it last sent.
pub const Bearer = struct {
    source: ?*TokenSource = null,
    /// `Bearer <token>`, owned by the transport's allocator.
    value: ?[]u8 = null,
    generation: u64 = 0,

    /// Bring `value` up to date (refreshing an expiring token within the
    /// caller's interrupt and deadline).
    pub fn sync(self: *Bearer, gpa: std.mem.Allocator, interrupt: Interrupt) void {
        const source = self.source orelse return;
        source.current(gpa, &self.generation, &self.value, interrupt);
    }

    /// After a 401: true when a new token was obtained and the request is
    /// worth one more try.
    pub fn recover(self: *Bearer, gpa: std.mem.Allocator, interrupt: Interrupt) bool {
        const source = self.source orelse return false;
        if (!source.recover(self.generation, interrupt)) return false;
        self.sync(gpa, interrupt);
        return true;
    }

    pub fn header(self: *const Bearer) ?std.http.Header {
        const value = self.value orelse return null;
        return .{ .name = "Authorization", .value = value };
    }

    pub fn deinit(self: *Bearer, gpa: std.mem.Allocator) void {
        if (self.value) |value| wipe(gpa, value);
        if (self.source) |source| source.destroy();
        self.* = .{};
    }
};

// ============================================================================
// Login
// ============================================================================

/// Human-facing instructions (the URL to open): the flow, not diagnostics.
pub const Notify = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, text: []const u8) void,

    pub fn say(self: Notify, text: []const u8) void {
        self.write(self.ctx, text);
    }
};

/// Receives the authorization URL in place of a browser (tests, or a host
/// that shows it its own way).
pub const OpenUrl = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, url: []const u8) void,
};

pub const LoginOptions = struct {
    open_browser: bool = true,
    notify: ?Notify = null,
    open_url: ?OpenUrl = null,
    abort: ?*const AbortSignal = null,
};

pub const Server = struct {
    name: []const u8,
    target: Target,
    settings: config.OAuthSettings = .{},
};

pub const LoginResult = struct {
    path: []u8,
    issuer: []u8,
    scope: ?[]u8,
    expires_at: ?i64,

    pub fn deinit(self: *LoginResult, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.issuer);
        if (self.scope) |scope| gpa.free(scope);
        self.* = undefined;
    }
};

const Client = struct { id: []const u8, secret: ?[]const u8 };

/// RFC 7591 registration of a public client for this redirect.
fn register(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, endpoint: []const u8, redirect_uri: []const u8, scope: ?[]const u8, abort: ?*const AbortSignal) !Client {
    const request = .{
        .client_name = "metacodes",
        .redirect_uris = &[_][]const u8{redirect_uri},
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .token_endpoint_auth_method = "none",
        .scope = scope,
    };
    const body = try std.json.Stringify.valueAlloc(arena, request, .{ .emit_null_optional_fields = false });
    const response = send(arena, gpa, io, .{
        .method = .POST,
        .url = endpoint,
        .headers = &.{.{ .name = "Accept", .value = "application/json" }},
        .content_type = "application/json",
        .body = body,
    }, .{ .abort = abort }) catch |err| switch (err) {
        error.Aborted, error.OutOfMemory => return err,
        else => return Error.McpOAuthRegistrationFailed,
    };
    if (response.status < 200 or response.status >= 300) return Error.McpOAuthRegistrationFailed;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, response.body, .{}) catch return Error.McpOAuthMalformedResponse;
    if (parsed != .object) return Error.McpOAuthMalformedResponse;
    return .{
        .id = stringField(parsed.object, "client_id") orelse return Error.McpOAuthMalformedResponse,
        .secret = stringField(parsed.object, "client_secret"),
    };
}

fn bindCallback(settings: config.OAuthSettings) !auth.CallbackServer {
    if (settings.callback_port) |port| {
        // A pre-registered redirect names this port exactly: another one
        // would be refused by the authorization server.
        const listener = net.listenLoopback(port, 4) catch return Error.McpOAuthCallbackPortBusy;
        return .{ .sock = listener.sock, .port = listener.port, .path = CALLBACK_PATH };
    }
    const listener = net.listenLoopback(0, 4) catch return Error.McpOAuthCallbackPortBusy;
    return .{ .sock = listener.sock, .port = listener.port, .path = CALLBACK_PATH };
}

/// Run the whole flow for one server and store the result.
pub fn login(
    gpa: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    server: Server,
    options: LoginOptions,
) !LoginResult {
    const path = try storePath(gpa, state_root, server.name, server.target.url);
    errdefer gpa.free(path);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plan = try discover(arena, gpa, io, server.target, server.settings, options.abort);

    var callback = try bindCallback(server.settings);
    defer callback.close();
    const redirect_uri = try std.fmt.allocPrint(arena, "http://localhost:{d}{s}", .{ callback.port, CALLBACK_PATH });

    const client: Client = if (server.settings.client_id) |id|
        .{ .id = id, .secret = null }
    else if (plan.registration_endpoint) |endpoint|
        try register(arena, gpa, io, endpoint, redirect_uri, plan.scope, options.abort)
    else
        return Error.McpOAuthNoClient;

    var pkce = try auth.generatePkce(gpa);
    defer pkce.deinit(gpa);
    const state = try auth.randomBase64Url(gpa, 32);
    defer auth.secureFree(gpa, state);

    var authorize: std.Io.Writer.Allocating = .init(arena);
    try authorize.writer.writeAll(plan.authorization_endpoint);
    try authorize.writer.writeByte(if (std.mem.indexOfScalar(u8, plan.authorization_endpoint, '?') == null) '?' else '&');
    try auth.appendFormField(&authorize.writer, "response_type", "code", true);
    try auth.appendFormField(&authorize.writer, "client_id", client.id, false);
    try auth.appendFormField(&authorize.writer, "redirect_uri", redirect_uri, false);
    if (plan.scope) |scope| try auth.appendFormField(&authorize.writer, "scope", scope, false);
    try auth.appendFormField(&authorize.writer, "state", state, false);
    try auth.appendFormField(&authorize.writer, "code_challenge", pkce.code_challenge, false);
    try auth.appendFormField(&authorize.writer, "code_challenge_method", "S256", false);
    try auth.appendFormField(&authorize.writer, "resource", plan.resource, false);
    const authorize_url = authorize.written();

    if (options.notify) |notify| {
        const text = try std.fmt.allocPrint(arena, "Authorize metacodes for MCP server '{s}' ({s}).\nOpen this URL if no browser window appears:\n\n{s}\n\nWaiting for the redirect on {s} …\n", .{ server.name, plan.issuer, authorize_url, redirect_uri });
        notify.say(text);
    }
    if (options.open_url) |opener| {
        opener.open(opener.ctx, authorize_url);
    } else if (options.open_browser) {
        auth.openBrowser(gpa, authorize_url) catch {};
    }

    const code = try callback.waitForAuthorizationCode(gpa, state, options.abort);
    defer auth.secureFree(gpa, code);

    var form: std.Io.Writer.Allocating = .init(arena);
    try auth.appendFormField(&form.writer, "grant_type", "authorization_code", true);
    try auth.appendFormField(&form.writer, "code", code, false);
    try auth.appendFormField(&form.writer, "redirect_uri", redirect_uri, false);
    try auth.appendFormField(&form.writer, "code_verifier", pkce.code_verifier, false);
    try appendClientAuth(&form.writer, client.id, client.secret);
    try auth.appendFormField(&form.writer, "resource", plan.resource, false);
    const token = try tokenRequest(arena, gpa, io, plan.token_endpoint, form.written(), .{ .abort = options.abort });

    const expires_at: ?i64 = if (token.expires_in) |seconds| util_time.nowUnix() + seconds else null;
    const scope = token.scope orelse plan.scope;
    try saveRecord(gpa, path, .{
        .server = server.name,
        .url = server.target.url,
        .resource = plan.resource,
        .issuer = plan.issuer,
        .token_endpoint = plan.token_endpoint,
        .client_id = client.id,
        .client_secret = client.secret,
        .access_token = token.access_token,
        .refresh_token = token.refresh_token,
        .expires_at = expires_at,
        .scope = scope,
    });
    const issuer = try gpa.dupe(u8, plan.issuer);
    errdefer gpa.free(issuer);
    return .{
        .path = path,
        .issuer = issuer,
        .scope = if (scope) |value| try gpa.dupe(u8, value) else null,
        .expires_at = expires_at,
    };
}

/// One line for a failed login, for the CLI.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        Error.McpOAuthNotAdvertised => "the server did not ask for authorization (no 401 and no OAuth protected resource metadata)",
        Error.McpOAuthMetadataUnavailable => "the authorization server publishes no usable metadata (RFC 8414 / OpenID Connect discovery)",
        Error.McpOAuthPkceUnsupported => "the authorization server does not advertise PKCE S256 (code_challenge_methods_supported); MCP clients must refuse it",
        Error.McpOAuthInsecureEndpoint => "an authorization endpoint is plain HTTP on a non-loopback host",
        Error.McpOAuthResourceMismatch => "the protected resource metadata names a resource that does not cover this server URL",
        Error.McpOAuthIssuerMismatch => "the authorization server metadata's issuer is not the server it was fetched from",
        Error.McpOAuthNoClient => "the authorization server offers no dynamic client registration; set oauth.clientId in the server's configuration",
        Error.McpOAuthRegistrationFailed => "dynamic client registration failed",
        Error.McpOAuthTokenRequestFailed => "the token request failed",
        Error.McpOAuthTokenRejected => "the authorization server rejected the grant",
        Error.McpOAuthMalformedResponse => "the authorization server's answer is malformed",
        Error.McpOAuthNetwork => "could not reach the server or its authorization server",
        Error.McpOAuthNoStateRoot => "no state root to store the token in; pass --state-dir or set METACODES_HOME",
        Error.McpOAuthPersistFailed => "the token could not be stored",
        Error.McpOAuthCallbackPortBusy => "the loopback callback port is unavailable (oauth.callbackPort in use?)",
        error.StateMismatch => "the redirect's state did not match; try again",
        error.OAuthDenied => "authorization was denied in the browser",
        error.Aborted => "login canceled",
        else => @errorName(err),
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Bearer challenges are found among several schemes" {
    const challenge = parseChallenge(
        \\Basic realm="x", Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="files:read files:write"
    ).?;
    try testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource/mcp", challenge.resource_metadata.?);
    try testing.expectEqualStrings("files:read files:write", challenge.scope.?);
    try testing.expectEqualStrings("invalid_token", challenge.@"error".?);

    const bare = parseChallenge("Bearer").?;
    try testing.expect(bare.resource_metadata == null);
    const unquoted = parseChallenge("bearer resource_metadata=https://h/m, DPoP algs=\"ES256\"").?;
    try testing.expectEqualStrings("https://h/m", unquoted.resource_metadata.?);
    try testing.expect(parseChallenge("Basic realm=\"x\"") == null);
}

test "token responses: bearer only, lifetime optional, rotation kept apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try parseTokenResponse(a, "{\"access_token\":\"at\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"rt\",\"scope\":\"s\"}");
    try testing.expectEqualStrings("at", full.access_token);
    try testing.expectEqual(@as(?i64, 3600), full.expires_in);
    try testing.expectEqualStrings("rt", full.refresh_token.?);
    const minimal = try parseTokenResponse(a, "{\"access_token\":\"at\"}");
    try testing.expect(minimal.refresh_token == null and minimal.expires_in == null);
    try testing.expectError(Error.McpOAuthMalformedResponse, parseTokenResponse(a, "{\"access_token\":\"at\",\"token_type\":\"mac\"}"));
    try testing.expectError(Error.McpOAuthMalformedResponse, parseTokenResponse(a, "{\"token_type\":\"bearer\"}"));
}

test "stored records round-trip, stay private and are keyed to their URL" {
    const a = testing.allocator;
    var root_buffer: [512]u8 = undefined;
    const root = @import("../tools/test_tmp.zig").path(&root_buffer, "mcp-oauth-store");
    const path = try storePath(a, root, "linear/prod", "https://mcp.linear.app/sse");
    defer a.free(path);
    try testing.expect(std.mem.indexOf(u8, path, "mcp-oauth") != null);
    try testing.expect(std.mem.indexOf(u8, std.fs.path.basename(path), "linear_prod-") != null);
    const other = try storePath(a, root, "linear/prod", "https://mcp.linear.app/mcp");
    defer a.free(other);
    try testing.expect(!std.mem.eql(u8, path, other));

    try saveRecord(a, path, .{
        .server = "linear/prod",
        .url = "https://mcp.linear.app/sse",
        .resource = "https://mcp.linear.app/sse",
        .issuer = "https://mcp.linear.app",
        .token_endpoint = "https://mcp.linear.app/token",
        .client_id = "cid",
        .access_token = "at",
        .refresh_token = "rt",
        .expires_at = 10,
    });
    var record = (try loadRecord(a, path, "https://mcp.linear.app/sse")).?;
    defer record.deinit(a);
    try testing.expectEqualStrings("rt", record.refresh_token.?);
    try testing.expect(record.client_secret == null);
    try testing.expect(record.isExpiredAt(0));
    try testing.expect(try loadRecord(a, path, "https://elsewhere.example/sse") == null);
    if (@import("builtin").os.tag != .windows) {
        const path_z = try a.dupeZ(u8, path);
        defer a.free(path_z);
        const mode = pfs.statMode(path_z.ptr, false) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u32, 0o600), mode & 0o777);
    }
    try testing.expect(try removeRecord(a, path));
    try testing.expect(!try removeRecord(a, path));
}
