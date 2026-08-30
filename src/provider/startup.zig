//! Startup route resolution (issue #16, delivery slice P0 — CLI/bootstrap).
//!
//! Turns `--provider/--channel/--offer/--model/--base-url` into one concrete
//! route by consulting the provider registry, replacing `main.zig`'s
//! `inferProviderKind` model-name guessing for every session that names a
//! provider. Sessions that name none keep the historical path untouched.
//!
//! The returned route owns its strings, so the registry and catalog used to
//! produce it can be torn down immediately — a process-lifetime catalog is a
//! P1 concern (live refresh), not a bootstrap requirement.
//!
//! `auth_scheme` borrows header-name literals from the profile. Built-in
//! profiles are comptime data and live forever; a runtime-registered profile
//! must outlive the route, which the registry ownership rules already require.

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
pub const ProviderRegistry = registry_mod.ProviderRegistry;

pub const StartupRequest = struct {
    /// Provider id or configuration alias. Null keeps the legacy path.
    provider: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    /// Exact offer id (`offer-…`), which pins a route with no ambiguity.
    offer_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Explicit `--base-url`; validated against the profile/route policy.
    base_url: ?[]const u8 = null,
};

pub const StartupRoute = struct {
    allocator: std.mem.Allocator,
    provider_id: Slug,
    channel_id: Slug,
    offer_id: OfferId,
    transport: types.ProviderKind,
    openai_protocol: types.OpenAIProtocol,
    protocol_id: []const u8,
    /// Owned.
    endpoint_url: []u8,
    /// Owned. Exactly what goes on the wire.
    request_model_id: []u8,
    /// Owned. Display identity only.
    display_name: []u8,
    /// Owned. Region and plan of the selected channel, shown in setup output
    /// before any request is sent. Null when the channel declares none.
    region: ?[]u8,
    plan: ?[]u8,
    auth_scheme: credential.AuthScheme,
    limits: offer_mod.EffectiveLimits,
    capabilities: offer_mod.CapabilityMatrix,
    /// True when the model was supplied by the user and is not in the
    /// profile's declared inventory: the route is real, the metadata unknown.
    model_from_user: bool,

    pub fn deinit(self: *StartupRoute) void {
        self.allocator.free(self.endpoint_url);
        self.allocator.free(self.request_model_id);
        self.allocator.free(self.display_name);
        if (self.region) |value| self.allocator.free(value);
        if (self.plan) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const Failure = union(enum) {
    unknown_provider: []const u8,
    unknown_channel: []const u8,
    unknown_offer: []const u8,
    /// `--offer` and `--channel` name different routes. Silently honouring one
    /// would ignore an explicit user instruction.
    offer_channel_conflict: struct { offer_channel: Slug, requested_channel: Slug },
    /// The model matches several routes; the samples say which.
    ambiguous_model: selection_mod.Ambiguity,
    endpoint_rejected: profile_mod.EndpointError,
    /// The offer's protocol has no built-in transport (a custom protocol needs
    /// a registered adapter). Reported instead of quietly falling back.
    unsupported_protocol: []const u8,
    no_route,

    /// One line the CLI can print verbatim. Caller frees.
    pub fn message(self: Failure, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .unknown_provider => |name| std.fmt.allocPrint(
                allocator,
                "unknown provider '{s}'; run with a registered provider id or alias",
                .{name},
            ),
            .unknown_channel => |name| std.fmt.allocPrint(
                allocator,
                "unknown channel '{s}' for the selected provider",
                .{name},
            ),
            .unknown_offer => |name| std.fmt.allocPrint(
                allocator,
                "offer '{s}' is not in the current catalog",
                .{name},
            ),
            .offer_channel_conflict => |conflict| std.fmt.allocPrint(
                allocator,
                "--offer names a route on channel '{s}' but --channel says '{s}'; drop one",
                .{ conflict.offer_channel.slice(), conflict.requested_channel.slice() },
            ),
            .ambiguous_model => |ambiguity| blk: {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, "model matches several routes; select one with --channel or --offer:");
                for (ambiguity.samplesSlice()) |sample| {
                    const text = try std.fmt.allocPrint(allocator, "\n  {s}/{s} [{s}] {s}", .{
                        sample.provider_id.slice(),
                        sample.channel_id.slice(),
                        sample.protocol,
                        &sample.offer_id.render(),
                    });
                    defer allocator.free(text);
                    try out.appendSlice(allocator, text);
                }
                break :blk out.toOwnedSlice(allocator);
            },
            .unsupported_protocol => |protocol| std.fmt.allocPrint(
                allocator,
                "protocol '{s}' has no built-in transport; register an adapter for it",
                .{protocol},
            ),
            .endpoint_rejected => |err| std.fmt.allocPrint(
                allocator,
                "the --base-url override is not valid for this provider route: {s}",
                .{@errorName(err)},
            ),
            .no_route => allocator.dupe(u8, "the selected provider exposes no usable route"),
        };
    }
};

pub const Outcome = union(enum) {
    route: StartupRoute,
    failure: Failure,
};

pub const ResolveError = error{OutOfMemory};

const OwnError = ResolveError || error{UnsupportedProtocolTransport};

/// Resolve one startup route.
///
/// Order of specificity: an explicit `--offer` pins exactly; otherwise the
/// provider (plus optional channel) narrows the catalog and the model selects
/// within it. A model the profile does not declare still routes — with unknown
/// metadata — because proxies legitimately accept private model names.
pub fn resolve(
    allocator: std.mem.Allocator,
    registry: *const ProviderRegistry,
    request: StartupRequest,
) ResolveError!Outcome {
    const provider_name = request.provider orelse return .{ .failure = .no_route };
    const profile = registry.find(provider_name) orelse
        return .{ .failure = .{ .unknown_provider = provider_name } };

    var channel_filter: ?Slug = null;
    if (request.channel) |name| {
        const parsed = Slug.parse(name) catch
            return .{ .failure = .{ .unknown_channel = name } };
        if (profile.channel(parsed) == null)
            return .{ .failure = .{ .unknown_channel = name } };
        channel_filter = parsed;
    }

    var overrides: [1]registry_mod.EndpointOverride = undefined;
    var override_slice: []const registry_mod.EndpointOverride = &.{};
    if (request.base_url) |url| {
        overrides[0] = .{
            .provider_id = profile.id,
            .channel_id = channel_filter,
            .base_url = url,
        };
        override_slice = overrides[0..1];
    }

    var catalog = registry.buildCatalog(allocator, .{
        .only_provider = profile.id,
        .endpoint_overrides = override_slice,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.IncomparableTokenUnits => return .{ .failure = .no_route },
        else => return .{ .failure = .{ .endpoint_rejected = @errorCast(err) } },
    };
    defer catalog.deinit();

    if (request.offer_id) |text| {
        const parsed = OfferId.parse(text) catch
            return .{ .failure = .{ .unknown_offer = text } };
        const found = catalog.find(parsed) orelse
            return .{ .failure = .{ .unknown_offer = text } };
        if (channel_filter) |wanted| {
            if (!found.channel_id.eql(wanted)) return .{ .failure = .{ .offer_channel_conflict = .{
                .offer_channel = found.channel_id,
                .requested_channel = wanted,
            } } };
        }
        return ownOrFail(allocator, profile, found, false);
    }

    if (request.model) |model| {
        var matches: usize = 0;
        var only: ?*const offer_mod.ModelOffer = null;
        var ambiguity = selection_mod.Ambiguity{ .match_count = 0 };
        for (catalog.items()) |*candidate| {
            if (channel_filter) |wanted| {
                if (!candidate.channel_id.eql(wanted)) continue;
            }
            if (!registry_mod.matchesSelector(candidate.*, model)) continue;
            matches += 1;
            ambiguity.match_count +|= 1;
            if (ambiguity.sample_len < selection_mod.MAX_AMBIGUITY_SAMPLES) {
                ambiguity.samples[ambiguity.sample_len] = .{
                    .offer_id = candidate.offer_id,
                    .provider_id = candidate.provider_id,
                    .channel_id = candidate.channel_id,
                    .protocol = candidate.protocol,
                };
                ambiguity.sample_len += 1;
            }
            if (only == null) only = candidate;
        }
        if (matches == 1) return ownOrFail(allocator, profile, only.?, false);
        if (matches > 1) return .{ .failure = .{ .ambiguous_model = ambiguity } };
        // Unlisted model: keep the user's exact string on a declared channel.
        const base = try defaultOffer(&catalog, profile, channel_filter) orelse
            return .{ .failure = .no_route };
        const owned = try ownOrFail(allocator, profile, base, true);
        if (owned == .failure) return owned;
        var route = owned.route;
        allocator.free(route.request_model_id);
        route.request_model_id = try allocator.dupe(u8, model);
        allocator.free(route.display_name);
        route.display_name = try allocator.dupe(u8, model);
        route.limits = .{};
        route.capabilities = .{};
        return .{ .route = route };
    }

    const base = try defaultOffer(&catalog, profile, channel_filter) orelse
        return .{ .failure = .no_route };
    return ownOrFail(allocator, profile, base, false);
}

fn ownOrFail(
    allocator: std.mem.Allocator,
    profile: *const profile_mod.ProviderProfile,
    offer: *const offer_mod.ModelOffer,
    model_from_user: bool,
) ResolveError!Outcome {
    const route = own(allocator, profile, offer, model_from_user) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedProtocolTransport => return .{
            .failure = .{ .unsupported_protocol = offer.protocol },
        },
    };
    return .{ .route = route };
}

fn defaultOffer(
    catalog: *const registry_mod.OfferCatalog,
    profile: *const profile_mod.ProviderProfile,
    channel_filter: ?Slug,
) ResolveError!?*const offer_mod.ModelOffer {
    const wanted = channel_filter orelse
        (if (profile.defaultChannel()) |descriptor| descriptor.id else null);
    if (wanted) |id| {
        for (catalog.items()) |*candidate| {
            if (candidate.channel_id.eql(id)) return candidate;
        }
    }
    if (catalog.items().len == 0) return null;
    return &catalog.items()[0];
}

fn own(
    allocator: std.mem.Allocator,
    profile: *const profile_mod.ProviderProfile,
    offer: *const offer_mod.ModelOffer,
    model_from_user: bool,
) OwnError!StartupRoute {
    // No silent fallback: a protocol without a built-in transport must surface
    // as an error, not quietly become the Anthropic wire.
    const protocol = profile_mod.Protocol.parse(offer.protocol) orelse
        return error.UnsupportedProtocolTransport;
    const transport = try registry_mod.transportKindFor(protocol);
    const openai_protocol = switch (transport) {
        .openai => try registry_mod.openAiProtocolFor(protocol),
        else => types.OpenAIProtocol.chat_completions,
    };

    const endpoint = try allocator.dupe(u8, offer.endpoint_ref);
    errdefer allocator.free(endpoint);
    const model = try allocator.dupe(u8, offer.request_model_id);
    errdefer allocator.free(model);
    const display = try allocator.dupe(u8, offer.display_name);
    errdefer allocator.free(display);
    const region = if (offer.region) |value| try allocator.dupe(u8, value) else null;
    errdefer if (region) |value| allocator.free(value);
    const plan = if (offer.plan) |value| try allocator.dupe(u8, value) else null;

    return .{
        .allocator = allocator,
        .provider_id = offer.provider_id,
        .channel_id = offer.channel_id,
        .offer_id = offer.offer_id,
        .transport = transport,
        .openai_protocol = openai_protocol,
        .protocol_id = offer.protocol,
        .endpoint_url = endpoint,
        .request_model_id = model,
        .display_name = display,
        .region = region,
        .plan = plan,
        .auth_scheme = profile.auth,
        .limits = offer.limits,
        .capabilities = offer.capabilities,
        .model_from_user = model_from_user,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

test "naming a provider selects its default channel without model-name guessing" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const outcome = try resolve(a, &registry, .{ .provider = "zai-coding-plan" });
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expect(route.channel_id.eqlText("cn-anthropic"));
    try std.testing.expectEqual(types.ProviderKind.anthropic, route.transport);
    try std.testing.expectEqualStrings(
        "https://open.bigmodel.cn/api/anthropic/v1/messages",
        route.endpoint_url,
    );
}

test "an alias reaches the same profile as its id" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try resolve(a, &registry, .{ .provider = "glm-coding-plan" });
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expect(route.provider_id.eqlText("zai-coding-plan"));
}

test "a channel plus model pins one route across protocols" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const outcome = try resolve(a, &registry, .{
        .provider = "zai",
        .channel = "global-openai",
        .model = "glm-4.6",
    });
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expectEqual(types.ProviderKind.openai, route.transport);
    try std.testing.expectEqual(types.OpenAIProtocol.chat_completions, route.openai_protocol);
    try std.testing.expectEqualStrings(
        "https://api.z.ai/api/coding/paas/v4/chat/completions",
        route.endpoint_url,
    );
    try std.testing.expectEqualStrings("glm-4.6", route.request_model_id);
}

test "an ambiguous model reports the candidate routes instead of guessing" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try resolve(a, &registry, .{ .provider = "zai", .model = "glm-4.6" });
    try std.testing.expect(outcome == .failure);
    try std.testing.expectEqual(@as(u16, 4), outcome.failure.ambiguous_model.match_count);
    const text = try outcome.failure.message(a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "--channel") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cn-anthropic") != null);
}

test "an explicit offer id pins without any ambiguity" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    var catalog = try registry.buildCatalog(a, .{ .only_provider = Slug.lit("zai-coding-plan") });
    defer catalog.deinit();
    const wanted = catalog.items()[3];
    const rendered = wanted.offer_id.render();

    const outcome = try resolve(a, &registry, .{ .provider = "zai", .offer_id = &rendered });
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expect(route.offer_id.eql(wanted.offer_id));
    try std.testing.expectEqualStrings(wanted.endpoint_ref, route.endpoint_url);
}

test "a private model name still routes, with metadata left unknown" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try resolve(a, &registry, .{
        .provider = "zai",
        .channel = "cn-openai",
        .model = "glm-internal-preview",
    });
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expectEqualStrings("glm-internal-preview", route.request_model_id);
    try std.testing.expect(route.model_from_user);
    // Unknown metadata stays unknown, so admission fails closed rather than
    // inheriting another model's limits.
    try std.testing.expectEqual(@as(?u32, null), route.limits.context_window);
    try std.testing.expectEqual(offer_mod.Tri.unknown, route.capabilities.get(.tools));
}

test "a base-url override is validated against the profile before use" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const rejected = try resolve(a, &registry, .{
        .provider = "zai",
        .channel = "cn-openai",
        .base_url = "https://open.bigmodel.cn/api/paas/v4",
    });
    try std.testing.expect(rejected == .failure);
    try std.testing.expectEqual(
        profile_mod.EndpointError.ForbiddenEndpointPath,
        rejected.failure.endpoint_rejected,
    );

    const accepted = try resolve(a, &registry, .{
        .provider = "zai",
        .channel = "cn-openai",
        .base_url = "https://relay.internal/api/coding/paas/v4",
    });
    var route = accepted.route;
    defer route.deinit();
    try std.testing.expectEqualStrings(
        "https://relay.internal/api/coding/paas/v4/chat/completions",
        route.endpoint_url,
    );
}

test "unknown provider and channel names fail with actionable messages" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const bad_provider = try resolve(a, &registry, .{ .provider = "not-a-vendor" });
    try std.testing.expect(bad_provider == .failure);
    const provider_text = try bad_provider.failure.message(a);
    defer a.free(provider_text);
    try std.testing.expect(std.mem.indexOf(u8, provider_text, "not-a-vendor") != null);

    const bad_channel = try resolve(a, &registry, .{ .provider = "zai", .channel = "eu-openai" });
    try std.testing.expect(bad_channel == .failure);
    const channel_text = try bad_channel.failure.message(a);
    defer a.free(channel_text);
    try std.testing.expect(std.mem.indexOf(u8, channel_text, "eu-openai") != null);
}

test "the route outlives the catalog it was resolved from" {
    const a = std.testing.allocator;
    var route: StartupRoute = undefined;
    {
        var registry = try ProviderRegistry.initWithBuiltins(a);
        defer registry.deinit();
        const outcome = try resolve(a, &registry, .{ .provider = "metask" });
        route = outcome.route;
    }
    defer route.deinit();
    try std.testing.expectEqualStrings("https://napi.metask-ai.com/v1/messages", route.endpoint_url);
}

test "a protocol with no built-in transport fails instead of falling back" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();

    const models = [_]profile_mod.ModelEntry{.{
        .request_model_id = "vendor-m1",
        .display_name = "Vendor M1",
    }};
    const routes = [_]profile_mod.ProtocolRoute{.{
        .protocol = .{ .custom = .{ .id = "vendor_v2", .path_suffix = "/v2/generate" } },
    }};
    const channels = [_]profile_mod.ChannelDescriptor{.{
        .id = Slug.lit("only"),
        .display_name = "Vendor",
        .base_url = "https://vendor.test/api",
        .routes = &routes,
    }};
    const kinds = [_]credential.CredentialKind{.api_key};
    try registry.register(.{
        .id = Slug.lit("novel-wire"),
        .implementation_id = Slug.lit("declarative_http"),
        .display_name = "Novel wire vendor",
        .channels = &channels,
        .models = &models,
        .accepted_credential_kinds = &kinds,
    });

    const outcome = try resolve(a, &registry, .{ .provider = "novel-wire" });
    try std.testing.expect(outcome == .failure);
    try std.testing.expectEqualStrings("vendor_v2", outcome.failure.unsupported_protocol);
    const text = try outcome.failure.message(a);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "no built-in transport") != null);
}

test "a resolved route carries the region and plan setup output must show" {
    const a = std.testing.allocator;
    var registry = try ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try resolve(a, &registry, .{
        .provider = "zai-coding-plan",
        .channel = "global-openai",
    });
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expectEqualStrings("global", route.region.?);
    try std.testing.expectEqualStrings("coding", route.plan.?);
    try std.testing.expectEqualStrings("openai_chat", route.protocol_id);

    // Providers without a region declare none rather than inventing one.
    const metask = try resolve(a, &registry, .{ .provider = "metask" });
    var plain = metask.route;
    defer plain.deinit();
    try std.testing.expect(plain.region == null);
    try std.testing.expect(plain.plan == null);
}
