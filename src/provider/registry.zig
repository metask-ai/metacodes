//! Provider registry and offer catalog — the single factory extension point
//! (issue #16, delivery slice P0).
//!
//! Adding a provider is: write one `profiles/<vendor>.zig` declaring a
//! `ProviderProfile`, add one line to `BUILTIN_PROFILES`. Nothing in
//! `AgentLoop`, the TUI, the Web UI, or the client factory changes. A provider
//! discovered at runtime (user-defined instance, plugin-supplied profile) uses
//! the same `register` call the built-ins go through, including validation.
//!
//! The catalog materializes offers as the cross product
//! `channel × route × model`, applying channel narrowing on top of each model's
//! own metadata. Every offer that survives is individually selectable — two
//! offers with the same visible model name are never deduplicated, because a
//! different channel, protocol, endpoint, or credential binding is a different
//! route with different limits, price, and health.

const std = @import("std");
const ids = @import("ids.zig");
const offer_mod = @import("offer.zig");
const profile_mod = @import("profile.zig");
const credential = @import("credential.zig");
const types = @import("../types.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const CatalogRevision = ids.CatalogRevision;
pub const ProviderProfile = profile_mod.ProviderProfile;
pub const ChannelDescriptor = profile_mod.ChannelDescriptor;
pub const Protocol = profile_mod.Protocol;
pub const ModelOffer = offer_mod.ModelOffer;

pub const metask = @import("profiles/metask.zig");
pub const openai = @import("profiles/openai.zig");
pub const gemini = @import("profiles/gemini.zig");
pub const zai_coding_plan = @import("profiles/zai_coding_plan.zig");

/// The built-in profile table. One line per provider — this is the extension
/// point the requirement asks for.
pub const BUILTIN_PROFILES = [_]ProviderProfile{
    metask.PROFILE,
    openai.PROFILE,
    gemini.PROFILE,
    zai_coding_plan.PROFILE,
};

// ── transport bridge ─────────────────────────────────────────────────────────

pub const TransportError = error{UnsupportedProtocolTransport};

/// Map a wire protocol onto the concrete client that implements it.
///
/// This is the *only* place a protocol becomes a `types.ProviderKind`, and it
/// is keyed by protocol rather than by vendor — which is what removes
/// `inferProviderKind`'s model-name guessing. A custom protocol has no built-in
/// transport and must fail loudly rather than fall back to Anthropic.
pub fn transportKindFor(protocol: Protocol) TransportError!types.ProviderKind {
    // Keyed by the *wire*, so a declarative custom protocol that only changes
    // the request path still reaches a real transport, while a genuinely novel
    // wire (no declared wire) fails closed until an adapter is registered.
    const wire = protocol.wire() orelse return error.UnsupportedProtocolTransport;
    return switch (wire) {
        .anthropic_messages => .anthropic,
        .openai_chat, .openai_responses => .openai,
        .gemini_generate_content => .gemini,
    };
}

/// The OpenAI wire variant a protocol selects. Never inferred from base URL or
/// model name — the route says which one it is.
pub fn openAiProtocolFor(protocol: Protocol) TransportError!types.OpenAIProtocol {
    const wire = protocol.wire() orelse return error.UnsupportedProtocolTransport;
    return switch (wire) {
        .openai_chat => .chat_completions,
        .openai_responses => .responses,
        else => error.UnsupportedProtocolTransport,
    };
}

// ── registry ─────────────────────────────────────────────────────────────────

pub const RegisterError = profile_mod.ProfileError || error{
    DuplicateProviderId,
    AliasCollision,
    OutOfMemory,
};

pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    /// Profile values. String fields are borrowed from static profile data or
    /// from a caller-owned arena that must outlive the registry.
    profiles: std.ArrayList(ProviderProfile) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProviderRegistry {
        return .{ .allocator = allocator };
    }

    pub fn initWithBuiltins(allocator: std.mem.Allocator) RegisterError!ProviderRegistry {
        var registry = ProviderRegistry.init(allocator);
        errdefer registry.deinit();
        for (BUILTIN_PROFILES) |profile| try registry.register(profile);
        return registry;
    }

    pub fn deinit(self: *ProviderRegistry) void {
        self.profiles.deinit(self.allocator);
        self.* = undefined;
    }

    /// The single extension point. Validation runs here so no consumer has to
    /// defend against an unroutable profile.
    pub fn register(self: *ProviderRegistry, profile: ProviderProfile) RegisterError!void {
        try profile_mod.validateProfile(profile);
        for (self.profiles.items) |existing| {
            if (existing.id.eql(profile.id)) return error.DuplicateProviderId;
            if (existing.matchesName(profile.id.slice())) return error.AliasCollision;
            for (profile.aliases) |alias| {
                if (existing.matchesName(alias)) return error.AliasCollision;
            }
        }
        // An alias must not shadow this profile's own id space either.
        for (profile.aliases, 0..) |alias, index| {
            if (profile.id.eqlText(alias)) return error.AliasCollision;
            for (profile.aliases[index + 1 ..]) |other| {
                if (std.mem.eql(u8, alias, other)) return error.AliasCollision;
            }
        }
        try self.profiles.append(self.allocator, profile);
    }

    /// Resolve by stable id or configuration alias.
    pub fn find(self: *const ProviderRegistry, name: []const u8) ?*const ProviderProfile {
        for (self.profiles.items) |*profile| {
            if (profile.matchesName(name)) return profile;
        }
        return null;
    }

    pub fn findById(self: *const ProviderRegistry, id: Slug) ?*const ProviderProfile {
        for (self.profiles.items) |*profile| {
            if (profile.id.eql(id)) return profile;
        }
        return null;
    }

    pub fn buildCatalog(
        self: *const ProviderRegistry,
        allocator: std.mem.Allocator,
        options: CatalogOptions,
    ) CatalogError!OfferCatalog {
        return OfferCatalog.build(allocator, self.profiles.items, options);
    }
};

// ── catalog ──────────────────────────────────────────────────────────────────

/// Binds a credential reference to a provider, optionally narrowed to one
/// channel. The binding participates in offer identity, so two BYOK keys on the
/// same route are distinct offers rather than accidental duplicates.
pub const CredentialBinding = struct {
    provider_id: Slug,
    channel_id: ?Slug = null,
    credential_ref: Slug,
};

/// An explicit endpoint override (`--base-url`, `METACODES_BASE_URL`, or a
/// configured relay). Validated against the profile and route policy while the
/// catalog is built, so an invalid override fails before any request exists.
pub const EndpointOverride = struct {
    provider_id: Slug,
    channel_id: ?Slug = null,
    base_url: []const u8,
};

/// Upper bound on credentials bound to one channel. Matches the configured pool
/// bound, which rejects a longer list at parse time; exceeding it here is an
/// error rather than a truncation, because silently dropping a credential the
/// caller bound means an account the user configured simply never appears.
pub const MAX_CHANNEL_BINDINGS: usize = 8;

pub const CatalogOptions = struct {
    revision: CatalogRevision = .initial,
    credential_bindings: []const CredentialBinding = &.{},
    endpoint_overrides: []const EndpointOverride = &.{},
    /// Restrict the catalog to one provider. Null builds every profile.
    only_provider: ?Slug = null,
    /// Providers the configuration disabled. They keep their configuration and
    /// credential references — that is what makes disabling different from
    /// removing — but produce no offers, so nothing can route to them.
    excluded_providers: []const Slug = &.{},
};

pub const CatalogError = profile_mod.EndpointError ||
    offer_mod.LimitsError ||
    error{ OutOfMemory, TooManyCredentialBindings };

/// Materialized offers plus the arena owning their constructed strings.
pub const OfferCatalog = struct {
    arena: std.heap.ArenaAllocator,
    offers: std.ArrayList(ModelOffer),
    revision: CatalogRevision,

    pub fn build(
        allocator: std.mem.Allocator,
        profiles: []const ProviderProfile,
        options: CatalogOptions,
    ) CatalogError!OfferCatalog {
        var catalog = OfferCatalog{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .offers = .empty,
            .revision = options.revision,
        };
        errdefer catalog.deinit();
        const arena = catalog.arena.allocator();

        for (profiles) |profile| {
            if (options.only_provider) |wanted| {
                if (!profile.id.eql(wanted)) continue;
            }
            var excluded = false;
            for (options.excluded_providers) |id| {
                if (profile.id.eql(id)) excluded = true;
            }
            if (excluded) continue;
            for (profile.channels) |channel| {
                const override = findOverride(options.endpoint_overrides, profile.id, channel.id);
                // Every binding that applies to this channel produces its *own*
                // offer: two accounts on one route are two route identities,
                // not one route that silently changes identity depending on
                // which credential resolution happened to pick. `null` is the
                // unbound case, so a provider with no configured pool builds
                // exactly the offers it always did.
                var binding_buffer: [MAX_CHANNEL_BINDINGS]?Slug = undefined;
                const bound_credentials = try collectBindings(
                    options.credential_bindings,
                    profile.id,
                    channel.id,
                    &binding_buffer,
                );
                for (channel.routes) |route| {
                    var url_buffer: [1024]u8 = undefined;
                    const url = try channel.endpointFor(
                        profile.endpoint_policy,
                        route.protocol,
                        override,
                        &url_buffer,
                    );
                    const endpoint = try arena.dupe(u8, url);
                    for (bound_credentials) |bound_credential| {
                        for (profile.inventoryFor(channel)) |entry| {
                            if (!entry.servesProtocol(route.protocol)) continue;
                            const limits = try entry.limits.intersect(channel.limits);
                            const capabilities = offer_mod.CapabilityMatrix.narrow(
                                entry.capabilities,
                                channel.capabilities,
                            );
                            const quote = if (channel.quote.isKnown()) channel.quote else entry.quote;
                            const controls = if (channel.controls.len > 0) channel.controls else entry.controls;
                            const offer_id = OfferId.derive(.{
                                .provider_id = profile.id,
                                .channel_id = channel.id,
                                .protocol = route.protocol.id(),
                                .endpoint_url = endpoint,
                                .request_model_id = entry.request_model_id,
                                .credential_ref = if (bound_credential) |ref| ref.slice() else "",
                            });
                            try catalog.offers.append(arena, .{
                                .offer_id = offer_id,
                                .provider_id = profile.id,
                                .channel_id = channel.id,
                                .canonical_model_id = entry.canonical_model_id,
                                .model_variant = entry.model_variant,
                                .request_model_id = entry.request_model_id,
                                .upstream_model_id = entry.upstream_model_id,
                                .protocol = route.protocol.id(),
                                .wire = route.protocol.wire(),
                                .endpoint_ref = endpoint,
                                .credential_ref = bound_credential,
                                .display_name = entry.display_name,
                                .region = channel.region,
                                .plan = channel.plan,
                                .account = channel.account,
                                .limits = limits,
                                .capabilities = capabilities,
                                .quote = quote,
                                .availability = entry.availability,
                                .controls = controls,
                                .catalog_revision = options.revision,
                            });
                        }
                    }
                }
            }
        }
        return catalog;
    }

    pub fn deinit(self: *OfferCatalog) void {
        // Offers and their strings all live in the arena; one free covers both.
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn items(self: *const OfferCatalog) []const ModelOffer {
        return self.offers.items;
    }

    pub fn find(self: *const OfferCatalog, offer_id: OfferId) ?*const ModelOffer {
        for (self.offers.items) |*candidate| {
            if (candidate.offer_id.eql(offer_id)) return candidate;
        }
        return null;
    }

    /// Offers whose canonical identity (or, absent one, request id) matches.
    /// Never a name-prefix guess — the selector is compared to declared data.
    pub fn countMatchingSelector(self: *const OfferCatalog, selector: []const u8) usize {
        var count: usize = 0;
        for (self.offers.items) |candidate| {
            if (matchesSelector(candidate, selector)) count += 1;
        }
        return count;
    }

    pub fn firstMatchingSelector(self: *const OfferCatalog, selector: []const u8) ?*const ModelOffer {
        for (self.offers.items) |*candidate| {
            if (matchesSelector(candidate.*, selector)) return candidate;
        }
        return null;
    }
};

pub fn matchesSelector(candidate: ModelOffer, selector: []const u8) bool {
    if (std.mem.eql(u8, candidate.request_model_id, selector)) return true;
    if (candidate.canonical_model_id) |canonical| {
        if (std.mem.eql(u8, canonical, selector)) return true;
    }
    if (candidate.model_variant) |variant| {
        if (std.mem.eql(u8, variant, selector)) return true;
    }
    return false;
}

fn findOverride(
    overrides: []const EndpointOverride,
    provider_id: Slug,
    channel_id: Slug,
) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    for (overrides) |override| {
        if (!override.provider_id.eql(provider_id)) continue;
        if (override.channel_id) |wanted| {
            if (wanted.eql(channel_id)) return override.base_url;
            continue;
        }
        fallback = override.base_url;
    }
    return fallback;
}

/// Credentials bound to one channel, or a single `null` when none is.
///
/// A channel-specific binding is more specific than a provider-wide one, so
/// when any channel-specific binding exists the provider-wide ones do not also
/// apply — otherwise "this key, only for this region" would silently also offer
/// every other key there.
fn collectBindings(
    bindings: []const CredentialBinding,
    provider_id: Slug,
    channel_id: Slug,
    buffer: []?Slug,
) error{TooManyCredentialBindings}![]const ?Slug {
    var len: usize = 0;
    for (bindings) |binding| {
        if (!binding.provider_id.eql(provider_id)) continue;
        const wanted = binding.channel_id orelse continue;
        if (!wanted.eql(channel_id)) continue;
        if (len == buffer.len) return error.TooManyCredentialBindings;
        buffer[len] = binding.credential_ref;
        len += 1;
    }
    if (len > 0) return buffer[0..len];

    for (bindings) |binding| {
        if (!binding.provider_id.eql(provider_id)) continue;
        if (binding.channel_id != null) continue;
        if (len == buffer.len) return error.TooManyCredentialBindings;
        buffer[len] = binding.credential_ref;
        len += 1;
    }
    if (len > 0) return buffer[0..len];

    buffer[0] = null;
    return buffer[0..1];
}

// ── tests ────────────────────────────────────────────────────────────────────

test "built-in registry accepts every shipped profile" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectEqual(BUILTIN_PROFILES.len, registry.profiles.items.len);
    try std.testing.expect(registry.find("metask") != null);
    try std.testing.expect(registry.find("zai-coding-plan") != null);
    // Aliases resolve to the same profile without becoming a second identity.
    try std.testing.expect(registry.find("glm-coding-plan").?.id.eqlText("zai-coding-plan"));
    try std.testing.expect(registry.find("anthropic").?.id.eqlText("metask"));
    try std.testing.expect(registry.find("nope") == null);
}

test "registration rejects duplicate ids and alias collisions" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    try std.testing.expectError(error.DuplicateProviderId, registry.register(metask.PROFILE));

    var shadow = openai.PROFILE;
    shadow.id = Slug.lit("openai-work");
    const stolen = [_][]const u8{"glm"};
    shadow.aliases = &stolen;
    try std.testing.expectError(error.AliasCollision, registry.register(shadow));
}

test "two instances may share one implementation with isolated identity" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var work = openai.PROFILE;
    work.id = Slug.lit("openai-work");
    var personal = openai.PROFILE;
    personal.id = Slug.lit("openai-personal");
    try registry.register(work);
    try registry.register(personal);

    const a = registry.find("openai-work").?;
    const b = registry.find("openai-personal").?;
    try std.testing.expect(a.implementation_id.eql(b.implementation_id));
    try std.testing.expect(!a.id.eql(b.id));
}

test "catalog materializes one offer per channel × route × model" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("zai-coding-plan"),
    });
    defer catalog.deinit();
    // 4 channels × 1 route each × 3 models.
    try std.testing.expectEqual(@as(usize, 12), catalog.items().len);

    // The same canonical model reached through four routes stays four offers.
    try std.testing.expectEqual(@as(usize, 4), catalog.countMatchingSelector("zai/glm-4.6"));
}

test "same visible model on different channels keeps distinct offers and endpoints" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("zai-coding-plan"),
    });
    defer catalog.deinit();

    var cn_anthropic: ?ModelOffer = null;
    var global_openai: ?ModelOffer = null;
    for (catalog.items()) |candidate| {
        if (!std.mem.eql(u8, candidate.request_model_id, "glm-4.6")) continue;
        if (candidate.channel_id.eqlText("cn-anthropic")) cn_anthropic = candidate;
        if (candidate.channel_id.eqlText("global-openai")) global_openai = candidate;
    }
    try std.testing.expect(!cn_anthropic.?.offer_id.eql(global_openai.?.offer_id));
    try std.testing.expectEqualStrings(
        "https://open.bigmodel.cn/api/anthropic/v1/messages",
        cn_anthropic.?.endpoint_ref,
    );
    try std.testing.expectEqualStrings(
        "https://api.z.ai/api/coding/paas/v4/chat/completions",
        global_openai.?.endpoint_ref,
    );
    try std.testing.expectEqualStrings("anthropic_messages", cn_anthropic.?.protocol);
    try std.testing.expectEqualStrings("openai_chat", global_openai.?.protocol);
    try std.testing.expectEqualStrings("cn", cn_anthropic.?.region.?);
    try std.testing.expectEqualStrings("global", global_openai.?.region.?);
}

test "credential binding changes offer identity, not the request model id" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var unbound = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("zai-coding-plan"),
    });
    defer unbound.deinit();

    const bindings = [_]CredentialBinding{.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .credential_ref = Slug.lit("cred-zai-work"),
    }};
    var bound = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("zai-coding-plan"),
        .credential_bindings = &bindings,
    });
    defer bound.deinit();

    try std.testing.expectEqual(unbound.items().len, bound.items().len);
    try std.testing.expect(!unbound.items()[0].offer_id.eql(bound.items()[0].offer_id));
    try std.testing.expectEqualStrings(
        unbound.items()[0].request_model_id,
        bound.items()[0].request_model_id,
    );
    try std.testing.expect(bound.items()[0].credential_ref.?.eqlText("cred-zai-work"));
}

test "an invalid endpoint override fails while the catalog is built" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const overrides = [_]EndpointOverride{.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .base_url = "https://open.bigmodel.cn/api/paas/v4",
    }};
    try std.testing.expectError(error.ForbiddenEndpointPath, registry.buildCatalog(
        std.testing.allocator,
        .{ .only_provider = Slug.lit("zai-coding-plan"), .endpoint_overrides = &overrides },
    ));
}

test "a channel-scoped override leaves the other channels alone" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    const overrides = [_]EndpointOverride{.{
        .provider_id = Slug.lit("zai-coding-plan"),
        .channel_id = Slug.lit("cn-openai"),
        .base_url = "https://relay.internal/api/coding/paas/v4",
    }};
    var catalog = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("zai-coding-plan"),
        .endpoint_overrides = &overrides,
    });
    defer catalog.deinit();
    for (catalog.items()) |candidate| {
        if (candidate.channel_id.eqlText("cn-openai")) {
            try std.testing.expectEqualStrings(
                "https://relay.internal/api/coding/paas/v4/chat/completions",
                candidate.endpoint_ref,
            );
        }
        if (candidate.channel_id.eqlText("global-openai")) {
            try std.testing.expectEqualStrings(
                "https://api.z.ai/api/coding/paas/v4/chat/completions",
                candidate.endpoint_ref,
            );
        }
    }
}

test "protocol selects the transport, model name never does" {
    try std.testing.expectEqual(types.ProviderKind.anthropic, try transportKindFor(.anthropic_messages));
    try std.testing.expectEqual(types.ProviderKind.openai, try transportKindFor(.openai_chat));
    try std.testing.expectEqual(types.ProviderKind.openai, try transportKindFor(.openai_responses));
    try std.testing.expectEqual(types.ProviderKind.gemini, try transportKindFor(.gemini_generate_content));
    try std.testing.expectError(error.UnsupportedProtocolTransport, transportKindFor(.{
        .custom = .{ .id = "vendor_v2", .path_suffix = "/v2" },
    }));

    try std.testing.expectEqual(types.OpenAIProtocol.chat_completions, try openAiProtocolFor(.openai_chat));
    try std.testing.expectEqual(types.OpenAIProtocol.responses, try openAiProtocolFor(.openai_responses));
    try std.testing.expectError(error.UnsupportedProtocolTransport, openAiProtocolFor(.anthropic_messages));

    // A GLM model reached over the Anthropic wire uses the Anthropic transport
    // — the opposite of what a model-name prefix rule would have concluded.
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("zai-coding-plan"),
    });
    defer catalog.deinit();
    for (catalog.items()) |candidate| {
        if (!candidate.channel_id.eqlText("cn-anthropic")) continue;
        const protocol = Protocol.parse(candidate.protocol).?;
        try std.testing.expectEqual(types.ProviderKind.anthropic, try transportKindFor(protocol));
    }
}

test "a runtime-registered relay maps a private request id to a canonical model" {
    var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
    defer registry.deinit();

    const models = [_]profile_mod.ModelEntry{.{
        .request_model_id = "relay-glm-pro",
        .display_name = "GLM-5.3 (relay-a)",
        .canonical_model_id = "zai/glm-5.3",
        .upstream_model_id = "glm-5.3",
    }};
    const routes = [_]profile_mod.ProtocolRoute{.{ .protocol = .openai_chat }};
    const channels = [_]profile_mod.ChannelDescriptor{.{
        .id = Slug.lit("channel-1"),
        .display_name = "Relay A",
        .base_url = "https://relay.test/v1",
        .routes = &routes,
    }};
    const kinds = [_]credential.CredentialKind{.api_key};
    try registry.register(.{
        .id = Slug.lit("relay-a"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Relay A",
        .channels = &channels,
        .models = &models,
        .accepted_credential_kinds = &kinds,
    });

    var catalog = try registry.buildCatalog(std.testing.allocator, .{
        .only_provider = Slug.lit("relay-a"),
    });
    defer catalog.deinit();
    const relayed = catalog.firstMatchingSelector("zai/glm-5.3").?;
    // The UI groups it as GLM-5.3 …
    try std.testing.expectEqualStrings("zai/glm-5.3", relayed.groupKey());
    try std.testing.expectEqualStrings("glm-5.3", relayed.upstream_model_id.?);
    // … while the wire model id stays exactly what the relay accepts.
    try std.testing.expectEqualStrings("relay-glm-pro", relayed.request_model_id);
}

test "catalog offers survive the registry that produced them" {
    var catalog: OfferCatalog = undefined;
    {
        var registry = try ProviderRegistry.initWithBuiltins(std.testing.allocator);
        defer registry.deinit();
        catalog = try registry.buildCatalog(std.testing.allocator, .{
            .only_provider = Slug.lit("metask"),
        });
    }
    defer catalog.deinit();
    try std.testing.expect(catalog.items().len > 0);
    try std.testing.expectEqualStrings(
        "https://napi.metask-ai.com/v1/messages",
        catalog.items()[0].endpoint_ref,
    );
}
