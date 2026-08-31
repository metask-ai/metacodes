//! From a resolved `RuntimeSelection` to concrete transport parameters
//! (issue #16, delivery slice P0 — the wiring half).
//!
//! This is where the offer graph stops being metadata and starts being bytes.
//! One call turns a selection into everything the client factory needs:
//! transport kind, wire protocol variant, request URL, the exact
//! `request_model_id`, and a provider-declared auth header — plus the effective
//! limits admission must use.
//!
//! Two rules are enforced here rather than left to call sites:
//!
//! - the wire model id is the offer's `request_model_id`, never its canonical
//!   or upstream name;
//! - the transport is chosen by the offer's protocol, never by a model-name
//!   prefix (`main.zig`'s `inferProviderKind` is the legacy fallback this
//!   replaces).

const std = @import("std");
const types = @import("../types.zig");
const ids = @import("ids.zig");
const offer_mod = @import("offer.zig");
const profile_mod = @import("profile.zig");
const credential = @import("credential.zig");
const registry_mod = @import("registry.zig");
const selection_mod = @import("selection.zig");

pub const Slug = ids.Slug;
pub const OfferId = ids.OfferId;
pub const ModelOffer = offer_mod.ModelOffer;
pub const ProviderRegistry = registry_mod.ProviderRegistry;
pub const OfferCatalog = registry_mod.OfferCatalog;
pub const RuntimeSelection = selection_mod.RuntimeSelection;

pub const BindError = selection_mod.ResolveError ||
    credential.ResolveError ||
    registry_mod.TransportError ||
    error{UnknownProvider};

/// Credential material available to this process, independent of provider.
/// Which of it is *eligible* is decided by the provider profile, so a key for
/// one vendor can never satisfy another.
pub const CredentialSources = struct {
    cli_api_key: ?[]const u8 = null,
    runtime_fd_secret: ?[]const u8 = null,
    stored_api_key: ?credential.StoredEntry = null,
    stored_oauth: ?credential.StoredEntry = null,
    precedence: credential.AuthPrecedence = .api_key_first,
    env: credential.EnvLookup = credential.EnvLookup.empty(),
    now_seconds: i64 = 0,
};

/// Everything the client factory needs, and nothing it does not.
///
/// `secret` is borrowed from the caller-owned credential material for the
/// duration of request setup; it is never copied into durable state.
pub const RuntimeBinding = struct {
    offer_id: OfferId,
    offer_revision: ids.OfferRevision,
    provider_id: Slug,
    channel_id: Slug,
    protocol: profile_mod.Protocol,
    transport: types.ProviderKind,
    /// Only meaningful when `transport == .openai`; the route decides it.
    openai_protocol: types.OpenAIProtocol,
    endpoint_url: []const u8,
    /// The exact string the request body (or URL) must carry.
    request_model_id: []const u8,
    /// Grouping identity for display; never sent on the wire.
    canonical_model_id: ?[]const u8,
    auth_scheme: credential.AuthScheme,
    credential_ref: credential.CredentialRef,
    secret: []const u8,
    limits: offer_mod.EffectiveLimits,
    capabilities: offer_mod.CapabilityMatrix,
    classify_error: profile_mod.ClassifyFn,
    revision_changed: bool,

    /// Token admission against the *channel's* effective limits, before any
    /// network I/O.
    pub fn admit(
        self: RuntimeBinding,
        request: offer_mod.AdmissionRequest,
        policy: offer_mod.AdmissionPolicy,
    ) offer_mod.Admission {
        return self.limits.admit(request, policy);
    }

    /// Provider-owned retry classification for a failed response.
    pub fn classify(self: RuntimeBinding, status: u16, body: []const u8) profile_mod.ErrorClass {
        return self.classify_error(status, body);
    }
};

pub fn bind(
    registry: *const ProviderRegistry,
    catalog: *const OfferCatalog,
    selection: RuntimeSelection,
    sources: CredentialSources,
    ref_id_buffer: []u8,
) BindError!RuntimeBinding {
    const resolution = try selection_mod.resolve(catalog, selection);
    return bindOffer(registry, resolution.primary(), sources, ref_id_buffer, resolution.revision_changed);
}

pub fn bindOffer(
    registry: *const ProviderRegistry,
    offer: *const ModelOffer,
    sources: CredentialSources,
    ref_id_buffer: []u8,
    revision_changed: bool,
) BindError!RuntimeBinding {
    const profile = registry.findById(offer.provider_id) orelse return error.UnknownProvider;
    const protocol = profile_mod.Protocol.parse(offer.protocol) orelse
        return error.UnsupportedProtocolTransport;
    const transport = try registry_mod.transportKindFor(protocol);
    const openai_protocol = switch (transport) {
        .openai => try registry_mod.openAiProtocolFor(protocol),
        else => types.OpenAIProtocol.chat_completions,
    };

    const resolved_credential = try credential.resolve(.{
        .provider_id = profile.id,
        .accepted_kinds = profile.accepted_credential_kinds,
        .env_aliases = profile.env_aliases,
        .runtime_fd_secret = sources.runtime_fd_secret,
        .cli_api_key = sources.cli_api_key,
        .stored_api_key = sources.stored_api_key,
        .stored_oauth = sources.stored_oauth,
        .precedence = sources.precedence,
        .env = sources.env,
        .now_seconds = sources.now_seconds,
    }, ref_id_buffer);

    return .{
        .offer_id = offer.offer_id,
        .offer_revision = offer.offer_revision,
        .provider_id = offer.provider_id,
        .channel_id = offer.channel_id,
        .protocol = protocol,
        .transport = transport,
        .openai_protocol = openai_protocol,
        .endpoint_url = offer.endpoint_ref,
        .request_model_id = offer.request_model_id,
        .canonical_model_id = offer.canonical_model_id,
        .auth_scheme = profile.auth,
        .credential_ref = resolved_credential.ref,
        .secret = resolved_credential.secret,
        .limits = offer.limits,
        .capabilities = offer.capabilities,
        .classify_error = profile.classify_error,
        .revision_changed = revision_changed,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const TestEnv = struct {
    pairs: []const [2][]const u8,

    fn lookup(self: *TestEnv) credential.EnvLookup {
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

fn offerFor(catalog: *const OfferCatalog, channel: []const u8, model: []const u8) *const ModelOffer {
    for (catalog.items()) |*candidate| {
        if (candidate.channel_id.eqlText(channel) and
            std.mem.eql(u8, candidate.request_model_id, model)) return candidate;
    }
    unreachable;
}

test "the GLM Anthropic route binds to the Anthropic transport and endpoint" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    var env = TestEnv{ .pairs = &.{.{ "GLM_API_KEY", "zai-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    const binding = try bindOffer(
        &registry,
        offerFor(&catalog, "cn-anthropic", "glm-4.6"),
        .{ .env = env.lookup() },
        &buffer,
        false,
    );
    try std.testing.expectEqual(types.ProviderKind.anthropic, binding.transport);
    try std.testing.expectEqualStrings(
        "https://open.bigmodel.cn/api/anthropic/v1/messages",
        binding.endpoint_url,
    );
    try std.testing.expectEqualStrings("glm-4.6", binding.request_model_id);
    try std.testing.expectEqualStrings("zai-secret", binding.secret);
    try std.testing.expectEqual(
        credential.CredentialKind.zai_coding_plan_api_key,
        binding.credential_ref.kind,
    );
}

test "the GLM OpenAI route binds to the OpenAI transport and chat protocol" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    var env = TestEnv{ .pairs = &.{.{ "ZAI_API_KEY", "zai-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    const binding = try bindOffer(
        &registry,
        offerFor(&catalog, "global-openai", "glm-4.6"),
        .{ .env = env.lookup() },
        &buffer,
        false,
    );
    try std.testing.expectEqual(types.ProviderKind.openai, binding.transport);
    try std.testing.expectEqual(types.OpenAIProtocol.chat_completions, binding.openai_protocol);
    try std.testing.expectEqualStrings(
        "https://api.z.ai/api/coding/paas/v4/chat/completions",
        binding.endpoint_url,
    );
}

test "the wire model id is the request id, never the canonical one" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
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
    const aliases = [_]credential.EnvAlias{.{ .name = "RELAY_A_KEY", .kind = .api_key, .canonical = true }};
    try registry.register(.{
        .id = Slug.lit("relay-a"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Relay A",
        .channels = &channels,
        .models = &models,
        .accepted_credential_kinds = &kinds,
        .env_aliases = &aliases,
    });

    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("relay-a") });
    defer catalog.deinit();
    var env = TestEnv{ .pairs = &.{.{ "RELAY_A_KEY", "relay-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    const binding = try bindOffer(&registry, &catalog.items()[0], .{ .env = env.lookup() }, &buffer, false);
    try std.testing.expectEqualStrings("relay-glm-pro", binding.request_model_id);
    try std.testing.expectEqualStrings("zai/glm-5.3", binding.canonical_model_id.?);
}

test "binding fails before I/O when no eligible credential exists" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    // Only a Metask key is present; it is not eligible for this provider.
    var env = TestEnv{ .pairs = &.{.{ "METASK_API_KEY", "metask-secret" }} };
    try std.testing.expectError(error.MissingCredentials, bindOffer(
        &registry,
        offerFor(&catalog, "cn-anthropic", "glm-4.6"),
        .{ .env = env.lookup() },
        &buffer,
        false,
    ));

    // Conflicting aliases are also a pre-flight failure.
    var conflicting = TestEnv{ .pairs = &.{
        .{ "GLM_API_KEY", "one" },
        .{ "ZAI_API_KEY", "two" },
    } };
    try std.testing.expectError(error.AmbiguousCredentialAliases, bindOffer(
        &registry,
        offerFor(&catalog, "cn-anthropic", "glm-4.6"),
        .{ .env = conflicting.lookup() },
        &buffer,
        false,
    ));
}

test "admission uses the bound channel limits and the provider classifier" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    var env = TestEnv{ .pairs = &.{.{ "ZAI_API_KEY", "zai-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    const bound = try bindOffer(
        &registry,
        offerFor(&catalog, "cn-anthropic", "glm-4.6"),
        .{ .env = env.lookup() },
        &buffer,
        false,
    );
    const too_large = bound.admit(.{ .input_tokens = 900_000, .requested_output_tokens = 10 }, .{});
    try std.testing.expect(!too_large.isAdmitted());
    const fits = bound.admit(.{ .input_tokens = 1_000, .requested_output_tokens = 1_000 }, .{});
    try std.testing.expect(fits.isAdmitted());

    // The unknown-limit model fails closed on the same route.
    const air = try bindOffer(
        &registry,
        offerFor(&catalog, "cn-anthropic", "glm-4.5-air"),
        .{ .env = env.lookup() },
        &buffer,
        false,
    );
    try std.testing.expect(!air.admit(.{ .input_tokens = 1, .requested_output_tokens = 1 }, .{}).isAdmitted());

    // Classification comes from the profile, not from a shared default.
    try std.testing.expectEqual(profile_mod.ErrorClass.quota_exceeded, bound.classify(429, "quota exhausted"));
    try std.testing.expect(!bound.classify(429, "quota exhausted").isRetryableTransport());
    try std.testing.expect(bound.classify(429, "slow down").isRetryableTransport());
}

test "a pinned selection binds end to end" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("metask") });
    defer catalog.deinit();
    var env = TestEnv{ .pairs = &.{.{ "METASK_API_KEY", "metask-secret" }} };
    var buffer: [ids.MAX_SLUG_LEN]u8 = undefined;

    const target = offerFor(&catalog, "default", "claude-sonnet-4-6");
    const binding = try bind(
        &registry,
        &catalog,
        RuntimeSelection.pinned(target.offer_id, target.offer_revision, .session),
        .{ .env = env.lookup() },
        &buffer,
    );
    try std.testing.expectEqual(types.ProviderKind.anthropic, binding.transport);
    try std.testing.expectEqualStrings("https://napi.metask-ai.com/v1/messages", binding.endpoint_url);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", binding.request_model_id);
    try std.testing.expect(binding.auth_scheme == .bearer);
}

test "the gemini profile's declared auth scheme matches what its transport sends" {
    // The Gemini transport hard-codes `x-goog-api-key` because the protocol
    // fixes it. This pins the profile declaration to that fact so the two
    // cannot drift apart silently.
    var buffer: [64]u8 = undefined;
    const materialized = try credential.materialize(
        registry_mod.gemini.PROFILE.auth,
        "gk-secret",
        &buffer,
    );
    try std.testing.expectEqualStrings("x-goog-api-key", materialized.name);
    try std.testing.expectEqualStrings("gk-secret", materialized.value);
}
