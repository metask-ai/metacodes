//! User-defined provider instances (issue #16, delivery slice P1).
//!
//! A provider the user configures is the same `ProviderProfile` a built-in file
//! declares — it goes through `ProviderRegistry.register` and the same
//! validation, so nothing downstream can tell the difference. What differs is
//! ownership: a built-in profile is comptime data that lives forever, while a
//! configured one is parsed at runtime, so a `Definitions` arena owns every
//! string the profile points at and must outlive the registry.
//!
//! **The schema is declarative and cannot execute anything.** A configured
//! provider names a base URL, an auth scheme, a *wire* protocol, model
//! metadata, and controls. It cannot supply code, a callback, a shell command,
//! or a request template, so a malicious config can misroute the user's own
//! traffic — which an endpoint policy still constrains — but cannot read
//! prompts or credentials it was not given.
//!
//! A protocol here is a built-in wire, optionally with a different request
//! path. That covers relays, gateways, and self-hosted servers, which differ
//! from the vendor by path far more often than by wire format. A genuinely
//! novel wire needs a reviewed adapter (P2) and is rejected rather than guessed.
//!
//! Every failure is a parse or validation failure, raised before any request
//! URL exists and long before any network I/O.

const std = @import("std");
const ids = @import("ids.zig");
const offer = @import("offer.zig");
const controls_mod = @import("controls.zig");
const profile_mod = @import("profile.zig");
const model_listing = @import("model_listing.zig");

pub const Slug = ids.Slug;
pub const ProviderProfile = profile_mod.ProviderProfile;
pub const ChannelDescriptor = profile_mod.ChannelDescriptor;
pub const ModelEntry = profile_mod.ModelEntry;
pub const Protocol = profile_mod.Protocol;
pub const Vendor = profile_mod.Vendor;

pub const SCHEMA_VERSION: u16 = 1;

/// Bounds. A configured provider is user input, so every list is capped rather
/// than trusted: an unbounded config is a memory-exhaustion vector reachable by
/// editing a file.
pub const MAX_PROVIDERS: usize = 32;
pub const MAX_CHANNELS: usize = 16;
pub const MAX_MODELS: usize = 128;
pub const MAX_CONTROLS: usize = controls_mod.MAX_CONTROLS;
pub const MAX_ENUM_VALUES: usize = 16;
pub const MAX_ENV_ALIASES: usize = 8;
pub const MAX_PATH_FRAGMENTS: usize = 8;

pub const DefinitionError = error{
    OutOfMemory,
    InvalidDocument,
    UnsupportedSchemaVersion,
    InvalidSlug,
    /// The protocol names a wire no transport serves. A novel wire needs a
    /// reviewed adapter; guessing one would send bytes no server understands.
    UnknownWire,
    /// A `dialect` that names no vendor (`vendor.zig`). Guessing one would
    /// write another vendor's parameters into the request.
    UnknownDialect,
    UnknownAuthScheme,
    UnknownCredentialKind,
    UnknownCapability,
    UnknownControlKind,
    MissingBaseUrl,
    NoChannels,
    NoModels,
    TooManyProviders,
    TooManyChannels,
    TooManyModels,
    TooManyControls,
    TooManyValues,
    TooManyEnvAliases,
    TooManyFragments,
    /// A custom header name that is empty, or an auth scheme missing the header
    /// it needs. Materializing it would produce a malformed request.
    InvalidAuthHeader,
    InvalidPrice,
    DuplicateProviderId,
    DuplicateChannelId,
    /// An `oauth` block on a profile that accepts no OAuth credential kind.
    /// Credential resolution opens the OAuth session only for kinds
    /// `oauth.servesKind` recognizes, so such a login would be stored and never
    /// consulted — `metacodes login` would report success and the session
    /// would ignore it. Rejected here, where the definition is.
    OAuthWithoutOAuthCredentialKind,
};

/// Parsed, validated, and owned. `profiles()` hands out `ProviderProfile`
/// values whose slices point into this arena.
pub const Definitions = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(ProviderProfile) = .empty,

    pub fn deinit(self: *Definitions) void {
        self.list.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }

    pub fn profiles(self: *const Definitions) []const ProviderProfile {
        return self.list.items;
    }

    pub fn find(self: *const Definitions, name: []const u8) ?*const ProviderProfile {
        for (self.list.items) |*candidate| {
            if (candidate.matchesName(name)) return candidate;
        }
        return null;
    }
};

/// Parse the `custom_providers` object of a configuration document.
///
/// Takes the raw JSON text rather than a parsed tree so the caller does not
/// have to keep one alive; everything the profiles reference is copied into the
/// arena here.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) DefinitionError!Definitions {
    var out = Definitions{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer out.deinit();

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return out;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), trimmed, .{}) catch
        return error.InvalidDocument;
    if (root != .object) return error.InvalidDocument;

    if (root.object.get("schema_version")) |value| {
        const version = intOf(value) orelse return error.InvalidDocument;
        if (version > SCHEMA_VERSION) return error.UnsupportedSchemaVersion;
    }

    const providers = root.object.get("custom_providers") orelse return out;
    if (providers != .object) return error.InvalidDocument;
    if (providers.object.count() > MAX_PROVIDERS) return error.TooManyProviders;

    const arena = out.arena.allocator();
    var it = providers.object.iterator();
    while (it.next()) |pair| {
        const built = try buildProfile(arena, pair.key_ptr.*, pair.value_ptr.*);
        for (out.list.items) |existing| {
            if (existing.id.eql(built.id)) return error.DuplicateProviderId;
        }
        try out.list.append(allocator, built);
    }
    return out;
}

fn buildProfile(
    arena: std.mem.Allocator,
    name: []const u8,
    value: std.json.Value,
) DefinitionError!ProviderProfile {
    if (value != .object) return error.InvalidDocument;
    const id = Slug.parse(name) catch return error.InvalidSlug;

    const display = try dupe(arena, stringOf(value.object.get("display_name")) orelse name);
    const implementation = if (stringOf(value.object.get("implementation_id"))) |text|
        Slug.parse(text) catch return error.InvalidSlug
    else
        id;

    const auth = try parseAuth(arena, value.object.get("auth"));
    const env_aliases = try parseEnvAliases(arena, value.object.get("env_aliases"));
    const kinds = try parseCredentialKinds(arena, value.object.get("credential_kinds"), env_aliases);
    const policy = try parsePolicy(arena, value.object.get("endpoint_policy"));
    const models = try parseModels(arena, value.object.get("models"));
    if (models.len == 0) return error.NoModels;
    const channels = try parseChannels(arena, value.object.get("channels"), policy);
    if (channels.len == 0) return error.NoChannels;

    const default_channel: ?Slug = if (stringOf(value.object.get("default_channel"))) |text|
        Slug.parse(text) catch return error.InvalidSlug
    else
        channels[0].id;

    const aliases = try parseAliases(arena, value.object.get("aliases"));
    const oauth = try parseOAuth(arena, value.object.get("oauth"));
    if (oauth.token_url != null and !acceptsOAuthKind(kinds))
        return error.OAuthWithoutOAuthCredentialKind;
    const key_setup = try pastedKeySetup(arena, display, kinds, channelNamed(channels, default_channel));

    const built = ProviderProfile{
        .id = id,
        .implementation_id = implementation,
        .display_name = display,
        .aliases = aliases,
        .channels = channels,
        .models = models,
        .accepted_credential_kinds = kinds,
        .env_aliases = env_aliases,
        .auth = auth,
        .default_channel = default_channel,
        .endpoint_policy = policy,
        .oauth_token_url = oauth.token_url,
        .oauth_authorize_url = oauth.authorize_url,
        .oauth_device_authorization_url = oauth.device_authorization_url,
        .oauth_client_id = oauth.client_id,
        .oauth_scope = oauth.scope,
        .api_key_setup = key_setup,
    };
    // The same structural validation a built-in profile goes through. Doing it
    // here means a malformed definition fails at parse time rather than at the
    // first request.
    profile_mod.validateProfile(built) catch return error.InvalidDocument;
    return built;
}

fn channelNamed(channels: []const ChannelDescriptor, id: ?Slug) ChannelDescriptor {
    if (id) |wanted| for (channels) |candidate| {
        if (candidate.id.eql(wanted)) return candidate;
    };
    return channels[0];
}

/// How a key for a configured provider is stored (`/login <id>`, `metacodes
/// login --provider <id>`): pasted, because there is no page to create it on
/// — whoever runs the relay or the server hands it out — and checked with
/// the model listing of `channel` (the default one; `model_listing.zig`),
/// sent the way the provider's requests carry the key. A Bedrock Converse
/// channel lists nothing to check against, so its key is stored unchecked,
/// as the built-in Bedrock's is. Null when the definition accepts no API key
/// at all (an OAuth-only gateway).
fn pastedKeySetup(
    arena: std.mem.Allocator,
    display: []const u8,
    kinds: []const profile_mod.CredentialKind,
    channel: ChannelDescriptor,
) DefinitionError!?profile_mod.ApiKeySetup {
    const accepts_key = for (kinds) |kind| {
        if (kind == .api_key) break true;
    } else false;
    if (!accepts_key) return null;
    const wire = channel.routes[0].protocol.wire();
    const check_url = if (wire) |known| try model_listing.listingUrl(arena, channel.base_url, known) else null;
    const pages = try arena.alloc(profile_mod.KeyPage, 1);
    pages[0] = .{
        .id = Slug.lit("key"),
        .label = display,
        .url = null,
        .check_url = check_url,
        .check_wire = if (check_url != null) wire else null,
    };
    return .{ .kind = .api_key, .pages = pages };
}

const OAuthDefinition = struct {
    token_url: ?[]const u8 = null,
    authorize_url: ?[]const u8 = null,
    device_authorization_url: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    scope: []const u8 = "",
};

/// `"oauth": { "token_url", "authorize_url", "device_authorization_url",
/// "client_id", "scope" }` (issue #33).
///
/// A configured provider is exactly the case where the OAuth client belongs in
/// configuration rather than in the binary: whoever runs the relay or gateway
/// registered it. Declaring the endpoints here is what makes
/// `metacodes login --provider <id>` a real flow for it.
fn parseOAuth(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError!OAuthDefinition {
    const object = value orelse return .{};
    if (object != .object) return error.InvalidDocument;
    const token_url = try dupeOptional(arena, stringOf(object.object.get("token_url")));
    const authorize_url = try dupeOptional(arena, stringOf(object.object.get("authorize_url")));
    const device_url = try dupeOptional(
        arena,
        stringOf(object.object.get("device_authorization_url")),
    );
    // Without a token endpoint neither grant can be completed and no refresh
    // can ever run, so an authorization endpoint on its own is a definition
    // that could only fail later.
    if (token_url == null and (authorize_url != null or device_url != null))
        return error.InvalidDocument;
    return .{
        .token_url = token_url,
        .authorize_url = authorize_url,
        .device_authorization_url = device_url,
        .client_id = try dupeOptional(arena, stringOf(object.object.get("client_id"))),
        .scope = try dupe(arena, stringOf(object.object.get("scope")) orelse ""),
    };
}

/// The same test credential resolution applies before it will open an OAuth
/// session for a profile. Asked at parse time so the answer is "this
/// definition is wrong" rather than a login nothing ever reads.
fn acceptsOAuthKind(kinds: []const profile_mod.CredentialKind) bool {
    for (kinds) |kind| {
        if (@import("oauth.zig").servesKind(kind)) return true;
    }
    return false;
}

fn parseAliases(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError![]const []const u8 {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    var out = try arena.alloc([]const u8, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        out[index] = try dupe(arena, stringOf(item) orelse return error.InvalidDocument);
    }
    return out;
}

fn parseAuth(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError!profile_mod.AuthScheme {
    const object = value orelse return .bearer;
    if (object != .object) return error.InvalidDocument;
    const kind = stringOf(object.object.get("kind")) orelse return error.UnknownAuthScheme;

    if (std.mem.eql(u8, kind, "bearer")) return .bearer;
    if (std.mem.eql(u8, kind, "api_key_header")) {
        const header = stringOf(object.object.get("header")) orelse return error.InvalidAuthHeader;
        if (header.len == 0) return error.InvalidAuthHeader;
        return .{ .api_key_header = try dupe(arena, header) };
    }
    if (std.mem.eql(u8, kind, "custom_header")) {
        const header = stringOf(object.object.get("header")) orelse return error.InvalidAuthHeader;
        if (header.len == 0) return error.InvalidAuthHeader;
        const prefix = stringOf(object.object.get("value_prefix")) orelse "";
        return .{ .custom_header = .{
            .name = try dupe(arena, header),
            .value_prefix = try dupe(arena, prefix),
        } };
    }
    // `signed_adapter` is deliberately not configurable: it is a reviewed
    // adapter reference, not a config value. There is no query-parameter scheme
    // at all — see `AuthScheme` for why a secret never goes in a URL.
    return error.UnknownAuthScheme;
}

fn parseEnvAliases(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError![]const profile_mod.EnvAlias {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    if (list.array.items.len > MAX_ENV_ALIASES) return error.TooManyEnvAliases;
    var out = try arena.alloc(profile_mod.EnvAlias, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidDocument;
        const alias_name = stringOf(item.object.get("name")) orelse return error.InvalidDocument;
        if (alias_name.len == 0) return error.InvalidDocument;
        out[index] = .{
            .name = try dupe(arena, alias_name),
            .kind = try parseCredentialKind(stringOf(item.object.get("kind")) orelse "api_key"),
            .canonical = boolOf(item.object.get("canonical")) orelse (index == 0),
        };
    }
    return out;
}

fn parseCredentialKind(text: []const u8) DefinitionError!profile_mod.CredentialKind {
    inline for (@typeInfo(profile_mod.CredentialKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(profile_mod.CredentialKind, field.name);
    }
    return error.UnknownCredentialKind;
}

fn parseCredentialKinds(
    arena: std.mem.Allocator,
    value: ?std.json.Value,
    env_aliases: []const profile_mod.EnvAlias,
) DefinitionError![]const profile_mod.CredentialKind {
    if (value) |list| {
        if (list != .array) return error.InvalidDocument;
        if (list.array.items.len == 0) return error.InvalidDocument;
        var out = try arena.alloc(profile_mod.CredentialKind, list.array.items.len);
        for (list.array.items, 0..) |item, index| {
            out[index] = try parseCredentialKind(stringOf(item) orelse return error.InvalidDocument);
        }
        return out;
    }
    // Default to exactly the kinds the declared aliases use, so an alias can
    // never name a credential the profile does not accept.
    if (env_aliases.len == 0) {
        const single = try arena.alloc(profile_mod.CredentialKind, 1);
        single[0] = .api_key;
        return single;
    }
    var out = try arena.alloc(profile_mod.CredentialKind, env_aliases.len);
    for (env_aliases, 0..) |alias, index| out[index] = alias.kind;
    return out;
}

fn parsePolicy(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError!profile_mod.EndpointPolicy {
    const object = value orelse return .{};
    if (object != .object) return error.InvalidDocument;
    return .{
        .require_tls = boolOf(object.object.get("require_tls")) orelse true,
        .allow_loopback_plaintext = boolOf(object.object.get("allow_loopback_plaintext")) orelse true,
        .forbidden_path_fragments = try parseFragments(arena, object.object.get("forbidden_path_fragments")),
        .required_path_fragments = try parseFragments(arena, object.object.get("required_path_fragments")),
        .allowed_hosts = try parseFragments(arena, object.object.get("allowed_hosts")),
    };
}

fn parseFragments(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError![]const []const u8 {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    if (list.array.items.len > MAX_PATH_FRAGMENTS) return error.TooManyFragments;
    var out = try arena.alloc([]const u8, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        out[index] = try dupe(arena, stringOf(item) orelse return error.InvalidDocument);
    }
    return out;
}

fn parseProtocol(arena: std.mem.Allocator, value: std.json.Value) DefinitionError!Protocol {
    if (stringOf(value)) |text| {
        return Protocol.parse(text) orelse error.UnknownWire;
    }
    if (value != .object) return error.InvalidDocument;
    const wire_text = stringOf(value.object.get("wire")) orelse return error.UnknownWire;
    const wire = Protocol.Wire.parse(wire_text) orelse return error.UnknownWire;
    const suffix = stringOf(value.object.get("path_suffix")) orelse
        (Protocol.parse(wire_text) orelse return error.UnknownWire).pathSuffix();
    const shape_text = stringOf(value.object.get("shape")) orelse "absolute_request_url";
    const shape: profile_mod.EndpointShape = if (std.mem.eql(u8, shape_text, "base_origin"))
        .base_origin
    else if (std.mem.eql(u8, shape_text, "absolute_request_url"))
        .absolute_request_url
    else
        return error.InvalidDocument;
    const label = stringOf(value.object.get("id")) orelse wire_text;
    return .{ .custom = .{
        .id = try dupe(arena, label),
        .path_suffix = try dupe(arena, suffix),
        .shape = shape,
        .wire = wire,
    } };
}

fn parseChannels(
    arena: std.mem.Allocator,
    value: ?std.json.Value,
    policy: profile_mod.EndpointPolicy,
) DefinitionError![]const ChannelDescriptor {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    if (list.array.items.len > MAX_CHANNELS) return error.TooManyChannels;
    var out = try arena.alloc(ChannelDescriptor, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidDocument;
        const channel_id = Slug.parse(stringOf(item.object.get("id")) orelse return error.InvalidDocument) catch
            return error.InvalidSlug;
        for (out[0..index]) |existing| {
            if (existing.id.eql(channel_id)) return error.DuplicateChannelId;
        }
        const base_url = stringOf(item.object.get("base_url")) orelse return error.MissingBaseUrl;
        // The endpoint is checked against this provider's own policy now, so a
        // definition that could only ever produce a rejected URL fails at parse
        // time instead of at the first request.
        policy.validate(base_url) catch return error.InvalidDocument;

        const protocol = try parseProtocol(arena, item.object.get("protocol") orelse return error.UnknownWire);
        const routes = try arena.alloc(profile_mod.ProtocolRoute, 1);
        // The route carries the definition's own policy. Without it the route
        // falls back to the default (`require_tls = true`), so a definition
        // whose base_url passed the check above is rejected again by
        // `validateProfile` — making the documented `endpoint_policy` inert for
        // exactly the plaintext relay/proxy case it exists to express.
        routes[0] = .{ .protocol = protocol, .policy = policy, .dialect = try parseDialect(item.object.get("dialect")) };

        out[index] = .{
            .id = channel_id,
            .display_name = try dupe(arena, stringOf(item.object.get("display_name")) orelse channel_id.slice()),
            .base_url = try dupe(arena, base_url),
            .routes = routes,
            .region = try dupeOptional(arena, stringOf(item.object.get("region"))),
            .plan = try dupeOptional(arena, stringOf(item.object.get("plan"))),
            .account = try dupeOptional(arena, stringOf(item.object.get("account"))),
            .models = try parseModels(arena, item.object.get("models")),
        };
    }
    return out;
}

fn parseModels(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError![]const ModelEntry {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    if (list.array.items.len > MAX_MODELS) return error.TooManyModels;
    var out = try arena.alloc(ModelEntry, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidDocument;
        const request_id = stringOf(item.object.get("request_model_id")) orelse return error.InvalidDocument;
        if (request_id.len == 0) return error.InvalidDocument;
        out[index] = .{
            .request_model_id = try dupe(arena, request_id),
            .display_name = try dupe(arena, stringOf(item.object.get("display_name")) orelse request_id),
            .canonical_model_id = try dupeOptional(arena, stringOf(item.object.get("canonical_model_id"))),
            .upstream_model_id = try dupeOptional(arena, stringOf(item.object.get("upstream_model_id"))),
            .model_variant = try dupeOptional(arena, stringOf(item.object.get("model_variant"))),
            .limits = try parseLimits(item.object.get("limits")),
            .capabilities = try parseCapabilities(item.object.get("capabilities")),
            .quote = try parseQuote(item.object.get("price")),
            .controls = try parseControls(arena, item.object.get("controls")),
            .dialect = try parseDialect(item.object.get("dialect")),
        };
    }
    return out;
}

/// `"dialect": "<vendor>"` on a channel (its route) or a model. Absent keeps
/// model-name inference; a value that names no vendor is an error.
fn parseDialect(value: ?std.json.Value) DefinitionError!?Vendor {
    const raw = value orelse return null;
    if (raw == .null) return null;
    const text = stringOf(raw) orelse return error.UnknownDialect;
    return Vendor.parse(text) orelse error.UnknownDialect;
}

fn parseLimits(value: ?std.json.Value) DefinitionError!offer.EffectiveLimits {
    const object = value orelse return .{};
    if (object != .object) return error.InvalidDocument;
    var out = offer.EffectiveLimits{
        .context_window = try optionalU32(object.object.get("context_window")),
        .max_input_tokens = try optionalU32(object.object.get("max_input_tokens")),
        .max_output_tokens = try optionalU32(object.object.get("max_output_tokens")),
        .max_completion_tokens = try optionalU32(object.object.get("max_completion_tokens")),
    };
    // A number the user typed is a declaration, not an observation; provenance
    // records which so a UI never presents it as vendor-confirmed.
    out.provenance = offer.Provenance.known(.user_config, null);
    if (stringOf(object.object.get("token_counting"))) |mode| {
        if (std.mem.eql(u8, mode, "provider_reported")) {
            out.token_counting = .{ .mode = .provider_reported, .unit = .tokens };
        } else if (std.mem.eql(u8, mode, "local_estimate")) {
            out.token_counting = .{ .mode = .local_estimate, .unit = .tokens };
        } else return error.InvalidDocument;
    }
    return out;
}

fn parseCapabilities(value: ?std.json.Value) DefinitionError!offer.CapabilityMatrix {
    const object = value orelse return .{};
    if (object != .object) return error.InvalidDocument;
    var out = offer.CapabilityMatrix{ .provenance = offer.Provenance.known(.user_config, null) };
    var it = object.object.iterator();
    while (it.next()) |pair| {
        const capability = parseCapability(pair.key_ptr.*) orelse return error.UnknownCapability;
        const state = stringOf(pair.value_ptr.*) orelse return error.InvalidDocument;
        const tri: offer.Tri = if (std.mem.eql(u8, state, "supported"))
            .supported
        else if (std.mem.eql(u8, state, "unsupported"))
            .unsupported
        else if (std.mem.eql(u8, state, "unknown"))
            .unknown
        else
            return error.InvalidDocument;
        out = out.with(capability, tri);
    }
    return out;
}

fn parseCapability(text: []const u8) ?offer.Capability {
    inline for (@typeInfo(offer.Capability).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(offer.Capability, field.name);
    }
    return null;
}

fn parseQuote(value: ?std.json.Value) DefinitionError!offer.Quote {
    const object = value orelse return .unknown;
    if (object != .object) return error.InvalidDocument;
    const currency_text = stringOf(object.object.get("currency")) orelse return error.InvalidPrice;
    const currency = offer.Currency.parse(currency_text) catch return error.InvalidPrice;
    const unit_text = stringOf(object.object.get("unit")) orelse "per_million_tokens";
    const unit = parseBillingUnit(unit_text) orelse return error.InvalidPrice;
    return .{
        .known = .{
            .currency = currency,
            .billing_unit = unit,
            .input_price_micros = try optionalMicros(object.object.get("input")),
            .output_price_micros = try optionalMicros(object.object.get("output")),
            .cached_input_price_micros = try optionalMicros(object.object.get("cached_input")),
            .cache_write_price_micros = try optionalMicros(object.object.get("cache_write")),
            .discount_basis_points = try optionalDiscount(object.object.get("discount_basis_points")),
            // A configured price is a declaration by the user, not a bill from the
            // provider, and must not read as one.
            .estimated = true,
            .provenance = offer.Provenance.known(.user_config, null),
        },
    };
}

fn parseBillingUnit(text: []const u8) ?offer.BillingUnit {
    inline for (@typeInfo(offer.BillingUnit).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(offer.BillingUnit, field.name);
    }
    return null;
}

fn parseControls(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError![]const controls_mod.ControlSpec {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    if (list.array.items.len > MAX_CONTROLS) return error.TooManyControls;
    var out = try arena.alloc(controls_mod.ControlSpec, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidDocument;
        const control_id = stringOf(item.object.get("id")) orelse return error.InvalidDocument;
        if (control_id.len == 0) return error.InvalidDocument;
        const kind_text = stringOf(item.object.get("kind")) orelse "enumeration";
        const kind = parseControlKind(kind_text) orelse return error.UnknownControlKind;
        out[index] = .{
            .id = try dupe(arena, control_id),
            .label = try dupe(arena, stringOf(item.object.get("label")) orelse control_id),
            .kind = kind,
            .allowed_values = try parseValues(arena, item.object.get("values")),
            .cost_latency_warning = try dupeOptional(arena, stringOf(item.object.get("cost_latency_warning"))),
            .confirmation_required = boolOf(item.object.get("confirmation_required")) orelse false,
        };
    }
    return out;
}

fn parseControlKind(text: []const u8) ?controls_mod.ValueKind {
    inline for (@typeInfo(controls_mod.ValueKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(controls_mod.ValueKind, field.name);
    }
    return null;
}

fn parseValues(arena: std.mem.Allocator, value: ?std.json.Value) DefinitionError![]const []const u8 {
    const list = value orelse return &.{};
    if (list != .array) return error.InvalidDocument;
    if (list.array.items.len > MAX_ENUM_VALUES) return error.TooManyValues;
    var out = try arena.alloc([]const u8, list.array.items.len);
    for (list.array.items, 0..) |item, index| {
        const text = stringOf(item) orelse return error.InvalidDocument;
        // A value longer than a control value can hold would be accepted here
        // and rejected at commit time, which reads as a mysterious failure.
        _ = controls_mod.ControlText.parse(text) catch return error.InvalidDocument;
        out[index] = try dupe(arena, text);
    }
    return out;
}

// ── writing a definition (`metacodes providers add`) ─────────────────────────

/// The part of the schema a command line can say. Everything else — prices,
/// limits beyond what a listing reports, controls, regions, an `oauth`
/// block — is the user's to add to `config.json` by hand, and a later
/// `--replace` keeps it (`patchEntry`).
pub const Draft = struct {
    display_name: ?[]const u8 = null,
    /// Null keeps the schema default, a bearer token.
    auth: ?profile_mod.AuthScheme = null,
    /// The environment variable the key is read from (`env_aliases`), in the
    /// shell or in `<state root>/.env`.
    key_env: ?[]const u8 = null,
    channels: []const DraftChannel,
    models: []const DraftModel,
};

pub const DraftChannel = struct {
    id: []const u8,
    /// As stored: `model_listing.channelBase` of what the user typed.
    base_url: []const u8,
    wire: Protocol.Wire,
    dialect: ?Vendor = null,
};

pub const DraftModel = struct {
    request_model_id: []const u8,
    display_name: ?[]const u8 = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

/// The JSON object `custom_providers.<id>` holds for `draft` — the same text a
/// person would write by hand, and nothing a person would not.
pub fn renderDraft(allocator: std.mem.Allocator, draft: Draft) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeDraft(&json, draft) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeDraft(json: *std.json.Stringify, draft: Draft) std.Io.Writer.Error!void {
    try json.beginObject();
    if (draft.display_name) |name| {
        try json.objectField("display_name");
        try json.write(name);
    }
    if (draft.auth) |auth| {
        try json.objectField("auth");
        try writeAuth(json, auth);
    }
    if (draft.key_env) |name| {
        try json.objectField("env_aliases");
        try writeEnvAliases(json, name);
    }
    try json.objectField("channels");
    try json.beginArray();
    for (draft.channels) |channel| try writeChannel(json, channel);
    try json.endArray();
    try json.objectField("models");
    try json.beginArray();
    for (draft.models) |model| try writeModel(json, model);
    try json.endArray();
    try json.endObject();
}

fn writeAuth(json: *std.json.Stringify, auth: profile_mod.AuthScheme) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("kind");
    switch (auth) {
        .bearer => try json.write("bearer"),
        .api_key_header => |header| {
            try json.write("api_key_header");
            try json.objectField("header");
            try json.write(header);
        },
        .custom_header => |custom| {
            try json.write("custom_header");
            try json.objectField("header");
            try json.write(custom.name);
            try json.objectField("value_prefix");
            try json.write(custom.value_prefix);
        },
        // Not configurable (`parseAuth`); a draft never holds one.
        .signed_adapter => unreachable,
    }
    try json.endObject();
}

fn writeEnvAliases(json: *std.json.Stringify, name: []const u8) std.Io.Writer.Error!void {
    try json.beginArray();
    try json.beginObject();
    try json.objectField("name");
    try json.write(name);
    try json.objectField("kind");
    try json.write("api_key");
    try json.objectField("canonical");
    try json.write(true);
    try json.endObject();
    try json.endArray();
}

fn writeChannel(json: *std.json.Stringify, channel: DraftChannel) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("id");
    try json.write(channel.id);
    try json.objectField("base_url");
    try json.write(channel.base_url);
    try json.objectField("protocol");
    try json.write(@tagName(channel.wire));
    if (channel.dialect) |dialect| {
        try json.objectField("dialect");
        try json.write(dialect.name());
    }
    try json.endObject();
}

fn writeModel(json: *std.json.Stringify, model: DraftModel) std.Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("request_model_id");
    try json.write(model.request_model_id);
    if (model.display_name) |name| {
        try json.objectField("display_name");
        try json.write(name);
    }
    if (model.context_window != null or model.max_output_tokens != null) {
        try json.objectField("limits");
        try json.beginObject();
        if (model.context_window) |window| {
            try json.objectField("context_window");
            try json.write(window);
        }
        if (model.max_output_tokens) |tokens| {
            try json.objectField("max_output_tokens");
            try json.write(tokens);
        }
        try json.endObject();
    }
    try json.endObject();
}

/// What `metacodes providers add <id> --replace` changes in an existing
/// definition. A null field is left exactly as it is, hand-written
/// additions and all.
pub const Patch = struct {
    display_name: ?[]const u8 = null,
    auth: ?profile_mod.AuthScheme = null,
    key_env: ?[]const u8 = null,
    /// Replaces the channel list.
    channels: ?[]const DraftChannel = null,
    /// Sets the dialect on every channel the definition keeps (with
    /// `channels`, give it there instead).
    dialect: ?Vendor = null,
    /// Replaces the model list. A model that stays keeps its object — the
    /// price, limits and controls someone wrote for it — and a new one is
    /// written as `renderDraft` writes it.
    models: ?[]const DraftModel = null,
};

pub const PatchError = error{ OutOfMemory, InvalidDocument };

/// `existing` (one `custom_providers` member, as JSON) with `patch` applied.
/// Keys keep their order; a key a patch adds goes at the end.
pub fn patchEntry(allocator: std.mem.Allocator, existing: []const u8, patch: Patch) PatchError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDocument,
    };
    if (root != .object) return error.InvalidDocument;
    const object = &root.object;

    if (patch.display_name) |name| try object.put(arena, "display_name", .{ .string = name });
    if (patch.auth) |auth| try object.put(arena, "auth", try valueOf(arena, auth, writeAuth));
    if (patch.key_env) |name| try object.put(arena, "env_aliases", try valueOf(arena, name, writeEnvAliases));
    if (patch.channels) |channels| {
        var list = std.json.Array.init(arena);
        for (channels) |channel| try list.append(try valueOf(arena, channel, writeChannel));
        try object.put(arena, "channels", .{ .array = list });
    } else if (patch.dialect) |dialect| {
        if (object.getPtr("channels")) |channels| if (channels.* == .array) {
            for (channels.array.items) |*channel| {
                if (channel.* == .object) try channel.object.put(arena, "dialect", .{ .string = dialect.name() });
            }
        };
    }
    if (patch.models) |models| {
        var list = std.json.Array.init(arena);
        for (models) |model| {
            const kept = if (object.get("models")) |current| keptModel(current, model.request_model_id) else null;
            try list.append(kept orelse try valueOf(arena, model, writeModel));
        }
        try object.put(arena, "models", .{ .array = list });
    }
    return std.json.Stringify.valueAlloc(allocator, root, .{}) catch error.OutOfMemory;
}

/// The model object `models` already holds for `request_model_id`.
fn keptModel(models: std.json.Value, request_model_id: []const u8) ?std.json.Value {
    if (models != .array) return null;
    for (models.array.items) |model| {
        if (model != .object) continue;
        const id = stringOf(model.object.get("request_model_id")) orelse continue;
        if (std.mem.eql(u8, id, request_model_id)) return model;
    }
    return null;
}

/// `value` written by `write`, read back as a tree in `arena`.
fn valueOf(
    arena: std.mem.Allocator,
    value: anytype,
    comptime write: fn (*std.json.Stringify, @TypeOf(value)) std.Io.Writer.Error!void,
) PatchError!std.json.Value {
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    write(&json, value) catch return error.OutOfMemory;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidDocument,
    };
}

// ── small helpers ────────────────────────────────────────────────────────────

fn dupe(arena: std.mem.Allocator, text: []const u8) DefinitionError![]const u8 {
    return arena.dupe(u8, text) catch error.OutOfMemory;
}

fn dupeOptional(arena: std.mem.Allocator, text: ?[]const u8) DefinitionError!?[]const u8 {
    const value = text orelse return null;
    return try dupe(arena, value);
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

fn boolOf(value: ?std.json.Value) ?bool {
    const found = value orelse return null;
    return switch (found) {
        .bool => |flag| flag,
        else => null,
    };
}

fn intOf(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn optionalU32(value: ?std.json.Value) DefinitionError!?u32 {
    const found = value orelse return null;
    // `intOf` accepts only a JSON integer, so no float conversion happens here.
    const number = intOf(found) orelse return error.InvalidDocument;
    if (number <= 0 or number > std.math.maxInt(u32)) return error.InvalidDocument;
    return @intCast(number);
}

/// Prices are given in whole currency units and stored as micro-units, so a
/// config says `3.0` rather than `3000000`.
fn optionalMicros(value: ?std.json.Value) DefinitionError!?u64 {
    const found = value orelse return null;
    const declared: f64 = switch (found) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => return error.InvalidPrice,
    };
    // Finiteness first: a comparison against a NaN is false, so the range check
    // alone would let `"input": nan` through to `@intFromFloat`, which is
    // illegal behaviour rather than a wrong number.
    if (!std.math.isFinite(declared)) return error.InvalidPrice;
    if (declared < 0 or declared > 1_000_000) return error.InvalidPrice;
    return @intFromFloat(@round(declared * 1_000_000.0));
}

fn optionalDiscount(value: ?std.json.Value) DefinitionError!?u16 {
    const found = value orelse return null;
    const number = intOf(found) orelse return error.InvalidPrice;
    if (number < 0 or number > 10_000) return error.InvalidPrice;
    return @intCast(number);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "an oauth block requires a credential kind the OAuth session serves" {
    // Without an OAuth kind the runtime never opens the OAuth session, so a
    // login stored for this provider would succeed on the command line and be
    // ignored by every session. A definition that can only mislead fails here.
    const a = testing.allocator;
    try testing.expectError(error.OAuthWithoutOAuthCredentialKind, parse(a,
        \\{"custom_providers":{"relay":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://relay.example.com/v1","protocol":"openai_chat"}],
        \\  "oauth":{"token_url":"https://relay.example.com/token","client_id":"relay-cli"}
        \\}}}
    ));
    // Declaring the kind is what makes the block meaningful.
    var accepted = try parse(a,
        \\{"custom_providers":{"relay":{
        \\  "models":[{"request_model_id":"m","display_name":"M"}],
        \\  "channels":[{"id":"default","base_url":"https://relay.example.com/v1","protocol":"openai_chat"}],
        \\  "credential_kinds":["openai_oauth"],
        \\  "oauth":{"token_url":"https://relay.example.com/token","client_id":"relay-cli"}
        \\}}}
    );
    defer accepted.deinit();
    try testing.expect(accepted.find("relay") != null);
}

const RELAY_CONFIG =
    \\{
    \\  "schema_version": 1,
    \\  "custom_providers": {
    \\    "my-relay": {
    \\      "display_name": "House relay",
    \\      "aliases": ["relay"],
    \\      "auth": {"kind": "custom_header", "header": "X-Relay-Token", "value_prefix": "Token "},
    \\      "env_aliases": [{"name": "RELAY_TOKEN", "kind": "api_key", "canonical": true}],
    \\      "endpoint_policy": {"required_path_fragments": ["/relay"]},
    \\      "channels": [
    \\        {"id": "primary", "display_name": "Primary", "base_url": "https://relay.example.com/relay/v1",
    \\         "protocol": {"wire": "openai_chat", "path_suffix": "/completions", "id": "relay_openai"},
    \\         "region": "eu", "plan": "team"}
    \\      ],
    \\      "models": [
    \\        {"request_model_id": "relay-glm-pro", "display_name": "GLM-4.6 (relay)",
    \\         "canonical_model_id": "zai/glm-4.6",
    \\         "limits": {"context_window": 200000, "max_output_tokens": 128000},
    \\         "capabilities": {"tools": "supported", "vision": "unsupported"},
    \\         "price": {"currency": "EUR", "unit": "per_million_tokens", "input": 2.5, "output": 9,
    \\                   "discount_basis_points": 9000},
    \\         "controls": [{"id": "reasoning_effort", "label": "Reasoning", "kind": "enumeration",
    \\                       "values": ["low", "high"], "cost_latency_warning": "slower"}]}
    \\      ]
    \\    }
    \\  }
    \\}
;

test "a configured provider becomes an ordinary profile, metadata and all" {
    const a = testing.allocator;
    var definitions = try parse(a, RELAY_CONFIG);
    defer definitions.deinit();

    try testing.expectEqual(@as(usize, 1), definitions.profiles().len);
    const built = definitions.find("relay").?;
    try testing.expect(built.id.eqlText("my-relay"));
    try testing.expectEqualStrings("House relay", built.display_name);
    try testing.expectEqualStrings("RELAY_TOKEN", built.canonicalEnvAlias(.api_key).?);
    try testing.expectEqualStrings("X-Relay-Token", built.auth.custom_header.name);
    try testing.expectEqualStrings("Token ", built.auth.custom_header.value_prefix);

    const channel = built.channels[0];
    try testing.expectEqualStrings("eu", channel.region.?);
    try testing.expectEqualStrings("team", channel.plan.?);

    const entry = built.models[0];
    try testing.expectEqualStrings("zai/glm-4.6", entry.canonical_model_id.?);
    try testing.expectEqual(@as(?u32, 200_000), entry.limits.context_window);
    try testing.expectEqual(offer.Tri.supported, entry.capabilities.get(.tools));
    try testing.expectEqual(offer.Tri.unsupported, entry.capabilities.get(.vision));
    // Declared metadata is user config, not a vendor observation.
    try testing.expectEqual(offer.Source.user_config, entry.limits.provenance.source);

    const priced = entry.quote.priced().?;
    try testing.expectEqualStrings("EUR", priced.currency.slice());
    try testing.expectEqual(@as(?u64, 2_500_000), priced.input_price_micros);
    try testing.expectEqual(@as(?u64, 9_000_000), priced.output_price_micros);
    try testing.expectEqual(@as(?u16, 9_000), priced.discount_basis_points);
    try testing.expect(priced.estimated);

    try testing.expectEqualStrings("reasoning_effort", entry.controls[0].id);
    try testing.expectEqualStrings("slower", entry.controls[0].cost_latency_warning.?);
}

test "a declarative protocol keeps its own path but reaches a real transport" {
    const a = testing.allocator;
    var definitions = try parse(a, RELAY_CONFIG);
    defer definitions.deinit();
    const protocol = definitions.profiles()[0].channels[0].routes[0].protocol;

    try testing.expectEqualStrings("relay_openai", protocol.id());
    try testing.expectEqualStrings("/completions", protocol.pathSuffix());
    // The wire is what selects the transport, so a relay that only moved the
    // path does not need an adapter.
    try testing.expectEqual(profile_mod.Protocol.Wire.openai_chat, protocol.wire().?);
}

test "a declared dialect lands on the route and the model; an unknown one is an error" {
    const a = testing.allocator;
    var definitions = try parse(a,
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat","dialect":"deepseek"}],
        \\  "models": [{"request_model_id":"m"},{"request_model_id":"n","dialect":"openrouter"}]}}}
    );
    defer definitions.deinit();
    const built = definitions.profiles()[0];
    try testing.expectEqual(Vendor.deepseek, built.channels[0].routes[0].dialect.?);
    try testing.expect(built.models[0].dialect == null);
    try testing.expectEqual(Vendor.openrouter, built.models[1].dialect.?);

    // A model's declaration outranks its route's for that model.
    var catalog = try @import("registry.zig").OfferCatalog.build(a, &.{built}, .{});
    defer catalog.deinit();
    for (catalog.items()) |item| {
        const want: Vendor = if (std.mem.eql(u8, item.request_model_id, "n")) .openrouter else .deepseek;
        try testing.expectEqual(want, item.dialect.bound().?);
        // The route's part stays apart: it is what another model inherits.
        try testing.expectEqual(Vendor.deepseek, item.dialect.route.?);
    }

    inline for (.{ "\"DeepSeek\"", "\"anthropic\"", "3" }) |bad| {
        try testing.expectError(error.UnknownDialect, parse(a,
            \\{"custom_providers": {"x": {
            \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat","dialect":
        ++ bad ++
            \\}],
            \\  "models": [{"request_model_id":"m"}]}}}
        ));
    }
}

test "a novel wire is rejected rather than guessed" {
    const a = testing.allocator;
    const text =
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":{"wire":"grpc_bidi"}}],
        \\  "models": [{"request_model_id":"m"}]}}}
    ;
    try testing.expectError(error.UnknownWire, parse(a, text));
}

test "a definition that could only produce a rejected URL fails at parse time" {
    const a = testing.allocator;
    // Plaintext non-loopback under the default policy.
    const plaintext =
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"http://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m"}]}}}
    ;
    try testing.expectError(error.InvalidDocument, parse(a, plaintext));

    // A URL carrying userinfo would reach `endpoint_ref` and every surface that
    // renders it.
    const userinfo =
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"https://key@x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m"}]}}}
    ;
    try testing.expectError(error.InvalidDocument, parse(a, userinfo));

    // And a base URL the provider's own policy forbids.
    const policy_violation =
        \\{"custom_providers": {"x": {
        \\  "endpoint_policy": {"required_path_fragments": ["/relay"]},
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m"}]}}}
    ;
    try testing.expectError(error.InvalidDocument, parse(a, policy_violation));
}

test "an explicit endpoint_policy governs the route, not just the parse" {
    const a = testing.allocator;
    // The same plaintext base the default policy rejects, with the definition
    // opting in. `validateProfile` checks the base against the profile policy
    // *and* every route policy, so a parsed policy that never reaches the route
    // leaves the documented `require_tls: false` unable to express anything.
    const opted_in =
        \\{"custom_providers": {"x": {
        \\  "endpoint_policy": {"require_tls": false},
        \\  "env_aliases": [{"name":"X_TOKEN","kind":"api_key","canonical":true}],
        \\  "channels": [{"id":"c","base_url":"http://host.docker.internal:3456",
        \\                "protocol":{"wire":"anthropic_messages","id":"x_anthropic"}}],
        \\  "models": [{"request_model_id":"m"}]}}}
    ;
    var definitions = try parse(a, opted_in);
    defer definitions.deinit();

    const built = definitions.find("x").?;
    try testing.expect(!built.endpoint_policy.require_tls);
    try testing.expect(!built.channels[0].routes[0].policy.require_tls);

    // The configured endpoint is reachable, not merely parseable.
    var buffer: [256]u8 = undefined;
    const url = try built.channels[0].endpointFor(
        built.endpoint_policy,
        built.channels[0].routes[0].protocol,
        null,
        &buffer,
    );
    try testing.expectEqualStrings("http://host.docker.internal:3456/v1/messages", url);
}

test "structurally incomplete definitions fail before anything is registered" {
    const a = testing.allocator;
    const cases = [_]struct { text: []const u8, want: DefinitionError }{
        .{ .text =
        \\{"custom_providers": {"x": {"models": [{"request_model_id":"m"}]}}}
        , .want = error.NoChannels },
        .{ .text =
        \\{"custom_providers": {"x": {"channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}]}}}
        , .want = error.NoModels },
        .{ .text =
        \\{"custom_providers": {"Not A Slug": {"channels": [], "models": []}}}
        , .want = error.InvalidSlug },
        .{ .text =
        \\{"custom_providers": {"x": {"auth": {"kind":"api_key_query"},
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m"}]}}}
        , .want = error.UnknownAuthScheme },
        .{ .text =
        \\{"custom_providers": {"x": {"auth": {"kind":"api_key_header"},
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m"}]}}}
        , .want = error.InvalidAuthHeader },
        .{ .text =
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m","price":{"currency":"EUROS","input":1}}]}}}
        , .want = error.InvalidPrice },
        .{ .text =
        \\{"schema_version": 99, "custom_providers": {}}
        , .want = error.UnsupportedSchemaVersion },
    };
    for (cases) |case| {
        testing.expectError(case.want, parse(a, case.text)) catch |err| {
            std.debug.print("case failed: {s}\n", .{case.text});
            return err;
        };
    }
}

test "an absent or empty section is not an error" {
    const a = testing.allocator;
    for ([_][]const u8{ "", "{}", "{\"custom_providers\": {}}" }) |text| {
        var definitions = try parse(a, text);
        defer definitions.deinit();
        try testing.expectEqual(@as(usize, 0), definitions.profiles().len);
    }
}

test "the schema cannot express code, a callback, or a request template" {
    const a = testing.allocator;
    // Unknown keys are ignored rather than interpreted: there is deliberately
    // no field a definition could smuggle behaviour through.
    const text =
        \\{"custom_providers": {"x": {
        \\  "on_request": "curl evil.example.com",
        \\  "request_template": "{{prompt}}",
        \\  "quote_hook": "./hook.sh",
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m"}]}}}
    ;
    var definitions = try parse(a, text);
    defer definitions.deinit();
    const built = definitions.profiles()[0];
    // The only executable hooks a profile has stay null for configured ones.
    try testing.expect(built.quote_hook == null);
    try testing.expectEqual(profile_mod.defaultClassifyError, built.classify_error);
}

test "configured providers are bounded, and duplicates are rejected" {
    const a = testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(a);
    try buffer.appendSlice(a, "{\"custom_providers\": {");
    for (0..MAX_PROVIDERS + 1) |index| {
        if (index > 0) try buffer.append(a, ',');
        const entry = try std.fmt.allocPrint(a,
            \\"p{d}": {{"channels":[{{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}}],"models":[{{"request_model_id":"m"}}]}}
        , .{index});
        defer a.free(entry);
        try buffer.appendSlice(a, entry);
    }
    try buffer.appendSlice(a, "}}");
    try testing.expectError(error.TooManyProviders, parse(a, buffer.items));
}

test "a non-finite or out-of-range price is rejected, not converted" {
    const a = testing.allocator;
    // `@intFromFloat` on a NaN or an out-of-range value is illegal behaviour,
    // and a comparison against NaN is false — so the range check alone would
    // not stop it. Each of these must be an error, not a number.
    for ([_][]const u8{
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m","price":{"currency":"USD","input":1e308}}]}}}
        ,
        \\{"custom_providers": {"x": {
        \\  "channels": [{"id":"c","base_url":"https://x.example.com/v1","protocol":"openai_chat"}],
        \\  "models": [{"request_model_id":"m","price":{"currency":"USD","input":-1}}]}}}
        ,
    }) |text| {
        try testing.expectError(error.InvalidPrice, parse(a, text));
    }
}

test "a configured provider's key is pasted and checked with its default channel's model listing" {
    const a = testing.allocator;
    var definitions = try parse(a,
        \\{"custom_providers": {
        \\  "relay": {"display_name": "House relay",
        \\    "channels": [{"id":"anthropic","base_url":"https://relay.example.com","protocol":"anthropic_messages"},
        \\                 {"id":"openai","base_url":"https://relay.example.com/v1","protocol":"openai_chat"}],
        \\    "models": [{"request_model_id":"m"}]},
        \\  "local": {"channels": [{"id":"openai","base_url":"http://127.0.0.1:11434/v1","protocol":"openai_chat"}],
        \\    "models": [{"request_model_id":"qwen3"}]},
        \\  "bedrock-relay": {"channels": [{"id":"bedrock","base_url":"https://bedrock.example.com","protocol":"bedrock_converse"}],
        \\    "models": [{"request_model_id":"anthropic.claude"}]},
        \\  "sso-only": {"credential_kinds": ["openai_oauth"],
        \\    "oauth": {"token_url":"https://sso.example.com/token","authorize_url":"https://sso.example.com/authorize","client_id":"c"},
        \\    "channels": [{"id":"openai","base_url":"https://sso.example.com/v1","protocol":"openai_chat"}],
        \\    "models": [{"request_model_id":"m"}]}}}
    );
    defer definitions.deinit();

    const relay = definitions.find("relay").?.api_key_setup.?;
    try testing.expectEqual(profile_mod.CredentialKind.api_key, relay.kind);
    try testing.expectEqual(@as(usize, 1), relay.pages.len);
    // No page to send anyone to; the check is the first channel's listing.
    try testing.expect(relay.pages[0].url == null);
    try testing.expectEqualStrings("House relay", relay.pages[0].label);
    try testing.expectEqualStrings("https://relay.example.com/v1/models?limit=1000", relay.pages[0].check_url.?);
    try testing.expectEqual(Protocol.Wire.anthropic_messages, relay.pages[0].check_wire.?);

    // A loopback server is checked where its requests go, in plain HTTP.
    try testing.expectEqualStrings("http://127.0.0.1:11434/v1/models", definitions.find("local").?.api_key_setup.?.pages[0].check_url.?);
    // Nothing to check a Bedrock key with: stored as it is pasted.
    try testing.expect(definitions.find("bedrock-relay").?.api_key_setup.?.pages[0].check_url == null);
    // A gateway that takes only its own sign-in takes no pasted key.
    try testing.expect(definitions.find("sso-only").?.api_key_setup == null);
}

test "a draft renders the schema a person writes, and parses back to the same provider" {
    const a = testing.allocator;
    const channels = [_]DraftChannel{
        .{ .id = "openai", .base_url = "https://relay.example.com/v1", .wire = .openai_chat },
        .{ .id = "anthropic", .base_url = "https://relay.example.com", .wire = .anthropic_messages, .dialect = .glm },
    };
    const models = [_]DraftModel{
        .{ .request_model_id = "glm-4.6" },
        .{ .request_model_id = "kimi-k2", .display_name = "Kimi K2", .context_window = 256_000, .max_output_tokens = 32_000 },
    };
    const text = try renderDraft(a, .{
        .display_name = "House relay",
        .auth = .{ .custom_header = .{ .name = "X-Relay-Token", .value_prefix = "Token " } },
        .key_env = "HOUSE_RELAY_KEY",
        .channels = &channels,
        .models = &models,
    });
    defer a.free(text);
    try testing.expectEqualStrings(
        "{\"display_name\":\"House relay\",\"auth\":{\"kind\":\"custom_header\",\"header\":\"X-Relay-Token\",\"value_prefix\":\"Token \"}," ++
            "\"env_aliases\":[{\"name\":\"HOUSE_RELAY_KEY\",\"kind\":\"api_key\",\"canonical\":true}]," ++
            "\"channels\":[{\"id\":\"openai\",\"base_url\":\"https://relay.example.com/v1\",\"protocol\":\"openai_chat\"}," ++
            "{\"id\":\"anthropic\",\"base_url\":\"https://relay.example.com\",\"protocol\":\"anthropic_messages\",\"dialect\":\"glm\"}]," ++
            "\"models\":[{\"request_model_id\":\"glm-4.6\"},{\"request_model_id\":\"kimi-k2\",\"display_name\":\"Kimi K2\",\"limits\":{\"context_window\":256000,\"max_output_tokens\":32000}}]}",
        text,
    );

    const document = try std.fmt.allocPrint(a, "{{\"custom_providers\":{{\"house-relay\":{s}}}}}", .{text});
    defer a.free(document);
    var definitions = try parse(a, document);
    defer definitions.deinit();
    const built = definitions.find("house-relay").?;
    try testing.expectEqualStrings("House relay", built.display_name);
    try testing.expectEqualStrings("HOUSE_RELAY_KEY", built.canonicalEnvAlias(.api_key).?);
    try testing.expectEqualStrings("Token ", built.auth.custom_header.value_prefix);
    try testing.expectEqual(@as(usize, 2), built.channels.len);
    try testing.expectEqual(Vendor.glm, built.channels[1].routes[0].dialect.?);
    try testing.expectEqual(@as(?u32, 256_000), built.models[1].limits.context_window);

    // The plain case is plain: no auth, no variable, no display name.
    const minimal = try renderDraft(a, .{ .channels = channels[0..1], .models = models[0..1] });
    defer a.free(minimal);
    try testing.expectEqualStrings(
        "{\"channels\":[{\"id\":\"openai\",\"base_url\":\"https://relay.example.com/v1\",\"protocol\":\"openai_chat\"}],\"models\":[{\"request_model_id\":\"glm-4.6\"}]}",
        minimal,
    );
}

test "a patch changes what it names and keeps what a person wrote by hand" {
    const a = testing.allocator;
    const existing =
        \\{"display_name":"Old","endpoint_policy":{"required_path_fragments":["/relay"]},
        \\ "channels":[{"id":"openai","base_url":"https://relay.example.com/relay/v1","protocol":"openai_chat","region":"eu"}],
        \\ "models":[{"request_model_id":"glm-4.6","price":{"currency":"EUR","input":2.5}},{"request_model_id":"gone"}]}
    ;
    const renamed = try patchEntry(a, existing, .{ .display_name = "New" });
    defer a.free(renamed);
    // Only the name moved; the policy, the region and the price are as written.
    try testing.expect(std.mem.indexOf(u8, renamed, "\"display_name\":\"New\"") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "\"region\":\"eu\"") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "\"required_path_fragments\":[\"/relay\"]") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "\"input\":2.5") != null);
    try testing.expect(std.mem.startsWith(u8, renamed, "{\"display_name\":\"New\",\"endpoint_policy\""));

    const models = [_]DraftModel{ .{ .request_model_id = "glm-4.6" }, .{ .request_model_id = "glm-5", .context_window = 200_000 } };
    const listed = try patchEntry(a, existing, .{ .models = &models, .dialect = .glm });
    defer a.free(listed);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, listed, .{});
    defer parsed.deinit();
    const kept = parsed.value.object.get("models").?.array.items;
    try testing.expectEqual(@as(usize, 2), kept.len);
    // The model that stays keeps its price; the new one is written fresh;
    // the one left out is gone.
    try testing.expect(kept[0].object.get("price") != null);
    try testing.expectEqualStrings("glm-5", kept[1].object.get("request_model_id").?.string);
    try testing.expectEqual(@as(i64, 200_000), kept[1].object.get("limits").?.object.get("context_window").?.integer);
    const channel = parsed.value.object.get("channels").?.array.items[0].object;
    try testing.expectEqualStrings("glm", channel.get("dialect").?.string);
    try testing.expectEqualStrings("eu", channel.get("region").?.string);

    try testing.expectError(error.InvalidDocument, patchEntry(a, "[1]", .{}));
}
