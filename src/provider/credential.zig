//! Typed credential references, provider-scoped resolution, and auth
//! materialization (issue #16, delivery slice P0).
//!
//! What this replaces: `core/auth.zig` resolves one Metask-shaped credential
//! into an opaque `[]const u8` bearer token, and `METASK_API_KEY` is consulted
//! for whatever provider happens to be selected. That is exactly the failure
//! the requirement calls out — an unrelated vendor key must never be picked
//! merely because it exists in the environment.
//!
//! Two structural guarantees replace the old convention:
//!
//! 1. **Environment aliases are provider-owned data.** A profile declares the
//!    variables it accepts; the resolver has no vendor branches, so a Metask
//!    key is not reachable from an OpenAI or Z.AI resolution at all.
//! 2. **Secrets never travel with identity.** `CredentialRef` is the durable,
//!    UI-visible, config-persistable half and carries no secret material.
//!    `Resolved` (the request-scoped half) borrows the bytes just long enough
//!    to materialize a header, and `Materialized` renders redacted.
//!
//! Dependency-free apart from `ids.zig` so the precedence rules stay unit
//! testable without a process environment.

const std = @import("std");
const ids = @import("ids.zig");

pub const Slug = ids.Slug;

// ── identity ─────────────────────────────────────────────────────────────────

pub const CredentialKind = enum {
    /// Generic key, kept for compatibility with existing configurations.
    api_key,
    metask_oauth,
    openai_oauth,
    /// Shares the OpenAI implementation but keeps a distinct issuer/client.
    openai_codex_oauth,
    /// Coding Plan keys are billed and scoped separately from general Z.AI keys.
    zai_coding_plan_api_key,

    pub fn id(self: CredentialKind) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?CredentialKind {
        inline for (@typeInfo(CredentialKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @field(CredentialKind, field.name);
        }
        return null;
    }

    pub fn isOAuth(self: CredentialKind) bool {
        return switch (self) {
            .metask_oauth, .openai_oauth, .openai_codex_oauth => true,
            .api_key, .zai_coding_plan_api_key => false,
        };
    }
};

pub const CredentialStatus = enum {
    unknown,
    active,
    /// OAuth access token past expiry; a refresh is required before use.
    expired,
    /// Provider rejected the material; do not retry as a transport failure.
    invalid,
    /// Temporarily rested after rate limiting.
    cooldown,
};

pub const CredentialSource = enum {
    unknown,
    cli,
    /// One-shot descriptor handed to the process at startup.
    runtime_fd,
    env,
    stored,
    interactive,
};

/// Durable, secret-free credential identity.
///
/// Stable across token refresh: rotating an OAuth access/refresh pair updates
/// the credential store, never this reference. Pool-ready fields (`priority`,
/// `cooldown_until`, `last_error`) are present from P0 so adding rotation in
/// P2 does not reshape persisted state.
pub const CredentialRef = struct {
    id: Slug,
    provider_id: Slug,
    kind: CredentialKind,
    status: CredentialStatus = .unknown,
    source: CredentialSource = .unknown,
    /// Account, plan, or workspace label. Never a secret.
    account_or_plan: ?[]const u8 = null,
    /// Unix seconds; null for material that does not expire.
    expires_at: ?i64 = null,
    priority: u8 = 0,
    cooldown_until: ?i64 = null,
    last_error: ?[]const u8 = null,

    pub fn isUsableAt(self: CredentialRef, now_seconds: i64) bool {
        if (self.status == .invalid) return false;
        if (self.cooldown_until) |until| if (now_seconds < until) return false;
        return true;
    }
};

/// Deterministic reference id for a credential discovered at resolution time.
/// Stable for one (provider, kind, source) triple so repeated resolutions do
/// not churn the persisted selection.
pub fn derivedRefId(
    provider_id: Slug,
    kind: CredentialKind,
    source: CredentialSource,
    buffer: []u8,
) error{NoSpaceLeft}!Slug {
    const text = try std.fmt.bufPrint(buffer, "cred-{s}-{s}-{s}", .{
        provider_id.slice(),
        @tagName(kind),
        @tagName(source),
    });
    return Slug.parse(text) catch error.NoSpaceLeft;
}

// ── environment aliases ──────────────────────────────────────────────────────

/// A provider-declared environment variable. Adding an alias is a profile
/// change; the resolver never grows a vendor branch.
pub const EnvAlias = struct {
    name: []const u8,
    kind: CredentialKind,
    /// Exactly one alias per kind should be canonical; it is the name shown in
    /// setup output and documentation.
    canonical: bool = false,
};

pub const EnvLookup = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    pub fn get(self: EnvLookup, name: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, name);
    }

    /// Lookup that always misses. Used by call sites that must not read the
    /// process environment (tests, sandboxed control-plane paths).
    pub fn empty() EnvLookup {
        const Impl = struct {
            var anchor: u8 = 0;
            fn get(_: *anyopaque, _: []const u8) ?[]const u8 {
                return null;
            }
        };
        return .{ .ctx = @ptrCast(&Impl.anchor), .getFn = Impl.get };
    }

    /// Backed by the real process environment.
    pub fn process() EnvLookup {
        const Impl = struct {
            var anchor: u8 = 0;
            fn get(_: *anyopaque, name: []const u8) ?[]const u8 {
                var buffer: [256]u8 = undefined;
                if (name.len + 1 > buffer.len) return null;
                @memcpy(buffer[0..name.len], name);
                buffer[name.len] = 0;
                const raw = std.c.getenv(@ptrCast(&buffer)) orelse return null;
                const value = std.mem.span(raw);
                return if (value.len == 0) null else value;
            }
        };
        return .{ .ctx = @ptrCast(&Impl.anchor), .getFn = Impl.get };
    }
};

// ── auth materialization ─────────────────────────────────────────────────────

/// How a provider turns credential material into request authentication.
///
/// `signed_adapter` exists so the type covers the reviewed-adapter case from
/// the start; materializing one is deliberately an error in P0 rather than an
/// undeclared hole in the union.
pub const AuthScheme = union(enum) {
    bearer,
    api_key_header: []const u8,
    api_key_query: []const u8,
    custom_header: CustomHeader,
    signed_adapter: []const u8,

    pub const CustomHeader = struct {
        name: []const u8,
        value_prefix: []const u8 = "",
    };

    pub fn id(self: AuthScheme) []const u8 {
        return @tagName(self);
    }
};

pub const MaterializeError = error{
    SignedAdapterRequired,
    AuthBufferTooSmall,
    EmptyCredentialMaterial,
};

/// Request-scoped authentication bytes.
///
/// The value borrows `buffer`, which the caller owns and should wipe. `format`
/// renders redacted so an accidental log line cannot leak the secret.
pub const Materialized = struct {
    placement: Placement,
    name: []const u8,
    value: []const u8,

    pub const Placement = enum { header, query };

    pub fn format(self: Materialized, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}:{s}=<redacted len={d}>", .{
            @tagName(self.placement),
            self.name,
            self.value.len,
        });
    }
};

pub fn materialize(
    scheme: AuthScheme,
    secret: []const u8,
    buffer: []u8,
) MaterializeError!Materialized {
    if (secret.len == 0) return error.EmptyCredentialMaterial;
    return switch (scheme) {
        .bearer => .{
            .placement = .header,
            .name = "authorization",
            .value = try writePrefixed(buffer, "Bearer ", secret),
        },
        .api_key_header => |header| .{
            .placement = .header,
            .name = header,
            .value = try writePrefixed(buffer, "", secret),
        },
        .api_key_query => |query| .{
            .placement = .query,
            .name = query,
            .value = try writePrefixed(buffer, "", secret),
        },
        .custom_header => |custom| .{
            .placement = .header,
            .name = custom.name,
            .value = try writePrefixed(buffer, custom.value_prefix, secret),
        },
        .signed_adapter => error.SignedAdapterRequired,
    };
}

fn writePrefixed(buffer: []u8, prefix: []const u8, secret: []const u8) MaterializeError![]const u8 {
    if (prefix.len + secret.len > buffer.len) return error.AuthBufferTooSmall;
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len..][0..secret.len], secret);
    return buffer[0 .. prefix.len + secret.len];
}

/// Wipe request-scoped auth bytes. Call after the request is serialized.
pub fn wipe(buffer: []u8) void {
    std.crypto.secureZero(u8, buffer);
}

/// Render a credential for a UI or log line: last four characters at most,
/// never the full value and never a short secret in the clear.
pub fn redact(secret: []const u8, buffer: []u8) []const u8 {
    const tail_len: usize = if (secret.len >= 8) 4 else 0;
    const stars = "********";
    const total = stars.len + tail_len;
    if (total > buffer.len) return "********";
    @memcpy(buffer[0..stars.len], stars);
    if (tail_len > 0) @memcpy(buffer[stars.len..][0..tail_len], secret[secret.len - tail_len ..]);
    return buffer[0..total];
}

// ── provider-scoped resolution ───────────────────────────────────────────────

pub const AuthPrecedence = enum { api_key_first, oauth_first };

/// Persisted credential material handed in by the credential store. The store
/// owns the bytes; resolution only borrows them.
pub const StoredEntry = struct {
    kind: CredentialKind,
    secret: []const u8,
    status: CredentialStatus = .active,
    account_or_plan: ?[]const u8 = null,
    expires_at: ?i64 = null,
    /// Set by the pool after a rate-limit or failure; resolution skips the
    /// entry until this time passes.
    cooldown_until: ?i64 = null,
};

pub const ResolveInput = struct {
    provider_id: Slug,
    /// Credential kinds the provider profile accepts. A kind outside this set
    /// is rejected even if material is available.
    accepted_kinds: []const CredentialKind,
    /// Provider-declared environment variables, most preferred first.
    env_aliases: []const EnvAlias = &.{},
    /// Explicitly selected credential, bypassing discovery.
    explicit: ?StoredEntry = null,
    /// One-shot secret injected over a runtime descriptor.
    runtime_fd_secret: ?[]const u8 = null,
    cli_api_key: ?[]const u8 = null,
    /// Persisted API key and OAuth material from the credential store.
    stored_api_key: ?StoredEntry = null,
    stored_oauth: ?StoredEntry = null,
    precedence: AuthPrecedence = .api_key_first,
    env: EnvLookup = EnvLookup.empty(),
    now_seconds: i64 = 0,
};

pub const ResolveError = error{
    MissingCredentials,
    AmbiguousCredentialAliases,
    CredentialKindNotAccepted,
    NoSpaceLeft,
};

/// The request-scoped half of a credential: a secret-free reference plus a
/// borrowed view of the material. Never persisted, never sent to a UI.
pub const Resolved = struct {
    ref: CredentialRef,
    secret: []const u8,
    /// Environment variable that supplied the value, when the source was `env`.
    alias_used: ?[]const u8 = null,
};

/// Deterministic, provider-scoped credential resolution.
///
/// Order (matching the requirement):
///   1. explicit reference / one-shot runtime material
///   2. injected runtime descriptor secret
///   3. provider-declared environment aliases
///   4. persisted credential store (expiry-aware)
///   5. interactive setup — the caller's job, signalled by MissingCredentials
///
/// `precedence` only reorders steps 3–4 within this provider; it never widens
/// the provider scope.
pub fn resolve(input: ResolveInput, ref_id_buffer: []u8) ResolveError!Resolved {
    if (input.explicit) |entry| {
        try requireAccepted(input.accepted_kinds, entry.kind);
        return try build(input, entry.kind, .cli, entry.secret, null, entry, ref_id_buffer);
    }

    if (input.runtime_fd_secret) |secret| {
        const kind = firstApiKeyKind(input.accepted_kinds);
        return try build(input, kind, .runtime_fd, secret, null, null, ref_id_buffer);
    }

    if (input.cli_api_key) |secret| {
        const kind = firstApiKeyKind(input.accepted_kinds);
        try requireAccepted(input.accepted_kinds, kind);
        return try build(input, kind, .cli, secret, null, null, ref_id_buffer);
    }

    const env_hit = try resolveEnv(input);

    if (input.precedence == .oauth_first) {
        if (try storedOAuth(input)) |entry|
            return try build(input, entry.kind, .stored, entry.secret, null, entry, ref_id_buffer);
        if (env_hit) |hit|
            return try build(input, hit.kind, .env, hit.value, hit.name, null, ref_id_buffer);
        if (try storedApiKey(input)) |entry|
            return try build(input, entry.kind, .stored, entry.secret, null, entry, ref_id_buffer);
        return error.MissingCredentials;
    }

    if (env_hit) |hit|
        return try build(input, hit.kind, .env, hit.value, hit.name, null, ref_id_buffer);
    if (try storedApiKey(input)) |entry|
        return try build(input, entry.kind, .stored, entry.secret, null, entry, ref_id_buffer);
    if (try storedOAuth(input)) |entry|
        return try build(input, entry.kind, .stored, entry.secret, null, entry, ref_id_buffer);
    return error.MissingCredentials;
}

const EnvHit = struct {
    name: []const u8,
    value: []const u8,
    kind: CredentialKind,
};

/// Scan every declared alias. Aliases sit at the same precedence level, so two
/// aliases holding *different* values is an ambiguity the user must resolve —
/// picking the first would silently prefer one account over another.
fn resolveEnv(input: ResolveInput) ResolveError!?EnvHit {
    var hit: ?EnvHit = null;
    for (input.env_aliases) |alias| {
        if (!isAccepted(input.accepted_kinds, alias.kind)) continue;
        const value = input.env.get(alias.name) orelse continue;
        if (hit) |existing| {
            if (!std.mem.eql(u8, existing.value, value)) return error.AmbiguousCredentialAliases;
            // Same value under several names: keep the canonical one for output.
            if (alias.canonical) hit = .{ .name = alias.name, .value = value, .kind = alias.kind };
            continue;
        }
        hit = .{ .name = alias.name, .value = value, .kind = alias.kind };
    }
    return hit;
}

fn storedApiKey(input: ResolveInput) ResolveError!?StoredEntry {
    return usableStored(input, input.stored_api_key);
}

fn storedOAuth(input: ResolveInput) ResolveError!?StoredEntry {
    return usableStored(input, input.stored_oauth);
}

/// Persisted material is eligible only when the profile accepts its kind and
/// the pool state says it may be used now. `CredentialRef.isUsableAt` is the
/// single definition of that, so the cooldown a failed request records is
/// actually honoured by the next resolution.
fn usableStored(input: ResolveInput, candidate: ?StoredEntry) ResolveError!?StoredEntry {
    const entry = candidate orelse return null;
    if (!isAccepted(input.accepted_kinds, entry.kind)) return null;
    const reference = CredentialRef{
        .id = Slug.lit("probe"),
        .provider_id = input.provider_id,
        .kind = entry.kind,
        .status = entry.status,
        .cooldown_until = entry.cooldown_until,
    };
    if (!reference.isUsableAt(input.now_seconds)) return null;
    return entry;
}

fn build(
    input: ResolveInput,
    kind: CredentialKind,
    source: CredentialSource,
    secret: []const u8,
    alias_used: ?[]const u8,
    entry: ?StoredEntry,
    ref_id_buffer: []u8,
) ResolveError!Resolved {
    try requireAccepted(input.accepted_kinds, kind);
    if (secret.len == 0) return error.MissingCredentials;
    const id = try derivedRefId(input.provider_id, kind, source, ref_id_buffer);
    const expires_at = if (entry) |value| value.expires_at else null;
    return .{
        .ref = .{
            .id = id,
            .provider_id = input.provider_id,
            .kind = kind,
            .status = statusFor(entry, expires_at, input.now_seconds),
            .source = source,
            .account_or_plan = if (entry) |value| value.account_or_plan else null,
            .expires_at = expires_at,
            .cooldown_until = if (entry) |value| value.cooldown_until else null,
        },
        .secret = secret,
        .alias_used = alias_used,
    };
}

fn statusFor(entry: ?StoredEntry, expires_at: ?i64, now_seconds: i64) CredentialStatus {
    if (expires_at) |deadline| if (now_seconds >= deadline) return .expired;
    if (entry) |value| return value.status;
    return .active;
}

fn isAccepted(accepted: []const CredentialKind, kind: CredentialKind) bool {
    for (accepted) |candidate| if (candidate == kind) return true;
    return false;
}

fn requireAccepted(accepted: []const CredentialKind, kind: CredentialKind) ResolveError!void {
    if (!isAccepted(accepted, kind)) return error.CredentialKindNotAccepted;
}

/// The API-key-shaped kind a provider accepts, for material that arrives
/// without a declared kind (CLI flag, runtime descriptor).
fn firstApiKeyKind(accepted: []const CredentialKind) CredentialKind {
    for (accepted) |kind| if (!kind.isOAuth()) return kind;
    return .api_key;
}

// ── tests ────────────────────────────────────────────────────────────────────

const TestEnv = struct {
    pairs: []const [2][]const u8,

    fn lookup(self: *TestEnv) EnvLookup {
        const Impl = struct {
            fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
                const env: *TestEnv = @ptrCast(@alignCast(ctx));
                for (env.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
                return null;
            }
        };
        return .{ .ctx = @ptrCast(self), .getFn = Impl.get };
    }
};

const ZAI_KINDS = [_]CredentialKind{.zai_coding_plan_api_key};
const ZAI_ALIASES = [_]EnvAlias{
    .{ .name = "ZAI_API_KEY", .kind = .zai_coding_plan_api_key, .canonical = true },
    .{ .name = "GLM_API_KEY", .kind = .zai_coding_plan_api_key },
    .{ .name = "Z_AI_API_KEY", .kind = .zai_coding_plan_api_key },
};

test "env aliases resolve to the canonical name" {
    var env = TestEnv{ .pairs = &.{.{ "GLM_API_KEY", "glm-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const resolved = try resolve(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .accepted_kinds = &ZAI_KINDS,
        .env_aliases = &ZAI_ALIASES,
        .env = env.lookup(),
    }, &buffer);
    try std.testing.expectEqualStrings("glm-secret", resolved.secret);
    try std.testing.expectEqualStrings("GLM_API_KEY", resolved.alias_used.?);
    try std.testing.expectEqual(CredentialSource.env, resolved.ref.source);
    try std.testing.expectEqual(CredentialKind.zai_coding_plan_api_key, resolved.ref.kind);
}

test "identical values under several aliases are not ambiguous" {
    var env = TestEnv{ .pairs = &.{
        .{ "GLM_API_KEY", "same" },
        .{ "Z_AI_API_KEY", "same" },
        .{ "ZAI_API_KEY", "same" },
    } };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const resolved = try resolve(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .accepted_kinds = &ZAI_KINDS,
        .env_aliases = &ZAI_ALIASES,
        .env = env.lookup(),
    }, &buffer);
    try std.testing.expectEqualStrings("ZAI_API_KEY", resolved.alias_used.?);
}

test "conflicting alias values fail before any network I/O" {
    var env = TestEnv{ .pairs = &.{
        .{ "GLM_API_KEY", "one" },
        .{ "ZAI_API_KEY", "two" },
    } };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    try std.testing.expectError(error.AmbiguousCredentialAliases, resolve(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .accepted_kinds = &ZAI_KINDS,
        .env_aliases = &ZAI_ALIASES,
        .env = env.lookup(),
    }, &buffer));
}

test "a Metask key cannot satisfy a Z.AI resolution" {
    var env = TestEnv{ .pairs = &.{.{ "METASK_API_KEY", "metask-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    try std.testing.expectError(error.MissingCredentials, resolve(.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .accepted_kinds = &ZAI_KINDS,
        .env_aliases = &ZAI_ALIASES,
        .env = env.lookup(),
    }, &buffer));
}

test "METASK_API_KEY still resolves for the metask profile" {
    var env = TestEnv{ .pairs = &.{.{ "METASK_API_KEY", "metask-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const kinds = [_]CredentialKind{ .api_key, .metask_oauth };
    const aliases = [_]EnvAlias{.{ .name = "METASK_API_KEY", .kind = .api_key, .canonical = true }};
    const resolved = try resolve(.{
        .provider_id = Slug.lit("metask"),
        .accepted_kinds = &kinds,
        .env_aliases = &aliases,
        .env = env.lookup(),
    }, &buffer);
    try std.testing.expectEqualStrings("metask-secret", resolved.secret);
}

test "precedence reorders env and stored oauth without widening scope" {
    var env = TestEnv{ .pairs = &.{.{ "METASK_API_KEY", "env-key" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const kinds = [_]CredentialKind{ .api_key, .metask_oauth };
    const aliases = [_]EnvAlias{.{ .name = "METASK_API_KEY", .kind = .api_key, .canonical = true }};
    const base = ResolveInput{
        .provider_id = Slug.lit("metask"),
        .accepted_kinds = &kinds,
        .env_aliases = &aliases,
        .stored_oauth = .{ .kind = .metask_oauth, .secret = "oauth-access", .expires_at = 9999 },
        .env = env.lookup(),
    };
    var api_first = base;
    api_first.precedence = .api_key_first;
    try std.testing.expectEqualStrings("env-key", (try resolve(api_first, &buffer)).secret);

    var oauth_first = base;
    oauth_first.precedence = .oauth_first;
    const via_oauth = try resolve(oauth_first, &buffer);
    try std.testing.expectEqualStrings("oauth-access", via_oauth.secret);
    try std.testing.expectEqual(CredentialKind.metask_oauth, via_oauth.ref.kind);
}

test "runtime descriptor outranks environment and stored material" {
    var env = TestEnv{ .pairs = &.{.{ "METASK_API_KEY", "env-key" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const kinds = [_]CredentialKind{.api_key};
    const aliases = [_]EnvAlias{.{ .name = "METASK_API_KEY", .kind = .api_key, .canonical = true }};
    const resolved = try resolve(.{
        .provider_id = Slug.lit("metask"),
        .accepted_kinds = &kinds,
        .env_aliases = &aliases,
        .runtime_fd_secret = "fd-key",
        .stored_api_key = .{ .kind = .api_key, .secret = "stored-key" },
        .env = env.lookup(),
    }, &buffer);
    try std.testing.expectEqualStrings("fd-key", resolved.secret);
    try std.testing.expectEqual(CredentialSource.runtime_fd, resolved.ref.source);
}

test "an expired stored OAuth credential is reported, not silently used as active" {
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const kinds = [_]CredentialKind{.metask_oauth};
    const resolved = try resolve(.{
        .provider_id = Slug.lit("metask"),
        .accepted_kinds = &kinds,
        .stored_oauth = .{ .kind = .metask_oauth, .secret = "stale", .expires_at = 100 },
        .now_seconds = 200,
    }, &buffer);
    try std.testing.expectEqual(CredentialStatus.expired, resolved.ref.status);
}

test "credential reference id is stable and secret-free" {
    var first: [ids.MAX_SLUG_LEN]u8 = undefined;
    var second: [ids.MAX_SLUG_LEN]u8 = undefined;
    const a = try derivedRefId(Slug.lit("openai"), .openai_oauth, .stored, &first);
    const b = try derivedRefId(Slug.lit("openai"), .openai_oauth, .stored, &second);
    try std.testing.expect(a.eql(b));
    try std.testing.expectEqualStrings("cred-openai-openai_oauth-stored", a.slice());
}

test "auth materialization covers bearer, api-key header, and custom header" {
    var buffer: [128]u8 = undefined;
    const bearer = try materialize(.bearer, "sk-secret", &buffer);
    try std.testing.expectEqualStrings("authorization", bearer.name);
    try std.testing.expectEqualStrings("Bearer sk-secret", bearer.value);

    const header = try materialize(.{ .api_key_header = "x-api-key" }, "sk-secret", &buffer);
    try std.testing.expectEqualStrings("x-api-key", header.name);
    try std.testing.expectEqualStrings("sk-secret", header.value);

    const custom = try materialize(
        .{ .custom_header = .{ .name = "x-goog-api-key", .value_prefix = "" } },
        "sk-secret",
        &buffer,
    );
    try std.testing.expectEqualStrings("x-goog-api-key", custom.name);

    const query = try materialize(.{ .api_key_query = "key" }, "sk-secret", &buffer);
    try std.testing.expectEqual(Materialized.Placement.query, query.placement);
}

test "signed adapters and empty material fail closed" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(
        error.SignedAdapterRequired,
        materialize(.{ .signed_adapter = "vendor-sigv4" }, "secret", &buffer),
    );
    try std.testing.expectError(error.EmptyCredentialMaterial, materialize(.bearer, "", &buffer));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.AuthBufferTooSmall, materialize(.bearer, "secret", &tiny));
}

test "materialized auth renders redacted" {
    var buffer: [128]u8 = undefined;
    const auth = try materialize(.bearer, "sk-super-secret", &buffer);
    var rendered: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&rendered, "{f}", .{auth});
    try std.testing.expect(std.mem.indexOf(u8, text, "sk-super-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "redacted") != null);
}

test "redaction keeps at most a four character tail" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("********cret", redact("sk-super-secret", &buffer));
    try std.testing.expectEqualStrings("********", redact("short", &buffer));
}

test "auth bytes can be wiped after use" {
    var buffer: [32]u8 = undefined;
    const auth = try materialize(.bearer, "sk-secret", &buffer);
    try std.testing.expect(auth.value.len > 0);
    wipe(&buffer);
    for (buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "a credential in cooldown is skipped until it expires" {
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const kinds = [_]CredentialKind{.api_key};
    const base = ResolveInput{
        .provider_id = Slug.lit("metask"),
        .accepted_kinds = &kinds,
        .stored_api_key = .{ .kind = .api_key, .secret = "resting", .cooldown_until = 500 },
        .now_seconds = 400,
    };
    try std.testing.expectError(error.MissingCredentials, resolve(base, &buffer));

    var later = base;
    later.now_seconds = 501;
    const resolved = try resolve(later, &buffer);
    try std.testing.expectEqualStrings("resting", resolved.secret);
    try std.testing.expectEqual(@as(?i64, 500), resolved.ref.cooldown_until);
}

test "an invalid stored credential is never selected" {
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;
    const kinds = [_]CredentialKind{.api_key};
    try std.testing.expectError(error.MissingCredentials, resolve(.{
        .provider_id = Slug.lit("metask"),
        .accepted_kinds = &kinds,
        .stored_api_key = .{ .kind = .api_key, .secret = "revoked", .status = .invalid },
    }, &buffer));
}
