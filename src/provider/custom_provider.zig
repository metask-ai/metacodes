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

pub const Slug = ids.Slug;
pub const ProviderProfile = profile_mod.ProviderProfile;
pub const ChannelDescriptor = profile_mod.ChannelDescriptor;
pub const ModelEntry = profile_mod.ModelEntry;
pub const Protocol = profile_mod.Protocol;

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
    };
    // The same structural validation a built-in profile goes through. Doing it
    // here means a malformed definition fails at parse time rather than at the
    // first request.
    profile_mod.validateProfile(built) catch return error.InvalidDocument;
    return built;
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
        routes[0] = .{ .protocol = protocol };

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
        };
    }
    return out;
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
    const number = intOf(found) orelse return error.InvalidDocument;
    if (number <= 0 or number > std.math.maxInt(u32)) return error.InvalidDocument;
    return @intCast(number);
}

/// Prices are given in whole currency units and stored as micro-units, so a
/// config says `3.0` rather than `3000000`.
fn optionalMicros(value: ?std.json.Value) DefinitionError!?u64 {
    const found = value orelse return null;
    const scaled: f64 = switch (found) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => return error.InvalidPrice,
    };
    if (scaled < 0 or scaled > 1_000_000) return error.InvalidPrice;
    return @intFromFloat(@round(scaled * 1_000_000.0));
}

fn optionalDiscount(value: ?std.json.Value) DefinitionError!?u16 {
    const found = value orelse return null;
    const number = intOf(found) orelse return error.InvalidPrice;
    if (number < 0 or number > 10_000) return error.InvalidPrice;
    return @intCast(number);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

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
